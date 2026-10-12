//
//  NLHistorySB.x
//  Listening history, written down in SpringBoard (NLHistory.h): every song
//  played long enough, whichever app plays it. SpringBoard hears every
//  now-playing change (-[SBMediaController _mediaRemoteNowPlayingInfoDidChange:])
//  and asks MediaRemote what plays, the way the island does.
//
//  - The song: while NowLyrics runs in the playing app, the title MediaRemote
//    has is a lyric line (and the artist may be the track's name), so the
//    song comes from the app's nowplaying.plist when that describes it
//    (NLHistoryNowLyricsSong). Elsewhere, MediaRemote's title and artist.
//  - One play: the same app, album and length (players report the length a
//    second or two apart, and 0 for a moment, so close is the same). A new
//    title is a new song unless NowLyrics is the one changing it. Starting over
//    (repeat), or coming back after a long pause, begins another play.
//  - Time: only while playing, pauses left out. A play counts once it has
//    played 30 seconds or half the song, whichever is shorter; it is written
//    then, on every pause, at its end, and every minute in between.
//  - After a respring the song playing goes on in the play it was in, rather
//    than starting a second one.
//

#import <UIKit/UIKit.h>
#import "NowLyrics.h"
#import "NLLocate.h"
#import "NLIslandStrip.h"
#import "NLHistory.h"

// Built with -DNLI_FILELOG (as the island's debug builds), what the history
// sees goes to /var/mobile/Library/Logs/NowLyricsHistory.log.
#ifdef NLI_FILELOG
#define NLH_LOG(...) NLIAppendLog(@"/var/mobile/Library/Logs/NowLyricsHistory.log", \
    [NSString stringWithFormat:@"%@ %@\n", [NSDate date], [NSString stringWithFormat:__VA_ARGS__]])
#else
#define NLH_LOG(...) do {} while (0)
#endif

static const NSTimeInterval kNLHistoryCountAfter = 30;     // seconds played for a play to count (or half the song)
static const NSTimeInterval kNLHistoryLongPause = 10 * 60; // back after longer than this: another play
static const NSTimeInterval kNLHistorySaveEvery = 60;      // while playing
static const NSTimeInterval kNLHistoryResumeGap = 2 * 60;  // after a respring: the last play goes on if it ended this recently

@interface NLHistoryPlay : NSObject
@property (nonatomic, copy) NSString *identifier, *bundleID;
@property (nonatomic, copy) NSString *shownTitle;           // MediaRemote's title, as last seen
@property (nonatomic, copy) NSString *title, *artist, *album, *key, *art;
@property (nonatomic, assign) double duration;
@property (nonatomic, assign) CFAbsoluteTime start, end;    // end: when it last played
@property (nonatomic, assign) CFAbsoluteTime playingSince;  // 0 while paused
@property (nonatomic, assign) CFAbsoluteTime savedAt;
@property (nonatomic, assign) double listened, lastElapsed;
@property (nonatomic, assign) BOOL fromNowLyrics, saved, dropped;
@end

@implementation NLHistoryPlay

- (NSDictionary *)entry {
    NSMutableDictionary *entry = [NSMutableDictionary dictionary];
    entry[NL_HP_ID] = self.identifier;
    entry[NL_HP_START] = @(round(self.start + kCFAbsoluteTimeIntervalSince1970));
    entry[NL_HP_END] = @(round(self.end + kCFAbsoluteTimeIntervalSince1970));
    entry[NL_HP_LISTENED] = @(round(self.listened));
    entry[NL_HP_TITLE] = self.title ?: @"";
    entry[NL_HP_ARTIST] = self.artist.length ? self.artist : nil;
    entry[NL_HP_ALBUM] = self.album.length ? self.album : nil;
    entry[NL_HP_DURATION] = self.duration > 0 ? @(round(self.duration)) : nil;
    entry[NL_HP_APP] = self.bundleID.length ? self.bundleID : nil;
    entry[NL_HP_KEY] = self.key;
    entry[NL_HP_ART] = self.art;
    return entry;
}

// How long it has to play to count: 30 seconds, or half a shorter song.
- (double)countsAfter {
    return self.duration > 0 ? MIN(kNLHistoryCountAfter, self.duration / 2) : kNLHistoryCountAfter;
}

- (BOOL)counts {
    return self.listened >= [self countsAfter];
}

@end

static BOOL gHistoryOn = NO;
static NSInteger gHistoryDays = kNLHistoryDefaultDays;
static NLHistoryPlay *gPlay = nil;
static NSTimer *gSaveTimer = nil;
static BOOL gLookedForResume = NO;   // after SpringBoard started: whether the first play was matched with the last one written
static NSString *gPrunedDay = nil;   // the day the old ones were last pruned on

