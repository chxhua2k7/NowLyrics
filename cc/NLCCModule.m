//
//  NLCCModule.m
//  NowLyrics' Control Center modules, one per size (NLCCProvider, Info.plist's
//  NSPrincipalClass: a CCSupport module provider, loaded into SpringBoard and
//  into Settings for Control Center's list of controls). Each is a copy of
//  Control Center's media player, made as the media module makes its own
//  (MediaControls' MRUControlCenterViewController), which NowLyrics lays out
//  as it lays out the media module's (NLSystemPlayerSB.x, in NowLyricsIsland):
//  at the module's size, with the lyrics as there, the lyrics sources in its
//  outputs' place and a lyrics glyph on its output buttons; 1×1 and 1×2 the
//  module's own tile over it (NLCCViews.m). Where NowLyrics does not lay this
//  iOS's player out, the tile alone, at 1×1 and 1×2 only.
//

#import "NLCC.h"
#import "../NLSystemPlayer.h"

@interface NLCCModule : NSObject <CCUIContentModule>
- (instancetype)initWithSize:(NSString *)size;   // rows × columns, as "2x4"
// Control Center's, kept: the player's blocks use it, and NowLyrics' sources
// list asks for it (its settings row).
@property (nonatomic, strong) CCUIContentModuleContext *contentModuleContext;
@end

// Built with -DNLI_FILELOG (as the island's debug builds), what the module
// does goes to /var/mobile/Library/Logs/NowLyricsCC.log.
#ifdef NLI_FILELOG
#define NLCC_LOG(...) NLIAppendLog(@"/var/mobile/Library/Logs/NowLyricsCC.log", \
    [NSString stringWithFormat:@"%@ %@\n", [NSDate date], [NSString stringWithFormat:__VA_ARGS__]])
#else
#define NLCC_LOG(...) do {} while (0)
#endif

NSString *NLCCL(NSString *key) {
    return [NL_ONCE([NSBundle bundleForClass:NLCCModule.class]) localizedStringForKey:key value:key table:nil];
}

#pragma mark - Tile

// The system player's follower of what plays (NowLyricsIsland's), nil without it.
static NLSPFollower *NLCCFollower(void) {
    return [NSClassFromString(@"NLSPFollower") shared];
}

// The tile, showing what plays while it is in a window (the follower reads
// only while something it feeds shows); play or pause sent from it.
@interface NLCCTileHost : UIView
@end

@implementation NLCCTileHost {
    NLCCTileView *_tile;
    NSData *_artwork;
    CFAbsoluteTime _artworkMissingSince;
    UIImage *_cover;
    NSDictionary *_sent;   // MediaRemote's info as the button left it, until MediaRemote's own changes
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _tile = [[NLCCTileView alloc] initWithFrame:self.bounds];
        _tile.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        __weak typeof(self) weakSelf = self;
        _tile.playPause = ^{ [weakSelf nlPlayPause]; };
        [self addSubview:_tile];
    }
    return self;
}

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;   // the module underneath, but for the tile's button
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    NLSPFollower *follower = NLCCFollower();
    if (!self.window || !follower) return;
    __weak typeof(self) weakSelf = self;
    [follower watch:self changed:^{
        NLCCTileHost *host = weakSelf;
        if (!host) return;
        host->_sent = nil;   // MediaRemote's own from here
        [host nlShow];
    }];
    [follower wake];
    [self nlShow];
}

- (void)nlShow {
    NLSPFollower *follower = NLCCFollower();
    NSDictionary *info = _sent ?: follower.info;
    [self nlAdoptArtwork:NLInfoArtwork(info)];
    [_tile showSong:NLCCSongNow(follower.bundleID, follower.np, info, _cover)];
}

// Between songs MediaRemote reports no cover for a moment: the last one stays
// for kNLMissingGrace, then the song has none. A new one is made small off
// the main queue.
- (void)nlAdoptArtwork:(NSData *)artwork {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!artwork && _artwork) {
        if (!_artworkMissingSince) {
            _artworkMissingSince = now;
            __weak typeof(self) weakSelf = self;
            NLAfter(kNLMissingGrace + 0.1, ^{ [weakSelf nlShow]; });
        }
        if (now - _artworkMissingSince < kNLMissingGrace) return;
    }
    _artworkMissingSince = 0;
    if (NLSame(artwork, _artwork)) return;
    _artwork = artwork;
    if (!artwork) {
        _cover = nil;
        return;
    }
    __weak typeof(self) weakSelf = self;
    NLCCMakeCover(artwork, 120, ^(UIImage *small) {
        NLCCTileHost *host = weakSelf;
        if (!host || host->_artwork != artwork) return;
        host->_cover = small;
        [host nlShow];
    });
}

