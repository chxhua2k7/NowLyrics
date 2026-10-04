//
//  NLWaveformView.m
//  Bars that bounce like the system's now-playing waveform. The system's moves
//  with the music, which takes an audio tap Preferences has no entitlement
//  for (MediaControls' MRUAudioAnalyzer), so this one is made up: each bar
//  wanders through its own heights at its own pace while something plays, and
//  they settle into dots when it stops. Given the cover, it is colored the way
//  the system's is: the bars are a window onto the artwork, lightened a little.
//

#import "NLLyricsPages.h"
#import <CoreImage/CoreImage.h>

@implementation NLWaveformView {
    NSArray<UIView *> *_bars;
    UIView *_barsHost;          // the bars; the fill's mask when there is a cover
    UIImageView *_fill;         // the cover, seen through the bars
}

- (instancetype)initWithBars:(NSUInteger)count {
    if ((self = [super initWithFrame:CGRectZero])) {
        self.userInteractionEnabled = NO;
        _barsHost = [UIView new];
        [self addSubview:_barsHost];
        NSMutableArray *bars = [NSMutableArray arrayWithCapacity:count];
        for (NSUInteger i = 0; i < count; i++) {
            UIView *bar = [UIView new];
            [_barsHost addSubview:bar];
            [bars addObject:bar];
        }
        _bars = bars;
        _barColor = [UIColor colorWithWhite:1 alpha:0.8];
        [self nlApplyColor];
        [self nlRest];
    }
    return self;
}

- (void)setBarColor:(UIColor *)barColor {
    _barColor = barColor ?: [UIColor colorWithWhite:1 alpha:0.8];
    [self nlApplyColor];
}

- (void)nlApplyColor {
    // Through the cover the bars are only a shape: opaque, any color.
    UIColor *color = _artwork ? UIColor.whiteColor : _barColor;
    for (UIView *bar in _bars) bar.backgroundColor = color;
}

// The system's waveform shows the cover blurred into soft color, not its
// details: a small copy, blurred, edges clamped so they do not darken.
static UIImage *NLBlurred(UIImage *image) {
    CGImageRef source = image.CGImage;
    if (!source) return image;
    static CIContext *context;
    if (!context) context = [CIContext contextWithOptions:nil];
    CIImage *input = [CIImage imageWithCGImage:source];
    CGFloat scale = 48 / MAX(input.extent.size.width, 1);
    input = [input imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGRect extent = input.extent;
    CIImage *blurred = [[input imageByClampingToExtent] imageByApplyingGaussianBlurWithSigma:4];
    CGImageRef cg = [context createCGImage:[blurred imageByCroppingToRect:extent] fromRect:extent];
    if (!cg) return image;
    UIImage *out = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    return out;
}

// The cover behind the bars, or plain bars again for nil.
- (void)setArtwork:(UIImage *)artwork {
    if (artwork == _artwork) return;
    _artwork = artwork;
    if (artwork) {
        if (!_fill) {
            _fill = [UIImageView new];
            _fill.contentMode = UIViewContentModeScaleAspectFill;
            _fill.clipsToBounds = YES;
            UIView *lighten = [UIView new];
            lighten.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
            lighten.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [_fill addSubview:lighten];
        }
        _fill.image = NLBlurred(artwork);
        if (_fill.superview != self) {
            [_barsHost removeFromSuperview];
            [self addSubview:_fill];
            _fill.maskView = _barsHost;
        }
    } else if (_fill.superview) {
        _fill.maskView = nil;
        [_fill removeFromSuperview];
        [self addSubview:_barsHost];
    }
    [self nlApplyColor];
    [self setNeedsLayout];
    if (_playing) [self nlBounce];   // the bars moved between views: start them again
}

// Evenly spread, as wide as the gaps between them are, full height; the
// height shown is a vertical scale on top.
- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    _barsHost.frame = b;
    _fill.frame = b;
    UIView *lighten = _fill.subviews.firstObject;
    lighten.frame = _fill.bounds;
    NSUInteger n = _bars.count;
    if (n == 0) return;
    CGFloat pitch = b.size.width / n;
    CGFloat width = MIN(MAX(round(pitch * 0.55 * 2) / 2, 1.5), 3.5);
    for (NSUInteger i = 0; i < n; i++) {
        UIView *bar = _bars[i];
        bar.bounds = CGRectMake(0, 0, width, b.size.height);
        bar.center = CGPointMake(pitch * (i + 0.5), CGRectGetMidY(b));
        bar.layer.cornerRadius = width / 2;
        if (!_playing) bar.layer.transform = CATransform3DMakeScale(1, MAX(MIN(width / MAX(b.size.height, 1), 1), 0.08), 1);
    }
}

