//
//  NLShared.h
//  What NowLyrics.dylib, NowLyricsIsland.dylib (SpringBoard) and
//  NowLyricsPrefs.bundle must agree on, and the small helpers all three use.
//  They are separate binaries, so these are compiled into each (static
//  inline) rather than exported from one.
//

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// A file of the jailbreak, by its path inside the jailbreak's root: under
// /var/jb on rootless, under the randomly named root roothide gives each
// jailbreak (jbroot(), from roothide's Theos, which also answers for rootless
// builds). Without that header, rootless.
#if __has_include(<roothide.h>)
#include <roothide.h>
static inline NSString *NLJBPath(NSString *path) { return jbroot(path); }
#else
static inline NSString *NLJBPath(NSString *path) { return [@"/var/jb" stringByAppendingString:path]; }
#endif

#define NL_PREFS_DOMAIN         @"com.c3x14n.nowlyrics"
// The domain until 1.2.3, the package's first name: its settings move into
// NL_PREFS_DOMAIN once (NLMoveOldPrefs), and a file by that name is still
// read when there is none by the new one (an app's in-container override).
#define NL_OLD_PREFS_DOMAIN     @"app.nowlyrics"
#define NL_RELOAD_NOTIFICATION  @"com.c3x14n.nowlyrics/ReloadPrefs"
// The settings page wrote, replaced or deleted lyrics files: each app drops
// what it holds in memory and looks the current track up again.
#define NL_LYRICS_CHANGED_NOTIFICATION @"com.c3x14n.nowlyrics/LyricsChanged"

// Apple Music's lyrics asked for by SpringBoard, for the song another app
// plays (NLAppleMusicSB.x): the request (`id`, `title`, `artist`,
// `duration`, `time`) and the answer (the same `id`, `elapsed`, and `ttml`,
// `notFound` or `error`, with the song it was found as: `adamID`,
// `matchTitle`, `matchArtist`) are files by these names, in the asking app's
// Library/NowLyrics or in NL_AM_DIR (in the jailbreak's root) for the
// settings page's test, each announced by a Darwin notification.
#define NL_AM_DIR                   NLJBPath(@"/var/mobile/Library/Caches/NowLyrics")
#define NL_AM_REQUEST_NAME          @"am-request.plist"
#define NL_AM_RESPONSE_NAME         @"am-response.plist"
#define NL_AM_REQUEST_FILE          [NL_AM_DIR stringByAppendingPathComponent:NL_AM_REQUEST_NAME]
#define NL_AM_RESPONSE_FILE         [NL_AM_DIR stringByAppendingPathComponent:NL_AM_RESPONSE_NAME]
#define NL_AM_REQUEST_NOTIFICATION  @"com.c3x14n.nowlyrics/AppleMusicRequest"
#define NL_AM_RESPONSE_NOTIFICATION @"com.c3x14n.nowlyrics/AppleMusicResponse"
// The settings page asking whether there is an Apple Music subscription:
// request `id`, `time`; answer `id`, `result` ("active", "none", "unknown"),
// `detail`. Through the same notifications.
#define NL_AM_CHECK_REQUEST_FILE    [NL_AM_DIR stringByAppendingPathComponent:@"am-check-request.plist"]
#define NL_AM_CHECK_RESPONSE_FILE   [NL_AM_DIR stringByAppendingPathComponent:@"am-check-response.plist"]
// Music's own request for Apple Music's lyrics failed (refused or not
// answered, not merely no lyrics for the song, NLStoreLyricsFailed): the
// subscription may have lapsed, so SpringBoard checks it (NLAppleMusicSB.x).
#define NL_AM_FAILED_NOTIFICATION   @"com.c3x14n.nowlyrics/AppleMusicFailed"

// How early a line switches: the island fades a new line in over a quarter
// of a second, so it has to start this much ahead to be up when the singing
// starts (the lyrics' own times are right on average, measured against
// LRCLIB). Word-by-word lighting keeps the words' own times. The island looks
// lines up the same way the apps do.
#define NL_LINE_MARGIN 0.3

