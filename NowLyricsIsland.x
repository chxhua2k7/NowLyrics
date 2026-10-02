//
//  NowLyricsIsland.x
//  The current lyric line in a strip under the compact Dynamic Island.
//  SpringBoard only.
//
//  - Height: -[SBSystemApertureSceneElement preferredEdgeOutsetsForLayoutMode:
//    suggestedOutsets:maximumOutsets:] is asked for the now-playing element's
//    frame; in compact layout (SpringBoard's mode 2; MediaRemoteUI numbers it 3)
//    its bottom outset is pushed down. Outsets are negative outwards, and
//    SpringBoard validates and animates the result like any element's own.
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

@interface SBSystemApertureSceneElement : NSObject
- (NSString *)clientIdentifier;
- (NSInteger)layoutMode;
@end

@interface SBSystemApertureViewController : UIViewController
- (void)preferredEdgeOutsetsDidInvalidateForLayoutSpecifier:(id)specifier;
@end

static NSString *const kNLPrefsDomain = @"app.nowlyrics";
static NSString *const kNLReloadNotification = @"app.nowlyrics/ReloadPrefs";
static const NSInteger kNLCompactLayoutMode = 2;   // SpringBoard's numbering
static const CGFloat kNLSideInset = 14;           // minimum, on a pill tall enough to have straight sides there
static const CGFloat kNLCurvePadding = 5;          // kept clear of the rounded ends
static const CGFloat kNLBottomGap = 5;             // between the strip and the pill's rounded bottom

#pragma mark - Settings

typedef struct {
    BOOL on;
    CGFloat height;      // pt added under the compact island
    CGFloat fontSize;
    CGFloat offset;      // pt, positive moves the line down
    BOOL artworkColor;
    BOOL scrollUp;       // line change pushes up instead of fading
    CGFloat speed;       // marquee, pt/s
} NLIslandSettings;

static NLIslandSettings gSettings = { NO, 14, 11, 0, NO, NO, 30 };

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
    s.height = round(NLNum(prefs, @"islandHeight", 14, 8, 24));
    s.fontSize = NLNum(prefs, @"islandFontSize", 11, 9, 15);
    s.offset = NLNum(prefs, @"islandOffset", 0, -6, 6);
    s.artworkColor = [prefs[@"islandColor"] isEqual:@"artwork"];
    s.scrollUp = [prefs[@"islandTransition"] isEqual:@"up"];
    s.speed = NLNum(prefs, @"islandMarqueeSpeed", 30, 10, 80);
    return s;
}

#pragma mark - State

static __weak SBSystemApertureViewController *gApertureVC = nil;
static __weak SBSystemApertureSceneElement *gElement = nil;
static __weak UIView *gSceneContainer = nil;   // as handed to -_layoutSceneViewInContainerView:

static NSString *gTitle = nil;
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

// A clipping strip with the line in it. Lines too wide for the strip scroll
// back and forth at the set speed, with the edges faded so the text does not
// end in a hard cut.
@interface NLIslandStripView : UIView
@property (nonatomic, readonly) UILabel *label;
- (void)setText:(NSString *)text scrollUp:(BOOL)scrollUp;
- (void)applyFontSize:(CGFloat)size color:(UIColor *)color speed:(CGFloat)speed;
@end

@implementation NLIslandStripView {
    UILabel *_label;
    CAGradientLayer *_fade;
    CGFloat _speed;
    CGFloat _laidOutWidth;
    NSString *_laidOutText;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;
        _label = [UILabel new];
        _label.textAlignment = NSTextAlignmentCenter;
        _label.lineBreakMode = NSLineBreakByClipping;
        [self addSubview:_label];
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
    _label.font = font;
    _label.textColor = color;
    _speed = speed;
    if (changed) [self restartMarquee];
}

- (void)setText:(NSString *)text scrollUp:(BOOL)scrollUp {
    if ([text isEqualToString:_label.text ?: @""]) return;
    CATransition *t = [CATransition animation];
    t.duration = scrollUp ? 0.3 : 0.25;
    t.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    if (scrollUp) {
        t.type = kCATransitionPush;
        t.subtype = kCATransitionFromTop;   // UIKit's flipped layers: the new line rises from below
    } else {
        t.type = kCATransitionFade;
    }
    [self.layer addAnimation:t forKey:@"line"];
    _label.text = text;
    [self restartMarquee];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.bounds.size.width != _laidOutWidth) [self restartMarquee];
}

- (void)restartMarquee {
    [_label.layer removeAnimationForKey:@"marquee"];
    CGRect b = self.bounds;
    _laidOutWidth = b.size.width;
    _laidOutText = _label.text;
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

static NLIslandStripView *gStrip = nil;
static UIView *gClip = nil;   // pill-sized, masked to the capsule: nothing escapes the black

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

static void NLIslandUpdate(void) {
    UIView *pill = NLPillFor(gSceneContainer);
    SBSystemApertureSceneElement *element = gElement;
    BOOL compact = [element respondsToSelector:@selector(layoutMode)] && element.layoutMode == kNLCompactLayoutMode;
    BOOL show = gSettings.on && pill && compact && gTitle.length > 0;
    if (!show) {
        gClip.hidden = YES;
        return;
    }
    if (!gClip) {
        gClip = [UIView new];
        gClip.userInteractionEnabled = NO;
        gClip.layer.mask = [CAShapeLayer layer];
        gStrip = [[NLIslandStripView alloc] initWithFrame:CGRectZero];
        [gClip addSubview:gStrip];
    }
    if (gClip.superview != pill) [pill addSubview:gClip];
    else if (pill.subviews.lastObject != gClip) [pill bringSubviewToFront:gClip];

    // The pill is a capsule, so near its bottom the rounded ends eat into the
    // width. Inset the strip to where the circle is at the bottom of the text,
    // the lowest point that has to stay inside.
    CGRect b = pill.bounds;
    CGFloat h = gSettings.height;
    CGFloat y = CGRectGetHeight(b) - h - kNLBottomGap + gSettings.offset;
    CGFloat r = MIN(CGRectGetWidth(b), CGRectGetHeight(b)) / 2;
    CGFloat lineHeight = [UIFont systemFontOfSize:gSettings.fontSize weight:UIFontWeightSemibold].lineHeight;
    CGFloat textBottom = y + (h + MIN(lineHeight, h)) / 2;
    CGFloat fromEdge = MAX(CGRectGetHeight(b) - textBottom, 0);   // distance above the pill's bottom
    CGFloat inset = kNLSideInset;
    if (fromEdge < r) {
        CGFloat dy = r - fromEdge;
        inset = MAX(inset, r - sqrt(MAX(r * r - dy * dy, 0)) + kNLCurvePadding);
    }
    if (!CGRectEqualToRect(gClip.frame, b)) {
        gClip.frame = b;
        ((CAShapeLayer *)gClip.layer.mask).path = [UIBezierPath bezierPathWithRoundedRect:b cornerRadius:r].CGPath;
    }
    gStrip.frame = CGRectMake(inset, y, MAX(CGRectGetWidth(b) - inset * 2, 0), h);
    [gStrip applyFontSize:gSettings.fontSize color:NLTextColor() speed:gSettings.speed];
    [gStrip setText:gTitle scrollUp:gSettings.scrollUp];
    gClip.hidden = NO;
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
    if (gSettings.on && mode == kNLCompactLayoutMode) {
        outsets.bottom = MAX(outsets.bottom - gSettings.height, maximum.bottom);
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
        BOOL heightChanged = now.on != gSettings.on || (now.on && now.height != gSettings.height);
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
