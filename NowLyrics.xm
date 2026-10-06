//
//  NowLyrics.xm
//  Synced lyrics on the lock screen, Control Center, Dynamic Island and CarPlay.
//
//  This file holds the hooks and the two ways of publishing. The engine that
//  decides what to show lives in NLEngine.m; see NowLyrics.h for the layout.
//
//  For third-party players the only thing hooked is
//  -[MPNowPlayingInfoCenter setNowPlayingInfo:], a public MediaPlayer API that
//  every such player calls to publish now-playing metadata. Nothing in the host
//  app's own (obfuscated) class hierarchy is touched, so app updates rarely
//  break this.
//
//  Apple's own Music app never calls that method: it hands MediaPlayer an
//  MPNowPlayingContentItem and MediaRemote reads the metadata out of that
//  object. For it the item itself is edited instead, see "Content items".
//

#import "NowLyrics.h"
#import "NLStoreLyrics.h"
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>
#import <pthread.h>

#pragma mark - Private MediaPlayer API

// Only what is touched is declared; the class itself is resolved at runtime.
@interface MPNowPlayingContentItem : MPContentItem
@property (nonatomic, copy) NSString *trackArtistName;
@property (nonatomic, copy) NSString *albumName;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) double elapsedTime;
@property (nonatomic, assign) float playbackRate;
@property (nonatomic, readonly) double calculatedElapsedTime;
@property (nonatomic, assign, getter=isExplicitItem) BOOL explicitItem;
- (void)setElapsedTime:(double)elapsedTime playbackRate:(float)playbackRate;
@end

#pragma mark - State

static BOOL gEnabled = NO;            // mirror of NLSettingsCurrent().enabled; safe to read from any thread
static BOOL gContentItemMode = NO;    // decided once, in %ctor
static BOOL gHooksInstalled = NO;

// Dictionary path. Main queue only.
static MPNowPlayingInfoCenter *gCenter = nil;
static NSDictionary *gBaseInfo = nil;   // last dictionary the player gave us
static BOOL gBypass = NO;               // set while we push our own update (main queue)
static NSDictionary *gPushedBase = nil; // gBaseInfo as of our last push
static NSString *gPushedTitle = nil;
static NSString *gPushedArtist = nil;
static double gPushedElapsed = -1;      // the elapsed time our last push carried

// Content-item path. The item is main-queue state; the raw pointer is a mirror
// the hooks may compare against from whatever thread the app happens to be on.
static MPNowPlayingContentItem *gMusicItem = nil;
static void *gMusicItemPtr = NULL;
static volatile int gIngestQueued = 0;   // one main-queue ingest already on its way
static BOOL gWritingItem = NO;           // main queue: we are the ones changing the item

#pragma mark - Dictionary path (third-party players)

// What the player reported, with the rewrites the system must never see the raw
// version of. Returns `info` itself when there is nothing to change.
static NSDictionary *NLCleanInfo(NSDictionary *info) {
    NLSettings *settings = NLSettingsCurrent();
    NSMutableDictionary *clean = nil;

    // Spotify Connect reports "Title • Artist" / "Playing on X": the real pair.
    NSString *realT = nil, *realA = nil;
    if (settings.spotifyConnect &&
        NLSplitConnectInfo(info[MPMediaItemPropertyTitle], info[MPMediaItemPropertyArtist], &realT, &realA)) {
        clean = [info mutableCopy];
        clean[MPMediaItemPropertyTitle] = realT;
        clean[MPMediaItemPropertyArtist] = realA;
    }
    // The system draws an "E" after the title for explicit tracks, and the
    // title is a lyric line now.
    if (settings.hideExplicit && [info[MPMediaItemPropertyIsExplicit] boolValue]) {
        if (!clean) clean = [info mutableCopy];
        clean[MPMediaItemPropertyIsExplicit] = @NO;
    }
    return clean ? [clean copy] : info;
}

