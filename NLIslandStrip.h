//
//  NLIslandStrip.h
//  Shared by NowLyricsIsland (SpringBoard) and the settings page's preview.
//

#import <UIKit/UIKit.h>

extern const CGFloat kNLDefaultSpeed;   // marquee, pt/s

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
// One whole marquee loop of the current line, or 0 when it fits.
@property (nonatomic, readonly) NSTimeInterval marqueeLoopDuration;
// Long enough to read the line once: the start, the glide, a moment at the end.
@property (nonatomic, readonly) NSTimeInterval marqueeReadDuration;
@end

// The most colorful bright pixel of the artwork, lifted until it reads on
// black; nil for a grey or dark cover. Any queue.
UIColor *NLColorFromArtwork(NSData *data);
