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
#import "../NLPlayerTint.h"
#import <CoreImage/CoreImage.h>

// A rested bar's vertical scale: a dot as tall as it is wide (0.2 while it has no height).
static CGFloat NLDotScale(CGFloat width, CGFloat height) { return height > 0 ? MAX(MIN(width / height, 1), 0.08) : 0.2; }

// A random value from `low` up to `low + span`, in thousandths.
static double NLRandom(double low, double span) { return low + span * arc4random_uniform(1000) / 1000.0; }

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
        [self nlApplyColor];
        [self nlRest];
    }
    return self;
}

- (void)nlApplyColor {
    // Through the cover the bars are only a shape: opaque, any color.
    UIColor *color = _artwork ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.8];
    for (UIView *bar in _bars) bar.backgroundColor = color;
}

// The system's waveform shows the cover blurred into soft color, not its
// details: a small copy, blurred, edges clamped so they do not darken.
static UIImage *NLBlurred(UIImage *image) {
    CGImageRef source = image.CGImage;
    if (!source) return image;
    // Every new island preview gives its waveform the same sample cover: that
    // one is blurred once.
    static UIImage *lastImage, *lastBlurred;
    if (image == lastImage) return lastBlurred;
    CGImageRef cg = NLCreateBlurredImage([CIImage imageWithCGImage:source], 48, 4);
    if (!cg) return image;
    UIImage *out = [UIImage imageWithCGImage:cg];
    CGImageRelease(cg);
    lastImage = image;
    lastBlurred = out;
    return out;
}

// The cover behind the bars, which become a window onto it. Given once, by the
// island preview as it makes the view, so nothing goes back to plain bars.
- (void)setArtwork:(UIImage *)artwork {
    if (artwork == _artwork) return;
    _artwork = artwork;
    if (artwork) {
        if (!_fill) {
            _fill = [UIImageView new];
            _fill.contentMode = UIViewContentModeScaleAspectFill;
            _fill.clipsToBounds = YES;
            UIView *lighten = [UIView new];   // sized by -layoutSubviews
            lighten.backgroundColor = [UIColor colorWithWhite:1 alpha:0.22];
            [_fill addSubview:lighten];
        }
        _fill.image = NLBlurred(artwork);
        if (_fill.superview != self) {
            [_barsHost removeFromSuperview];
            [self addSubview:_fill];
            _fill.maskView = _barsHost;
        }
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
        if (!_playing) bar.layer.transform = CATransform3DMakeScale(1, NLDotScale(width, MAX(b.size.height, 1)), 1);
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
        for (int k = 0; k < 8; k++) [values addObject:@(NLRandom(0.22, 0.78))];
        [values addObject:values.firstObject];
        CAKeyframeAnimation *a = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale.y"];
        a.values = values;
        a.duration = 2.2 + 0.35 * (i % 3) + arc4random_uniform(400) / 1000.0;
        a.calculationMode = kCAAnimationCubic;
        a.repeatCount = HUGE_VALF;
        a.removedOnCompletion = NO;
        a.beginTime = CACurrentMediaTime() - NLRandom(0, 1);
        [bar.layer addAnimation:a forKey:@"bounce"];
    }];
}

