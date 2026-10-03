//
//  NLIslandStrip.m
//  The line strip and the album color, shared by NowLyricsIsland (SpringBoard)
//  and the island settings page's preview, so the preview is the real thing.
//

#import "NLIslandStrip.h"
#import <ImageIO/ImageIO.h>
#import <QuartzCore/QuartzCore.h>

const CGFloat kNLDefaultSpeed = 30;   // pt/s, shown as 1.0×


@implementation NLIslandStripView {
    UIView *_content;
    UILabel *_label;
    CAGradientLayer *_fade;
    CGFloat _fontSize;
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
        _speed = kNLDefaultSpeed;
    }
    return self;
}

// Runs on every update, so nothing is built unless something changed.
- (void)applyFontSize:(CGFloat)size color:(UIColor *)color speed:(CGFloat)speed {
    BOOL changed = size != _fontSize || speed != _speed;
    BOOL recolor = ![color isEqual:_label.textColor];
    if (!changed && !recolor) return;
    if (size != _fontSize) _label.font = [UIFont systemFontOfSize:size weight:UIFontWeightSemibold];
    _label.textColor = color;
    _fontSize = size;
    _speed = speed;
    if (changed || recolor) _label.attributedText = [self lineWithText:_text explicit:_explicit];
    if (changed) [self restartMarquee];
}

// The line, with the system's "E" after it for explicit tracks, as the
// expanded island and the lock screen show it: the e.square.fill symbol at the
// text's size and a little dimmer than the text.
- (NSAttributedString *)lineWithText:(NSString *)text explicit:(BOOL)explicit {
    UIFont *font = _label.font;
    UIColor *color = _label.textColor;
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] initWithString:text ?: @""
        attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}];
    if (!explicit || text.length == 0) return line;
    // Drawn once per font and color, not per line.
    static UIImage *badge;
    static UIFont *badgeFont;
    static UIColor *badgeColor;
    if (!badge || ![badgeFont isEqual:font] || ![badgeColor isEqual:color]) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithFont:font scale:UIImageSymbolScaleSmall];
        badge = [[UIImage systemImageNamed:@"e.square.fill" withConfiguration:config]
                 imageWithTintColor:[color colorWithAlphaComponent:0.7] renderingMode:UIImageRenderingModeAlwaysOriginal];
        badgeFont = font;
        badgeColor = color;
    }
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
    BOOL sameLine = [text isEqualToString:old];
    if (sameLine && explicit == _explicit) return;   // sameLine below: only the badge changed, no line change animation
    _text = [text copy];
    _explicit = explicit;
    if (sameLine || old.length == 0 || CGRectIsEmpty(_content.bounds)) {
        CATransition *t = [CATransition animation];
        t.type = kCATransitionFade;
        t.duration = 0.25;
        [_content.layer addAnimation:t forKey:@"line"];
        _label.attributedText = [self lineWithText:text explicit:explicit];
        [self restartMarquee];
        return;
    }

    // The old line leaves as a copy taken from what is on screen right now:
    // where the marquee has it and how faded it is. A snapshot of the layer
    // (CATransition) or of its model values shows the line opaque at its start
    // instead, so a change during the marquee's fade at the end flashed the
    // start of the previous line.
    CALayer *shown = _label.layer.presentationLayer ?: _label.layer;
    UILabel *leaving = [UILabel new];
    leaving.textAlignment = _label.textAlignment;
    leaving.lineBreakMode = _label.lineBreakMode;
    leaving.attributedText = _label.attributedText;
    leaving.frame = shown.frame;
    leaving.alpha = shown.opacity;
    [_content addSubview:leaving];
    CALayer *edgeFade = self.layer.mask;

    _label.attributedText = [self lineWithText:text explicit:explicit];
    [self restartMarquee];
    // A long line fades at the strip's edges; it keeps that while it leaves,
    // even when the new line fits and needs none.
    if (edgeFade && !self.layer.mask) {
        self.layer.mask = edgeFade;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_marqueeLoopDuration == 0 && self.layer.mask == edgeFade) self.layer.mask = nil;
        });
    }

    if (!scrollUp) {
        // Fade: the old line out and the new one in, in place.
        _label.alpha = 0;
        [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
            leaving.alpha = 0;
            self->_label.alpha = 1;
        } completion:^(BOOL finished) {
            [leaving removeFromSuperview];
        }];
        return;
    }

    // Scroll up, done by hand (Core Animation's push slides snapshots of the
    // whole layer and, in a strip this short, ran the two lines into each
    // other). The old line drifts up half a line while fading out quickly; the
    // new one rises from half a line below on a soft spring, starting a beat
    // later, so the change reads as one line giving way to the next rather than
    // two blocks being pushed.
    CGFloat shift = round(_content.bounds.size.height * 0.55);
    _label.transform = CGAffineTransformMakeTranslation(0, shift);
    _label.alpha = 0;
    // The old line is gone (alpha 0.15 s) before the new one is more than
    // faintly there, so the two never read as overlapping.
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
        leaving.transform = CGAffineTransformMakeTranslation(0, -shift);
    } completion:^(BOOL finished) {
        [leaving removeFromSuperview];
    }];
    [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        leaving.alpha = 0;
    } completion:nil];
    [UIView animateWithDuration:0.5 delay:0.08 usingSpringWithDamping:0.82 initialSpringVelocity:0.4
                        options:UIViewAnimationOptionAllowUserInteraction animations:^{
        self->_label.transform = CGAffineTransformIdentity;
    } completion:nil];
    [UIView animateWithDuration:0.28 delay:0.08 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self->_label.alpha = 1;
    } completion:nil];
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
        _marqueeLoopDuration = 0;
        _marqueeReadDuration = 0;
        return;
    }

    // Start flush left, glide to flush right and stay there; much later, fade
    // out, go back and fade in at the start. The start hold is long enough to
    // read it; the glide eases in and out instead of starting and stopping at
    // full speed.
    _label.frame = CGRectMake(0, 0, textWidth, b.size.height);
    CGFloat edge = 10;
    _fade.frame = b;
    _fade.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor,
                     (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
    _fade.locations = @[@0, @(edge / b.size.width), @(1 - edge / b.size.width), @1];
    self.layer.mask = _fade;

    CGFloat startX = textWidth / 2;
    CGFloat endX = startX - overflow;
    // The end is held long: a line usually goes on being sung after it has
    // scrolled through, and going back to its start then read as the start
    // flashing up again. Only a line that stays far longer (a long title over
    // an instrumental break) comes round again.
    double hold = 1.2, endHold = 8, fade = 0.25, glide = overflow / MAX(_speed, 1);
    double total = hold + glide + endHold + fade * 2;
    double glideEnd = (hold + glide) / total, out = (hold + glide + endHold) / total, back = out + fade / total;
    CAMediaTimingFunction *linear = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];

    CAKeyframeAnimation *move = [CAKeyframeAnimation animationWithKeyPath:@"position.x"];
    move.values = @[@(startX), @(startX), @(endX), @(endX), @(startX), @(startX)];
    move.keyTimes = @[@0, @(hold / total), @(glideEnd), @(back), @(back), @1];
    move.timingFunctions = @[linear, [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut],
                             linear, linear, linear];

    // The jump back happens while the line is invisible.
    CAKeyframeAnimation *opacity = [CAKeyframeAnimation animationWithKeyPath:@"opacity"];
    opacity.values = @[@1, @1, @0, @1];
    opacity.keyTimes = @[@0, @(out), @(back), @1];

    move.duration = opacity.duration = total;   // a group does not stretch its children
    CAAnimationGroup *a = [CAAnimationGroup animation];
    a.animations = @[move, opacity];
    a.duration = total;
    _marqueeLoopDuration = total;
    _marqueeReadDuration = hold + glide + hold;
    a.repeatCount = HUGE_VALF;
    a.removedOnCompletion = NO;
    [_label.layer addAnimation:a forKey:@"marquee"];
}