static BOOL NLHistoryLengthsClose(double a, double b) {
    return a <= 0 || b <= 0 || fabs(a - b) <= 3;
}

static BOOL NLHistorySameText(NSString *a, NSString *b) {
    return a.length == 0 || b.length == 0 || [a isEqualToString:b];   // an empty one is not known yet
}

// When NowLyrics in the app first saw the song its nowplaying.plist names, as
// a CFAbsoluteTime (`started`); for an app still running an older NowLyrics,
// when it wrote the file. NAN without either.
static CFAbsoluteTime NLHistorySongStarted(NSDictionary *np) {
    id started = np[NL_NP_STARTED];
    if ([started isKindOfClass:NSNumber.class] && [started doubleValue] > 0) return [started doubleValue];
    id stamp = np[NL_NP_STAMP];
    if ([stamp isKindOfClass:NSNumber.class]) return [stamp doubleValue];
    NSDate *updated = np[NL_NP_UPDATED];
    return [updated isKindOfClass:NSDate.class] ? updated.timeIntervalSinceReferenceDate : NAN;
}

// `text` is a line of the lyrics file the app shows.
static BOOL NLHistoryIsLyricLine(NSDictionary *np, NSString *text) {
    NSString *path = NLString(np, NL_NP_PATH);
    if (!path) return NO;
    for (NLLyricLine *line in NLParseLRCFile(path)) {
        if ([line.text isEqualToString:text]) return YES;
    }
    return NO;
}

// The playing app's nowplaying.plist when it describes the song MediaRemote
// reports (`title`, `duration`), first seen here at `since`; else nil. It
// does with the same title (whether or not NowLyrics runs there now), and
// with another when that one is a line of its lyrics or NowLyrics began the
// song after this play did (it writes the file for each new song, and the
// line may not be up yet). An older file is another song's.
static NSDictionary *NLHistoryNowLyricsSong(NSString *bundleID, NSString *title, double duration, CFAbsoluteTime since) {
    NSDictionary *np = NLReadNowPlaying(bundleID);
    NSString *npTitle = NLString(np, NL_NP_TITLE);
    if (npTitle.length == 0 || !NLHistoryLengthsClose(duration, NLNum(np[NL_NP_DURATION], 0))) return nil;
    if ([npTitle isEqualToString:title]) return np;
    if (NLHistorySongStarted(np) >= since - 5) return np;
    return NLHistoryIsLyricLine(np, title) ? np : nil;
}

static void NLHistoryAdopt(NLHistoryPlay *play, NSDictionary *np) {
    play.fromNowLyrics = YES;
    play.title = NLString(np, NL_NP_TITLE);
    play.artist = NLString(np, NL_NP_ARTIST);
    play.key = NLString(np, NL_NP_KEY) ?: NLTrackKey(play.title, play.artist);
}

#pragma mark - Saving

static void NLHistorySave(NLHistoryPlay *play, BOOL now) {
    if (!play || play.dropped || ![play counts]) return;
    CFAbsoluteTime time = CFAbsoluteTimeGetCurrent();
    if (!now && play.saved && time - play.savedAt < kNLHistorySaveEvery) return;
    play.saved = YES;
    play.savedAt = time;
    NLH_LOG(@"save %@", [play entry]);
    NLHistorySavePlay([play entry]);
    // Once a day, the days past what is kept go.
    NSString *today = NLHistoryDayKey([NSDate date]);
    if (![today isEqualToString:gPrunedDay]) {
        gPrunedDay = today;
        NLHistoryPrune(gHistoryDays);
    }
}

// The time played since the last look, added up to now.
static void NLHistoryAccount(void) {
    NLHistoryPlay *play = gPlay;
    if (!play || play.playingSince <= 0) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double span = now - play.playingSince;
    if (span > 0 && span < 6 * 3600) play.listened += span;   // not across a clock change
    play.playingSince = now;
    play.end = now;
}

// While playing, a look every minute: nothing may change for the whole song
// in an app that only reports at its start, and a respring would lose it.
static void NLHistoryTimerTick(void) {
    NLHistoryAccount();
    NLHistorySave(gPlay, NO);
}

static void NLHistorySetTimer(BOOL on) {
    if (on == (gSaveTimer != nil)) return;
    [gSaveTimer invalidate];
    gSaveTimer = on ? [NSTimer scheduledTimerWithTimeInterval:kNLHistorySaveEvery repeats:YES block:^(NSTimer *timer) { NLHistoryTimerTick(); }] : nil;
    gSaveTimer.tolerance = 10;
}

