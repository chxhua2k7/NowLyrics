//
//  NLPlayerTint.m
//

#import "NLPlayerTint.h"
#import <CoreImage/CoreImage.h>

// White text needs the background no brighter than this (relative luminance)
// to read comfortably.
static const CGFloat kNLReadableLuma = 0.3;

// Between songs the artwork goes missing for a moment: the old look stays
// until the new cover is there (shown at once then, with a short fade), and
// only a cover missing this long brings the fallback. Going to the fallback at
// once flashed coral between songs.
static const NSTimeInterval kNLMissingGrace = 2.5;
static const NSTimeInterval kNLFade = 0.25;

// Looks closer than this (summed RGB difference) change without a fade.
static const CGFloat kNLSameLook = 0.06;

typedef struct { CGFloat r, g, b; } NLRGB;

static NLRGB NLRGBOf(UIColor *color) {
    CGFloat r = 0, g = 0, b = 0, a = 1;
    [color getRed:&r green:&g blue:&b alpha:&a];
    return (NLRGB){r, g, b};
}

// A color deepened until white text reads on it.
static UIColor *NLDeepened(UIColor *color) {
    CGFloat h = 0, s = 0, b = 0, a = 1;
    if (![color getHue:&h saturation:&s brightness:&b alpha:&a]) return nil;
    return [UIColor colorWithHue:h saturation:MIN(s * 1.15, 0.85) brightness:MIN(b, 0.38) alpha:1];
}

// NowLyrics' coral, the main switch's icon's color, deepened.
static UIColor *NLCoral(void) {
    return NLDeepened([UIColor colorWithRed:0.95 green:0.38 blue:0.44 alpha:1]);
}

// The artwork bytes in one number: NSData's own hash reads only their start,
// which covers of one size can share.
static NSUInteger NLTintPrint(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger n = data.length;
    uint64_t h = 1469598103934665603ULL ^ n;
    for (NSUInteger i = 0; i < 64 && n; i++) {
        h ^= bytes[(n - 1) * i / 63];
        h *= 1099511628211ULL;
    }
    return (NSUInteger)h;
}

