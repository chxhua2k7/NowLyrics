//
//  NLSettings.m
//  The settings snapshot, the per-app switch, and the load-time safety checks.
//  The file itself is read by NLReadPrefsFile() in NLShared.h.
//

#import "NowLyrics.h"
#import <pthread.h>

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

#pragma mark - Values

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
    if (!NLPrefBool(prefs, @"enabled", YES)) return NO;

    // An empty array means "all off" and must not fall through to the defaults.
    NSSet<NSString *> *selected = NLSelectedApps(prefs);
    if (selected) return [selected containsObject:bundleID];
    return NLListContains(kNLDefaultBundles, bundleID);
}

#pragma mark - Snapshot

@implementation NLSettings

- (instancetype)initWithPrefs:(NSDictionary *)prefs {
    if (!(self = [super init])) return nil;

    id artistField = prefs[@"artistField"];
    if ([artistField isEqual:@"next"]) _artistMode = NLArtistModeNextLine;
    else if ([artistField isEqual:@"none"]) _artistMode = NLArtistModeNone;
    else _artistMode = NLArtistModeTitle;

    id preferred = prefs[@"preferredSource"];
    if ([preferred isEqual:@"musixmatch"]) _preferredSource = NLSourceMusixmatch;
    else if ([preferred isEqual:@"lrclib"]) _preferredSource = NLSourceLRCLIB;
    else if ([preferred isEqual:@"netease"]) _preferredSource = NLSourceNetease;
    else _preferredSource = NLSourceNone;

    // Defaults match prefs/NowLyrics.plist.
    _useLRCLIB = NLPrefBool(prefs, @"useLRCLIB", YES);
    _useNetease = NLPrefBool(prefs, @"useNetease", YES);
    _killOnChange = NLPrefBool(prefs, @"killOnChange", NO);
    _diagnostics = NLPrefBool(prefs, @"diagnostics", NO);
    _spotifyConnect = NLPrefBool(prefs, @"spotifyConnect", YES);
    _hideExplicit = NLPrefBool(prefs, @"hideExplicit", NO);
    _offset = NLPrefNum(prefs, @"offset", 0);
    _cacheClearedAt = NLPrefNum(prefs, @"cacheClearedAt", 0);
    _musixmatchToken = NLExtractToken(prefs[@"musixmatchToken"]);
    _musixmatchKey = NLTrimmed(prefs[@"musixmatchKey"]);

    // Selected but no credentials entered is the same as switched off.
    BOOL wantsMusixmatch = NLPrefBool(prefs, @"useMusixmatch", NO);
    _useMusixmatch = wantsMusixmatch && (_musixmatchKey.length || _musixmatchToken.length);
    if (wantsMusixmatch && !_useMusixmatch) {
        NLLog(@"Musixmatch selected but no token or API key set, skipping that source");
    }

    // Only these invalidate lyrics already fetched. The offset control posts a
    // notification per change, so clearing the cache on every reload would
    // mean refetching on every nudge.
    _sourceSignature = [NSString stringWithFormat:@"%d%d%d|%ld|%@|%@",
                        _useMusixmatch, _useLRCLIB, _useNetease, (long)_preferredSource,
                        _musixmatchKey ?: @"", _musixmatchToken ?: @""];

    _enabled = NLEnabledForBundle([[NSBundle mainBundle] bundleIdentifier], prefs);
    return self;
}

@end

// The snapshot is swapped on the main queue, but the hooks in NowLyrics.xm
// read it on whatever thread the app publishes from: a reader taking the old
// one just as the swap releases it would retain a freed object.
static NLSettings *gCurrent = nil;
static pthread_mutex_t gCurrentMutex = PTHREAD_MUTEX_INITIALIZER;

static NLSettings *NLSettingsSet(NLSettings *settings) {
    pthread_mutex_lock(&gCurrentMutex);
    gCurrent = settings;
    pthread_mutex_unlock(&gCurrentMutex);
    return settings;
}

NLSettings *NLSettingsCurrent(void) {
    pthread_mutex_lock(&gCurrentMutex);
    NLSettings *current = gCurrent;
    pthread_mutex_unlock(&gCurrentMutex);
    return current ?: NLSettingsReload();
}

NLSettings *NLSettingsReload(void) {
    return NLSettingsSet([[NLSettings alloc] initWithPrefs:NLReadPrefsFile()]);
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
