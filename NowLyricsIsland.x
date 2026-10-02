//
//  NowLyricsIsland.x
//  The current lyric line in a strip under the compact Dynamic Island.
//  SpringBoard only.
//
//  - Height: -[SBSystemApertureSceneElement preferredEdgeOutsetsForLayoutMode:
//    suggestedOutsets:maximumOutsets:] is asked for the now-playing element's
//    frame; in compact layout (SpringBoard's mode 2; MediaRemoteUI numbers it 3)
//    its bottom outset is pushed down until the island ends exactly on the
//    status bar's line (the top safe-area inset), never past it. Outsets are
//    negative outwards, and SpringBoard validates and animates the result like
//    any element's own.
//  - Width: the line is centred under the camera at the camera's width, so it
//    stays put while the artwork and waveform change size, and clear of
//    artwork-spinning tweaks.
//  - Strip: hung in the island's black pill (SBSystemApertureContainerView),
//    found from the view SpringBoard hands to -_layoutSceneViewInContainerView:.
//    That view only carries MediaRemoteUI's scene, and inside MediaRemoteUI only
//    the leading and trailing views reach the screen in compact layout (and get
//    transformed by artwork-spinning tweaks), so the strip lives here.
//  - Text: the now-playing title, which NowLyrics already sets to the current
//    line, from MRMediaRemoteGetNowPlayingInfo; SBMediaController keeps no info
//    dictionary on 16.5.1. The artwork in the same answer gives the album color.
//
//  Settings are the NowLyrics preference file, re-read on its reload
//  notification, so every change on the settings page applies at once.
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>

// The pill. Its content view is what SpringBoard scales (a transform against a
// reference size), fades (contentAlpha) and clips while the island resizes,
// with the artwork and waveform in it; addContentSubview: puts a view there.
@interface SBSystemApertureContainerView : UIView
- (void)addContentSubview:(UIView *)view;
@end

@interface SBSystemApertureSceneElement : NSObject
- (NSString *)clientIdentifier;
- (NSInteger)layoutMode;
@end

@interface SBSystemApertureViewController : UIViewController
@property (readonly, nonatomic) CGRect minimumSensorRegionFrame;
- (void)preferredEdgeOutsetsDidInvalidateForLayoutSpecifier:(id)specifier;
@end

static NSString *const kNLPrefsDomain = @"app.nowlyrics";
static NSString *const kNLReloadNotification = @"app.nowlyrics/ReloadPrefs";
static const NSInteger kNLCompactLayoutMode = 2;   // SpringBoard's numbering
// The added band is only ~11 pt and a line's box (its font's line height) is
// taller, so the box hangs 1 pt past the island's bottom: that point is line
// spacing, never ink, and the capsule clip takes it. The text then sits in the
// middle of the band instead of on the camera's edge.
static const CGFloat kNLBottomGap = -1;

#pragma mark - Settings

typedef struct {
    BOOL on;
    CGFloat fontSize;
    BOOL artworkColor;
    BOOL scrollUp;       // line change pushes up instead of fading
    CGFloat speed;       // marquee, pt/s
} NLIslandSettings;

static NLIslandSettings gSettings = { NO, 11, NO, NO, 30 };