// MPNowPlayingInfoCenter sends a third-party app's info at most every half
// second: a set within 0.5 s of the last send waits a full 0.5 s, then goes
// with the elapsed time it was given, and MediaRemote stamps it with when it
// arrives. The position everyone reads (the island's word timing runs on it)
// was 0.5 s behind until the next update, and our line changes often come
// right after the player's own update. The last send is forgotten first, on
// the center's own queue (ahead of the set, which queues behind it), so ours
// goes at once. 16.5.1: -_onQueue_pushNowPlayingInfoAndRetry:, _pushDate;
// system apps are exempt.
static void NLLiftPushThrottle(MPNowPlayingInfoCenter *center) {
    static Ivar pushDate, accessQueue;
    static Class queueClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Ivar date = class_getInstanceVariable(MPNowPlayingInfoCenter.class, "_pushDate");
        Ivar queue = class_getInstanceVariable(MPNowPlayingInfoCenter.class, "_accessQueue");
        const char *dateType = date ? ivar_getTypeEncoding(date) : NULL, *queueType = queue ? ivar_getTypeEncoding(queue) : NULL;
        if (dateType && dateType[0] == '@' && queueType && queueType[0] == '@') {
            pushDate = date;
            accessQueue = queue;
        }
        queueClass = objc_getClass("OS_dispatch_queue");
    });
    if (!pushDate || !center) return;
    id queue = object_getIvar(center, accessQueue);
    if (![queue isKindOfClass:queueClass]) return;
    dispatch_barrier_async((dispatch_queue_t)queue, ^{ object_setIvar(center, pushDate, nil); });
}

static void NLPushInfo(NSDictionary *info) {
    gBypass = YES;
    NLLiftPushThrottle(gCenter);
    gCenter.nowPlayingInfo = info;
    gBypass = NO;
}

// `info` with the elapsed time as of now: pushed with the player's own, the
// scrubber would jump back.
static NSMutableDictionary *NLInfoNow(NSDictionary *info) {
    NSMutableDictionary *now = [info mutableCopy];
    now[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(NLEnginePosition());
    return now;
}

static void NLPublishInfo(NSString *title, NSString *artist) {
    if (!gCenter || gBaseInfo.count == 0) return;
    // A flip during a long gap, or a settings change that moved nothing:
    // the system already shows exactly this.
    if (gBaseInfo == gPushedBase && NLSame(title, gPushedTitle) && NLSame(artist, gPushedArtist)) return;

    NSMutableDictionary *info = NLInfoNow(gBaseInfo);
    if (title) info[MPMediaItemPropertyTitle] = title;
    if (artist) info[MPMediaItemPropertyArtist] = artist;
    gPushedBase = gBaseInfo;
    gPushedTitle = title;
    gPushedArtist = artist;
    gPushedElapsed = [info[MPNowPlayingInfoPropertyElapsedPlaybackTime] doubleValue];
    NLPushInfo(info);
}

// `value` is what our last push put there (and that was not empty).
static BOOL NLIsPushed(id value, NSString *pushed) {
    return pushed.length && [value isKindOfClass:NSString.class] && [value isEqualToString:pushed];
}

// Some apps read nowPlayingInfo back, edit it and push it again. What they
// read is our last push, elapsed time included, which by then is old: taken
// as news it would set the clock back by however long ago that push was, and
// lines and words would run that much late until the player next reported a
// position itself. Main queue.
static BOOL NLIsOwnEcho(NSDictionary *info) {
    if (gPushedElapsed < 0 || NLNum(info[MPNowPlayingInfoPropertyElapsedPlaybackTime], -1) != gPushedElapsed) return NO;
    NSString *title = info[MPMediaItemPropertyTitle], *artist = info[MPMediaItemPropertyArtist];
    return NLIsPushed(title, gPushedTitle) || NLIsPushed(artist, gPushedArtist);
}

// Switched off: put the player's own title back now instead of leaving the
// last line up until the player happens to publish again, and forget its
// info, which goes stale while nothing is listening.
static void NLRestoreInfo(void) {
    if (gCenter && gBaseInfo.count) NLPushInfo(NLInfoNow(gBaseInfo));
    gBaseInfo = nil;
    gPushedBase = nil;
    gPushedTitle = nil;
    gPushedArtist = nil;
    gPushedElapsed = -1;
}

// Main queue. `ownEcho`: the hook already found this to be our own last push
// read back (and gave the system the current position instead).
static void NLIngestInfo(MPNowPlayingInfoCenter *center, NSDictionary *info, BOOL ownEcho) {
    gCenter = center;

    NSString *title = info[MPMediaItemPropertyTitle];
    NSString *artist = info[MPMediaItemPropertyArtist];
    NSString *album = info[MPMediaItemPropertyAlbumTitle];
    NSTimeInterval duration = [info[MPMediaItemPropertyPlaybackDuration] doubleValue];
    NSNumber *elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime];
    NSNumber *rate = info[MPNowPlayingInfoPropertyPlaybackRate];
    if (ownEcho || NLIsOwnEcho(info)) elapsed = nil;   // the clock keeps running instead

    // Some apps read nowPlayingInfo back, edit it and push it again. That would
    // feed our lyric line back as the track title and trigger a refetch on every
    // line, so restore the real values first.
    NSString *realTitle = NLEngineTrackTitle();
    NSString *realArtist = NLEngineTrackArtist();
    BOOL titleEchoed = NLIsPushed(title, gPushedTitle) && realTitle.length;
    BOOL artistEchoed = NLIsPushed(artist, gPushedArtist) && realArtist.length;
    if (titleEchoed || artistEchoed) {
        NSMutableDictionary *restored = [info mutableCopy];
        if (titleEchoed) { title = realTitle; restored[MPMediaItemPropertyTitle] = realTitle; }
        if (artistEchoed) { artist = realArtist; restored[MPMediaItemPropertyArtist] = realArtist; }
        gBaseInfo = [restored copy];
    } else {
        gBaseInfo = info;
    }

    NLEngineIngest(title, artist, album, duration, elapsed, rate);
}

