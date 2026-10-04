//
//  NLSettings.m
//  The settings snapshot, the per-app switch, and the load-time safety checks.
//  The file itself is read by NLReadPrefsFile() in NLShared.h.
//

#import "NowLyrics.h"

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
// through the App Store or a jailbreak (its /Applications, NLJBPath).
// Daemons and services that happen to link MediaPlayer (sosd, for one) live
// elsewhere and are not worth a hook.
static NSString *const kNLAppRoots[] = {
    @"/Applications/",
    @"/private/var/containers/Bundle/Application/",
    @"/var/containers/Bundle/Application/",
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

static NLSource NLSourceNamed(id name) {
    if ([name isEqual:@"musixmatch"]) return NLSourceMusixmatch;
    if ([name isEqual:@"lrclib"]) return NLSourceLRCLIB;
    if ([name isEqual:@"netease"]) return NLSourceNetease;
    if ([name isEqual:@"applemusic"]) return NLSourceAppleMusic;
    return NLSourceNone;
}

@implementation NLSettings {
    NSDictionary *_prefs;   // for the per-song offsets, looked up as tracks come
}

- (instancetype)initWithPrefs:(NSDictionary *)prefs {
    if (!(self = [super init])) return nil;
    _prefs = prefs;

    id artistField = prefs[@"artistField"];
    if ([artistField isEqual:@"next"]) _artistMode = NLArtistModeNextLine;
    else if ([artistField isEqual:@"none"]) _artistMode = NLArtistModeNone;
    else _artistMode = NLArtistModeTitle;

    // The order: the user's, any sources it does not name after it in the
    // default order. Before there was an order, a preferred source.
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    id savedOrder = prefs[@"sourceOrder"];
    NSArray *names = [savedOrder isKindOfClass:NSArray.class] ? savedOrder
                   : @[@"applemusic", prefs[@"preferredSource"] ?: @""];
    for (id name in [names arrayByAddingObjectsFromArray:@[@"applemusic", @"musixmatch", @"lrclib", @"netease"]]) {
        NLSource source = NLSourceNamed(name);
        if (source != NLSourceNone && ![order containsObject:@(source)]) [order addObject:@(source)];
    }
    _sourceOrder = [order copy];

    // Defaults match prefs/NowLyrics.plist.
    _useLRCLIB = NLPrefBool(prefs, @"useLRCLIB", YES);
    _useNetease = NLPrefBool(prefs, @"useNetease", YES);
    // Apple Music's lyrics answer only in Music (NLSources.m).
    _useAppleMusic = NLPrefBool(prefs, @"useAppleMusic", NO);
    _useAppleMusicElsewhere = _useAppleMusic && NLPrefBool(prefs, @"appleMusicOtherApps", YES);
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
    _sourceSignature = [NSString stringWithFormat:@"%d%d%d%d%d|%@|%@|%@",
                        _useMusixmatch, _useLRCLIB, _useNetease, _useAppleMusic, _useAppleMusicElsewhere,
                        [_sourceOrder componentsJoinedByString:@","],
                        _musixmatchKey ?: @"", _musixmatchToken ?: @""];

    _enabled = NLEnabledForBundle([[NSBundle mainBundle] bundleIdentifier], prefs);
    return self;
}

- (NSTimeInterval)offsetForTrack:(NSString *)key {
    return _offset + NLTrackOffset(_prefs, key);
}

// `trackSources` maps track keys to the source picked for that song on the
// "Now Playing" page, by the same names as `sourceOrder`.
- (NLSource)sourceForTrack:(NSString *)key {
    id all = _prefs[NL_TRACK_SOURCES_KEY];
    if (![all isKindOfClass:[NSDictionary class]] || key.length == 0) return NLSourceNone;
    return NLSourceNamed(((NSDictionary *)all)[key]);
}

@end

static NLSettings *gCurrent = nil;

NLSettings *NLSettingsCurrent(void) {
    return gCurrent ?: NLSettingsReload();
}

NLSettings *NLSettingsReload(void) {
    gCurrent = [[NLSettings alloc] initWithPrefs:NLReadPrefsFile()];
    return gCurrent;
}

NLSettings *NLSettingsReloadPicking(NSString *trackKey, NSString *source) {
    NSMutableDictionary *prefs = [NLReadPrefsFile() mutableCopy] ?: [NSMutableDictionary dictionary];
    if (trackKey.length) {
        id old = prefs[NL_TRACK_SOURCES_KEY];
        NSMutableDictionary *sources = [old isKindOfClass:[NSDictionary class]] ? [old mutableCopy] : [NSMutableDictionary dictionary];
        if (source.length) sources[trackKey] = source;
        else [sources removeObjectForKey:trackKey];
        prefs[NL_TRACK_SOURCES_KEY] = sources;
    }
    gCurrent = [[NLSettings alloc] initWithPrefs:prefs];
    return gCurrent;
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

    NSString *jailbreakApps = NLJBPath(@"/Applications/");
    BOOL underAppRoot = [main.bundlePath hasPrefix:jailbreakApps] ||
                        [main.bundlePath hasPrefix:[@"/private" stringByAppendingString:jailbreakApps]];
    for (int i = 0; !underAppRoot && kNLAppRoots[i]; i++) {
        if ([main.bundlePath hasPrefix:kNLAppRoots[i]]) underAppRoot = YES;
    }
    if (!underAppRoot) return NO;

    return !NLListContains(kNLDeniedBundles, main.bundleIdentifier);
}

BOOL NLProcessUsesContentItems(void) {
    return NLListContains(kNLContentItemBundles, [[NSBundle mainBundle] bundleIdentifier]);
}
