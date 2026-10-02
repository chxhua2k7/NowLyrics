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
#import <MediaPlayer/MediaPlayer.h>
#import <objc/runtime.h>

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
static BOOL gBypass = NO;               // set while we push our own update
static NSString *gPushedTitle = nil;
static NSString *gPushedArtist = nil;

// Content-item path. The item is main-queue state; the raw pointer is a mirror
// the hooks may compare against from whatever thread the app happens to be on.
static MPNowPlayingContentItem *gMusicItem = nil;
static void *gMusicItemPtr = NULL;
static volatile int gIngestQueued = 0;   // one main-queue ingest already on its way

#pragma mark - Dictionary path (third-party players)

static void NLPublishInfo(NSString *title, NSString *artist) {
    if (!gCenter || gBaseInfo.count == 0) return;

    NSMutableDictionary *info = [gBaseInfo mutableCopy];
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(MAX(NLEnginePosition(), 0));   // otherwise the scrubber jumps back
    if (title) info[MPMediaItemPropertyTitle] = title;
    if (artist) info[MPMediaItemPropertyArtist] = artist;
    if (NLSettingsCurrent().hideExplicit) info[MPMediaItemPropertyIsExplicit] = @NO;   // also when switched on mid-track
    gPushedTitle = title;
    gPushedArtist = artist;

    gBypass = YES;
    gCenter.nowPlayingInfo = info;
    gBypass = NO;
}

// Main queue.
static void NLIngestInfo(MPNowPlayingInfoCenter *center, NSDictionary *info) {
    gCenter = center;

    NSString *title = info[MPMediaItemPropertyTitle];
    NSString *artist = info[MPMediaItemPropertyArtist];
    NSString *album = info[MPMediaItemPropertyAlbumTitle];
    NSTimeInterval duration = [info[MPMediaItemPropertyPlaybackDuration] doubleValue];
    NSNumber *elapsed = info[MPNowPlayingInfoPropertyElapsedPlaybackTime];
    NSNumber *rate = info[MPNowPlayingInfoPropertyPlaybackRate];

    // Some apps read nowPlayingInfo back, edit it and push it again. That would
    // feed our lyric line back as the track title and trigger a refetch on every
    // line, so restore the real values first.
    NSString *realTitle = NLEngineTrackTitle();
    NSString *realArtist = NLEngineTrackArtist();
    BOOL titleEchoed = gPushedTitle.length && [title isEqualToString:gPushedTitle] && realTitle.length;
    BOOL artistEchoed = gPushedArtist.length && [artist isEqualToString:gPushedArtist] && realArtist.length;
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
    NLEngineCancelFlip();   // whatever was scheduled belonged to the old item
    NLLog(@"now playing item %p (%@)", item, item.identifier);
    NLIngestItem(item);
}

// Any thread. A cheap pointer check, then one ingest on the main queue no
// matter how many setters fired in the meantime: a track change touches the
// item several times in a row, and so does our own publish.
static void NLItemTouched(id item) {
    if (!item || (__bridge void *)item != gMusicItemPtr) return;
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
    if (rate > 0 || gMusicItemPtr == NULL) {
        dispatch_async(dispatch_get_main_queue(), ^{ NLAdoptItem((MPNowPlayingContentItem *)item); });
    }
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
    if (NLSettingsCurrent().hideExplicit && [item respondsToSelector:@selector(isExplicitItem)] && item.isExplicitItem) {
        item.explicitItem = NO;
    }
    BOOL writeTitle = NLItemNeedsWrite(item, wantTitle, item.title, &kNLPushedTitleKey);
    BOOL writeArtist = NLItemNeedsWrite(item, wantArtist, item.trackArtistName, &kNLPushedArtistKey);
    if (!writeTitle && !writeArtist) return;

    // Recorded first, so the hooks see these as ours and not as a new track.
    if (writeTitle) {
        NLItemSet(item, &kNLPushedTitleKey, wantTitle);
        item.title = wantTitle;
    }
    if (writeArtist) {
        NLItemSet(item, &kNLPushedArtistKey, wantArtist);
        item.trackArtistName = wantArtist;
    }

    // Re-anchoring the clock is what makes MediaRemote pull the metadata again
    // (AMLyrics does the same). The value is the one the item already
    // extrapolates to, so the progress bar does not move.
    [item setElapsedTime:NLItemElapsed(item) playbackRate:item.playbackRate];
}

#pragma mark - Publishing

