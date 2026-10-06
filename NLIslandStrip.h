//
//  NLIslandStrip.h
//  Shared by NowLyricsIsland (SpringBoard) and the settings page's preview.
//

#import <UIKit/UIKit.h>

extern const CGFloat kNLDefaultSpeed;   // marquee, pt/s
// Island.plist's default font size, the camera's width until it is measured
// (a 14 Pro's), and what is kept clear on each side of the line.
static const CGFloat kNLDefaultFontSize = 11;
static const CGFloat kNLDefaultSensorWidth = 125;
static const CGFloat kNLContentGap = 4;
// The line's font.
static inline UIFont *NLIslandFont(CGFloat size) { return [UIFont systemFontOfSize:size weight:UIFontWeightSemibold]; }
// The line's box height: the font's exact line height, for the last size
// asked (each file that calls it keeps its own). Main queue.
static inline CGFloat NLIslandLineHeight(CGFloat size) {
    static CGFloat lastSize = -1, height = 0;
    if (size != lastSize) {
        lastSize = size;
        height = NLIslandFont(size).lineHeight;
    }
    return height;
}
// The line's box in an island `area` big: `width` wide and centred, `height`
// tall on the bottom edge, so a bigger font only grows upwards.
static inline CGRect NLIslandStripFrame(CGSize area, CGFloat width, CGFloat height) {
    return CGRectMake(round((area.width - width) / 2), area.height - height, width, height);
}
// The line's color: the album's when that is wanted and the cover gave one,
// else the island's white.
static inline UIColor *NLIslandTextColor(BOOL artworkColor, UIColor *album) {
    if (artworkColor && album) return album;
    static UIColor *white;
    if (!white) white = [UIColor colorWithWhite:1 alpha:0.92];
    return white;
}
// A clock that read `position` at `since` (CACurrentMediaTime), running at `rate`: now.
static inline double NLClockAt(double position, CFTimeInterval since, double rate) {
    return position + (CACurrentMediaTime() - since) * rate;
}
// The first view controller up `responder`'s chain (whose view holds it); nil when none does yet.
static inline UIViewController *NLViewControllerOf(UIResponder *responder) {
    for (UIResponder *r = responder.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) return (UIViewController *)r;
    }
    return nil;
}
// `view` or the nearest of its superviews that is a `cls`; nil for a Nil class.
static inline UIView *NLAncestorOfClass(UIView *view, Class cls) {
    for (UIView *v = view; v; v = v.superview) {
        if ([v isKindOfClass:cls]) return v;
    }
    return nil;
}

// A clipping strip with the line in it. Line changes animate an inner content
// view, so a pushed-out line is cut at the strip's edge instead of sliding over
// the artwork. Lines too wide for the strip scroll through once at the set
// speed, with the edges faded so the text does not end in a hard cut.
@interface NLIslandStripView : UIView
- (void)setText:(NSString *)text explicit:(BOOL)explicit scrollUp:(BOOL)scrollUp;
- (void)applyFontSize:(CGFloat)size color:(UIColor *)color speed:(CGFloat)speed;
// Word by word for the line now shown (call after -setText:…): the sung part
// lights up as it is sung and a long line scrolls along with it instead of at
// the marquee speed. `texts` joined are the line; `starts`/`ends` are seconds
// on the clock `position` is read from, which runs at `rate` (0 = paused).
// nil texts go back to the plain line. A new -setText: line also does.
- (void)setWordTexts:(NSArray<NSString *> *)texts starts:(NSArray<NSNumber *> *)starts ends:(NSArray<NSNumber *> *)ends
            position:(NSTimeInterval)position rate:(double)rate;
// Long enough to read the line once: the start, the glide, a moment at the end.
@property (nonatomic, readonly) NSTimeInterval marqueeReadDuration;
@end

// The most colorful bright pixel of the artwork, lifted until it reads on
// black; nil for a grey or dark cover. Any queue.
UIColor *NLColorFromArtwork(NSData *data);
// A cover sampled small: `image` drawn into `px` (NL_SAMPLE_SIDE squared RGBA
// bytes, premultiplied, big-endian) at `quality`, zeroed first; NO, `px` all
// zero, when no bitmap context could be made. Any queue.
#define NL_SAMPLE_SIDE 16
BOOL NLSampleImage(CGImageRef image, CGInterpolationQuality quality, uint8_t *px);

// Tells covers apart (-[NSData hash] only reads the first 80 bytes, which
// JPEGs from the same encoder share). Never 0. Any queue.
NSUInteger NLArtworkPrint(NSData *data);