// Library/NowLyrics/nowplaying.plist in each app's container: what the app is
// playing and which lyrics it uses, for the settings page and the island (the
// now-playing title they could ask MediaRemote for is a lyric line by then).
#define NL_NOWPLAYING_FILE @"nowplaying.plist"
#define NL_NP_KEY       @"key"        // NLTrackKey(title, artist)
#define NL_NP_TITLE     @"title"
#define NL_NP_ARTIST    @"artist"
#define NL_NP_DURATION  @"duration"
#define NL_NP_STATUS    @"status"     // what answered, as the diagnostics readout says it; absent while searching
#define NL_NP_PATH      @"path"       // the lyrics file in use, absent when there is none
#define NL_NP_WORDS     @"words"      // the lyrics have word timings
#define NL_NP_UPDATED   @"updated"    // NSDate
#define NL_NP_STAMP     @"stamp"      // the same as a CFAbsoluteTime: a date in the plist keeps whole seconds only
#define NL_NP_STARTED   @"started"    // CFAbsoluteTime the app first saw this track (the listening history matches plays by it)
// That folder (each app's Library/NowLyrics; NLCacheDir() from inside the
// app) and its folder of lyrics added by hand.
#define NL_FOLDER_NAME   @"NowLyrics"
#define NL_APP_FOLDER    @"Library/" NL_FOLDER_NAME
#define NL_MANUAL_FOLDER @"manual"
// Left there once the lyrics cached before 1.2.0 are gone (NLClearOldCache,
// NLLyrics.m); until then the settings page's library leaves those out.
#define NL_OLD_CACHE_CLEARED @".old-cache-cleared"

// The settings page looking the playing song up again with a source:
// Library/NowLyrics/lookup.plist beside nowplaying.plist, with `key` (the
// track key), `source` (a sourceOrder name, "" for automatic) and `stamp` (a
// CFAbsoluteTime). The app reads it when told the lyrics changed, so the pick
// holds at once, before cfprefsd has written the preference file the app reads
// (which once took a few taps).
#define NL_LOOKUP_FILE  @"lookup.plist"
#define NL_LOOKUP_KEY     @"key"
#define NL_LOOKUP_SOURCE  @"source"
#define NL_LOOKUP_STAMP   @"stamp"

// What a hit from an app's disk cache says as its status (NL_NP_STATUS):
// "cache", or "cache · <source>" when the file names its source. Written by
// the apps (NLSources.m), read by the settings page.
#define NL_STATUS_CACHE         @"cache"
#define NL_STATUS_CACHE_PREFIX  NL_STATUS_CACHE @" · "
#define NL_STATUS_NOTES_SEPARATOR  @" · "   // between the sources' answers in a miss (NLResolveLyrics); the settings page splits on it
#define NL_STATUS_RETRY_SUFFIX     @" (will retry)"   // after a miss whose lookup is asked again (NLEngine.m)
static inline NSString *NLCacheStatus(NSString *source) {
    return source.length ? [NL_STATUS_CACHE_PREFIX stringByAppendingString:source] : NL_STATUS_CACHE;
}
// The source a status names, the cache's prefix taken off ("cache · LRCLIB" → "LRCLIB").
static inline NSString *NLStatusSource(NSString *status) {
    return [status hasPrefix:NL_STATUS_CACHE_PREFIX] ? [status substringFromIndex:[NL_STATUS_CACHE_PREFIX length]] : status;
}

// MediaRemoteUI: the now-playing element in the island (its client
// identifier) and the player's group in the lock screen's notification list.
#define NL_MEDIAREMOTEUI_ID @"com.apple.MediaRemoteUI"

// Whether SpringBoard shows the Dynamic Island, as it found once it had
// finished launching (NowLyricsIsland.x), for the settings page: the notify
// state of this name, 0 until SpringBoard has said. SpringBoard's own answer
// counts an island given by other means too (a MobileGestalt edit, a tweak
// in SpringBoard), on an iPad as well.
#define NL_ISLAND_STATE_NAME "com.c3x14n.nowlyrics.island"
static const uint64_t kNLIslandAbsent = 1;
static const uint64_t kNLIslandPresent = 2;

// A value made once, on first use, by one expression (a compiled regex, a
// character set, a constant collection, a looked-up function); thread-safe.
// Variadic so the commas of array and dictionary literals pass through.
#define NL_ONCE(...) ({ static __typeof__(__VA_ARGS__) nlOnceValue_; static dispatch_once_t nlOnceToken_; dispatch_once(&nlOnceToken_, ^{ nlOnceValue_ = (__VA_ARGS__); }); nlOnceValue_; })

