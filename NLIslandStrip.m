//
//  NLIslandStrip.m
//  The line strip and the album color, shared by NowLyricsIsland (SpringBoard)
//  and the island settings page's preview, so the preview is the real thing.
//

#import "NLIslandStrip.h"
#import "NLShared.h"
#import <ImageIO/ImageIO.h>

const CGFloat kNLDefaultSpeed = 30;   // pt/s, shown as 1.0×

// A label for the line: centred, clipped rather than truncated (the marquee moves it).
static UILabel *NLLineLabel(void) {
    UILabel *label = [UILabel new];
    label.textAlignment = NSTextAlignmentCenter;
    label.lineBreakMode = NSLineBreakByClipping;
    return label;
}

// A gradient running left to right through `colors` (CGColors).
static CAGradientLayer *NLSideGradient(NSArray *colors) {
    CAGradientLayer *gradient = [CAGradientLayer layer];
    gradient.colors = colors;
    gradient.startPoint = CGPointMake(0, 0.5);
    gradient.endPoint = CGPointMake(1, 0.5);
    return gradient;
}

// position.x through `values` at `keyTimes` over `duration`, held at the end.
static CAKeyframeAnimation *NLSlideThrough(NSArray *values, NSArray *keyTimes, CFTimeInterval duration) {
    CAKeyframeAnimation *move = [CAKeyframeAnimation animationWithKeyPath:@"position.x"];
    move.values = values;
    move.keyTimes = keyTimes;
    move.duration = duration;
    move.fillMode = kCAFillModeForwards;
    move.removedOnCompletion = NO;
    return move;
}


@implementation NLIslandStripView {
    UIView *_content;
    UILabel *_label;
    CAGradientLayer *_fade;
    CGFloat _fontSize;
    CGFloat _speed;
    CGFloat _laidOutWidth;
    NSString *_text;
    BOOL _explicit;
    // Word by word: two copies of the line inside _label (which then draws
    // nothing itself but keeps the size and the scrolling), the full-color one
    // masked to what has been sung and the dimmed one to the rest, so no glyph
    // is ever drawn twice on top of itself.
    UILabel *_lit, *_dim;
    CAGradientLayer *_litMask, *_dimMask;
    NSArray<NSString *> *_wordTexts;
    NSArray<NSNumber *> *_wordStarts, *_wordEnds;
    UIColor *_color;
    NSTimeInterval _wordPosition;   // the clock at _wordSetAt
    CFTimeInterval _wordSetAt;
    double _wordRate;
    BOOL _lineFits;   // the current line fits the strip: no faded edges of its own
    // A line that leaves with faded edges keeps them over a new line that fits
    // until it is gone: the line change holding them (0: none), and a count
    // each hold takes the next number of, so only the last one's cleanup ends it.
    NSUInteger _edgeFadeHold, _edgeFadeHolds;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.clipsToBounds = YES;
        self.userInteractionEnabled = NO;
        _content = [[UIView alloc] initWithFrame:self.bounds];
        _content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_content];
        _label = NLLineLabel();
        [_content addSubview:_label];
        _fade = NLSideGradient(@[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor,
                                 (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor]);   // the edges of a long line, faded
        _speed = kNLDefaultSpeed;
        _alignment = NSTextAlignmentCenter;
    }
    return self;
}

- (void)setAlignment:(NSTextAlignment)alignment {
    if (alignment == _alignment) return;
    _alignment = alignment;
    [self restartMarquee];
}

// Runs on every update, so nothing is built unless something changed.
- (void)applyFontSize:(CGFloat)size color:(UIColor *)color speed:(CGFloat)speed {
    BOOL changed = size != _fontSize || speed != _speed;
    BOOL recolor = ![color isEqual:_color];
    if (!changed && !recolor) return;
    if (size != _fontSize) _label.font = NLIslandFont(size);
    _color = color;
    _fontSize = size;
    _speed = speed;
    [self renderLine];
    if (changed) [self restartMarquee];
}

// The line into the label, or, word by word, dimmed into the label and in full
// color into the lit copy over it.
- (void)renderLine {
    if (!_color) _color = UIColor.whiteColor;
    if (_wordTexts && _lit) {
        UIColor *dim = [_color colorWithAlphaComponent:CGColorGetAlpha(_color.CGColor) * 0.4];
        _label.attributedText = [self lineWithText:_text explicit:_explicit color:UIColor.clearColor];
        _dim.attributedText = [self lineWithText:_text explicit:_explicit color:dim];
        _lit.attributedText = [self lineWithText:_text explicit:_explicit color:_color];
    } else {
        _label.attributedText = [self lineWithText:_text explicit:_explicit color:_color];
    }
}