// The cover small and blurred (edges clamped so they do not darken), how dark
// a scrim it needs (enough for its brightest tenth to come down to
// kNLReadableLuma), and its average color under that scrim.
static UIImage *NLBlurredCover(NSData *data, CGFloat *scrim, NLRGB *seen) {
    static CIContext *context;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ context = [CIContext contextWithOptions:nil]; });
    CIImage *input = [CIImage imageWithData:data];
    if (!input || input.extent.size.width < 1) return nil;
    CGFloat scale = 64 / input.extent.size.width;
    input = [input imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect extent = input.extent;
    CIImage *blurred = [[[input imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:6] imageByCroppingToRect:extent];
    CGImageRef cg = [context createCGImage:blurred fromRect:extent];
    if (!cg) return nil;

    enum { side = 16 };
    uint8_t px[side * side * 4];
    memset(px, 0, sizeof(px));
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef bitmap = CGBitmapContextCreate(px, side, side, 8, side * 4, space,
                                                kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (bitmap) {
        CGContextDrawImage(bitmap, CGRectMake(0, 0, side, side), cg);
        CGContextRelease(bitmap);
    }
    float lumas[side * side];
    double sumR = 0, sumG = 0, sumB = 0;
    for (int i = 0; i < side * side; i++) {
        lumas[i] = (0.2126f * px[i * 4] + 0.7152f * px[i * 4 + 1] + 0.0722f * px[i * 4 + 2]) / 255.0f;
        sumR += px[i * 4] / 255.0; sumG += px[i * 4 + 1] / 255.0; sumB += px[i * 4 + 2] / 255.0;
    }
    // The 90th percentile: a few bright pixels do not darken the whole thing.
    for (int i = 1; i < side * side; i++) {
        float v = lumas[i];
        int j = i - 1;
        while (j >= 0 && lumas[j] > v) { lumas[j + 1] = lumas[j]; j--; }
        lumas[j + 1] = v;
    }
    CGFloat bright = lumas[(int)(side * side * 0.9)];
    *scrim = bright > kNLReadableLuma ? MIN(MAX(1 - kNLReadableLuma / bright, 0.15), 0.8) : 0.15;
    CGFloat keep = (1 - *scrim) / (side * side);
    *seen = (NLRGB){sumR * keep, sumG * keep, sumB * keep};

    UIImage *image = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return image;
}

// The artwork print standing for "nothing is playing".
static const NSUInteger kNLNothing = NSUIntegerMax;

@implementation NLPlayerTintView {
    UIView *_stage;              // all of it: faded out with nothing playing, the system's material shows
    UIView *_base;               // the solid color
    UIImageView *_cover;
    UIView *_scrim;
    BOOL _shown;                 // something from showNowPlaying: is on screen
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

- (void)setClearsWhenNothingPlays:(BOOL)clears {
    _clearsWhenNothingPlays = clears;
    if (!_shown) _stage.alpha = clears ? 0 : 1;   // until it is given something: clear, or the coral
}

- (void)showNowPlaying:(NSDictionary *)info animated:(BOOL)animated {
    id title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    BOOL song = [title isKindOfClass:NSString.class] && [title length];
    NSData *artwork = song ? info[@"kMRMediaRemoteNowPlayingInfoArtworkData"] : nil;
    if (![artwork isKindOfClass:NSData.class] || artwork.length == 0) artwork = nil;
    // Nothing playing is a song without a cover here, unless this one clears then.
    NSUInteger print = (!song && _clearsWhenNothingPlays) ? kNLNothing : artwork ? NLTintPrint(artwork) : 0;
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
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            UIColor *solid = nil;
            CGFloat scrim = 0;
            NLRGB seen = {0, 0, 0};
            UIImage *cover = artwork ? NLBlurredCover(artwork, &scrim, &seen) : nil;
            if (!cover) solid = NLCoral();
            if (solid) seen = NLRGBOf(solid);
            dispatch_async(dispatch_get_main_queue(), ^{
                if (generation != self->_generation) return;
                shown();
                BOOL wasHidden = self->_stage.alpha < 0.5;
                // Coming back from nothing: the look is put in place, then faded in.
                [self nlShowSolid:solid cover:cover scrim:scrim seen:seen fade:fade && !wasHidden];
                [self nlSetStageVisible:YES fade:fade];
            });
        });
    };
    if (wait <= 0) work();
    else dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (generation == self->_generation) work();
    });
}

- (void)nlSetStageVisible:(BOOL)visible fade:(BOOL)fade {
    CGFloat alpha = visible ? 1 : 0;
    if (_stage.alpha == alpha) return;
    void (^changes)(void) = ^{ self->_stage.alpha = alpha; };
    if (fade && self.window) {
        [UIView animateWithDuration:kNLFade delay:0
                            options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                         animations:changes completion:nil];
    } else {
        [UIView performWithoutAnimation:changes];
    }
}

- (void)nlShowSolid:(UIColor *)solid cover:(UIImage *)cover scrim:(CGFloat)scrim seen:(NLRGB)seen fade:(BOOL)fade {
    CGFloat difference = fabs(seen.r - _seen.r) + fabs(seen.g - _seen.g) + fabs(seen.b - _seen.b);
    _seen = seen;
    fade = fade && self.window && difference > kNLSameLook;
    BOOL wasCover = _cover.alpha > 0.5;
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction;
    void (^animate)(void (^)(void)) = ^(void (^changes)(void)) {
        if (fade) [UIView animateWithDuration:kNLFade delay:0 options:options animations:changes completion:nil];
        else [UIView performWithoutAnimation:changes];
    };

    if (cover) {
        if (wasCover && fade) {
            // Cover to cover: the image itself does not animate, so dissolve it.
            [UIView transitionWithView:_cover duration:kNLFade options:UIViewAnimationOptionTransitionCrossDissolve | options
                            animations:^{ self->_cover.image = cover; } completion:nil];
        } else {
            [UIView performWithoutAnimation:^{ self->_cover.image = cover; }];
        }
        animate(^{
            self->_cover.alpha = 1;
            self->_scrim.alpha = scrim;
        });
    } else {
        // From a cover the color comes in underneath as the cover fades out.
        if (wasCover) [UIView performWithoutAnimation:^{ self->_base.backgroundColor = solid; }];
        animate(^{
            self->_base.backgroundColor = solid;
            self->_cover.alpha = 0;
            self->_scrim.alpha = 0;
        });
    }
}

@end
