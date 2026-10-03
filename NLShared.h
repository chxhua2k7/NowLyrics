//
//  NLShared.h
//  What NowLyrics.dylib and NowLyricsIsland.dylib (SpringBoard) must agree on.
//  They are separate binaries, so these are compiled into each rather than
//  exported from one.
//

#import <Foundation/Foundation.h>

#define NL_PREFS_DOMAIN         @"app.nowlyrics"
#define NL_RELOAD_NOTIFICATION  @"app.nowlyrics/ReloadPrefs"

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
