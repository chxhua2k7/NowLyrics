//
//  NLOffsetControl.h
//  The slider-plus-field control behind NLOffsetCell, also used on the
//  "Now Playing" page for the song's own offset.
//

#import <UIKit/UIKit.h>

// A UIControl so PSControlTableCell can treat it like any other: it fires
// UIControlEventValueChanged whenever the committed value changes, whether
// that came from the slider or from the field.
@interface NLOffsetControl : UIControl
@property (nonatomic, assign) double value;   // for the offset: seconds, positive means lyrics appear earlier
@property (nonatomic, assign) BOOL stacked;   // value pill on the first line, slider full width below
// step: dragging snaps to it, typing can be finer. unit: "s" (the default) also
// accepts "300ms" when typing, "" shows a bare number. scale: the value is shown
// and typed divided by it (a speed as "1.0×"). nil/0 keep the current setting.
- (void)setMinimum:(double)minimum maximum:(double)maximum step:(double)step unit:(NSString *)unit scale:(double)scale;
@end