@end

#pragma mark - Album color

// The most colorful bright pixel of a small copy of the artwork, lifted until
// it reads on black. Average colors come out muddy, so the vivid one wins. The
// copy is decoded small to begin with rather than from the full-size cover.
UIColor *NLColorFromArtwork(NSData *data) {
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;
    CGImageRef cg = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
        (id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (id)kCGImageSourceThumbnailMaxPixelSize: @64,
    });
    CFRelease(source);
    if (!cg) return nil;
    enum { side = 16 };
    uint8_t px[side * side * 4];
    memset(px, 0, sizeof(px));
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, side, side, 8, side * 4, space,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (ctx) {
        CGContextSetInterpolationQuality(ctx, kCGInterpolationMedium);
        CGContextDrawImage(ctx, CGRectMake(0, 0, side, side), cg);
        CGContextRelease(ctx);
    }
    CGImageRelease(cg);
    if (!ctx) return nil;

    // Hue, saturation and brightness as -[UIColor getHue:saturation:brightness:alpha:] gives them.
    CGFloat bestScore = -1, bh = 0, bs = 0, bb = 0;
    for (size_t i = 0; i < side * side; i++) {
        CGFloat r = px[i * 4] / 255.0, g = px[i * 4 + 1] / 255.0, bl = px[i * 4 + 2] / 255.0;
        CGFloat max = MAX(r, MAX(g, bl)), min = MIN(r, MIN(g, bl)), delta = max - min;
        CGFloat b = max, s = max > 0 ? delta / max : 0, h = 0;
        if (delta > 0) {
            if (max == r) h = (g - bl) / delta;
            else if (max == g) h = 2 + (bl - r) / delta;
            else h = 4 + (r - g) / delta;
            h /= 6;
            if (h < 0) h += 1;
        }
        CGFloat score = s * (0.4 + b);
        if (b > 0.3 && score > bestScore) { bestScore = score; bh = h; bs = s; bb = b; }
    }
    if (bestScore < 0.15) return nil;   // a grey or dark cover: stay white
    return [UIColor colorWithHue:bh saturation:MIN(bs, 0.65) brightness:MAX(bb, 0.92) alpha:1];
}