// The preference file. Sandboxed apps cannot always read the global one, so a
// few locations are tried. The first is the process's own Library, which in
// SpringBoard is the global file itself and in an app is an in-container
// override (how NowLyrics is configured when injected with TrollFools and
// there is no Settings panel). The new name anywhere before the old one
// (NL_OLD_PREFS_DOMAIN); the path that worked is remembered, unless it is
// an old one, so the new file is found once it is there. Reloads happen on
// every settings change. Main queue.
static inline NSDictionary *NLReadPrefsFile(void) {
    static NSString *knownPath = nil;
    if (knownPath) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:knownPath];
        if (dict.count) return dict;
        knownPath = nil;
    }
    NSString *library = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject;
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    if (library) [candidates addObject:[library stringByAppendingPathComponent:@"Preferences"]];
    // In SpringBoard the process's own Library is the global one: probed once.
    for (NSString *dir in @[@"/var/mobile/Library/Preferences", NLJBPath(@"/var/mobile/Library/Preferences")]) {
        if (![candidates containsObject:dir]) [candidates addObject:dir];
    }
    for (NSString *domain in @[NL_PREFS_DOMAIN, NL_OLD_PREFS_DOMAIN]) {
        NSString *name = [domain stringByAppendingPathExtension:@"plist"];
        for (NSString *dir in candidates) {
            NSString *path = [dir stringByAppendingPathComponent:name];
            NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
            if (!dict.count) continue;
            if ([domain isEqualToString:NL_PREFS_DOMAIN]) knownPath = path;
            return dict;
        }
    }
    return nil;
}

// Tolerant reads: any wrong type on the way down yields nil (or the
// fallback) instead of an exception, so a plist, a JSON answer or another
// process's file may be sloppy with its shape. These take the container,
// whatever it is.
static inline id NLValue(id container, NSString *key) {
    return [container isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)container)[key] : nil;
}
static inline NSString *NLString(id container, NSString *key) {
    id value = NLValue(container, key);
    return [value isKindOfClass:[NSString class]] ? value : nil;
}
static inline NSArray *NLArray(id container, NSString *key) {
    id value = NLValue(container, key);
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}
// NSNumber only. JSON null decodes to NSNull, which does not respond to
// doubleValue; sending it anyway raises an unrecognised-selector exception,
// and on a background queue that takes the whole host app down.
static inline double NLNum(id value, double fallback) {
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}
// Loose: anything that answers -doubleValue / -boolValue (a number, or a
// numeric string from a text field, a plist property or another tweak's
// domain); `fallback` for the rest, nil and NSNull included.
static inline double NLLooseNum(id value, double fallback) {
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : fallback;
}
static inline BOOL NLLooseBool(id value, BOOL fallback) {
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}
// A string without its outer whitespace and newlines; nil for anything else.
static inline NSString *NLTrimmed(id value) {
    return [value isKindOfClass:[NSString class]]
        ? [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] : nil;
}

// The Musixmatch User Token the requests use, from the `musixmatchToken`
// field: the Musixmatch app's "Copy debug info" produces a whole block, so the
// token is pulled out of it and the field can just be pasted into. nil when
// there is none (an empty field, or a block with nothing after its marker).
static inline NSString *NLMusixmatchUserToken(id value) {
    NSString *raw = NLTrimmed(value);
    if (raw.length == 0) return nil;
    NSRange marker = [raw rangeOfString:@"[UserToken]:"];
    if (marker.location == NSNotFound) return raw;
    for (NSString *piece in [[raw substringFromIndex:NSMaxRange(marker)] componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (piece.length) return piece;
    }
    return nil;
}

// Whether Musixmatch can be asked: a User Token or an API key (`musixmatchKey`)
// that is more than whitespace. The apps, the unlock and the Now Playing page
// all go by this one rule.
static inline BOOL NLMusixmatchHasCredentials(id token, id key) {
    return NLMusixmatchUserToken(token).length || NLTrimmed(key).length;
}

// Typed preference reads that fall back on a missing key or a value of the wrong type.
static inline BOOL NLPrefBool(NSDictionary *prefs, NSString *key, BOOL fallback) {
    id value = prefs[key];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}
static inline double NLPrefNum(NSDictionary *prefs, NSString *key, double fallback) {
    return NLNum(prefs[key], fallback);
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
    return [all isKindOfClass:[NSDictionary class]] && trackKey.length ? NLNum(((NSDictionary *)all)[trackKey], 0) : 0;
}
// The offset a song plays with: the global `offset` plus its own (positive
// means lyrics appear earlier), as the apps and the island look lines up.
static inline double NLOffsetForTrack(NSDictionary *prefs, NSString *trackKey) {
    return NLPrefNum(prefs, @"offset", 0) + NLTrackOffset(prefs, trackKey);
}

// Equal, nil and nil included.
static inline BOOL NLSame(id a, id b) { return a == b || [a isEqual:b]; }

// Darwin notifications (the NL_*_NOTIFICATION names): posted to every
// process, observed with no observer object.
static inline void NLPostDarwin(NSString *name) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge CFStringRef)name, NULL, NULL, YES);
}
static inline void NLObserveDarwin(NSString *name, CFNotificationCallback callback, CFNotificationSuspensionBehavior behavior) {
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, callback, (__bridge CFStringRef)name, NULL, behavior);
}
// A request or answer handed between the apps, SpringBoard and the settings
// page: `plist` written atomically as `path` (its folder made first), then
// `notification` posted.
static inline void NLWritePlistAndPost(NSDictionary *plist, NSString *path, NSString *notification) {
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    [plist writeToFile:path atomically:YES];
    NLPostDarwin(notification);
}

