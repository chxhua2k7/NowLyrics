//
//  NLShared.h
//  What NowLyrics.dylib and NowLyricsIsland.dylib (SpringBoard) must agree on.
//  They are separate binaries, so these are compiled into each rather than
//  exported from one.
//

#import <Foundation/Foundation.h>

#define NL_PREFS_DOMAIN         @"app.nowlyrics"
#define NL_RELOAD_NOTIFICATION  @"app.nowlyrics/ReloadPrefs"
// The settings page wrote, replaced or deleted lyrics files: each app drops
// what it holds in memory and looks the current track up again.
#define NL_LYRICS_CHANGED_NOTIFICATION @"app.nowlyrics/LyricsChanged"

// Apple Music's lyrics asked for by SpringBoard, for the song another app
// plays (NLAppleMusicSB.x): the request (an `id` and the catalog `adamID`) and
// the answer (the same `id`, `ttml` or `error`, `elapsed`) go through these
// files, each announced by a Darwin notification.
#define NL_AM_DIR                   @"/var/mobile/Library/Caches/NowLyrics"
#define NL_AM_REQUEST_FILE          NL_AM_DIR @"/am-request.plist"
#define NL_AM_RESPONSE_FILE         NL_AM_DIR @"/am-response.plist"
#define NL_AM_REQUEST_NOTIFICATION  @"app.nowlyrics/AppleMusicRequest"
#define NL_AM_RESPONSE_NOTIFICATION @"app.nowlyrics/AppleMusicResponse"
// The settings page asking whether there is an Apple Music subscription:
// request `id`, `time`; answer `id`, `result` ("active", "none", "unknown"),
// `detail`. Through the same notifications.
#define NL_AM_CHECK_REQUEST_FILE    NL_AM_DIR @"/am-check-request.plist"
#define NL_AM_CHECK_RESPONSE_FILE   NL_AM_DIR @"/am-check-response.plist"

// How early a line may switch, so it is up when the singing starts. The island
// looks lines up the same way the apps do.
#define NL_LINE_MARGIN 0.15

// Library/NowLyrics/nowplaying.plist in each app's container: what the app is
// playing and which lyrics it uses, for the settings page and the island (the
// now-playing title they could ask MediaRemote for is a lyric line by then).
#define NL_NOWPLAYING_FILE @"nowplaying.plist"
#define NL_NP_KEY       @"key"        // NLTrackKey(title, artist)
#define NL_NP_TITLE     @"title"
#define NL_NP_ARTIST    @"artist"
#define NL_NP_ALBUM     @"album"
#define NL_NP_DURATION  @"duration"
#define NL_NP_STATUS    @"status"     // what answered, as the diagnostics readout says it; absent while searching
#define NL_NP_PATH      @"path"       // the lyrics file in use, absent when there is none
#define NL_NP_WORDS     @"words"      // the lyrics have word timings
#define NL_NP_UPDATED   @"updated"    // NSDate
#define NL_NP_STAMP     @"stamp"      // the same as a CFAbsoluteTime: a date in the plist keeps whole seconds only

// The settings page looking the playing song up again with a source:
// Library/NowLyrics/lookup.plist beside nowplaying.plist, with `key` (the
// track key), `source` (a sourceOrder name, "" for automatic) and `stamp` (a
// CFAbsoluteTime). The app reads it when told the lyrics changed, so the pick
// holds at once, before cfprefsd has written the preference file the app reads
// (which once took a few taps).
#define NL_LOOKUP_FILE  @"lookup.plist"

// The preference file. Sandboxed apps cannot always read the global one, so a
// few locations are tried. The first is the process's own Library, which in
// SpringBoard is the global file itself and in an app is an in-container
// override (how NowLyrics is configured when injected with TrollFools and
// there is no Settings panel). The path that worked is remembered; reloads
// happen on every settings change. Main queue.
static inline NSDictionary *NLReadPrefsFile(void) {
    static NSString *knownPath = nil;
    if (knownPath) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:knownPath];
        if (dict.count) return dict;
        knownPath = nil;
    }
    NSString *name = [NL_PREFS_DOMAIN stringByAppendingPathExtension:@"plist"];
    NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (library) [candidates addObject:[library stringByAppendingPathComponent:@"Preferences"]];
    [candidates addObject:@"/var/mobile/Library/Preferences"];
    [candidates addObject:@"/var/jb/var/mobile/Library/Preferences"];
    for (NSString *dir in candidates) {
        NSString *path = [dir stringByAppendingPathComponent:name];
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict.count) {
            knownPath = path;
            return dict;
        }
    }
    return nil;
}

// Typed reads that fall back on a missing key or a value of the wrong type.
static inline BOOL NLPrefBool(NSDictionary *prefs, NSString *key, BOOL fallback) {
    id value = prefs[key];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

static inline double NLPrefNum(NSDictionary *prefs, NSString *key, double fallback) {
    id value = prefs[key];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}

// One song's own offset, on top of the global one: `trackOffsets` maps track
// keys to seconds (positive means lyrics appear earlier, like `offset`).
#define NL_TRACK_OFFSETS_KEY @"trackOffsets"
// The source picked for one song: track key → "applemusic", "musixmatch",
// "lrclib" or "netease" (sourceOrder's names). Same limit as the offsets.
#define NL_TRACK_SOURCES_KEY @"trackSources"
static const NSUInteger kNLTrackOffsetsLimit = 500;

static inline double NLTrackOffset(NSDictionary *prefs, NSString *trackKey) {
    id all = prefs[NL_TRACK_OFFSETS_KEY];
    if (![all isKindOfClass:[NSDictionary class]] || trackKey.length == 0) return 0;
    id value = ((NSDictionary *)all)[trackKey];
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : 0;
}
