//
//  NLPlayerHeader.m
//  The lock screen's own player as a table's header (MediaControls' cover
//  sheet platter: artwork, the line being sung as its title, scrubber,
//  transport) on a background of its own, as it has its platter's on the lock
//  screen (glass on iOS 26, a system material below); with Player over its
//  cover its cover blurred over that. Shown on the main page, the "Now
//  Playing" page and (NLPageTop) the other pages but the island's.
//
//  And the pages' theme: the color of what the island preview shows, the
//  album's or NowLyrics' own.
//

#import "NLLyricsPages.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import "../NLIslandStrip.h"
#import "../NLPlayerTint.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>

@interface NSObject (NLPlatter)
+ (UIViewController *)coverSheetPlatterViewController;   // MRPlatterViewController, as the lock screen makes it
- (void)setOnScreen:(BOOL)onScreen;                       // what makes it animate (the waveform) and update
+ (id)effectWithStyle:(NSInteger)style;                   // UIGlassEffect (iOS 26)
@end

static const CGFloat kNLGlassRadius = 28;   // the lock screen player's corners on iOS 26
static const CGFloat kNLPlatterRadius = 20;   // below that, as the tint's

@implementation NLPlayerHeader {
    __weak UIViewController *_owner;
    __weak UITableView *_table;
    UIViewController *_platter;
    UIView *_host;
    UIView *_backdrop;               // the background under the player (glass on iOS 26)
    NLWaveformDriver *_waveform;     // moves its waveform, which has no audio tap here
    NLPlayerTintView *_tint;         // the platter's background, from its cover (NLPlayerTint.h)
    BOOL _tintedOnce;                // shown once: changes fade after that
    id _infoObserver;                // MediaRemote's now-playing changes
    id _nextUpObserver;              // NextUp 3's next track changes
    NSUInteger _ticks;
}


- (instancetype)initWithOwner:(UIViewController *)owner table:(UITableView *)table {
    if (!(self = [super init])) return nil;
    _owner = owner;
    _table = table;
    dlopen("/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls", RTLD_NOW);
    NLNextUpLoad();   // NextUp 3, if installed: its Up Next row, as on the lock screen
    Class platterClass = objc_getClass("MRPlatterViewController");
    if (![platterClass respondsToSelector:@selector(coverSheetPlatterViewController)]) return self;
    _platter = [platterClass coverSheetPlatterViewController];
    if (!_platter) return self;
    _host = [[UIView alloc] initWithFrame:CGRectMake(0, 0, table.bounds.size.width, 220)];
    [owner addChildViewController:_platter];
    [_host addSubview:_platter.view];
    [_platter didMoveToParentViewController:owner];
    table.tableHeaderView = _host;

    // On the lock screen the player sits on its platter's material; here its
    // own material shows nothing, so it gets a background of its own: iOS 26's
    // glass, or below that a system material. Player over its cover lies over it.
    UIVisualEffect *effect = nil;
    if (@available(iOS 26.0, *)) {
        Class glassClass = NSClassFromString(@"UIGlassEffect");
        id glass = [glassClass respondsToSelector:@selector(effectWithStyle:)] ? [glassClass effectWithStyle:0] : nil;   // regular
        if ([glass isKindOfClass:UIVisualEffect.class]) effect = glass;
    } else {
        effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemThinMaterial];
    }
    if (effect) {
        _backdrop = [[UIVisualEffectView alloc] initWithEffect:effect];
        _backdrop.userInteractionEnabled = NO;
        _backdrop.clipsToBounds = YES;
        _backdrop.layer.cornerCurve = kCACornerCurveContinuous;
        [_host insertSubview:_backdrop belowSubview:_platter.view];
    }

    // Its material background gives way to its cover blurred (see -refreshTint),
    // below iOS 26 (NLPlayerTintAvailable).
    if (NLPlayerTintAvailable()) {
        _tint = [NLPlayerTintView new];
        [_platter.view insertSubview:_tint atIndex:0];
    }
    // Before the page is shown: Crescendo's row and the color in place from the
    // first frame, not one refresh (and a jump) later.
    NLCrescendoSyncPlayer(_platter);
    [self refreshTint];

    // A new song's color as soon as MediaRemote has its cover, rather than at
    // the next refresh.
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void (*registerFor)(dispatch_queue_t) = (void (*)(dispatch_queue_t))NLMediaRemote("MRMediaRemoteRegisterForNowPlayingNotifications");
        if (registerFor) registerFor(dispatch_get_main_queue());
    });
    __weak typeof(self) weakSelf = self;
    // NextUp's row comes and goes with the queue: the player's height with it.
    _nextUpObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"NUNextUpDidChangeNotification"
                                                                        object:nil queue:NSOperationQueue.mainQueue
                                                                    usingBlock:^(NSNotification *note) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf layout]; });
    }];
    _infoObserver = [[NSNotificationCenter defaultCenter] addObserverForName:@"kMRMediaRemoteNowPlayingInfoDidChangeNotification"
                                                                      object:nil queue:NSOperationQueue.mainQueue
                                                                  usingBlock:^(NSNotification *note) {
        [weakSelf refreshTint];
        NLThemeRefresh();
    }];
    return self;
}