#pragma mark - Content items (Apple Music)

// Music.app never calls -setNowPlayingInfo:. Its playback engine owns an
// MPNowPlayingContentItem, keeps its elapsed time up to date, and MediaRemote
// reads title, artist and progress straight out of that object. So the lyric
// line goes into the item's own title, the way AMLyrics does it, and MediaPlayer
// republishes because a property changed.

// What the app put on the item versus what we last wrote there. Kept on the
// item itself, so a copy handed back by MediaPlayer can still be told apart
// from a new track.
static char kNLRealTitleKey, kNLRealArtistKey, kNLPushedTitleKey, kNLPushedArtistKey;

static NSString *NLItemGet(id item, const void *key) {
    return objc_getAssociatedObject(item, key);
}

static void NLItemSet(id item, const void *key, NSString *value) {
    objc_setAssociatedObject(item, key, value, OBJC_ASSOCIATION_COPY_NONATOMIC);
}

// Anything on the item that is not what we wrote there came from the app and is
// therefore real. Returns the real value known so far.
static NSString *NLItemField(id item, const void *realKey, const void *pushedKey, NSString *current) {
    if (current.length && ![current isEqualToString:NLItemGet(item, pushedKey)]) {
        NLItemSet(item, realKey, current);
        return current;
    }
    return NLItemGet(item, realKey);
}

static double NLItemElapsed(MPNowPlayingContentItem *item) {
    double t = [item respondsToSelector:@selector(calculatedElapsedTime)]
        ? item.calculatedElapsedTime
        : item.elapsedTime;
    return (isnan(t) || t < 0) ? 0 : t;
}

// Main queue. Runs after the app changed something on the current item; the
// engine works out whether that was a new track or just progress.
static void NLIngestItem(MPNowPlayingContentItem *item) {
    if (!item || item != gMusicItem || !gEnabled) return;

    NSString *title = NLItemField(item, &kNLRealTitleKey, &kNLPushedTitleKey, item.title);
    NSString *artist = NLItemField(item, &kNLRealArtistKey, &kNLPushedArtistKey, item.trackArtistName);
    double duration = item.duration;

    // Metadata arrives piecemeal; wait until there is enough to identify the track.
    if (title.length == 0 || isnan(duration) || duration <= 0) return;

    NLEngineIngest(title, artist, item.albumName, duration, @(NLItemElapsed(item)), @(item.playbackRate));
}