static CGFloat NLNum(NSDictionary *prefs, NSString *key, CGFloat fallback, CGFloat lo, CGFloat hi) {
    id v = prefs[key];
    CGFloat n = [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : fallback;
    return isnan(n) ? fallback : MIN(MAX(n, lo), hi);
}

static BOOL NLBool(NSDictionary *prefs, NSString *key, BOOL fallback) {
    id v = prefs[key];
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : fallback;
}

// The file NLSettings.m reads, at the paths SpringBoard can see.
static NLIslandSettings NLIslandReadSettings(void) {
    NSDictionary *prefs = nil;
    for (NSString *root in @[@"/var/jb/var/mobile", @"/var/mobile"]) {
        prefs = [NSDictionary dictionaryWithContentsOfFile:
                 [NSString stringWithFormat:@"%@/Library/Preferences/%@.plist", root, kNLPrefsDomain]];
        if (prefs.count) break;
    }
    NLIslandSettings s;
    s.on = NLBool(prefs, @"enabled", YES) && NLBool(prefs, @"islandLyrics", NO);
    s.fontSize = NLNum(prefs, @"islandFontSize", 11, 9, 15);
    s.artworkColor = [prefs[@"islandColor"] isEqual:@"artwork"];
    s.scrollUp = [prefs[@"islandTransition"] isEqual:@"up"];
    s.speed = NLNum(prefs, @"islandMarqueeSpeed", 30, 10, 80);
    return s;
}

#pragma mark - State

static __weak SBSystemApertureViewController *gApertureVC = nil;
static __weak SBSystemApertureSceneElement *gElement = nil;
static __weak UIView *gSceneContainer = nil;   // as handed to -_layoutSceneViewInContainerView:

// Geometry. gExtra is what the island is grown by: the distance from the
// compact island's bottom to the status bar's line. gSensorWidth is the
// camera's width; the line is centred under it at that width. Both come from
// the fixed sensor region (14 Pro values until measured). The artwork and
// waveform widths SpringBoard reports change across expand and collapse, and
// a line placed between them moved sideways with every change.
static CGFloat gExtra = 11;
static CGFloat gSensorWidth = 125;
static const CGFloat kNLContentGap = 4;   // kept clear on each side of the line

static NSString *gTitle = nil;
static BOOL gExplicit = NO;   // the track is flagged explicit (and NowLyrics was not told to hide that)
static UIColor *gArtworkColor = nil;
static NSUInteger gArtworkHash = 0;

static BOOL NLIsNowPlaying(id element) {
    NSString *client = [element respondsToSelector:@selector(clientIdentifier)] ? [element clientIdentifier] : nil;
    return [client isEqualToString:@"com.apple.MediaRemoteUI"];
}

// The black pill on screen.
static UIView *NLPillFor(UIView *view) {
    Class pill = objc_getClass("SBSystemApertureContainerView");
    for (UIView *v = view; v; v = v.superview) {
        if (pill && [v isKindOfClass:pill]) return v;
    }
    return nil;
}

#pragma mark - Strip view

// A clipping strip with the line in it. Line changes animate an inner content
// view, so a pushed-out line is cut at the strip's edge instead of sliding over
// the artwork. Lines too wide for the strip scroll back and forth at the set
// speed, with the edges faded so the text does not end in a hard cut.
@interface NLIslandStripView : UIView
@property (nonatomic, readonly) UILabel *label;
- (void)setText:(NSString *)text explicit:(BOOL)explicit scrollUp:(BOOL)scrollUp;
- (void)applyFontSize:(CGFloat)size color:(UIColor *)color speed:(CGFloat)speed;
@end

@implementation NLIslandStripView {
    UIView *_content;
    UILabel *_label;
    CAGradientLayer *_fade;
    CGFloat _speed;
    CGFloat _laidOutWidth;
    NSString *_text;
    BOOL _explicit;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;
        _content = [[UIView alloc] initWithFrame:self.bounds];
        _content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_content];
        _label = [UILabel new];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.lineBreakMode = NSLineBreakByClipping;
        [_content addSubview:_label];
        _fade = [CAGradientLayer layer];
        _fade.startPoint = CGPointMake(0, 0.5);
        _fade.endPoint = CGPointMake(1, 0.5);
        _speed = 30;
    }
    return self;
}

- (UILabel *)label { return _label; }

- (void)applyFontSize:(CGFloat)size color:(UIColor *)color speed:(CGFloat)speed {
    UIFont *font = [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
    BOOL changed = ![font isEqual:_label.font] || speed != _speed;
    BOOL recolor = ![color isEqual:_label.textColor];
    _label.font = font;
    _label.textColor = color;
    _speed = speed;
    if (changed || recolor) _label.attributedText = [self lineWithText:_text explicit:_explicit];
    if (changed) [self restartMarquee];
}

// The line, with the system's "E" after it for explicit tracks, as the
// expanded island and the lock screen show it: the e.square.fill symbol at the
// text's size and a little dimmer than the text.
- (NSAttributedString *)lineWithText:(NSString *)text explicit:(BOOL)explicit {
    UIFont *font = _label.font ?: [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
    UIColor *color = _label.textColor ?: UIColor.whiteColor;
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] initWithString:text ?: @""
        attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}];
    if (!explicit || text.length == 0) return line;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithFont:font scale:UIImageSymbolScaleSmall];
    UIImage *badge = [[UIImage systemImageNamed:@"e.square.fill" withConfiguration:config]
                      imageWithTintColor:[color colorWithAlphaComponent:0.7] renderingMode:UIImageRenderingModeAlwaysOriginal];
    if (!badge) return line;
    NSTextAttachment *attachment = [NSTextAttachment new];
    attachment.image = badge;
    CGFloat side = round(font.capHeight + 2);
    attachment.bounds = CGRectMake(0, round((font.capHeight - side) / 2), side * badge.size.width / MAX(badge.size.height, 1), side);
    [line appendAttributedString:[[NSAttributedString alloc] initWithString:@" " attributes:@{NSFontAttributeName: font}]];
    [line appendAttributedString:[NSAttributedString attributedStringWithAttachment:attachment]];
    return line;
}