void NLPublish(NSString *title, NSString *artist) {
    if (gContentItemMode) NLPublishItem(title, artist);
    else NLPublishInfo(title, artist);
}

// The dictionary path needs nothing: the player's next update overwrites ours.
// A content item keeps whatever we last wrote until we put it back.
void NLPublishRestore(void) {
    if (gContentItemMode) NLPublishItem(nil, nil);
}

#pragma mark - Hooks

%group NLHooks

%hook MPNowPlayingInfoCenter

// %orig must be alone on its line. Written as `if (x) { %orig; return; }` logos
// swallows everything after %orig on that line, closing brace included.
- (void)setNowPlayingInfo:(NSDictionary *)nowPlayingInfo {
    if (!gEnabled || gBypass) {
        %orig;
        return;
    }

    // Let the original call through untouched, then push the decorated version
    // from the main queue. That way the caller's thread does not matter.
    NSDictionary *snapshot = [nowPlayingInfo copy];
    MPNowPlayingInfoCenter *center = self;

    // Both rewrites below happen before the system sees the dictionary;
    // otherwise the raw values show for a moment at every track change until
    // our first push lands. One copy covers both.
    NLSettings *settings = NLSettingsCurrent();
    NSMutableDictionary *clean = nil;

    // Spotify Connect reports "Title • Artist" / "Playing on X": the real pair.
    NSString *realT = nil, *realA = nil;
    if (settings.spotifyConnect &&
        NLSplitConnectInfo(snapshot[MPMediaItemPropertyTitle], snapshot[MPMediaItemPropertyArtist], &realT, &realA)) {
        clean = [snapshot mutableCopy];
        clean[MPMediaItemPropertyTitle] = realT;
        clean[MPMediaItemPropertyArtist] = realA;
    }
    // The system draws an "E" after the title for explicit tracks, and the
    // title is a lyric line now.
    if (settings.hideExplicit && [snapshot[MPMediaItemPropertyIsExplicit] boolValue]) {
        if (!clean) clean = [snapshot mutableCopy];
        clean[MPMediaItemPropertyIsExplicit] = @NO;
    }
    if (clean) snapshot = [clean copy];
    %orig(snapshot);

    dispatch_async(dispatch_get_main_queue(), ^{
        NLIngestInfo(center, snapshot);
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
    if (item && gMusicItemPtr == NULL) {
        dispatch_async(dispatch_get_main_queue(), ^{ NLAdoptItem(item); });
    }
}

- (MPNowPlayingContentItem *)nowPlayingContentItem {
    MPNowPlayingContentItem *item = %orig;
    if (item && gMusicItemPtr == NULL) {
        dispatch_async(dispatch_get_main_queue(), ^{ NLAdoptItem(item); });
    }
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
// the setting is on; MediaRemote reads it straight off the item.
- (void)setExplicitItem:(BOOL)explicitItem {
    %orig(explicitItem && !NLSettingsCurrent().hideExplicit);
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
    BOOL sourcesChanged = ![old.sourceSignature isEqualToString:now.sourceSignature];

    dispatch_async(dispatch_get_main_queue(), ^{
        gEnabled = now.enabled;
        if (gEnabled) NLInstallHooks();   // just switched on, hook now

        if (sourcesChanged) NLEngineForgetLyrics();
        else if (gEnabled && NLClearCacheIfRequested(now.cacheClearedAt)) NLEngineForgetLyrics();

        if (!gEnabled) {
            if (old.enabled) {
                NLEngineCancelFlip();
                NLPublishRestore();   // the app will not put its title back by itself
            }
        } else if (gContentItemMode) {
            if (gMusicItem) NLIngestItem(gMusicItem);   // re-reads the item: refetches, or just redraws
        } else if (!sourcesChanged) {
            NLEnginePushUpdate();   // e.g. offset moved: redraw without waiting for the player
        }

        NLLog(@"preferences reloaded, enabled %d → %d", old.enabled, now.enabled);

        if (now.killOnChange && (now.enabled || old.enabled)) {
            exit(0);
        }
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
        if (gEnabled) NLClearCacheIfRequested(settings.cacheClearedAt);   // a clear tapped while this app was not running

        // Registered even when inactive, so a later switch-on is noticed.
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL,
                                        NLPrefsChanged,
                                        (__bridge CFStringRef)kNLReloadNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);

        NLLog(@"%@ enabled=%d contentItems=%d", [[NSBundle mainBundle] bundleIdentifier], gEnabled, gContentItemMode);

        if (gEnabled) NLInstallHooks();
    }
}