// Stopped: the bars shrink to dots, as the system's do.
- (void)nlRest {
    for (UIView *bar in _bars) {
        CALayer *shown = bar.layer.presentationLayer ?: bar.layer;
        CATransform3D from = shown.transform;
        [bar.layer removeAnimationForKey:@"bounce"];
        bar.layer.transform = CATransform3DMakeScale(1, NLDotScale(bar.bounds.size.width, bar.bounds.size.height), 1);
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

enum { kNLDriverBars = 6 };   // the levels MRUWaveformData takes

// The display link's target. A link keeps its target while it runs, so with
// the driver itself as the target, a driver its owner let go of would run on
// for as long as Preferences does: this one holds it weakly, and the driver's
// -dealloc ends the link.
@interface NLWaveformFrames : NSObject
@property (nonatomic, weak) NLWaveformDriver *driver;
@end

@interface NLWaveformDriver ()
- (void)nlFrame:(CADisplayLink *)link;
@end

// Each bar glides from one made-up level to the next with an ease in and out,
// the same motion NLWaveformView makes, but written into the system's own
// waveform views every frame, so they keep their own look: the cover
// saturated, blurred, dimmed and lightened through the bars.
@implementation NLWaveformDriver {
    NSHashTable<UIView *> *_views;
    CADisplayLink *_link;
    double _from[kNLDriverBars], _to[kNLDriverBars], _start[kNLDriverBars], _length[kNLDriverBars];
}

- (instancetype)init {
    if ((self = [super init])) _views = [NSHashTable weakObjectsHashTable];
    return self;
}

- (void)dealloc {
    [_link invalidate];
}

static void NLCollectWaveforms(UIView *view, Class waveformClass, NSHashTable<UIView *> *into) {
    if (view.class == waveformClass) [into addObject:view];
    for (UIView *sub in view.subviews) NLCollectWaveforms(sub, waveformClass, into);
}

- (void)driveViewsIn:(UIView *)root {
    // By class rather than by name: no string per view on every pass.
    Class waveformClass = NSClassFromString(@"MRUWaveformView");
    if (root && waveformClass) NLCollectWaveforms(root, waveformClass, _views);
    [self nlWake];   // views found now get the levels too
    if (!_link && _views.count) {
        NLWaveformFrames *frames = [NLWaveformFrames new];
        frames.driver = self;
        _link = [CADisplayLink displayLinkWithTarget:frames selector:@selector(nlFrame:)];
        _link.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

- (void)stop {
    [_link invalidate];
    _link = nil;
}

// Playing again: the link runs again.
- (void)setPlaying:(BOOL)playing {
    _playing = playing;
    if (playing) [self nlWake];
}

// The link again after resting (-nlFrame:). Resting, each bar would have gone
// on with its stretches (when stopped, 0.3 s ones from 0 to 0); it picks its
// stretch up where that rhythm would be now, so the bars rise when they would
// have.
- (void)nlWake {
    if (!_link.paused) return;
    CFTimeInterval now = CACurrentMediaTime();
    for (int i = 0; i < kNLDriverBars; i++) {
        if (_length[i] > 0) _start[i] = now - fmod(now - _start[i], _length[i]);
    }
    _link.paused = NO;
}

static double NLEase(double t) {
    t = MIN(MAX(t, 0), 1);
    return t * t * (3 - 2 * t);
}

- (void)nlFrame:(CADisplayLink *)link {
    static Class dataClass;
    if (!dataClass) dataClass = NSClassFromString(@"MRUWaveformData");   // once MediaControls has it
    if (!dataClass) return;
    // Drawn nowhere (its page covered, or its views gone): nothing to write,
    // so the link rests too, until -driveViewsIn: or playing wakes it.
    BOOL shown = NO;
    for (UIView *view in _views) {
        if (view.window) { shown = YES; break; }
    }
    if (!shown) {
        link.paused = YES;
        return;
    }
    CFTimeInterval now = CACurrentMediaTime();
    BOOL still = !_playing;   // stopped, every bar settled at 0, on every view
    NSMutableArray<NSNumber *> *amplitudes = [NSMutableArray arrayWithCapacity:kNLDriverBars];
    for (int i = 0; i < kNLDriverBars; i++) {
        double t = _length[i] > 0 ? (now - _start[i]) / _length[i] : 1;
        double level = _from[i] + (_to[i] - _from[i]) * NLEase(t);
        double target = _playing ? NLRandom(0.2, 0.8) : 0;
        // A new stretch once this one is done, or at once when playing stops.
        if (t >= 1 || (!_playing && _to[i] != 0)) {
            _from[i] = level;
            _to[i] = target;
            _start[i] = now;
            _length[i] = _playing ? NLRandom(0.24, 0.14) : 0.3;
        }
        if (level != 0 || _from[i] != 0) still = NO;   // from 0 to 0: it stays at 0
        [amplitudes addObject:@(level)];
    }
    id data = [[dataClass alloc] initWithAmplitudes:amplitudes];
    for (UIView *view in _views) {
        if (!view.window) { still = NO; continue; }
        if ([view respondsToSelector:@selector(setWaveformData:)]) [(id)view setWaveformData:data];
    }
    // Stopped and settled: every later frame would write these same zeros,
    // which the views keep (their -layoutSubviews applies the data they hold
    // again). The link rests until playing starts or -driveViewsIn: comes by.
    if (still) link.paused = YES;
}

@end

@implementation NLWaveformFrames

- (void)nlFrame:(CADisplayLink *)link {
    [self.driver nlFrame:link];
}

@end