- (void)nlPlayPause {
    _sent = NLCCTogglePlayPause(_sent ?: NLCCFollower().info);
    NLCC_LOG(@"play/pause");
    [self nlShow];
}

@end

// Without NowLyrics' player: the tile alone on Control Center's own platter, which does not open.
@interface NLCCTileViewController : UIViewController <CCUIContentModuleContentViewController>
@end

@implementation NLCCTileViewController
- (void)loadView { self.view = [NLCCTileHost new]; }
- (CGFloat)preferredExpandedContentHeight { return 0; }
- (CGFloat)preferredExpandedContentWidth { return 0; }
- (BOOL)providesOwnPlatter { return NO; }
- (BOOL)shouldBeginTransitionToExpandedContentModule { return NO; }
- (BOOL)_canShowWhileLocked { return YES; }
@end

#pragma mark - Module

@implementation NLCCModule {
    UIViewController<CCUIContentModuleContentViewController> *_contentViewController;
    BOOL _player;      // the media player's copy (else the tile alone)
    NSString *_size;
}

- (instancetype)initWithSize:(NSString *)size {
    if ((self = [super init])) {
        _size = [size copy];
        Class own = NSClassFromString(@"NLSPOwnModule"), player = objc_getClass("MRUControlCenterViewController");
        _player = player && [own canAdopt];
        if (_player) {
            _contentViewController = [player new];
            [own adopt:_contentViewController size:_size tile:[NLCCTileHost new]];
        } else {
            _contentViewController = [NLCCTileViewController new];
        }
        NLCC_LOG(@"module %@: %@", _size, _player ? @"player" : @"tile");
    }
    return self;
}

- (UIViewController<CCUIContentModuleContentViewController> *)contentViewController {
    return _contentViewController;
}

- (UIViewController *)backgroundViewController {
    return nil;
}

// As the media module hands its player Control Center's context (its blocks).
- (void)setContentModuleContext:(CCUIContentModuleContext *)context {
    _contentModuleContext = context;
    if (!_player) return;
    MRUControlCenterViewController *player = (MRUControlCenterViewController *)_contentViewController;
    __weak CCUIContentModuleContext *weakContext = context;
    player.dismissalBlock = ^(void (^completion)(void)) {
        [weakContext dismissModule];
        if (completion) completion();
    };
    player.routingCornerViewTappedBlock = ^{ [weakContext requestExpandModule]; };
    player.homeGestureDismissalAllowedBlock = ^(BOOL allowed) { [weakContext setHomeGestureDismissalAllowed:allowed]; };
}

// CCSupport asks every provided module its size: the module's, the same on its side.
- (CCUILayoutSize)moduleSizeForOrientation:(int)orientation {
    NSArray<NSString *> *parts = [_size componentsSeparatedByString:@"x"];
    return (CCUILayoutSize){.width = (unsigned long long)parts[1].integerValue, .height = (unsigned long long)parts[0].integerValue};
}

@end

#pragma mark - Provider

// The modules in Control Center's list of controls (CCSupport's
// CCSModuleProvider): "NowLyrics 1×1" to "NowLyrics 3×4", or where
// NowLyrics does not lay the player out (after iOS 16) the tile's two.
@interface NLCCProvider : NSObject
@end

@implementation NLCCProvider

static NSString *const kNLCCModulePrefix = @"com.c3x14n.nowlyrics.cc.";

- (NSArray<NSString *> *)nlSizes {
    if (@available(iOS 17.0, *)) return @[@"1x1", @"1x2"];
    return NLCCSizeNames();
}

- (NSString *)nlSizeOfModule:(NSString *)identifier {
    NSString *size = [identifier hasPrefix:kNLCCModulePrefix] ? [identifier substringFromIndex:kNLCCModulePrefix.length] : nil;
    return [NLCCSizeNames() containsObject:size] ? size : nil;
}

- (NSUInteger)numberOfProvidedModules {
    return self.nlSizes.count;
}

- (NSString *)identifierForModuleAtIndex:(NSUInteger)index {
    return [kNLCCModulePrefix stringByAppendingString:self.nlSizes[index]];
}

- (id)moduleInstanceForModuleIdentifier:(NSString *)identifier {
    NSString *size = [self nlSizeOfModule:identifier];
    return size ? [[NLCCModule alloc] initWithSize:size] : nil;
}

- (NSString *)displayNameForModuleIdentifier:(NSString *)identifier {
    NSString *size = [[self nlSizeOfModule:identifier] stringByReplacingOccurrencesOfString:@"x" withString:@"×"];
    return size ? [@"NowLyrics " stringByAppendingString:size] : @"NowLyrics";
}

- (UIImage *)settingsIconForModuleIdentifier:(NSString *)identifier {
    return [UIImage imageNamed:@"SettingsIcon" inBundle:[NSBundle bundleForClass:self.class] compatibleWithTraitCollection:nil];
}

@end