- (void)setText:(NSString *)text explicit:(BOOL)explicit scrollUp:(BOOL)scrollUp {
    NSString *old = _text ?: @"";
    text = text ?: @"";
    if ([text isEqualToString:old] && explicit == _explicit) return;
    BOOL sameLine = [text isEqualToString:old];   // only the badge changed: no line change animation
    NSAttributedString *leavingLine = _label.attributedText;
    _text = [text copy];
    _explicit = explicit;
    if (sameLine || !scrollUp || old.length == 0 || CGRectIsEmpty(_content.bounds)) {
        CATransition *t = [CATransition animation];
        t.type = kCATransitionFade;
        t.duration = 0.25;
        [_content.layer addAnimation:t forKey:@"line"];
        _label.attributedText = [self lineWithText:text explicit:explicit];
        [self restartMarquee];
        return;
    }

    // Scroll up, done by hand: the old line rises a full line height and fades
    // while the new one comes up from a full line height below. Core Animation's
    // push transition slides snapshots of the whole layer and, in a strip this
    // short, the two lines ran into each other halfway.
    UILabel *leaving = [UILabel new];
    leaving.textAlignment = _label.textAlignment;
    leaving.lineBreakMode = _label.lineBreakMode;
    leaving.attributedText = leavingLine;
    leaving.frame = _label.layer.presentationLayer ? _label.layer.presentationLayer.frame : _label.frame;
    [_content addSubview:leaving];

    _label.attributedText = [self lineWithText:text explicit:explicit];
    [self restartMarquee];
    CGFloat shift = _content.bounds.size.height;
    _label.transform = CGAffineTransformMakeTranslation(0, shift);
    _label.alpha = 0;
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        leaving.transform = CGAffineTransformMakeTranslation(0, -shift);
        leaving.alpha = 0;
        self->_label.transform = CGAffineTransformIdentity;
        self->_label.alpha = 1;
    } completion:^(BOOL finished) {
        [leaving removeFromSuperview];
    }];
}

// The width changes all through SpringBoard's resize animations. Restarting the
// marquee on every step would make the line jump, so wait until it settles;
// meanwhile the label keeps its frame and the strip just clips it.
- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.bounds.size.width == _laidOutWidth) return;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restartMarquee) object:nil];
    [self performSelector:@selector(restartMarquee) withObject:nil afterDelay:0.4];
}

- (void)restartMarquee {
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(restartMarquee) object:nil];
    [_label.layer removeAnimationForKey:@"marquee"];
    CGRect b = _content.bounds;
    _laidOutWidth = b.size.width;
    CGFloat textWidth = ceil([_label sizeThatFits:CGSizeMake(CGFLOAT_MAX, b.size.height)].width);
    CGFloat overflow = textWidth - b.size.width;
    if (overflow <= 1 || b.size.width <= 0) {
        _label.frame = b;
        self.layer.mask = nil;
        return;
    }

    // Start flush left, glide to flush right, hold, jump back. Holds are long
    // enough to read the ends; the whole loop repeats while the line lasts.
    _label.frame = CGRectMake(0, 0, textWidth, b.size.height);
    CGFloat edge = 10;
    _fade.frame = b;
    _fade.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor,
                     (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _fade.locations = @[@0, @(edge / b.size.width), @(1 - edge / b.size.width), @1];
    self.layer.mask = _fade;

    CGFloat startX = textWidth / 2;
    CGFloat endX = startX - overflow;
    double hold = 1.2, glide = overflow / MAX(_speed, 1), total = hold + glide + hold;
    CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"position.x"];
    a.values = @[@(startX), @(startX), @(endX), @(endX)];
    a.keyTimes = @[@0, @(hold / total), @((hold + glide) / total), @1];
    a.duration = total;
    a.repeatCount = HUGE_VALF;
    a.removedOnCompletion = NO;
    [_label.layer addAnimation:a forKey:@"marquee"];
}