// The line, with the system's "E" after it for explicit tracks, as the
// expanded island and the lock screen show it: the e.square.fill symbol at the
// text's size and a little dimmer than the text.
- (NSAttributedString *)lineWithText:(NSString *)text explicit:(BOOL)explicit color:(UIColor *)color {
    UIFont *font = _label.font;
    NSMutableAttributedString *line = [[NSMutableAttributedString alloc] initWithString:text ?: @""
        attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}];
    if (!explicit || text.length == 0) return line;
    // Drawn once per font and color, not per line. Word by word asks for three
    // colors in turn (clear, dimmed, full), so each is kept; a new font, or a
    // few album colors on, starts over.
    static NSMutableDictionary<UIColor *, UIImage *> *badges;
    static UIFont *badgeFont;
    if (!badges || ![badgeFont isEqual:font] || badges.count >= 6) {
        badges = [NSMutableDictionary dictionary];
        badgeFont = font;
    }
    UIImage *badge = badges[color];
    if (!badge) {
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithFont:font scale:UIImageSymbolScaleSmall];
        badge = [[UIImage systemImageNamed:@"e.square.fill" withConfiguration:config]
                 imageWithTintColor:[color colorWithAlphaComponent:0.7] renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (badge) badges[color] = badge;
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
    BOOL oldExplicit = _explicit, wasWords = _wordTexts != nil;
    _text = [text copy];
    _explicit = explicit;
    if (!sameLine) [self clearWords];   // they belonged to the previous line
    if (sameLine || old.length == 0 || CGRectIsEmpty(_content.bounds)) {
        CATransition *t = [CATransition animation];
        t.type = kCATransitionFade;
        t.duration = 0.25;
        [_content.layer addAnimation:t forKey:@"line"];
        [self renderLine];
        [self restartMarquee];
        return;
    }

    // The old line leaves as a copy taken from what is on screen right now:
    // where the marquee has it and how faded it is. A snapshot of the layer
    // (CATransition) or of its model values shows the line opaque at its start
    // instead, so a change during the marquee's fade at the end flashed the
    // start of the previous line.
    CALayer *shown = _label.layer.presentationLayer ?: _label.layer;
    UILabel *leaving = NLLineLabel();
    leaving.textAlignment = _label.textAlignment;   // where the old line sat
    // Sung word by word, the line is all lit by the time it leaves.
    leaving.attributedText = wasWords ? [self lineWithText:old explicit:oldExplicit color:_color] : _label.attributedText;
    leaving.frame = shown.frame;
    leaving.alpha = shown.opacity;
    [_content addSubview:leaving];
    BOOL leavingFaded = !_lineFits;   // the old line has faded edges of its own

    [self renderLine];
    [self restartMarquee];
    // A long line fades at the strip's edges; it keeps that while it leaves,
    // even when the new line fits and needs none. -restartMarquee keeps it on
    // while it is held (the word times that follow in the same update run it
    // again), and only the last such line change's cleanup takes it off.
    if (leavingFaded && _lineFits) {
        NSUInteger hold = ++_edgeFadeHolds;
        _edgeFadeHold = hold;
        self.layer.mask = _fade;
        NLAfter(0.3, ^{
            if (self->_edgeFadeHold != hold) return;   // a later line change holds it on longer
            self->_edgeFadeHold = 0;
            if (self->_lineFits) self.layer.mask = nil;
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
    CGFloat gutter = _alignment == NSTextAlignmentLeft ? kNLStripEdge : 0;   // see -alignment
    CGFloat textWidth = ceil([_label sizeThatFits:CGSizeMake(CGFLOAT_MAX, b.size.height)].width);
    CGFloat overflow = textWidth + gutter - b.size.width;
    BOOL fits = overflow <= 1 || b.size.width <= 0;
    _lineFits = fits;
    if (fits) {
        _label.textAlignment = _alignment;
        _label.frame = CGRectMake(gutter, 0, b.size.width - gutter, b.size.height);
        self.layer.mask = _edgeFadeHold ? _fade : nil;   // a line leaving with faded edges keeps them (-setText:…)
    } else {
        // The label is a little wider on each side than its text (half the
        // faded edge, or the gutter at the left), so the first and last
        // characters are not eaten by it.
        CGFloat edge = kNLStripEdge;
        _label.textAlignment = NSTextAlignmentCenter;
        textWidth += (gutter ?: round(edge * 0.5)) * 2;
        overflow = textWidth - b.size.width;
        _label.frame = CGRectMake(0, 0, textWidth, b.size.height);
        _fade.frame = b;
        _fade.locations = @[@0, @(edge / b.size.width), @(1 - edge / b.size.width), @1];
        self.layer.mask = _fade;
    }
    // Fitting, or word by word (the singing moves the line along instead): no marquee.
    if (fits || _wordTexts) {
        _marqueeReadDuration = 0;
        [self applyWords];
        return;
    }

    // Start flush left, glide to flush right and stay there; much later, fade
    // out, go back and fade in at the start. The start hold is long enough to
    // read it; the glide eases in and out instead of starting and stopping at
    // full speed.
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
    _marqueeReadDuration = hold + glide + hold;
    a.repeatCount = HUGE_VALF;
    a.removedOnCompletion = NO;
    [_label.layer addAnimation:a forKey:@"marquee"];
}

#pragma mark Word by word

// The timing and the layout of one line's pieces, for the two functions below.
typedef struct {
    NSUInteger n;
    const double *ts, *te;   // each piece's start and end
    const CGFloat *xs;       // n + 1 offsets across the text: piece i spans xs[i]..xs[i+1]
    CGFloat x0;              // where the text starts in the label
    CGFloat visible, overflow, restX;   // the strip's width, how much wider the label is, its unscrolled centre
} NLWordGeometry;

// How much of the line is lit at time t: within a piece in proportion to its
// time, between pieces up to where the last one ended.
static CGFloat NLLitWidth(const NLWordGeometry *g, double t) {
    for (NSUInteger i = 0; i < g->n; i++) {
        if (t < g->ts[i]) return g->x0 + g->xs[i];
        if (t < g->te[i]) return g->x0 + g->xs[i] + (g->xs[i + 1] - g->xs[i]) * (t - g->ts[i]) / (g->te[i] - g->ts[i]);
    }
    return g->x0 + g->xs[g->n];
}

// The label's centre for a long line: still until the lit edge passes two
// thirds of the strip, then moving to keep it there, stopping at the end.
static CGFloat NLLineCentre(const NLWordGeometry *g, double t) {
    if (g->overflow <= 1) return g->restX;
    CGFloat shift = MIN(MAX(NLLitWidth(g, t) - g->visible * 0.65, 0), g->overflow);
    return g->restX - shift;
}

- (void)clearWords {
    _wordTexts = nil;
    _wordStarts = _wordEnds = nil;
    [_litMask removeAllAnimations];
    [_dimMask removeAllAnimations];
    [_lit removeFromSuperview];
    [_dim removeFromSuperview];
}

- (void)setWordTexts:(NSArray<NSString *> *)texts starts:(NSArray<NSNumber *> *)starts ends:(NSArray<NSNumber *> *)ends
            position:(NSTimeInterval)position rate:(double)rate {
    // Pieces equal to the ones running were checked against this line when
    // they came (a new line clears them), so only new ones are joined.
    BOOL running = _wordTexts && [texts isEqualToArray:_wordTexts];
    BOOL usable = texts.count && starts.count == texts.count && ends.count == texts.count &&
                  (running || [[texts componentsJoinedByString:@""] isEqualToString:_text ?: @""]);
    if (!usable) {
        if (!_wordTexts) return;
        [self clearWords];
        [self renderLine];
        [self restartMarquee];
        return;
    }
    // Asked again with what is already running (every layout pass asks): keep
    // it, unless the clock moved differently from what is being shown.
    double projected = NLClockAt(_wordPosition, _wordSetAt, _wordRate);
    if (running && [starts isEqualToArray:_wordStarts] && rate == _wordRate &&
        fabs(projected - position) < 0.08) return;
    _wordTexts = [texts copy];
    _wordStarts = [starts copy];
    _wordEnds = [ends copy];
    _wordPosition = position;
    _wordSetAt = CACurrentMediaTime();
    _wordRate = rate;
    [self restartMarquee];   // frames first, then the words on them
}

// The lit copy's mask grows over each piece while it is sung, and a line too
// long for the strip slides so the sung edge stays in view. Both are sampled
// from the word times into keyframes once, so nothing runs per frame.
- (void)applyWords {
    if (!_wordTexts) {
        [self clearWords];
        return;
    }
    [_litMask removeAllAnimations];
    [_dimMask removeAllAnimations];
    if (!_lit) {
        // Two masks that meet at the sung edge with a soft overlap, both placed
        // at it: the lit copy's fades out to the right of it (its right end is
        // the edge), the dimmed copy's fades in over the same stretch (anchored
        // a feather into it).
        _lit = NLLineLabel();
        _dim = NLLineLabel();
        _lit.autoresizingMask = _dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _litMask = NLSideGradient(@[(id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor]);
        _litMask.anchorPoint = CGPointMake(1, 0);
        _dimMask = NLSideGradient(@[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor]);
        _lit.layer.mask = _litMask;
        _dim.layer.mask = _dimMask;
    }
    for (UILabel *copy in @[_dim, _lit]) {
        // The label's own font too, not only the string's: UILabel places a
        // single line by its font's metrics, and the default 17 pt one put
        // these copies lower than the line they replace.
        copy.font = _label.font;
        copy.textAlignment = _label.textAlignment;
        if (copy.superview != _label) [_label addSubview:copy];
        copy.frame = _label.bounds;
    }
    [self renderLine];

    // Where each piece starts and ends across the label. The line is centred
    // (or at a side) when it fits; the last piece lights the explicit badge
    // after it too.
    CGRect lb = _label.bounds;
    NSUInteger n = _wordTexts.count;
    CGFloat lineWidth = ceil(_lit.attributedText.size.width);
    NSTextAlignment alignment = _label.textAlignment;   // centred in its padded label when long
    CGFloat x0 = alignment == NSTextAlignmentCenter ? MAX(0, round((lb.size.width - lineWidth) / 2))
               : alignment == NSTextAlignmentRight ? MAX(0, lb.size.width - lineWidth) : 0;
    NSDictionary *attrs = @{NSFontAttributeName: _label.font};
    CGFloat xs[n + 1];
    double ts[n], te[n];
    NSMutableString *prefix = [NSMutableString string];
    xs[0] = 0;
    for (NSUInteger i = 0; i < n; i++) {
        [prefix appendString:_wordTexts[i]];
        xs[i + 1] = [prefix sizeWithAttributes:attrs].width;
        ts[i] = _wordStarts[i].doubleValue;
        te[i] = _wordEnds[i].doubleValue;
    }
    xs[n] = MAX(xs[n], lineWidth);
    double tLast = 0;
    for (NSUInteger i = 0; i < n; i++) {
        // An end the source left out is the next start (or a beat later).
        if (te[i] <= ts[i]) te[i] = (i + 1 < n) ? ts[i + 1] : ts[i] + 0.6;
        tLast = MAX(tLast, te[i]);
    }
    NLWordGeometry g = { .n = n, .ts = ts, .te = te, .xs = xs, .x0 = x0,
                         .visible = _content.bounds.size.width,
                         .overflow = lb.size.width - _content.bounds.size.width,
                         .restX = lb.size.width / 2 };
    CGFloat overflow = g.overflow;

    double now = NLClockAt(_wordPosition, _wordSetAt, _wordRate);
    CGFloat height = lb.size.height;

    // The soft edge is about a character wide. Its far side is where the lit
    // part ends, stretched so the whole fade has passed the last character by
    // the time the line is sung.
    CGFloat feather = MAX(round(_label.font.pointSize * 1.2), 8);
    CGFloat span = MAX(xs[n], 1);
    CGFloat (^edgeAt)(double) = ^CGFloat(double t) {
        return x0 + (NLLitWidth(&g, t) - x0) * (span + feather) / span;
    };
    CGFloat maskWidth = lb.size.width + feather * 2;
    NSArray *litStops = @[@0, @((maskWidth - feather) / maskWidth), @1];
    NSArray *dimStops = @[@0, @(feather / maskWidth), @1];

    // A long line's scroll follows the sung edge, averaged over a second of
    // song around each moment so it glides instead of stepping word by word.
    double (^glideAt)(double) = ^double(double t) {
        double sum = 0;
        for (int j = -12; j <= 12; j++) sum += NLLineCentre(&g, t + j * 0.04);
        return sum / 25;
    };

    BOOL still = _wordRate <= 0 || now >= tLast;   // paused or done: hold where the singing is
    CGFloat edge = edgeAt(still ? now : tLast);
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _litMask.locations = litStops;
    _dimMask.locations = dimStops;
    _litMask.bounds = CGRectMake(0, 0, maskWidth, height);
    _dimMask.bounds = CGRectMake(0, 0, maskWidth, height);
    _dimMask.anchorPoint = CGPointMake(feather / maskWidth, 0);   // its left end a feather before the edge
    _litMask.position = CGPointMake(edge, 0);
    _dimMask.position = CGPointMake(edge, 0);
    if (still && overflow > 1) _label.layer.position = CGPointMake(glideAt(now), _label.layer.position.y);
    [CATransaction commit];
    if (still) return;

    // From now to the last piece's end in steps of 40 ms of song time (the
    // glide runs half a second longer, to settle).
    double glideEnd = tLast + 0.5;
    NSUInteger steps = MIN((NSUInteger)ceil((glideEnd - now) / 0.04), (NSUInteger)3000);
    steps = MAX(steps, (NSUInteger)1);
    NSMutableArray *edges = [NSMutableArray arrayWithCapacity:steps + 1];
    NSMutableArray *centres = [NSMutableArray arrayWithCapacity:steps + 1];
    NSMutableArray *keyTimes = [NSMutableArray arrayWithCapacity:steps + 1];
    for (NSUInteger k = 0; k <= steps; k++) {
        double t = now + (glideEnd - now) * k / steps;
        [edges addObject:@(edgeAt(t))];
        if (overflow > 1) [centres addObject:@(glideAt(t))];
        [keyTimes addObject:@((double)k / steps)];
    }
    CFTimeInterval duration = (glideEnd - now) / _wordRate;

    CAKeyframeAnimation *move = NLSlideThrough(edges, keyTimes, duration);   // the same for both masks (each layer copies it)
    [_litMask addAnimation:move forKey:@"words"];
    [_dimMask addAnimation:move forKey:@"words"];
    if (overflow > 1) [_label.layer addAnimation:NLSlideThrough(centres, keyTimes, duration) forKey:@"marquee"];
}

@end

#pragma mark - Album color

// The small copy of a cover that NLColorFromArtwork below and the player tint
// (NLPlayerTint.m) read their colors from.
BOOL NLSampleImage(CGImageRef image, CGInterpolationQuality quality, uint8_t *px) {
    memset(px, 0, NL_SAMPLE_SIDE * NL_SAMPLE_SIDE * 4);
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, NL_SAMPLE_SIDE, NL_SAMPLE_SIDE, 8, NL_SAMPLE_SIDE * 4, space,
                                             kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGColorSpaceRelease(space);
    if (!ctx) return NO;
    CGContextSetInterpolationQuality(ctx, quality);
    CGContextDrawImage(ctx, CGRectMake(0, 0, NL_SAMPLE_SIDE, NL_SAMPLE_SIDE), image);
    CGContextRelease(ctx);
    return YES;
}

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
    enum { side = NL_SAMPLE_SIDE };
    uint8_t px[side * side * 4];
    BOOL drawn = NLSampleImage(cg, kCGInterpolationMedium, px);
    CGImageRelease(cg);
    if (!drawn) return nil;

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

// Tells covers apart. -[NSData hash] only reads the first 80 bytes, which
// JPEGs from the same encoder share, so the length and two samples from the
// compressed data further in go in as well.
NSUInteger NLArtworkPrint(NSData *data) {
    const uint8_t *bytes = data.bytes;
    NSUInteger length = data.length;
    uint64_t h = 1469598103934665603ULL ^ length;   // FNV-1a
    NSUInteger window = MIN(length, (NSUInteger)256);
    NSUInteger starts[] = { length / 2 - MIN(length / 2, window / 2), length - window };
    for (int k = 0; k < 2; k++) {
        for (NSUInteger i = starts[k]; i < starts[k] + window; i++) { h ^= bytes[i]; h *= 1099511628211ULL; }
    }
    return (NSUInteger)h ?: 1;   // 0 means "nothing claimed"
}
