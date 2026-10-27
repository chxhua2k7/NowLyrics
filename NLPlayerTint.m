//
//  NLPlayerTint.m
//

#import "NLPlayerTint.h"
#import "NLIslandStrip.h"
#import "NLLocate.h"
#import <CoreImage/CoreImage.h>
#import <objc/runtime.h>

// White text needs the background no brighter than this (relative luminance)
// to read comfortably.
static const CGFloat kNLReadableLuma = 0.3;

// Between songs the artwork goes missing for a moment: the old look stays
// until the new cover is there (shown at once then, with a short fade), and
// only a cover missing kNLMissingGrace (NLLocate.h) brings the fallback. Going
// to the fallback at once flashed coral between songs.
static const NSTimeInterval kNLFade = 0.25;
static const UIViewAnimationOptions kNLFadeOptions = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction;

// Looks closer than this (summed RGB difference) change without a fade.
static const CGFloat kNLSameLook = 0.06;

// At full clearness the look keeps this much of itself, and the material
// under it this much of its blur and tint.
static const CGFloat kNLClearestLook = 0.3;
static const CGFloat kNLClearestMaterial = 0.2;

@interface UIView (NLMaterial)
@property (nonatomic, assign) CGFloat weighting;          // MTMaterialView: 0 none of it, 1 all of it
@property (nonatomic, copy) NSString *groupNameBase;      // materials of one group share one backdrop
@end

static char kNLGroupKey;   // a thinned material's own group's former one