@end

// Content-view-sized and clipped to the capsule, so nothing escapes the black.
// It lives in the pill's content view (see NLIslandUpdate), which SpringBoard
// scales, fades and clips together with the artwork and waveform while the
// island resizes, so the line needs no resize handling of its own.
@interface NLIslandClipView : UIView
@end

@implementation NLIslandClipView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.layer.cornerCurve = kCACornerCurveCircular;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) / 2;
}
@end

static NLIslandStripView *gStrip = nil;
static NLIslandClipView *gClip = nil;

#pragma mark - Album color

// The most colorful bright pixel of a small copy of the artwork, lifted until
// it reads on black. Average colors come out muddy, so the vivid one wins.
static UIColor *NLColorFromArtwork(UIImage *image) {
    CGImageRef cg = image.CGImage;
    if (!cg) return nil;
    enum { side = 16 };
    uint8_t px[side * side * 4];
    memset(px, 0, sizeof(px));
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, side, side, 8, side * 4, space,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) return nil;
    CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
    CGContextDrawImage(ctx, CGRectMake(0, 0, side, side), cg);
    CGContextRelease(ctx);

    CGFloat bestScore = -1, bh = 0, bs = 0, bb = 0;
    for (size_t i = 0; i < side * side; i++) {
        UIColor *c = [UIColor colorWithRed:px[i * 4] / 255.0 green:px[i * 4 + 1] / 255.0 blue:px[i * 4 + 2] / 255.0 alpha:1];
        CGFloat h, s, b, a;
        if (![c getHue:&h saturation:&s brightness:&b alpha:&a]) continue;
        CGFloat score = s * (0.4 + b);
        if (b > 0.3 && score > bestScore) { bestScore = score; bh = h; bs = s; bb = b; }
    }
    if (bestScore < 0.15) return nil;   // a grey or dark cover: stay white
    return [UIColor colorWithHue:bh saturation:MIN(bs, 0.65) brightness:MAX(bb, 0.92) alpha:1];
}

#pragma mark - Updating

static UIColor *NLTextColor(void) {
    if (gSettings.artworkColor && gArtworkColor) return gArtworkColor;
    return [UIColor colorWithWhite:1 alpha:0.92];
}

static void NLIslandInvalidateHeight(void);

// Where the island should end: the top safe-area inset, the line apps start
// their content under. SpringBoard's own windows may report none, so the
// pill's window, the key window and a 14 Pro default are tried in turn.
//
// The compact island ends where the camera's sensor region ends, a fixed
// rectangle; measuring the pill instead fed back into itself (the pill had not
// taken the last height yet) and the island kept resizing by half points.
static void NLIslandMeasureExtra(UIView *pill) {
    SBSystemApertureViewController *vc = gApertureVC;
    if (!pill.window || !vc.isViewLoaded || ![vc respondsToSelector:@selector(minimumSensorRegionFrame)]) return;
    CGRect sensor = vc.minimumSensorRegionFrame;
    if (CGRectIsEmpty(sensor)) return;
    gSensorWidth = CGRectGetWidth(sensor);
    CGFloat compactBottom = CGRectGetMaxY([vc.view convertRect:sensor toCoordinateSpace:vc.view.window.screen.coordinateSpace]);

    CGFloat line = pill.window.safeAreaInsets.top;
    if (line < 30) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        line = UIApplication.sharedApplication.keyWindow.safeAreaInsets.top;
#pragma clang diagnostic pop
    }
    if (line < 30) line = compactBottom + 11;
    CGFloat extra = MIN(MAX(round((line - compactBottom) * 2) / 2, 0), 30);
    if (fabs(extra - gExtra) < 0.5) return;
    NSLog(@"[NowLyricsIsland] island grows %.1f -> %.1f pt (line %.1f, compact bottom %.1f)", gExtra, extra, line, compactBottom);
    gExtra = extra;
    dispatch_async(dispatch_get_main_queue(), ^{ NLIslandInvalidateHeight(); });
}