// Main queue. MediaPlayer sometimes hands over a copy of the item we already
// decorated; it is recognised by its identifier so the real title survives the
// swap instead of the lyric line being taken for it.
static void NLAdoptItem(MPNowPlayingContentItem *item) {
    if (item == gMusicItem) return;

    MPNowPlayingContentItem *old = gMusicItem;
    if (item && old && old.identifier.length && [item.identifier isEqualToString:old.identifier]) {
        const void *keys[] = { &kNLRealTitleKey, &kNLRealArtistKey, &kNLPushedTitleKey, &kNLPushedArtistKey };
        for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++) {
            NLItemSet(item, keys[i], NLItemGet(old, keys[i]));
        }
    }

    gMusicItem = item;
    gMusicItemPtr = (__bridge void *)item;
    // An item made before the hooks went in (the app started switched off)
    // has its explicit flag set without the setter hook's say; cleared here
    // the way that hook would have. Any other item went through the hook.
    if (gEnabled && NLSettingsCurrent().hideExplicit &&
        [item respondsToSelector:@selector(isExplicitItem)] && item.isExplicitItem) item.explicitItem = NO;
    NLEngineCancelFlip();   // whatever was scheduled belonged to the old item
    NLLog(@"now playing item %p (%@)", item, item.identifier);
    NLIngestItem(item);
}

static void NLAdoptItemLater(MPNowPlayingContentItem *item) {
    dispatch_async(dispatch_get_main_queue(), ^{ NLAdoptItem(item); });
}

// Any thread. A cheap pointer check, then one ingest on the main queue no
// matter how many setters fired in the meantime: a track change touches the
// item several times in a row. Our own writes are skipped; they happen on the
// main queue, and an ingest after them would only find nothing to do.
static void NLItemTouched(id item) {
    if (!gEnabled || !item || (__bridge void *)item != gMusicItemPtr) return;
    if (gWritingItem && pthread_main_np()) return;
    if (__atomic_exchange_n(&gIngestQueued, 1, __ATOMIC_ACQ_REL)) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        __atomic_store_n(&gIngestQueued, 0, __ATOMIC_RELEASE);
        NLIngestItem(gMusicItem);
    });
}

// Any thread. Progress only ever goes to the item being played, so an unknown
// item that is moving is the current one. Paused updates to unknown items are
// ignored: those can be queue housekeeping.
static void NLItemProgressed(id item, float rate) {
    if (!item) return;
    if ((__bridge void *)item == gMusicItemPtr) {
        NLItemTouched(item);
        return;
    }
    if (rate > 0 || gMusicItemPtr == NULL) NLAdoptItemLater((MPNowPlayingContentItem *)item);
}

// Whether the field has to be written: either we want a value the item does not
// show, or we want nothing while it still shows something of ours.
static BOOL NLItemNeedsWrite(id item, NSString *want, NSString *current, const void *pushedKey) {
    if (want.length) return ![want isEqualToString:current];
    return current.length && [current isEqualToString:NLItemGet(item, pushedKey)];
}

// Main queue. nil puts the app's own value back. Nothing is written when the
// item already shows what we want, which is what stops the change notifications
// this raises from feeding back into another publish.
static void NLPublishItem(NSString *title, NSString *artist) {
    MPNowPlayingContentItem *item = gMusicItem;
    if (!item) return;

    NSString *wantTitle = title ?: NLItemGet(item, &kNLRealTitleKey);
    NSString *wantArtist = artist ?: NLItemGet(item, &kNLRealArtistKey);
    BOOL writeTitle = NLItemNeedsWrite(item, wantTitle, item.title, &kNLPushedTitleKey);
    BOOL writeArtist = NLItemNeedsWrite(item, wantArtist, item.trackArtistName, &kNLPushedArtistKey);
    if (!writeTitle && !writeArtist) return;

    // Recorded first, so these are seen as ours and not as a new track.
    gWritingItem = YES;
    if (writeTitle) {
        NLItemSet(item, &kNLPushedTitleKey, wantTitle);
        item.title = wantTitle;
    }
    if (writeArtist) {
        NLItemSet(item, &kNLPushedArtistKey, wantArtist);
        item.trackArtistName = wantArtist;
    }

    // MediaRemote is told by the change notification -setTitle: and
    // -setTrackArtistName: post. MediaPlayer drops this same-value set (16.5
    // always, 18 and 26 once the item has been set once), so it moves
    // nothing; it is kept as a harmless nudge.
    [item setElapsedTime:NLItemElapsed(item) playbackRate:item.playbackRate];
    gWritingItem = NO;
}