// The materials of a backdrop group share its filters too: the lock screen's
// notifications took the player's thinned blur (and lost their corners). So a
// thinned material gets a group of its own first, and its old one back only
// once it is whole again.
static void NLSetWeighting(UIView *material, CGFloat weighting) {
    if (![material respondsToSelector:@selector(setWeighting:)] || ![material respondsToSelector:@selector(weighting)]) return;
    BOOL thin = weighting < 0.999;
    BOOL grouped = [material respondsToSelector:@selector(groupNameBase)] && [material respondsToSelector:@selector(setGroupNameBase:)];
    NSString *own = [NSString stringWithFormat:@"NowLyrics-%p", material];
    BOOL alone = grouped && [material.groupNameBase isEqualToString:own];
    if (thin && grouped && !alone) {
        objc_setAssociatedObject(material, &kNLGroupKey, material.groupNameBase ?: (id)NSNull.null, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        material.groupNameBase = own;
    }
    if (fabs(material.weighting - weighting) > 0.001) material.weighting = weighting;
    if (!thin && alone) {
        id former = objc_getAssociatedObject(material, &kNLGroupKey);
        material.groupNameBase = former == NSNull.null ? nil : former;
        objc_setAssociatedObject(material, &kNLGroupKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

typedef struct { CGFloat r, g, b; } NLRGB;

static NLRGB NLRGBOf(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return (NLRGB){r, g, b};
}

// NowLyrics' coral, the main switch's icon's color, deepened until white text
// reads on it; made once.
static UIColor *NLCoral(void) {
    static UIColor *coral;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CGFloat h = 0, s = 0, b = 0, a = 1;
        [[UIColor colorWithRed:0.95 green:0.38 blue:0.44 alpha:1] getHue:&h saturation:&s brightness:&b alpha:&a];
        coral = [UIColor colorWithHue:h saturation:MIN(s * 1.15, 0.85) brightness:MIN(b, 0.38) alpha:1];
    });
    return coral;
}

// The soft copy of a cover under the player here and in the settings page's
// waveform (NLWaveformView.m).
CGImageRef NLCreateBlurredImage(CIImage *input, CGFloat width, CGFloat sigma) {
    CIContext *context = NL_ONCE([CIContext contextWithOptions:nil]);   // one for every caller: safe across threads
    CGFloat scale = width / MAX(input.extent.size.width, 1);
    CIImage *small = [input imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect extent = small.extent;
    CIImage *blurred = [[[small imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:sigma] imageByCroppingToRect:extent];
    return [context createCGImage:blurred fromRect:extent];
}

// Ascending, for qsort.
static int NLCompareFloats(const void *a, const void *b) {
    float x = *(const float *)a, y = *(const float *)b;
    return (x > y) - (x < y);
}

// The cover small and blurred (edges clamped so they do not darken), how dark
// a scrim it needs (enough for its brightest tenth to come down to
// kNLReadableLuma), and its average color under that scrim.
static UIImage *NLBlurredCover(NSData *data, CGFloat *scrim, NLRGB *seen) {
    CIImage *input = [CIImage imageWithData:data];
    if (!input || input.extent.size.width < 1) return nil;
    CGImageRef cg = NLCreateBlurredImage(input, 64, 6);
    if (!cg) return nil;

    enum { side = NL_SAMPLE_SIDE };
    uint8_t px[side * side * 4];
    NLSampleImage(cg, kCGInterpolationDefault, px);   // no bitmap context: px stays all zero
    float lumas[side * side];
    double sumR = 0, sumG = 0, sumB = 0;
    for (int i = 0; i < side * side; i++) {
        lumas[i] = (0.2126f * px[i * 4] + 0.7152f * px[i * 4 + 1] + 0.0722f * px[i * 4 + 2]) / 255.0f;
        sumR += px[i * 4] / 255.0; sumG += px[i * 4 + 1] / 255.0; sumB += px[i * 4 + 2] / 255.0;
    }
    // The 90th percentile: a few bright pixels do not darken the whole thing.
    qsort(lumas, side * side, sizeof(float), NLCompareFloats);
    CGFloat bright = lumas[(int)(side * side * 0.9)];
    *scrim = bright > kNLReadableLuma ? MIN(MAX(1 - kNLReadableLuma / bright, 0.15), 0.8) : 0.15;
    CGFloat keep = (1 - *scrim) / (side * side);
    *seen = (NLRGB){sumR * keep, sumG * keep, sumB * keep};

    UIImage *image = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return image;
}

// The cover made for `artwork` (its print), on one queue for every tint and
// the last one kept: Control Center's players each have a tint, and they
// would all make the same at each song.
static void NLSharedBlurredCover(NSData *artwork, NSUInteger print, void (^done)(UIImage *cover, CGFloat scrim, NLRGB seen)) {
    static dispatch_queue_t queue;
    static NSUInteger madePrint;
    static UIImage *made;
    static CGFloat madeScrim;
    static NLRGB madeSeen;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.c3x14n.nowlyrics.tint", DISPATCH_QUEUE_SERIAL); });
    dispatch_async(queue, ^{
        if (!made || madePrint != print) {
            madeScrim = 0;
            madeSeen = (NLRGB){0, 0, 0};
            made = NLBlurredCover(artwork, &madeScrim, &madeSeen);
            madePrint = print;
        }
        UIImage *cover = made;
        CGFloat scrim = madeScrim;
        NLRGB seen = madeSeen;
        dispatch_async(dispatch_get_main_queue(), ^{ done(cover, scrim, seen); });
    });
}

// The artwork print standing for "nothing is playing".
static const NSUInteger kNLNothing = NSUIntegerMax;

// `changes` faded in over kNLFade, or made at once.
static void NLFadeOrSet(BOOL fade, void (^changes)(void)) {
    if (fade) [UIView animateWithDuration:kNLFade delay:0 options:kNLFadeOptions animations:changes completion:nil];
    else [UIView performWithoutAnimation:changes];
}

@implementation NLPlayerTintView {
    UIView *_stage;              // all of it: faded out with nothing playing, the system's material shows
    UIView *_base;               // the solid color
    UIImageView *_cover;
    UIView *_scrim;
    BOOL _shown;                 // something from showNowPlaying: is on screen
    BOOL _stageVisible;          // the look is up (not faded out for nothing playing)
    NSUInteger _shownPrint;      // ... from this artwork (0: none, kNLNothing: nothing playing)
    BOOL _pending;               // a change is waiting or being worked out
    NSUInteger _pendingPrint;
    NSUInteger _generation;      // invalidates a pending change
    NLRGB _seen;                 // roughly what the look shows, to skip changes nobody would see
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.layer.cornerCurve = kCACornerCurveContinuous;
        UIViewAutoresizing fill = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _stage = [[UIView alloc] initWithFrame:self.bounds];
        _stageVisible = YES;
        _stage.autoresizingMask = fill;
        [self addSubview:_stage];
        _base = [[UIView alloc] initWithFrame:self.bounds];
        _base.autoresizingMask = fill;
        _base.backgroundColor = NLCoral();
        [_stage addSubview:_base];
        _cover = [[UIImageView alloc] initWithFrame:self.bounds];
        _cover.contentMode = UIViewContentModeScaleAspectFill;
        _cover.autoresizingMask = fill;
        _cover.alpha = 0;
        [_stage addSubview:_cover];
        _scrim = [[UIView alloc] initWithFrame:self.bounds];
        _scrim.backgroundColor = UIColor.blackColor;
        _scrim.autoresizingMask = fill;
        _scrim.alpha = 0;
        [_stage addSubview:_scrim];
        _seen = NLRGBOf(_base.backgroundColor);
    }
    return self;
}

- (void)dealloc {
    NLSetWeighting(_material, 1);
}

- (void)setClearsWhenNothingPlays:(BOOL)clears {
    _clearsWhenNothingPlays = clears;
    if (_shown) return;
    _stageVisible = !clears;   // until it is given something: clear, or the coral
    _stage.alpha = clears ? 0 : [self nlOpacity];
    [self nlApplyMaterial];
}

- (CGFloat)nlOpacity {
    return 1 - (1 - kNLClearestLook) * _clearness;
}

// The material as the look wants it: thinned under a look that shows, whole
// otherwise.
- (void)nlApplyMaterial {
    BOOL thin = _stageVisible && !self.hidden && _clearness > 0;
    NLSetWeighting(_material, thin ? 1 - (1 - kNLClearestMaterial) * _clearness : 1);
}

- (void)setMaterial:(UIView *)material {
    if (material == _material) return;
    NLSetWeighting(_material, 1);   // the one it leaves, whole again
    _material = material;
    [self nlApplyMaterial];
}

- (void)setClearness:(CGFloat)clearness {
    clearness = MIN(MAX(clearness, 0), 1);
    if (fabs(clearness - _clearness) < 0.001) return;
    _clearness = clearness;
    if (_stageVisible) [UIView performWithoutAnimation:^{ self->_stage.alpha = [self nlOpacity]; }];
    [self nlApplyMaterial];
}

- (void)setHidden:(BOOL)hidden {
    BOOL was = self.hidden;
    [super setHidden:hidden];
    if (was != hidden) [self nlApplyMaterial];
}

- (void)showNowPlaying:(NSDictionary *)info animated:(BOOL)animated {
    BOOL song = NLInfoTitle(info) != nil;
    NSData *artwork = song ? NLInfoArtwork(info) : nil;
    // Nothing playing is a song without a cover here, unless this one clears then.
    NSUInteger print = (!song && _clearsWhenNothingPlays) ? kNLNothing : artwork ? NLArtworkPrint(artwork) : 0;
    if (_shown && print == _shownPrint) {
        // What shows already: a change on its way (a moment without a cover,
        // a placeholder, a moment with nothing between songs) is called off.
        _generation++;
        _pending = NO;
        return;
    }
    if (_pending && print == _pendingPrint) return;   // on its way already

    NSUInteger generation = ++_generation;
    _pending = YES;
    _pendingPrint = print;
    BOOL first = !_shown;
    BOOL fade = animated && !first;
    NSTimeInterval wait = (first || artwork) ? 0 : kNLMissingGrace;

    void (^shown)(void) = ^{
        self->_pending = NO;
        self->_shown = YES;
        self->_shownPrint = print;
    };
    void (^work)(void) = ^{
        if (print == kNLNothing) {   // nothing to color by: the system's own look
            shown();
            [self nlSetStageVisible:NO fade:fade];
            return;
        }
        void (^show)(UIImage *, CGFloat, NLRGB) = ^(UIImage *cover, CGFloat scrim, NLRGB seen) {
            if (generation != self->_generation) return;
            shown();
            BOOL wasHidden = !self->_stageVisible;
            // Coming back from nothing: the look is put in place, then faded in.
            [self nlShowCover:cover scrim:scrim seen:seen fade:fade && !wasHidden];
            [self nlSetStageVisible:YES fade:fade];
        };
        if (artwork) NLSharedBlurredCover(artwork, print, show);
        else show(nil, 0, (NLRGB){0, 0, 0});
    };
    if (wait <= 0) work();
    else NLAfter(wait, ^{ if (generation == self->_generation) work(); });
}

- (void)nlSetStageVisible:(BOOL)visible fade:(BOOL)fade {
    _stageVisible = visible;
    CGFloat alpha = visible ? [self nlOpacity] : 0;
    if (fabs(_stage.alpha - alpha) < 0.01) {   // alpha comes back as a float
        [self nlApplyMaterial];
        return;
    }
    NLFadeOrSet(fade && self.window, ^{
        self->_stage.alpha = alpha;
        [self nlApplyMaterial];
    });
}

- (void)nlShowCover:(UIImage *)cover scrim:(CGFloat)scrim seen:(NLRGB)seen fade:(BOOL)fade {
    if (!cover) seen = NLRGBOf(NLCoral());   // no cover: the coral
    CGFloat difference = fabs(seen.r - _seen.r) + fabs(seen.g - _seen.g) + fabs(seen.b - _seen.b);
    _seen = seen;
    fade = fade && self.window && difference > kNLSameLook;
    BOOL wasCover = _cover.alpha > 0.5;

    if (cover) {
        if (wasCover && fade) {
            // Cover to cover: the image itself does not animate, so dissolve it.
            [UIView transitionWithView:_cover duration:kNLFade options:UIViewAnimationOptionTransitionCrossDissolve | kNLFadeOptions
                            animations:^{ self->_cover.image = cover; } completion:nil];
        } else {
            [UIView performWithoutAnimation:^{ self->_cover.image = cover; }];
        }
        NLFadeOrSet(fade, ^{
            self->_cover.alpha = 1;
            self->_scrim.alpha = scrim;
        });
    } else {
        // From a cover the color comes in underneath as the cover fades out.
        if (wasCover) [UIView performWithoutAnimation:^{ self->_base.backgroundColor = NLCoral(); }];
        NLFadeOrSet(fade, ^{
            self->_base.backgroundColor = NLCoral();
            self->_cover.alpha = 0;
            self->_scrim.alpha = 0;
        });
    }
}

@end