- (void)dealloc {
    if (_infoObserver) [[NSNotificationCenter defaultCenter] removeObserver:_infoObserver];
    if (_nextUpObserver) [[NSNotificationCenter defaultCenter] removeObserver:_nextUpObserver];
}

// Behind the player, while the switch is on: the cover blurred and darkened
// (NLPlayerTintView). Off: the background under the player.
- (BOOL)tintWanted {
    id on = NLReadPref(nil, NL_PLAYER_TINT_KEY);
    return ![on respondsToSelector:@selector(boolValue)] || [on boolValue];
}

- (void)refreshTint {
    if (!_tint) return;
    NLNowPlayingInfo(^(NSDictionary *info) {
        BOOL animated = self->_tintedOnce;
        self->_tintedOnce = YES;
        [self->_tint showNowPlaying:info animated:animated];
    });
}

// The player's own material, which this page shows (the lock screen's
// platter gives it one there).
- (UIView *)material {
    UIView *material = nil;
    @try { material = [_platter valueForKey:@"backgroundView"]; } @catch (NSException *e) { material = nil; }
    return [material isKindOfClass:UIView.class] ? material : nil;
}

// Under the player, in its frame and corners: its background, and the tint.
- (void)layoutBackground {
    if (_backdrop) {
        CGRect frame = _platter.view.frame;
        if (!CGRectEqualToRect(_backdrop.frame, frame)) _backdrop.frame = frame;
        CGFloat radius = kNLGlassRadius;
        if (@available(iOS 26.0, *)) {} else radius = MAX([self material].layer.cornerRadius, kNLPlatterRadius);
        _backdrop.layer.cornerRadius = radius;
    }
    [self layoutTint];
}

// Right over the player's material, in its shape: it covers it (with nothing
// playing, in NowLyrics' coral).
- (void)layoutTint {
    if (!_tint) return;
    UIView *material = [self material];
    _tint.hidden = ![self tintWanted];
    id clear = NLReadPref(nil, @"playerTintClear");
    _tint.clearness = MIN(MAX([clear respondsToSelector:@selector(doubleValue)] ? [clear doubleValue] : 50, 0), 100) / 100;
    _tint.material = material;
    if (material.superview) {
        material.alpha = 1;
        UIView *container = material.superview;
        NSUInteger above = [container.subviews indexOfObject:material] + 1;
        if (_tint.superview != container || [container.subviews indexOfObject:_tint] != above) {
            [container insertSubview:_tint aboveSubview:material];
        }
        _tint.frame = material.frame;
        _tint.layer.cornerRadius = MAX(material.layer.cornerRadius, kNLPlatterRadius);
    } else {
        if (_tint.superview != _platter.view) [_platter.view insertSubview:_tint atIndex:0];
        _tint.frame = _platter.view.bounds;
        _tint.layer.cornerRadius = 24;
        [_platter.view sendSubviewToBack:_tint];
    }
}

// Inset like the table's cards, as tall as it asks to be, with room above it
// and before the first card.
- (void)layout {
    UITableView *table = _table;
    if (!_platter || !table) return;
    CGFloat inset = table.layoutMargins.left;
    CGFloat width = MAX(table.bounds.size.width - inset * 2, 0);
    NLCrescendoSyncPlayer(_platter);
    // The player's own size, with what tweaks add to it (Crescendo's volume row,
    // NextUp's Up Next row: both grow -[MRUNowPlayingView sizeThatFits:]).
    CGFloat height = NLPlayerFittingHeight(_platter, width);
    if (height < 60) height = _platter.preferredContentSize.height;
    if (height < 60) height = [_platter.view systemLayoutSizeFittingSize:CGSizeMake(width, UILayoutFittingCompressedSize.height)].height;
    if (height < 60) height = 200;
    CGRect frame = CGRectMake(inset, 16, width, height);
    if (!CGRectEqualToRect(_platter.view.frame, frame)) _platter.view.frame = frame;
    CGRect host = CGRectMake(0, 0, table.bounds.size.width, 16 + height + 24);
    if (!CGRectEqualToRect(_host.frame, host) || table.tableHeaderView != _host) {
        _host.frame = host;
        table.tableHeaderView = _host;   // re-set so the table takes the new height
    }
    [_platter.view layoutIfNeeded];
    [self layoutBackground];
    [self syncWaveform];
}