#pragma mark - Apple Music's own lyrics

// The playing song's catalog ID, from the content item; 0 if it has none (a
// file of your own, say).
static long long NLItemAdamID(MPNowPlayingContentItem *item) {
    for (NSString *key in @[@"lyricsAdamID", @"storeID"]) {
        id value = nil;
        @try { value = [item valueForKey:key]; } @catch (NSException *e) { value = nil; }
        long long adamID = [value respondsToSelector:@selector(longLongValue)] ? [value longLongValue] : 0;
        if (adamID > 0) return adamID;
    }
    return 0;
}

// Fetch queue. What Music's own lyrics view shows: the storefront's text
// (Traditional Chinese in Taiwan) and, where Apple has it, word timing, as
// TTML. The item is read on the main queue, where it lives; the store answers
// on a queue of its own.
NSString *NLAppleMusicLyrics(NSString *title, NSTimeInterval timeout) {
    NSMutableArray<NSString *> *box = [NSMutableArray array];   // the answer, under @synchronized
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        MPNowPlayingContentItem *item = gMusicItem;
        // The real title, not the lyric line the item shows by now.
        NSString *real = NLItemGet(item, &kNLRealTitleKey) ?: item.title;
        long long adamID = [real isEqualToString:title] ? NLItemAdamID(item) : 0;
        NLLog(@"Apple Music lyrics: adam ID %lld", adamID);
        BOOL asked = adamID > 0 && NLAskStoreLyrics(adamID, ^(NSString *text, id response, NSError *error) {
            if (error) NLLog(@"Apple Music store lyrics error: %@", error);
            if (NLStoreLyricsFailed(error)) NLPostDarwin(NL_AM_FAILED_NOTIFICATION);   // SpringBoard checks the subscription
            @synchronized (box) {
                if (text) [box addObject:[text copy]];
            }
            dispatch_semaphore_signal(done);
        });
        if (!asked) dispatch_semaphore_signal(done);   // another track, or not from the catalog
    });
    dispatch_semaphore_wait(done, NLTimeIn(timeout));
    @synchronized (box) {
        return box.firstObject;
    }
}

#pragma mark - Publishing

void NLPublish(NSString *title, NSString *artist) {
    if (gContentItemMode) NLPublishItem(title, artist);
    else NLPublishInfo(title, artist);
}

void NLPublishRestore(void) {
    if (gContentItemMode) NLPublishItem(nil, nil);
    else NLRestoreInfo();
}

// "Hide explicit badge" just went on, or the app was just switched on with it
// on. New info is cleaned on its way in; this is for what the player
// published before (which went through untouched while switched off).
static void NLHideExplicitNow(void) {
    if (gContentItemMode) {
        MPNowPlayingContentItem *item = gMusicItem;
        if ([item respondsToSelector:@selector(isExplicitItem)] && item.isExplicitItem) item.explicitItem = NO;
    } else if (gBaseInfo) {
        gBaseInfo = NLCleanInfo(gBaseInfo);
    }
}

#pragma mark - Hooks

%group NLHooks

%hook MPNowPlayingInfoCenter

