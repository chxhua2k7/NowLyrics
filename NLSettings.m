//
//  NLSettings.m
//  Preference file lookup, the per-app switch, and the load-time safety checks.
//

#import "NowLyrics.h"

NSString *const kNLPrefsDomain = NL_PREFS_DOMAIN;
NSString *const kNLReloadNotification = NL_RELOAD_NOTIFICATION;
#ifndef NL_VERSION
#error NL_VERSION comes from PACKAGE_VERSION in the Makefile
#endif
NSString *const kNLUserAgent = @"NowLyrics/" NL_VERSION;

// Enabled when the user has never opened the app picker.
static NSString *const kNLDefaultBundles[] = {
    @"com.apple.Music",
    @"com.spotify.client",
    @"com.google.ios.youtubemusic",
    @"com.skysoft.kkbox.ios",
    @"com.soundcloud.TouchApp",
    @"com.aspiro.tidal",
    @"com.deezer.Deezer",
    @"com.amazon.mp3",
    nil,
};

// Never hooked, even if the user selects them. Breaking these is hard to recover from.
static NSString *const kNLDeniedBundles[] = {
    @"com.apple.springboard",
    @"com.apple.preferences",
    @"com.apple.spotlight",
    @"com.apple.incallservice",
    @"com.apple.PosterBoard",     // draws the lock screen
    @"com.apple.MediaRemoteUI",   // draws the now-playing controls
    nil,
};

// Only real apps: the system ones in /Applications and everything installed
// through the App Store or a jailbreak. Daemons and services that happen to
// link MediaPlayer (sosd, for one) live elsewhere and are not worth a hook.
static NSString *const kNLAppRoots[] = {
    @"/Applications/",
    @"/private/var/containers/Bundle/Application/",
    @"/var/containers/Bundle/Application/",
    @"/private/var/jb/Applications/",
    @"/var/jb/Applications/",
    nil,
};

// Apple's own apps do not publish through -setNowPlayingInfo:; they give
// MediaPlayer a content item instead, and that object is what gets edited.
// Only Music is known to need this.
static NSString *const kNLContentItemBundles[] = {
    @"com.apple.Music",
    nil,
};

static BOOL NLListContains(NSString *const list[], NSString *bundleID) {
    if (bundleID.length == 0) return NO;   // [nil compare:] would return NSOrderedSame
    for (int i = 0; list[i]; i++) {
        if ([bundleID caseInsensitiveCompare:list[i]] == NSOrderedSame) return YES;
    }
    return NO;
}

@interface NLSettings ()
@property (nonatomic, readwrite) BOOL enabled;
@property (nonatomic, readwrite) NLArtistMode artistMode;
@property (nonatomic, readwrite) NLSource preferredSource;
@property (nonatomic, readwrite) BOOL useMusixmatch;
@property (nonatomic, readwrite) BOOL useLRCLIB;
@property (nonatomic, readwrite) BOOL useNetease;
@property (nonatomic, readwrite, copy) NSString *musixmatchKey;
@property (nonatomic, readwrite, copy) NSString *musixmatchToken;
@property (nonatomic, readwrite) BOOL killOnChange;
@property (nonatomic, readwrite) BOOL diagnostics;
@property (nonatomic, readwrite) BOOL spotifyConnect;
@property (nonatomic, readwrite) BOOL hideExplicit;
@property (nonatomic, readwrite) NSTimeInterval offset;
@property (nonatomic, readwrite) NSTimeInterval cacheClearedAt;
@property (nonatomic, readwrite, copy) NSString *sourceSignature;
@end

@implementation NLSettings
@end

#pragma mark - Reading the file

// Sandboxed apps cannot always read the global preference file, so try a few
// locations. The first is an in-container override, which is how this can be
// configured when injected with TrollFools and there is no Settings panel.
static NSDictionary *NLReadPrefs(void) {
    // Remember which path worked; reloads happen on every settings change.
    static NSString *knownPath = nil;
    if (knownPath) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:knownPath];
        if (dict.count) return dict;
        knownPath = nil;
    }

    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *localDir = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES) firstObject];
    if (localDir) {
        [candidates addObject:[localDir stringByAppendingFormat:@"/Preferences/%@.plist", kNLPrefsDomain]];
    }
    [candidates addObject:[NSString stringWithFormat:@"/var/mobile/Library/Preferences/%@.plist", kNLPrefsDomain]];
    [candidates addObject:[NSString stringWithFormat:@"/var/jb/var/mobile/Library/Preferences/%@.plist", kNLPrefsDomain]];

    for (NSString *path in candidates) {
        NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
        if (dict.count) {
            knownPath = path;
            NLLog(@"preferences loaded from %@", path);
            return dict;
        }
    }
    return nil;
}

static BOOL NLBool(NSDictionary *prefs, NSString *key, BOOL fallback) {
    id value = prefs[key];
    return [value isKindOfClass:[NSNumber class]] ? [value boolValue] : fallback;
}