- (void)appear {
    [self refreshTint];
    if ([_platter respondsToSelector:@selector(setOnScreen:)]) [(id)_platter setOnScreen:YES];
}

- (void)disappear {
    [_waveform stop];
    _waveform = nil;
    if ([_platter respondsToSelector:@selector(setOnScreen:)]) [(id)_platter setOnScreen:NO];
}

// The page's top shows something else now: the player leaves the table and
// its owner.
- (void)remove {
    [self disappear];
    if (_platter) {
        [_platter willMoveToParentViewController:nil];
        [_platter.view removeFromSuperview];
        [_platter removeFromParentViewController];
    }
    UITableView *table = _table;
    if (table.tableHeaderView == _host) table.tableHeaderView = nil;
    _platter = nil;
    _tint = nil;
    _backdrop = nil;
    _host = nil;
}

// The platter's own waveform gets its levels from an audio tap Preferences
// cannot have; made-up ones keep it moving while something plays, and it keeps
// its own look.
- (void)syncWaveform {
    if (!_platter) return;
    if (!_waveform) _waveform = [NLWaveformDriver new];
    [_waveform driveViewsIn:_platter.view];
    NLNowPlayingIsPlaying(^(BOOL playing) { self->_waveform.playing = playing; });
}

- (void)tick {
    [self syncWaveform];
    if (NLCrescendoSyncPlayer(_platter)) [self layout];
    if (_ticks++ % 4 == 0) {
        [self refreshTint];
        [self layoutBackground];
    }
}

@end

#pragma mark - The other pages

BOOL NLTopOnEveryPage(void) {
    id on = NLReadPref(nil, @"topOnEveryPage");
    return ![on respondsToSelector:@selector(boolValue)] || [on boolValue];
}

static const CGFloat kNLIslandRoomBelow = 12;   // between the open island and the first card

// What the other pages' island previews ask for their values (their
// specifier's target, which the specifier keeps): the island page's settings.
@interface NLIslandPreviewValuesSource : NSObject
@end

@implementation NLIslandPreviewValuesSource
- (NSDictionary *)nlIslandPreviewValues {
    return NLIslandPreviewValuesFromPlist(nil);
}
@end

@implementation NLPageTop {
    __weak UIViewController *_owner;
    __weak UITableView *_table;
    NSString *_shown;            // "player", "island" or "none"
    NLPlayerHeader *_player;
    UIView *_islandHost;         // the table's header, holding the island preview
    PSTableCell *_island;        // NLIslandPreviewCell
    PSSpecifier *_islandRow;     // its specifier, which a cell does not keep (its page does)
    NSTimer *_refresh;
    NSUInteger _ticks;
    BOOL _appeared;
}

- (instancetype)initWithOwner:(UIViewController *)owner table:(UITableView *)table {
    if (!(self = [super init])) return nil;
    _owner = owner;
    _table = table;
    _shown = @"none";
    return self;
}

- (void)dealloc {
    [_refresh invalidate];
}

- (void)update {
    UIViewController *owner = _owner;
    UITableView *table = _table;
    NSString *wanted = owner && table && NLTopOnEveryPage() ? NLMainPageTop(nil) : @"none";
    if ([wanted isEqualToString:_shown]) return;
    [_refresh invalidate];
    _refresh = nil;
    [_player remove];
    _player = nil;
    if (_islandHost) {
        [_islandHost removeFromSuperview];
        if (table.tableHeaderView == _islandHost) table.tableHeaderView = nil;
        _islandHost = nil;
        _island = nil;
        _islandRow = nil;
    }
    _shown = wanted;
    if ([wanted isEqualToString:@"player"]) {
        _player = [[NLPlayerHeader alloc] initWithOwner:owner table:table];
        [_player layout];
    } else if ([wanted isEqualToString:@"island"]) {
        [self addIslandPreview];
    }
    if (_appeared) [self appear];   // changed from this page
}