// %orig must be alone on its line. Written as `if (x) { %orig; return; }` logos
// swallows everything after %orig on that line, closing brace included.
- (void)setNowPlayingInfo:(NSDictionary *)nowPlayingInfo {
    // gBypass only marks our own push, which is always on the main queue; an
    // app publishing from another thread meanwhile is still the app.
    if (!gEnabled || (gBypass && pthread_main_np())) {
        %orig;
        return;
    }

    // Let the original call through untouched, then push the decorated version
    // from the main queue. That way the caller's thread does not matter.
    NSDictionary *snapshot = [nowPlayingInfo copy];
    MPNowPlayingInfoCenter *center = self;

    // Cleaned before the system sees it; otherwise the raw values show for a
    // moment at every track change until our first push lands.
    snapshot = NLCleanInfo(snapshot);
    // Our own push read back: the system gets the position as of now, not as
    // of that push. Only on the main queue, which our state belongs to;
    // elsewhere the ingest finds it and pushes the right one right after.
    BOOL ownEcho = pthread_main_np() && NLIsOwnEcho(snapshot);
    if (ownEcho) snapshot = [NLInfoNow(snapshot) copy];
    %orig(snapshot);

    dispatch_async(dispatch_get_main_queue(), ^{
        NLIngestInfo(center, snapshot, ownEcho);
    });
}

%end

%end

%group NLMusicHooks

%hook MPNowPlayingInfoCenter

// Progress updates are the primary signal for which item is current (below);
// these two only seed it, in case the first thing the app does is announce
// the item without moving it.
- (void)setNowPlayingContentItem:(MPNowPlayingContentItem *)item {
    %orig;
    if (item && gMusicItemPtr == NULL) NLAdoptItemLater(item);
}

- (MPNowPlayingContentItem *)nowPlayingContentItem {
    MPNowPlayingContentItem *item = %orig;
    if (item && gMusicItemPtr == NULL) NLAdoptItemLater(item);
    return item;
}


%end

// -setTitle: is implemented by the superclass, so it is hooked there.
%hook MPContentItem

- (void)setTitle:(NSString *)title {
    %orig;
    NLItemTouched(self);
}

%end

%hook MPNowPlayingContentItem

// Music's explicit flag, the "E" after the title. Cleared on the way in when
// the setting is on; MediaRemote reads it straight off the item. Switched
// off, it goes through as it is, like everything else.
- (void)setExplicitItem:(BOOL)explicitItem {
    %orig(explicitItem && !(gEnabled && NLSettingsCurrent().hideExplicit));
}

- (void)setTrackArtistName:(NSString *)name {
    %orig;
    NLItemTouched(self);
}

- (void)setDuration:(double)duration {
    %orig;
    NLItemTouched(self);
}

- (void)setPlaybackRate:(float)rate {
    %orig;
    NLItemTouched(self);
}

- (void)setElapsedTime:(double)elapsed {
    %orig;
    NLItemProgressed(self, self.playbackRate);
}

- (void)setElapsedTime:(double)elapsed playbackRate:(float)rate {
    %orig;
    NLItemProgressed(self, rate);
}

// Not present on every iOS version; ellekit skips a selector it cannot find.
- (void)setElapsedTime:(double)elapsed playbackRate:(float)rate timestamp:(double)timestamp {
    %orig;
    NLItemProgressed(self, rate);
}

%end

%end

// Hooking happens once. Whether we act is decided at runtime through gEnabled,
// so switching off needs no unhooking (and there is no way to unhook anyway).
// Which group goes in depends on how the app publishes, see NLProcessUsesContentItems().
static void NLInstallHooks(void) {
    if (gHooksInstalled) return;
    gHooksInstalled = YES;
    if (gContentItemMode) {
        %init(NLMusicHooks);
    } else {
        %init(NLHooks);
    }
}

#pragma mark - Preference changes