static void NLHistoryFinish(void) {
    NLHistoryAccount();
    NLHistorySave(gPlay, YES);
    gPlay = nil;
    NLHistorySetTimer(NO);
}

// After SpringBoard started: the song playing may be the one the last play
// written was on, cut off by the respring. Then that play goes on.
static void NLHistoryResume(NLHistoryPlay *play) {
    if (gLookedForResume) return;
    gLookedForResume = YES;
    NSDictionary *last = NLHistoryReadDay(NLHistoryDayKey([NSDate date])).lastObject;
    double end = NLNum(last[NL_HP_END], 0) - kCFAbsoluteTimeIntervalSince1970;
    if (!last || play.start - end > kNLHistoryResumeGap || ![(NLString(last, NL_HP_APP) ?: @"") isEqualToString:play.bundleID] ||
        ![NLString(last, NL_HP_KEY) isEqualToString:play.key]) return;
    play.identifier = last[NL_HP_ID];
    play.start = NLNum(last[NL_HP_START], 0) - kCFAbsoluteTimeIntervalSince1970;
    play.listened = NLNum(last[NL_HP_LISTENED], 0);
    play.art = play.art ?: NLString(last, NL_HP_ART);
    play.saved = YES;
}

#pragma mark - Following what plays

static void NLHistoryRefresh(void);

static void NLHistoryIngest(NSDictionary *info, NSString *bundleID) {
    NLHistoryAccount();
    NSString *title = NLInfoTitle(info);
    NLH_LOG(@"ingest app=%@ title=%@ artist=%@ album=%@ duration=%@ rate=%@ elapsed=%@ keys=%@", bundleID, title,
            info[NL_MR_ARTIST], info[NL_MR_ALBUM], info[NL_MR_DURATION], info[NL_MR_RATE], info[NL_MR_ELAPSED],
            [info.allKeys componentsJoinedByString:@","]);
    if (!title || !bundleID) {
        NLHistoryFinish();   // nothing plays (or no song to name)
        return;
    }
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    NSString *artist = NLString(info, NL_MR_ARTIST);
    NSString *album = NLString(info, NL_MR_ALBUM);
    double duration = NLNum(info[NL_MR_DURATION], 0);
    BOOL playing = NLInfoPlaying(info);
    double elapsed = NLNum(info[NL_MR_ELAPSED], -1);
    NSDate *stamp = info[NL_MR_TIMESTAMP];
    if (elapsed >= 0 && [stamp isKindOfClass:NSDate.class] && playing) elapsed += -stamp.timeIntervalSinceNow * NLNum(info[NL_MR_RATE], 1);

    NLHistoryPlay *play = gPlay;
    BOOL same = play && [play.bundleID isEqualToString:bundleID] && NLHistorySameText(play.album, album) &&
                NLHistoryLengthsClose(play.duration, duration);
    if (same && ![title isEqualToString:play.shownTitle] && !play.fromNowLyrics) {
        // A new title: NowLyrics showing a line of this song, or another song.
        NSDictionary *np = NLHistoryNowLyricsSong(bundleID, title, duration, play.start);
        if (np && [NLString(np, NL_NP_TITLE) isEqualToString:play.title]) NLHistoryAdopt(play, np);
        else same = NO;
    } else if (same && play.fromNowLyrics) {
        // NowLyrics names the song: it has moved on when its file names another.
        NSDictionary *np = NLHistoryNowLyricsSong(bundleID, title, duration, play.start);
        NSString *npTitle = NLString(np, NL_NP_TITLE);
        if (npTitle && ![npTitle isEqualToString:play.title]) same = NO;
    }
    // Started over (repeat one), or back after a long pause.
    if (same && playing && play.lastElapsed > kNLHistoryCountAfter && elapsed >= 0 && elapsed < 5) same = NO;
    if (same && playing && play.playingSince <= 0 && now - play.end > kNLHistoryLongPause) same = NO;

    if (!same) {
        NLHistoryFinish();
        play = [NLHistoryPlay new];
        play.identifier = NSUUID.UUID.UUIDString;
        play.bundleID = bundleID;
        play.album = album;
        play.duration = duration;
        play.start = now;
        play.end = now;
        NSDictionary *np = NLHistoryNowLyricsSong(bundleID, title, duration, now);
        if (np) {
            NLHistoryAdopt(play, np);
        } else {
            play.title = title;
            play.artist = artist;
            play.key = NLTrackKey(title, artist);
        }
        gPlay = play;
        NLHistoryResume(play);
        // A look again in a few seconds for the cover (between songs the old
        // one can linger), and once the song would count.
        NLAfter(4, ^{ if (gPlay == play) NLHistoryRefresh(); });
        NLAfter([play countsAfter] + 1, ^{ if (gPlay == play) NLHistoryRefresh(); });
    }
    play.shownTitle = title;
    if (play.album.length == 0 && album.length) play.album = album;
    if (play.duration <= 0 && duration > 0) play.duration = duration;
    if (elapsed >= 0) play.lastElapsed = elapsed;

    // The cover, once the song has been on for a moment (between songs the
    // old one can linger), and again whenever it changes: a player may show a
    // stand-in until the real one has loaded (Spotify).
    NSData *artwork = NLInfoArtwork(info);
    if (artwork && now - play.start >= 3) {
        NSString *art = [NSString stringWithFormat:@"%lx.jpg", (unsigned long)NLArtworkPrint(artwork)];
        if (![art isEqualToString:play.art]) {
            play.art = art;
            NLHistorySaveArtwork(artwork, art);
            if (play.saved) play.savedAt = 0;   // written with the new one at the next look
        }
    }

    play.playingSince = playing ? now : 0;
    if (playing) play.end = now;
    NLH_LOG(@"play %@ same=%d np=%d title=%@ key=%@ listened=%.1f playing=%d", play.identifier, same, play.fromNowLyrics, play.title, play.key, play.listened, playing);
    NLHistorySetTimer(playing);
    NLHistorySave(play, !playing);
}