// The main page's island preview row, as the table's header: the island
// floats over the table from its top either way (NLIslandPreviewCell.m), and
// the header keeps the room it opens into. There the gaps around the row's
// group make up the rest of that room; here the first card follows at once,
// so the header holds all of it.
- (void)addIslandPreview {
    UITableView *table = _table;
    Class cellClass = NSClassFromString(@"NLIslandPreviewCell");
    if (!table || !cellClass) return;
    static NLIslandPreviewValuesSource *source;
    if (!source) source = [NLIslandPreviewValuesSource new];
    PSSpecifier *specifier = [PSSpecifier preferenceSpecifierNamed:@"" target:source set:nil get:nil detail:nil cell:PSStaticTextCell edit:nil];
    specifier.identifier = @"islandPreview";
    CGFloat height = NLIslandPreviewOpenBottom() + kNLIslandRoomBelow;
    [specifier setProperty:@(height) forKey:@"height"];
    _islandRow = specifier;
    _island = [[cellClass alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"islandPreview" specifier:specifier];
    _island.specifier = specifier;   // what a table sets on the cells it shows
    _islandHost = [[UIView alloc] initWithFrame:CGRectMake(0, 0, table.bounds.size.width, height)];
    _island.frame = _islandHost.bounds;
    _island.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [_islandHost addSubview:_island];
    table.tableHeaderView = _islandHost;
}

- (void)layout {
    [_player layout];
    UITableView *table = _table;
    if (_islandHost && table) {
        CGFloat height = NLIslandPreviewOpenBottom() + kNLIslandRoomBelow;
        CGRect frame = CGRectMake(0, 0, table.bounds.size.width, height);
        if (!CGRectEqualToRect(_islandHost.frame, frame) || table.tableHeaderView != _islandHost) {
            _islandHost.frame = frame;
            table.tableHeaderView = _islandHost;   // re-set so the table takes the new height
        }
    }
}

// While the page is up the player follows what is playing, as the main page's
// does, and the theme what the island preview shows.
- (void)appear {
    _appeared = YES;
    [_player appear];
    [_refresh invalidate];
    _refresh = nil;
    if ([_shown isEqualToString:@"none"]) return;
    __weak typeof(self) weakSelf = self;
    _refresh = [NSTimer scheduledTimerWithTimeInterval:0.75 repeats:YES block:^(NSTimer *timer) { [weakSelf tick]; }];
}

- (void)disappear {
    _appeared = NO;
    [_refresh invalidate];
    _refresh = nil;
    [_player disappear];
}

- (void)tick {
    [_player tick];
    if (_ticks++ % 4 == 0) NLThemeRefresh();
}

@end

#pragma mark - Theme

NSString *const NLThemeChangedNotification = @"NLThemeChangedNotification";

static UIColor *gThemeColor;
static UIColor *gThemeSource;   // the color gThemeColor was made from

UIColor *NLThemeColor(void) {
    if (!gThemeSource) NLThemeSetColor(NLNowLyricsColor());
    return gThemeColor;
}

// A cover's color as a tint that reads on the page: light on dark, deep on
// light. nil (the system's) for a grey one.
static UIColor *NLThemeFrom(UIColor *color) {
    CGFloat h = 0, s = 0, b = 0, a = 1;
    if (![color getHue:&h saturation:&s brightness:&b alpha:&a] || s < 0.15) return nil;
    s = MIN(s, 0.85);
    return [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *traits) {
        BOOL dark = traits.userInterfaceStyle == UIUserInterfaceStyleDark;
        return [UIColor colorWithHue:h saturation:s brightness:dark ? MAX(b, 0.85) : MIN(b, 0.62) alpha:1];
    }];
}

void NLThemeSetColor(UIColor *color) {
    if (gThemeSource && [color isEqual:gThemeSource]) return;
    gThemeSource = color ?: UIColor.clearColor;
    gThemeColor = NLThemeFrom(color);
    [[NSNotificationCenter defaultCenter] postNotificationName:NLThemeChangedNotification object:nil];
}

// The cover the theme's color was last taken from, and that color: refreshes
// bring the same cover back (every few seconds, and with each line NowLyrics
// publishes as the title), and decoding it is the costly part.
static NSData *gThemeArtwork;
static UIColor *gThemeArtworkColor;

// What the island preview shows, without it on screen: what is playing, when
// its "Preview what's playing" switch is on and the cover has a color;
// NowLyrics' sample otherwise.
void NLThemeRefresh(void) {
    id live = NLReadPref(nil, @"islandPreviewLive");
    if (![live respondsToSelector:@selector(boolValue)] || ![live boolValue]) {
        NLThemeSetColor(NLNowLyricsColor());
        return;
    }
    NLNowPlayingInfo(^(NSDictionary *info) {
        NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        id title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
        BOOL usable = [title isKindOfClass:NSString.class] && [title length] && [artwork isKindOfClass:NSData.class] && artwork.length;
        if (usable && ![artwork isEqual:gThemeArtwork]) {
            gThemeArtwork = artwork;
            gThemeArtworkColor = NLColorFromArtwork(artwork);
        }
        UIColor *color = usable ? gThemeArtworkColor : nil;
        NLThemeSetColor(color ?: NLNowLyricsColor());
    });
}

static void NLThemeSwitches(UIView *view, UIColor *color) {
    if ([view isKindOfClass:UISwitch.class]) {
        ((UISwitch *)view).onTintColor = color;
        return;
    }
    for (UIView *sub in view.subviews) NLThemeSwitches(sub, color);
}

void NLThemeCell(UITableViewCell *cell) {
    NLThemeSwitches(cell, gThemeColor);
}

void NLThemeTable(UITableView *table) {
    for (UITableViewCell *cell in table.visibleCells) NLThemeCell(cell);
}