// Preferences written straight into the domain (NSNull removes one), then
// one reload notice to the apps and the island: the settings page's writes
// that are not its rows', and SpringBoard's when it keeps the Apple Music
// unlock in step with the subscription (NLAppleMusicSB.x).
static inline void NLWritePrefs(NSDictionary<NSString *, id> *values) {
    CFStringRef domain = (__bridge CFStringRef)NL_PREFS_DOMAIN;
    for (NSString *key in values) {
        id value = values[key] == NSNull.null ? nil : values[key];
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, domain);
    }
    CFPreferencesAppSynchronize(domain);
    NLPostDarwin(NL_RELOAD_NOTIFICATION);
}

// The old domain's settings (NL_OLD_PREFS_DOMAIN) moved into NL_PREFS_DOMAIN
// once: those it does not have yet, then the old ones removed (their file
// goes with them), then a reload notice. SpringBoard as it starts, the
// settings page too in case it is first.
static inline void NLMoveOldPrefs(void) {
    CFStringRef old = (__bridge CFStringRef)NL_OLD_PREFS_DOMAIN, domain = (__bridge CFStringRef)NL_PREFS_DOMAIN;
    NSArray *keys = CFBridgingRelease(CFPreferencesCopyKeyList(old, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    if (!keys.count) return;
    NSMutableDictionary *moved = [CFBridgingRelease(CFPreferencesCopyMultiple((__bridge CFArrayRef)keys, old, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) mutableCopy];
    NSArray *present = CFBridgingRelease(CFPreferencesCopyKeyList(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost));
    if (present) [moved removeObjectsForKeys:present];
    if (moved.count) CFPreferencesSetMultiple((__bridge CFDictionaryRef)moved, NULL, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSetMultiple(NULL, (__bridge CFArrayRef)keys, old, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize(old, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    NLPostDarwin(NL_RELOAD_NOTIFICATION);
}

// `seconds` from now as a dispatch time, and `block` on the main queue then.
static inline dispatch_time_t NLTimeIn(double seconds) { return dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)); }
static inline void NLAfter(double seconds, dispatch_block_t block) { dispatch_after(NLTimeIn(seconds), dispatch_get_main_queue(), block); }

// A class, its framework loaded first when it is not here yet; Nil when this
// iOS has neither.
static inline Class NLLoadedClass(const char *name, const char *framework) {
    Class cls = objc_getClass(name);
    if (!cls) {
        dlopen(framework, RTLD_NOW);
        cls = objc_getClass(name);
    }
    return cls;
}

#ifdef NLI_FILELOG
// Debug builds (-DNLI_FILELOG): `text` appended to the log at `path`, made when missing.
static inline void NLIAppendLog(NSString *path, NSString *text) {
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) {
        [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil];
        h = [NSFileHandle fileHandleForWritingAtPath:path];
    }
    [h seekToEndOfFile];
    [h writeData:[text dataUsingEncoding:NSUTF8StringEncoding]];
    [h closeFile];
}
#endif