static NSString *NLTrimmed(id value) {
    return [value isKindOfClass:[NSString class]]
        ? [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
        : nil;
}

// The Musixmatch app's "Copy debug info" produces a whole block; pull the
// token out of it so the field can just be pasted into.
static NSString *NLExtractToken(id value) {
    NSString *raw = NLTrimmed(value);
    if (raw.length == 0) return nil;

    NSRange marker = [raw rangeOfString:@"[UserToken]:"];
    if (marker.location == NSNotFound) return raw;

    NSString *tail = [raw substringFromIndex:NSMaxRange(marker)];
    for (NSString *piece in [tail componentsSeparatedByCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (piece.length) return piece;
    }
    return nil;
}

// The app picker is AltList's ATLApplicationListMultiSelectionController, which
// stores the enabled apps as an array of bundle identifiers. nil means the user
// has never opened that page, which is the only time the built-in defaults apply.
static NSSet<NSString *> *NLSelectedApps(NSDictionary *prefs) {
    id raw = prefs[@"enabledApps"];
    if (![raw isKindOfClass:[NSArray class]]) return nil;
    return [NSSet setWithArray:(NSArray *)raw];
}

// Recomputed on every preference change, which is what makes the per-app
// switches take effect without relaunching the host app.
static BOOL NLEnabledForBundle(NSString *bundleID, NSDictionary *prefs) {
    if (bundleID.length == 0) return NO;
    if (NLListContains(kNLDeniedBundles, bundleID)) return NO;
    if (!NLBool(prefs, @"enabled", YES)) return NO;

    // An empty array means "all off" and must not fall through to the defaults.
    NSSet<NSString *> *selected = NLSelectedApps(prefs);
    if (selected) return [selected containsObject:bundleID];
    return NLListContains(kNLDefaultBundles, bundleID);
}

static NLSettings *gCurrent = nil;

NLSettings *NLSettingsCurrent(void) {
    return gCurrent ?: NLSettingsReload();
}

NLSettings *NLSettingsReload(void) {
    NSDictionary *prefs = NLReadPrefs();
    NLSettings *s = [NLSettings new];

    id artistField = prefs[@"artistField"];
    if ([artistField isKindOfClass:[NSString class]]) {
        if ([artistField isEqualToString:@"next"]) s.artistMode = NLArtistModeNextLine;
        else if ([artistField isEqualToString:@"none"]) s.artistMode = NLArtistModeNone;
        else s.artistMode = NLArtistModeTitle;
    } else {
        // Carry over the old boolean so existing installs keep their choice.
        s.artistMode = NLBool(prefs, @"keepOriginalTitle", YES) ? NLArtistModeTitle : NLArtistModeNone;
    }

    s.preferredSource = NLSourceNone;
    id preferred = prefs[@"preferredSource"];
    if ([preferred isKindOfClass:[NSString class]]) {
        if ([preferred isEqualToString:@"musixmatch"]) s.preferredSource = NLSourceMusixmatch;
        else if ([preferred isEqualToString:@"lrclib"]) s.preferredSource = NLSourceLRCLIB;
        else if ([preferred isEqualToString:@"netease"]) s.preferredSource = NLSourceNetease;
    }

    s.useLRCLIB = NLBool(prefs, @"useLRCLIB", YES);
    s.useNetease = NLBool(prefs, @"useNetease", YES);
    s.killOnChange = NLBool(prefs, @"killOnChange", NO);
    s.diagnostics = NLBool(prefs, @"diagnostics", NO);
    s.spotifyConnect = NLBool(prefs, @"spotifyConnect", YES);
    s.hideExplicit = NLBool(prefs, @"hideExplicit", NO);
    s.offset = NLNum(prefs[@"offset"], 0);
    s.cacheClearedAt = NLNum(prefs[@"cacheClearedAt"], 0);
    s.musixmatchToken = NLExtractToken(prefs[@"musixmatchToken"]);
    s.musixmatchKey = NLTrimmed(prefs[@"musixmatchKey"]);

    // Selected but no credentials entered is the same as switched off.
    BOOL wantsMusixmatch = NLBool(prefs, @"useMusixmatch", NO);
    s.useMusixmatch = wantsMusixmatch && (s.musixmatchKey.length || s.musixmatchToken.length);
    if (wantsMusixmatch && !s.useMusixmatch) {
        NLLog(@"Musixmatch selected but no token or API key set, skipping that source");
    }

    // Only these invalidate lyrics already fetched. The offset control posts a
    // notification per change, so clearing the cache on every reload would
    // mean refetching on every nudge.
    s.sourceSignature = [NSString stringWithFormat:@"%d%d%d|%ld|%@|%@",
                         s.useMusixmatch, s.useLRCLIB, s.useNetease, (long)s.preferredSource,
                         s.musixmatchKey ?: @"", s.musixmatchToken ?: @""];

    s.enabled = NLEnabledForBundle([[NSBundle mainBundle] bundleIdentifier], prefs);
    gCurrent = s;
    return s;
}

#pragma mark - Process checks

// Load-time safety check, independent of user settings. The filter matches on a
// class that exists in plenty of processes, so confirm this is an ordinary app
// before doing anything at all.
BOOL NLProcessIsEligible(void) {
    NSBundle *main = [NSBundle mainBundle];
    if (main.bundleIdentifier.length == 0) return NO;

    id type = [main objectForInfoDictionaryKey:@"CFBundlePackageType"];
    if (![type isKindOfClass:[NSString class]] || ![type isEqualToString:@"APPL"]) return NO;

    if ([main.bundlePath hasPrefix:@"/System/Library/CoreServices/"]) return NO;

    BOOL underAppRoot = NO;
    for (int i = 0; kNLAppRoots[i]; i++) {
        if ([main.bundlePath hasPrefix:kNLAppRoots[i]]) { underAppRoot = YES; break; }
    }
    if (!underAppRoot) return NO;

    return !NLListContains(kNLDeniedBundles, main.bundleIdentifier);
}

BOOL NLProcessUsesContentItems(void) {
    return NLListContains(kNLContentItemBundles, [[NSBundle mainBundle] bundleIdentifier]);
}
