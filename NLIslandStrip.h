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
// One whole marquee loop of the current line, or 0 when it fits.
@property (nonatomic, readonly) NSTimeInterval marqueeLoopDuration;
// Long enough to read the line once: the start, the glide, a moment at the end.
@property (nonatomic, readonly) NSTimeInterval marqueeReadDuration;
@end

// The most colorful bright pixel of the artwork, lifted until it reads on
// black; nil for a grey or dark cover. Any queue.
UIColor *NLColorFromArtwork(NSData *data);