static void NLPrefsChanged(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NLSettings *old = NLSettingsCurrent();
    NLSettings *now = NLSettingsReload();

    dispatch_async(dispatch_get_main_queue(), ^{
        gEnabled = now.enabled;
        if (gEnabled) NLInstallHooks();   // just switched on, hook now

        // Files only need checking after a new "Clear lyrics cache" tap, or
        // when this app was off at the time of one.
        BOOL clearDue = gEnabled && (now.cacheClearedAt != old.cacheClearedAt || !old.enabled);
        BOOL forget = ![old.sourceSignature isEqualToString:now.sourceSignature] ||
                      (clearDue && NLClearCacheIfRequested(now.cacheClearedAt));
        if (forget) NLEngineForgetLyrics();   // also looks the current track up again
        if (gEnabled && now.hideExplicit && !(old.enabled && old.hideExplicit)) NLHideExplicitNow();

        if (!gEnabled) {
            if (old.enabled) {
                NLEngineCancelFlip();
                NLPublishRestore();   // put the app's own title back
            }
        } else if (gContentItemMode && !old.enabled) {
            if (gMusicItem) NLIngestItem(gMusicItem);   // ignored while switched off, so read it now
        } else if (!forget) {
            NLEnginePushUpdate();   // e.g. offset moved: redraw without waiting for the player
        }

        NLLog(@"preferences reloaded, enabled %d → %d", old.enabled, now.enabled);

        // Only for a change this app acts on: the settings page and SpringBoard
        // also write values only they read (whether Apple Music is unlocked,
        // which SpringBoard keeps in step, the library's filter, the island's
        // options), and every write posts this same notification. Nor for
        // Apple Music locked, which switches it off too: SpringBoard does that
        // by itself when the subscription lapses (NLAppleMusicSB.x), likely
        // while this app plays, and it is no change made in Settings. The app
        // goes on with the other sources (`forget` above).
        BOOL locked = old.useAppleMusic && !now.useAppleMusic && !now.appleMusicVerified;
        if (now.killOnChange && !locked && (now.enabled || old.enabled) && ![now sameEffectAs:old]) {
            exit(0);
        }
    });
}

// The settings page changed lyrics files (added, edited, deleted, asked for a
// new search): forget what is held in memory, so the current track is looked
// up again on disk and, if its file is gone, online.
static void NLLyricsChanged(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        // The settings page often wrote a setting just before (a source picked
        // for this song); the file on disk may only have caught up now, after
        // the reload notification that came with it. Read it again first, with
        // the pick the page left beside nowplaying.plist (NL_LOOKUP_FILE) on
        // top, which holds even when the file has not caught up yet.
        static CFAbsoluteTime lastLookup = 0;
        NSString *lookupPath = [[NLNowPlayingPath() stringByDeletingLastPathComponent] stringByAppendingPathComponent:NL_LOOKUP_FILE];
        NSDictionary *lookup = [NSDictionary dictionaryWithContentsOfFile:lookupPath];
        double stamp = NLLooseNum(lookup[NL_LOOKUP_STAMP], 0);
        NSString *key = NLString(lookup, NL_LOOKUP_KEY);
        BOOL fresh = stamp > lastLookup && CFAbsoluteTimeGetCurrent() - stamp < 30 && key;
        NLSettings *now;
        if (fresh) {
            lastLookup = stamp;
            now = NLSettingsReloadPicking(key, NLString(lookup, NL_LOOKUP_SOURCE) ?: @"");
        } else {
            now = NLSettingsReload();
        }
        gEnabled = now.enabled;
        if (!gEnabled) return;   // switching on looks the track up anyway
        NLLog(@"lyrics files changed, looking the track up again");
        NLEngineForgetLyrics();
    });
}

#pragma mark - Entry point

%ctor {
    @autoreleasepool {
        if (!NLProcessIsEligible()) return;

        gContentItemMode = NLProcessUsesContentItems();
        NLEngineStart();
        NLSettings *settings = NLSettingsReload();
        gEnabled = settings.enabled;
        if (gEnabled) NLEngineClearCacheLater(settings.cacheClearedAt);   // a clear tapped while this app was not running

        // Registered even when inactive, so a later switch-on is noticed.
        NLObserveDarwin(NL_RELOAD_NOTIFICATION, NLPrefsChanged, CFNotificationSuspensionBehaviorCoalesce);
        NLObserveDarwin(NL_LYRICS_CHANGED_NOTIFICATION, NLLyricsChanged, CFNotificationSuspensionBehaviorCoalesce);

        NLLog(@"%@ enabled=%d contentItems=%d", [[NSBundle mainBundle] bundleIdentifier], gEnabled, gContentItemMode);

        if (gEnabled) NLInstallHooks();
    }
}