- (void)setPlaying:(BOOL)playing {
    if (playing == _playing && (!playing || [_bars.firstObject.layer animationForKey:@"bounce"])) return;
    _playing = playing;
    if (playing) [self nlBounce];
    else [self nlRest];
}

// Each bar its own loop of heights, so the whole never visibly repeats.
- (void)nlBounce {
    [_bars enumerateObjectsUsingBlock:^(UIView *bar, NSUInteger i, BOOL *stop) {
        NSMutableArray *values = [NSMutableArray array];
        for (int k = 0; k < 8; k++) [values addObject:@(0.22 + 0.78 * arc4random_uniform(1000) / 1000.0)];
        [values addObject:values.firstObject];
        CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale.y"];
        a.values = values;
        a.duration = 2.2 + 0.35 * (i % 3) + arc4random_uniform(400) / 1000.0;
        a.calculationMode = kCAAnimationCubic;
        a.repeatCount = HUGE_VALF;
        a.removedOnCompletion = NO;
        a.beginTime = CACurrentMediaTime() - arc4random_uniform(1000) / 1000.0;
        [bar.layer addAnimation:a forKey:@"bounce"];
    }];
}

// Stopped: the bars shrink to dots, as the system's do.
- (void)nlRest {
    for (UIView *bar in _bars) {
        CALayer *shown = bar.layer.presentationLayer ?: bar.layer;
        CATransform3D from = shown.transform;
        [bar.layer removeAnimationForKey:@"bounce"];
        CGFloat dot = bar.bounds.size.height > 0 ? MIN(bar.bounds.size.width / bar.bounds.size.height, 1) : 0.2;
        bar.layer.transform = CATransform3DMakeScale(1, MAX(dot, 0.08), 1);
        CABasicAnimation *settle = [CABasicAnimation animationWithKeyPath:@"transform"];
        settle.fromValue = [NSValue valueWithCATransform3D:from];
        settle.duration = 0.3;
        [bar.layer addAnimation:settle forKey:@"settle"];
    }
}

@end


#pragma mark - Driving the system's own waveform

@interface NSObject (NLWaveformData)
- (instancetype)initWithAmplitudes:(NSArray<NSNumber *> *)amplitudes;
- (void)setWaveformData:(id)data;
@end

// Each bar glides from one made-up level to the next with an ease in and out,
// the same motion NLWaveformView makes, but written into the system's own
// waveform views every frame, so they keep their own look: the cover
// saturated, blurred, dimmed and lightened through the bars.
@implementation NLWaveformDriver {
    NSHashTable<UIView *> *_views;
    CADisplayLink *_link;
    double _from[6], _to[6], _start[6], _length[6];
}

- (instancetype)init {
    if ((self = [super init])) _views = [NSHashTable weakObjectsHashTable];
    return self;
}

- (void)dealloc {
    [_link invalidate];
}

static void NLCollectWaveforms(UIView *view, NSHashTable<UIView *> *into) {
    if ([NSStringFromClass(view.class) isEqualToString:@"MRUWaveformView"]) [into addObject:view];
    for (UIView *sub in view.subviews) NLCollectWaveforms(sub, into);
}

- (void)driveViewsIn:(UIView *)root {
    if (root) NLCollectWaveforms(root, _views);
    if (!_link && _views.count) {
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(nlFrame:)];
        _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

- (void)stop {
    [_link invalidate];
    _link = nil;
}

static double NLEase(double t) {
    t = MIN(MAX(t, 0), 1);
    return t * t * (3 - 2 * t);
}

- (void)nlFrame:(CADisplayLink *)link {
    Class dataClass = NSClassFromString(@"MRUWaveformData");
    if (!dataClass) return;
    CFTimeInterval now = CACurrentMediaTime();
    NSMutableArray<NSNumber *> *amplitudes = [NSMutableArray arrayWithCapacity:6];
    for (int i = 0; i < 6; i++) {
        double t = _length[i] > 0 ? (now - _start[i]) / _length[i] : 1;
        double level = _from[i] + (_to[i] - _from[i]) * NLEase(t);
        double target = _playing ? 0.2 + 0.8 * arc4random_uniform(1000) / 1000.0 : 0;
        // A new stretch once this one is done, or at once when playing stops.
        if (t >= 1 || (!_playing && _to[i] != 0)) {
            _from[i] = level;
            _to[i] = target;
            _start[i] = now;
            _length[i] = _playing ? 0.24 + 0.14 * arc4random_uniform(1000) / 1000.0 : 0.3;
        }
        [amplitudes addObject:@(level)];
    }
    id data = [[dataClass alloc] initWithAmplitudes:amplitudes];
    for (UIView *view in _views) {
        if (view.window && [view respondsToSelector:@selector(setWaveformData:)]) [(id)view setWaveformData:data];
    }
}

@end