// Frames, set only from the pill's layoutSubviews (hooked below) or right
// after attaching. That pass runs inside SpringBoard's resize animations, so
// the line moves in the same animation as the artwork and waveform even when
// resizes come quickly one after another; frames set from anywhere else jumped
// to the end of whatever animation was running.
static void NLIslandLayout(UIView *pill) {
    UIView *host = gClip.superview;
    if (!host || NLPillFor(host) != pill) return;
    // The line's box sits on the island's bottom edge, between the artwork and
    // the waveform; the camera above it is the only thing it shares rows with.
    // It is as tall as the font needs. Measured in the content view, which is
    // the pill's size or, while scaling, its reference size.
    CGRect b = host.bounds;
    CGFloat h = MIN(ceil([UIFont systemFontOfSize:gSettings.fontSize weight:UIFontWeightSemibold].lineHeight), CGRectGetHeight(b));
    CGFloat y = CGRectGetHeight(b) - h - kNLBottomGap;
    CGFloat width = MAX(MIN(gSensorWidth, CGRectGetWidth(b)) - kNLContentGap * 2, 0);
    CGRect strip = CGRectMake(round((CGRectGetWidth(b) - width) / 2), y, width, h);
    if (!CGRectEqualToRect(gClip.frame, b)) gClip.frame = b;
    if (!CGRectEqualToRect(gStrip.frame, strip)) gStrip.frame = strip;
    NLIslandMeasureExtra(pill);
}

static BOOL NLLayerAnimating(CALayer *layer) {
    return layer.animationKeys.count > 0;
}

// Fades the line in once the pill has finished moving. Attached while the
// island is still growing (playback just started, a collapse), its frames are
// the final ones inside a pill that is not there yet, which read as the line
// drifting into place. Polls the pill's layers rather than guessing a delay.
static BOOL gRevealPending = NO;
static void NLIslandRevealWhenStill(UIView *pill, int attempt) {
    if (gRevealPending && attempt == 0) return;
    gRevealPending = YES;
    UIView *host = gClip.superview;
    BOOL moving = NLLayerAnimating(pill.layer) || NLLayerAnimating(host.layer) || NLLayerAnimating(pill.superview.layer);
    if (moving && attempt < 30) {
        __weak UIView *weakPill = pill;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.07 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (!gRevealPending) return;   // hidden again meanwhile (expanded, app opened)
            UIView *p = weakPill;
            if (p && gClip.superview && NLPillFor(gClip.superview) == p) NLIslandRevealWhenStill(p, attempt + 1);
            else gRevealPending = NO;
        });
        return;
    }
    gRevealPending = NO;
    [UIView performWithoutAnimation:^{ NLIslandLayout(pill); }];
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ gClip.alpha = 1; } completion:nil];
}

static void NLIslandUpdate(void) {
    UIView *pill = NLPillFor(gSceneContainer);
    SBSystemApertureSceneElement *element = gElement;
    BOOL compact = [element respondsToSelector:@selector(layoutMode)] && element.layoutMode == kNLCompactLayoutMode;
    BOOL show = gSettings.on && pill && compact && gTitle.length > 0;
    if (!show) {
        // Faded rather than hidden (expanding, the app taking over): a strip
        // vanishing in one frame reads as a flash.
        gRevealPending = NO;
        if (gClip.superview && gClip.alpha > 0) {
            [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                             animations:^{ gClip.alpha = 0; } completion:nil];
        }
        return;
    }
    if (!gClip) {
        gClip = [[NLIslandClipView alloc] initWithFrame:CGRectZero];
        gStrip = [[NLIslandStripView alloc] initWithFrame:CGRectZero];
        gStrip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;   // stays on the bottom edge
        [gClip addSubview:gStrip];
    }
    // In the pill's content view, next to the artwork and waveform, so the line
    // gets exactly their scaling, fading and clipping during a resize instead
    // of chasing the pill's frame from outside.
    BOOL fresh = !gClip.superview || NLPillFor(gClip.superview) != pill;
    if (fresh) {
        gClip.alpha = 0;
        if ([pill respondsToSelector:@selector(addContentSubview:)]) [(SBSystemApertureContainerView *)pill addContentSubview:gClip];
        else [pill addSubview:gClip];
        [UIView performWithoutAnimation:^{ NLIslandLayout(pill); }];
    } else {
        UIView *host = gClip.superview;
        if (host.subviews.lastObject != gClip) [host bringSubviewToFront:gClip];
        [pill setNeedsLayout];   // frames are only ever set in the pill's own layout pass
    }
    [gStrip applyFontSize:gSettings.fontSize color:NLTextColor() speed:gSettings.speed];
    [gStrip setText:gTitle explicit:gExplicit scrollUp:gSettings.scrollUp];
    if (gClip.alpha < 1) NLIslandRevealWhenStill(pill, 0);
}

