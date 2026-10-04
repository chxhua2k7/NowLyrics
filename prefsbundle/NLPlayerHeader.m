//
//  NLPlayerHeader.m
//  The lock screen's own player as a table's header (MediaControls' cover
//  sheet platter: artwork, the line being sung as its title, scrubber,
//  transport), behind it its cover blurred; shown on the main page and the
//  "Now Playing" page.
//
//  And the pages' theme: the color of what the island preview shows, the
//  album's or NowLyrics' own.
//

#import "NLLyricsPages.h"
#import "../NLIslandStrip.h"
#import "../NLPlayerTint.h"
#import <dlfcn.h>
#import <objc/runtime.h>

@interface NSObject (NLPlatter)
+ (UIViewController *)coverSheetPlatterViewController;   // MRPlatterViewController, as the lock screen makes it
- (void)setOnScreen:(BOOL)onScreen;                       // what makes it animate (the waveform) and update
@end

@implementation NLPlayerHeader {
    __weak UIViewController *_owner;
    __weak UITableView *_table;
    UIViewController *_platter;
    UIView *_host;
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

    // Its material background gives way to its cover blurred (see -refreshTint).
    _tint = [NLPlayerTintView new];
    [_platter.view insertSubview:_tint atIndex:0];
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
// (NLPlayerTintView). Off: its own material.
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

// Right over the platter's own background, in its shape: it covers it, and
// lets it through with nothing playing (NLPlayerTintView goes clear then).
- (void)layoutTint {
    if (!_tint) return;
    UIView *material = nil;
    @try { material = [_platter valueForKey:@"backgroundView"]; } @catch (NSException *e) { material = nil; }
    _tint.hidden = ![self tintWanted];
    if ([material isKindOfClass:UIView.class] && material.superview) {
        material.alpha = 1;
        UIView *container = material.superview;
        NSUInteger above = [container.subviews indexOfObject:material] + 1;
        if (_tint.superview != container || [container.subviews indexOfObject:_tint] != above) {
            [container insertSubview:_tint aboveSubview:material];
        }
        _tint.frame = material.frame;
        _tint.layer.cornerRadius = MAX(material.layer.cornerRadius, 20);
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
    [self layoutTint];
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
        [self layoutTint];
    }
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