static void NLHistoryRefresh(void) {
    if (!gHistoryOn) return;
    NLH_LOG(@"refresh");
    NLNowPlayingInfo(^(NSDictionary *info) {
        if (!gHistoryOn) return;
        // SpringBoard names no app for some players (Safari's web audio on
        // iOS 26): MediaRemote is asked then, and without an answer the song
        // is written down all the same, with no app.
        NSString *bundleID = info ? NLSpringBoardPlayingBundleID() : nil;
        if (info && !bundleID) {
            NLNowPlayingBundleID(^(NSString *other) {
                if (gHistoryOn) NLHistoryIngest(info, other ?: @"");
            });
            return;
        }
        NLHistoryIngest(info, bundleID);
    });
}

%hook SBMediaController
- (void)_mediaRemoteNowPlayingInfoDidChange:(id)notification {
    %orig;
    if (!gHistoryOn) return;
    dispatch_async(dispatch_get_main_queue(), ^{ NLHistoryRefresh(); });
}
%end

#pragma mark - Settings and the settings page

// At launch only read: the first now-playing change starts the following.
static void NLHistoryReadPrefs(BOOL atLaunch) {
    NSDictionary *prefs = NLReadPrefsFile();
    BOOL wasOn = gHistoryOn;
    NSInteger days = MAX((NSInteger)NLLooseNum(prefs[NL_HISTORY_DAYS_PREF], kNLHistoryDefaultDays), 0);
    BOOL daysChanged = days != gHistoryDays;
    gHistoryOn = NLLooseBool(prefs[NL_HISTORY_PREF], NO);
    gHistoryDays = days;
    NLH_LOG(@"prefs on=%d days=%ld launch=%d", gHistoryOn, (long)days, atLaunch);
    if (atLaunch) return;
    if (wasOn && !gHistoryOn) NLHistoryFinish();
    if (!wasOn && gHistoryOn) NLHistoryRefresh();
    // A shorter limit applies at once, recording or not: the page asked first.
    if (daysChanged) NLHistoryPrune(gHistoryDays);
}

static void NLHistoryPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                  const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ NLHistoryReadPrefs(NO); });
}

// The settings page deleted plays: the one on now is not written again if it
// went too.
static void NLHistoryEdited(CFNotificationCenterRef center, void *observer, CFStringRef name,
                            const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NLHistoryPlay *play = gPlay;
        if (!play.saved || play.dropped) return;
        NSString *day = NLHistoryDayKey([NSDate dateWithTimeIntervalSinceReferenceDate:play.start]);
        NLHistoryContainsPlay(day, play.identifier, ^(BOOL found) {
            if (!found) play.dropped = YES;
        });
    });
}

%ctor {
    @autoreleasepool {
        NLHistoryReadPrefs(YES);
        NLObserveDarwin(NL_RELOAD_NOTIFICATION, NLHistoryPrefsChanged, CFNotificationSuspensionBehaviorCoalesce);
        NLObserveDarwin(NL_HISTORY_EDITED_NOTIFICATION, NLHistoryEdited, CFNotificationSuspensionBehaviorCoalesce);
        %init;
    }
}