static void NLIslandRefreshInfo(void) {
    static void (*getInfo)(dispatch_queue_t, void (^)(CFDictionaryRef)) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (mr) getInfo = (void (*)(dispatch_queue_t, void (^)(CFDictionaryRef)))dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    });
    if (!getInfo || !gSettings.on) return;
    getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef ref) {
        NSDictionary *info = (__bridge NSDictionary *)ref;
        id title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
        gTitle = [title isKindOfClass:NSString.class] ? title : nil;
        // Cleared by the players already when "Hide explicit badge" is on.
        gExplicit = [info[@"kMRMediaRemoteNowPlayingInfoIsExplicitTrack"] respondsToSelector:@selector(boolValue)]
                 && [info[@"kMRMediaRemoteNowPlayingInfoIsExplicitTrack"] boolValue];

        NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        if (gSettings.artworkColor && [artwork isKindOfClass:NSData.class] && artwork.hash != gArtworkHash) {
            NSUInteger hash = artwork.hash;
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                UIColor *color = NLColorFromArtwork([UIImage imageWithData:artwork]);
                dispatch_async(dispatch_get_main_queue(), ^{
                    gArtworkHash = hash;
                    gArtworkColor = color;
                    NLIslandUpdate();
                });
            });
        }
        NLIslandUpdate();
    });
}

// The height lives in the element's outsets, so SpringBoard has to ask again.
static void NLIslandInvalidateHeight(void) {
    SBSystemApertureViewController *vc = gApertureVC;
    SBSystemApertureSceneElement *element = gElement;
    if (element && [vc respondsToSelector:@selector(preferredEdgeOutsetsDidInvalidateForLayoutSpecifier:)]) {
        [vc preferredEdgeOutsetsDidInvalidateForLayoutSpecifier:element];
    }
    [vc.view setNeedsLayout];
}

#pragma mark - Hooks

%hook SBSystemApertureViewController
- (void)viewDidLoad {
    %orig;
    gApertureVC = self;
}
%end

%hook SBSystemApertureSceneElement

- (NSDirectionalEdgeInsets)preferredEdgeOutsetsForLayoutMode:(NSInteger)mode suggestedOutsets:(NSDirectionalEdgeInsets)suggested maximumOutsets:(NSDirectionalEdgeInsets)maximum {
    NSDirectionalEdgeInsets outsets = %orig;
    if (!NLIsNowPlaying(self)) return outsets;
    gElement = self;
    if (mode == kNLCompactLayoutMode) {
        if (gSettings.on) outsets.bottom = MAX(outsets.bottom - gExtra, maximum.bottom);
    }
    return outsets;
}

- (void)_layoutSceneViewInContainerView:(UIView *)container {
    %orig;
    if (!NLIsNowPlaying(self)) return;
    gElement = self;
    gSceneContainer = container;
    if (gSettings.on && !gTitle) NLIslandRefreshInfo();
    NLIslandUpdate();
}

%end

%hook SBSystemApertureContainerView
- (void)layoutSubviews {
    %orig;
    if (gClip.superview && NLPillFor(gClip.superview) == self) NLIslandLayout(self);
}
%end

%hook SBMediaController
- (void)_mediaRemoteNowPlayingInfoDidChange:(id)notification {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ NLIslandRefreshInfo(); });
}
%end

static void NLIslandPrefsChanged(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NLIslandSettings now = NLIslandReadSettings();
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL heightChanged = now.on != gSettings.on;
        BOOL colorChanged = now.artworkColor != gSettings.artworkColor;
        gSettings = now;
        if (colorChanged) gArtworkHash = 0;   // fetch the artwork again
        if (heightChanged) NLIslandInvalidateHeight();
        if (now.on && (!gTitle || colorChanged)) NLIslandRefreshInfo();
        NLIslandUpdate();
    });
}

%ctor {
    @autoreleasepool {
        if (!objc_getClass("SBSystemApertureSceneElement")) return;   // no Dynamic Island support in this iOS
        gSettings = NLIslandReadSettings();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, NLIslandPrefsChanged,
                                        (__bridge CFStringRef)kNLReloadNotification, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
        %init;
    }
}
