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

// The app picker is AltList's ATLApplicationListMultiSelectionController, which
// stores the enabled apps as an array of bundle identifiers. nil means the user
// has never opened that page, which is the only time the built-in defaults apply.
static NSArray<NSString *> *NLSelectedApps(NSDictionary *prefs) {
    return NLArray(prefs, @"enabledApps");
}

// Recomputed on every preference change, which is what makes the per-app
// switches take effect without relaunching the host app.
static BOOL NLEnabledForBundle(NSString *bundleID, NSDictionary *prefs) {
    if (NLListContains(kNLDeniedBundles, bundleID)) return NO;
    if (!NLPrefBool(prefs, @"enabled", YES)) return NO;

    // An empty array means "all off" and must not fall through to the defaults.
    NSArray<NSString *> *selected = NLSelectedApps(prefs);
    if (selected) return [selected containsObject:bundleID];
    return NLListContains(kNLDefaultBundles, bundleID);
}

// A per-song table (`trackOffsets`, `trackSources`): track key → value.
// Anything but a dictionary is none.
static NSDictionary *NLPerSong(NSDictionary *prefs, NSString *key) {
    id all = prefs[key];
    return [all isKindOfClass:[NSDictionary class]] ? all : nil;
}

#pragma mark - Snapshot

@implementation NLSettings {
    NSDictionary *_prefs;   // the offsets and the per-song sources, looked up as tracks come
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
    for (NSString *name in NLCompletedSourceOrder(prefs[@"sourceOrder"], prefs[@"preferredSource"])) [order addObject:@(NLSourceNamed(name))];
    _sourceOrder = [order copy];

    // Defaults match prefs/NowLyrics.plist.
    _useLRCLIB = NLPrefBool(prefs, @"useLRCLIB", YES);
    _useNetease = NLPrefBool(prefs, @"useNetease", YES);
    // Apple Music's lyrics: in Music by its item, in other apps through SpringBoard (appleMusicOtherApps).
    _useAppleMusic = NLPrefBool(prefs, @"useAppleMusic", NO);
    _useAppleMusicElsewhere = _useAppleMusic && NLPrefBool(prefs, @"appleMusicOtherApps", YES);
    _killOnChange = NLPrefBool(prefs, @"killOnChange", NO);
    _appleMusicVerified = NLPrefBool(prefs, @"appleMusicVerified", NO);
    _diagnostics = NLPrefBool(prefs, @"diagnostics", NO);
    _spotifyConnect = NLPrefBool(prefs, @"spotifyConnect", YES);
    _hideExplicit = NLPrefBool(prefs, @"hideExplicit", NO);
    _cacheClearedAt = NLPrefNum(prefs, @"cacheClearedAt", 0);
    _musixmatchToken = NLMusixmatchUserToken(prefs[@"musixmatchToken"]);
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
    return NLOffsetForTrack(_prefs, key);
}

// `trackSources` maps track keys to the source picked for that song on the
// "Now Playing" page, by the same names as `sourceOrder`.
- (NLSource)sourceForTrack:(NSString *)key {
    NSDictionary *all = NLPerSong(_prefs, NL_TRACK_SOURCES_KEY);
    return all && key.length ? NLSourceNamed(all[key]) : NLSourceNone;
}

- (BOOL)lyricsOffForTrack:(NSString *)key {
    NSDictionary *all = NLPerSong(_prefs, NL_TRACK_SOURCES_KEY);
    return all && key.length && [all[key] isEqual:NL_TRACK_SOURCE_OFF];
}

// What the app reads, value by value; the per-song tables whole, since any
// song may come up.
- (BOOL)sameEffectAs:(NLSettings *)other {
    if (!other) return NO;
    return _enabled == other->_enabled && _artistMode == other->_artistMode &&
           [_sourceOrder isEqualToArray:other->_sourceOrder] &&
           _useMusixmatch == other->_useMusixmatch && _useLRCLIB == other->_useLRCLIB && _useNetease == other->_useNetease &&
           _useAppleMusic == other->_useAppleMusic && _useAppleMusicElsewhere == other->_useAppleMusicElsewhere &&
           NLSame(_musixmatchKey, other->_musixmatchKey) && NLSame(_musixmatchToken, other->_musixmatchToken) &&
           _killOnChange == other->_killOnChange && _diagnostics == other->_diagnostics &&
           _spotifyConnect == other->_spotifyConnect && _hideExplicit == other->_hideExplicit &&
           _cacheClearedAt == other->_cacheClearedAt &&
           [_sourceSignature isEqualToString:other->_sourceSignature] &&
           NLPrefNum(_prefs, @"offset", 0) == NLPrefNum(other->_prefs, @"offset", 0) &&
           NLSame(NLPerSong(_prefs, NL_TRACK_OFFSETS_KEY), NLPerSong(other->_prefs, NL_TRACK_OFFSETS_KEY)) &&
           NLSame(NLPerSong(_prefs, NL_TRACK_SOURCES_KEY), NLPerSong(other->_prefs, NL_TRACK_SOURCES_KEY));
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

NLSettings *NLSettingsReloadPicking(NSString *trackKey, NSString *source) {
    NSMutableDictionary *prefs = [NLReadPrefsFile() mutableCopy] ?: [NSMutableDictionary dictionary];
    if (trackKey.length) {
        id old = prefs[NL_TRACK_SOURCES_KEY];
        NSMutableDictionary *sources = [old isKindOfClass:[NSDictionary class]] ? [old mutableCopy] : [NSMutableDictionary dictionary];
        sources[trackKey] = source.length ? source : nil;   // nil removes it
        prefs[NL_TRACK_SOURCES_KEY] = sources;
    }
    return NLSettingsSet([[NLSettings alloc] initWithPrefs:prefs]);
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

    // Only real apps: the system ones in /Applications and everything installed
    // through the App Store or a jailbreak (its /Applications, NLJBPath).
    // Daemons and services that happen to link MediaPlayer (sosd, for one) live
    // elsewhere and are not worth a hook.
    NSString *jailbreakApps = NLJBPath(@"/Applications/");
    BOOL underAppRoot = NO;
    for (NSString *root in @[@"/Applications/", @"/private/var/containers/Bundle/Application/", @"/var/containers/Bundle/Application/",
                             jailbreakApps, [@"/private" stringByAppendingString:jailbreakApps]]) {
        if ([main.bundlePath hasPrefix:root]) { underAppRoot = YES; break; }
    }
    if (!underAppRoot) return NO;

    return !NLListContains(kNLDeniedBundles, main.bundleIdentifier);
}

BOOL NLProcessUsesContentItems(void) {
    return NLListContains(kNLContentItemBundles, [[NSBundle mainBundle] bundleIdentifier]);
}
