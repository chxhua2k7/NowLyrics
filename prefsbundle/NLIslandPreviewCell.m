//
//  NLIslandPreviewCell.m
//  The top row of the "Lyrics in the island" page: a compact Dynamic Island
//  drawn at its real size, singing random lines (NLPreviewLines.m) with the
//  page's current color, line change, font size and scroll speed. The strip in
//  it is NowLyricsIsland's own NLIslandStripView, so what it shows is what the
//  island will do.
//
//  It answers touches the way the real island does: it swells under a finger
//  with a light tap, a tap moves on to the next line, and a long press opens
//  it with a firmer one. Open, it stays until tapped (or left alone a while).
//  Every move is a spring given as response and damping, the way UIKit's own
//  system animations are tuned.
//
//  The page's controller posts NLIslandPreviewChangedNotification after each
//  change; the cell then asks it (-nlIslandPreviewValues) for the values.
//

#import <UIKit/UIKit.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import "../NLIslandStrip.h"

NSString *const NLIslandPreviewChangedNotification = @"NLIslandPreviewChanged";
NSArray<NSString *> *NLPreviewLinePool(NSBundle *bundle);   // NLPreviewLines.m

@interface NSObject (NLIslandPreview)
- (NSDictionary *)nlIslandPreviewValues;
@end

// The compact island on a 14 Pro with music playing, grown to the status bar,
// and the expanded one a long press opens.
static const CGSize kNLCompact = {192, 48};
static const CGSize kNLExpanded = {330, 92};
static const CGFloat kNLSensorWidth = 125;   // the line is centred under the camera at this width
static const CGFloat kNLPressScale = 1.06;
static const NSTimeInterval kNLExpandDelay = 0.45;
static const NSTimeInterval kNLAutoCollapse = 6;
static const NSUInteger kNLBars = 6;
static const NSUInteger kNLRecentLines = 6;   // not repeated until this many others came by

@interface NLIslandPreviewCell : PSTableCell <UIGestureRecognizerDelegate>
@end

@implementation NLIslandPreviewCell {
    UIView *_pill;
    UIImageView *_art;
    NSArray<UIView *> *_bars;
    NLIslandStripView *_strip;
    UILabel *_titleLabel;      // expanded only
    UILabel *_lineLabel;       // expanded only
    UIColor *_albumColor;
    UIColor *_textColor;
    NSString *_line;
    NSMutableArray<NSString *> *_recent;
    NSUInteger _generation;    // invalidates the pending line change
    NSUInteger _pressGeneration;
    NSUInteger _openGeneration;   // invalidates the pending auto-collapse
    BOOL _pressStartedOpen;
    CGFloat _fontSize;
    BOOL _scrollUp;
    BOOL _expanded;
    BOOL _pressCancelled;
    CGPoint _pressStart;
    UIImpactFeedbackGenerator *_lightTap, *_firmTap;
}

// A stand-in cover: a warm gradient with a note on it. Its album color comes
// from the same NLColorFromArtwork() the island uses.
static UIImage *NLSampleArtwork(CGFloat side) {
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side)];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(id)[UIColor colorWithRed:1.00 green:0.48 blue:0.36 alpha:1].CGColor,
                            (id)[UIColor colorWithRed:0.86 green:0.25 blue:0.55 alpha:1].CGColor];
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
        CGContextDrawLinearGradient(context.CGContext, gradient, CGPointZero, CGPointMake(side, side), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:side * 0.45 weight:UIImageSymbolWeightSemibold];
        UIImage *note = [[UIImage systemImageNamed:@"music.note" withConfiguration:config]
                         imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.9] renderingMode:UIImageRenderingModeAlwaysOriginal];
        [note drawInRect:CGRectMake((side - note.size.width) / 2, (side - note.size.height) / 2, note.size.width, note.size.height)];
    }];
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.clipsToBounds = NO;
        self.contentView.clipsToBounds = NO;

        _pill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kNLCompact.width, kNLCompact.height)];
        _pill.backgroundColor = UIColor.blackColor;
        _pill.layer.cornerRadius = kNLCompact.height / 2;
        _pill.layer.cornerCurve = kCACornerCurveContinuous;
        _pill.layer.borderWidth = 1;
        _pill.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.1].CGColor;   // shows on a dark row only
        _pill.clipsToBounds = YES;
        [self.contentView addSubview:_pill];

        UIImage *art = NLSampleArtwork(64);
        _art = [[UIImageView alloc] initWithImage:art];
        _art.layer.cornerCurve = kCACornerCurveContinuous;
        _art.clipsToBounds = YES;
        [_pill addSubview:_art];
        _albumColor = NLColorFromArtwork(UIImagePNGRepresentation(art));

        NSMutableArray *bars = [NSMutableArray array];
        for (NSUInteger i = 0; i < kNLBars; i++) {
            UIView *bar = [UIView new];
            bar.backgroundColor = [_albumColor ?: UIColor.whiteColor colorWithAlphaComponent:0.85];
            bar.layer.cornerRadius = 1.25;
            [_pill addSubview:bar];
            [bars addObject:bar];
        }
        _bars = bars;

        _strip = [[NLIslandStripView alloc] initWithFrame:CGRectZero];
        [_pill addSubview:_strip];

        _titleLabel = [UILabel new];
        _titleLabel.text = @"NowLyrics";
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        _titleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
        _titleLabel.alpha = 0;
        [_pill addSubview:_titleLabel];

        _lineLabel = [UILabel new];
        _lineLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        _lineLabel.numberOfLines = 2;
        _lineLabel.adjustsFontSizeToFitWidth = YES;
        _lineLabel.minimumScaleFactor = 0.8;
        _lineLabel.alpha = 0;
        [_pill addSubview:_lineLabel];

        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(nlPressed:)];
        press.minimumPressDuration = 0;
        press.delegate = self;
        [_pill addGestureRecognizer:press];

        _lightTap = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        _firmTap = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        _recent = [NSMutableArray array];
        _fontSize = 11;
        _textColor = [UIColor colorWithWhite:1 alpha:0.92];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nlValuesChanged:)
                                                     name:NLIslandPreviewChangedNotification object:nil];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark Layout

- (void)layoutSubviews {
    [super layoutSubviews];
    [self nlLayoutPill];
}

// Bounds and centre rather than frame, so the press transform can stay on.
- (void)nlLayoutPill {
    CGSize size = _expanded ? kNLExpanded : kNLCompact;
    CGRect b = self.contentView.bounds;
    _pill.bounds = CGRectMake(0, 0, size.width, size.height);
    _pill.center = CGPointMake(round(CGRectGetMidX(b)), round(CGRectGetMidY(b)));
    _pill.layer.cornerRadius = _expanded ? 38 : size.height / 2;

    CGFloat art = _expanded ? 52 : 23;
    _art.frame = _expanded ? CGRectMake(20, (size.height - art) / 2, art, art) : CGRectMake(10, 12.5, art, art);
    _art.layer.cornerRadius = _expanded ? 11 : 5;

    CGFloat barsRight = size.width - (_expanded ? 22 : 10);
    CGFloat barsMidY = _expanded ? 28 : 24;
    [_bars enumerateObjectsUsingBlock:^(UIView *bar, NSUInteger i, BOOL *stop) {
        bar.bounds = CGRectMake(0, 0, 2.5, 20);
        bar.center = CGPointMake(barsRight - (kNLBars - 1 - i) * 4 - 1.25, barsMidY);
    }];

    CGFloat textX = CGRectGetMaxX(_art.frame) + 14, textW = barsRight - 30 - textX;
    // Bounds and centre here too: these carry a scale while they appear.
    CGFloat lineW = size.width - 22 - textX;
    _titleLabel.bounds = CGRectMake(0, 0, textW, 18);
    _titleLabel.center = CGPointMake(textX + textW / 2, 18 + 9);
    _lineLabel.bounds = CGRectMake(0, 0, lineW, 40);
    _lineLabel.center = CGPointMake(textX + lineW / 2, 36 + 20);

    // The strip as NowLyricsIsland lays it out: the font's exact line height on
    // the bottom edge, centred at the camera's width less a little each side.
    CGFloat h = [UIFont systemFontOfSize:_fontSize weight:UIFontWeightSemibold].lineHeight;
    CGFloat width = kNLSensorWidth - 8;
    CGRect strip = CGRectMake(round((size.width - width) / 2), size.height - h, width, h);
    if (!CGRectEqualToRect(_strip.frame, strip)) _strip.frame = strip;
}

#pragma mark Lifecycle

- (void)didMoveToWindow {
    [super didMoveToWindow];
    _generation++;   // stops the cycle while off screen
    if (!self.window) {
        if (_expanded) {
            _expanded = NO;   // back closed next time, without animating off screen
            _titleLabel.alpha = _lineLabel.alpha = 0;
            _strip.alpha = 1;
            _pill.transform = CGAffineTransformIdentity;
            [self nlLayoutPill];
        }
        return;
    }
    [self nlApplyValues];
    [self nlAnimateBars];
    [self nlNextLine];
}

- (void)nlValuesChanged:(NSNotification *)note {
    [self nlApplyValues];
}

- (void)nlApplyValues {
    NSDictionary *values = nil;
    id target = self.specifier.target;
    if ([target respondsToSelector:@selector(nlIslandPreviewValues)]) values = [target nlIslandPreviewValues];
    _fontSize = [values[@"islandFontSize"] respondsToSelector:@selector(doubleValue)] ? [values[@"islandFontSize"] doubleValue] : 11;
    CGFloat speed = [values[@"islandMarqueeSpeed"] respondsToSelector:@selector(doubleValue)] ? [values[@"islandMarqueeSpeed"] doubleValue] : kNLDefaultSpeed;
    _scrollUp = [values[@"islandTransition"] isEqual:@"up"];
    _textColor = ([values[@"islandColor"] isEqual:@"artwork"] && _albumColor) ? _albumColor : [UIColor colorWithWhite:1 alpha:0.92];
    _lineLabel.textColor = _textColor;
    [self nlLayoutPill];
    [_strip layoutIfNeeded];
    [_strip applyFontSize:_fontSize color:_textColor speed:speed];
}

#pragma mark Lines

// A line that has not come by recently.
- (NSString *)nlPickLine {
    NSArray<NSString *> *pool = NLPreviewLinePool([NSBundle bundleForClass:self.class]);
    NSMutableArray<NSString *> *fresh = [NSMutableArray array];
    for (NSString *line in pool) {
        if (![_recent containsObject:line] && ![line isEqualToString:_line]) [fresh addObject:line];
    }
    NSArray<NSString *> *from = fresh.count ? fresh : pool;
    NSString *line = from[arc4random_uniform((uint32_t)from.count)];
    [_recent addObject:line];
    while (_recent.count > MIN(kNLRecentLines, pool.count / 2)) [_recent removeObjectAtIndex:0];
    return line;
}

// Shows a new line, then waits for it: a short one for a moment, a long one
// until it has scrolled through at the set speed. Held still while expanded.
- (void)nlNextLine {
    NSUInteger generation = ++_generation;
    _line = [self nlPickLine];
    [_strip setText:_line explicit:NO scrollUp:_scrollUp];
    [UIView transitionWithView:_lineLabel duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ self->_lineLabel.text = self->_line; } completion:nil];
    NSTimeInterval dwell = MAX(_strip.marqueeReadDuration, 2.6);
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dwell * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NLIslandPreviewCell *cell = weakSelf;
        if (!cell || cell->_generation != generation || !cell.window) return;
        if (cell->_expanded) { cell->_generation++; return; }   // resumes on collapse
        [cell nlNextLine];
    });
}

#pragma mark Springs

// A spring the way Apple describes theirs: how quickly it settles (response,
// seconds) and how much it overshoots (damping ratio, 1 = none).
static void NLSpring(NSTimeInterval response, CGFloat damping, void (^animations)(void)) {
    UISpringTimingParameters *spring = [[UISpringTimingParameters alloc] initWithDampingRatio:damping
                                                                              initialVelocity:CGVectorMake(0, 0)];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:response timingParameters:spring];
    animator.interruptible = YES;
    [animator addAnimations:animations];
    [animator startAnimation];
}

#pragma mark Touch

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;   // the table still scrolls when the drag starts on the island
}

- (void)nlPressed:(UILongPressGestureRecognizer *)press {
    switch (press.state) {
        case UIGestureRecognizerStateBegan: {
            _pressCancelled = NO;
            _pressStartedOpen = _expanded;
            _pressStart = [press locationInView:self];
            [_lightTap prepare];
            [_firmTap prepare];
            [_lightTap impactOccurred];
            [self nlSetPressed:YES];
            if (_expanded) break;   // open already: this press is a tap to close
            NSUInteger generation = ++_pressGeneration;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNLExpandDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NLIslandPreviewCell *cell = weakSelf;
                if (cell && cell->_pressGeneration == generation && !cell->_pressCancelled) [cell nlSetExpanded:YES];
            });
            break;
        }
        case UIGestureRecognizerStateChanged: {
            // A drag is a scroll, not a press.
            CGPoint p = [press locationInView:self];
            if (!_pressCancelled && hypot(p.x - _pressStart.x, p.y - _pressStart.y) > 12) {
                _pressCancelled = YES;
                _pressGeneration++;
                [self nlSetPressed:NO];
            }
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (_pressCancelled) break;
            _pressGeneration++;
            [self nlSetPressed:NO];
            if (_pressStartedOpen) [self nlSetExpanded:NO];   // a tap on the open island closes it
            else if (_expanded) [self nlCollapseLater];        // just opened by this press: stays open
            else [self nlNextLine];                            // a tap: the next line
            break;
        }
        default:   // cancelled, failed
            _pressCancelled = YES;
            _pressGeneration++;
            [self nlSetPressed:NO];
            break;
    }
}

// Swells under the finger (less when open) and settles back when it lifts.
- (void)nlSetPressed:(BOOL)pressed {
    CGFloat scale = _expanded ? 1.02 : kNLPressScale;
    NLSpring(pressed ? 0.25 : 0.4, pressed ? 0.8 : 0.6, ^{
        self->_pill.transform = pressed ? CGAffineTransformMakeScale(scale, scale) : CGAffineTransformIdentity;
    });
}

// Left open and untouched, it closes by itself, as the real one does when the
// screen is touched elsewhere.
- (void)nlCollapseLater {
    NSUInteger generation = ++_openGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNLAutoCollapse * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NLIslandPreviewCell *cell = weakSelf;
        if (cell && cell->_openGeneration == generation && cell->_expanded) [cell nlSetExpanded:NO];
    });
}

// Opening morphs the island and its artwork in one spring with a little
// overshoot; the compact contents go first and the expanded ones arrive
// growing from 85 %. Closing is the same in reverse, without the overshoot.
- (void)nlSetExpanded:(BOOL)expanded {
    if (_expanded == expanded) return;
    _expanded = expanded;
    _openGeneration++;
    if (expanded) [_firmTap impactOccurred];
    else [_lightTap impactOccurred];
    _lineLabel.text = _line;

    NLSpring(expanded ? 0.5 : 0.42, expanded ? 0.78 : 0.95, ^{
        [self nlLayoutPill];
        self->_pill.transform = CGAffineTransformIdentity;
    });

    CGAffineTransform small = CGAffineTransformMakeScale(0.85, 0.85);
    if (expanded) {
        _titleLabel.transform = small;
        _lineLabel.transform = small;
    }
    [UIView animateWithDuration:expanded ? 0.12 : 0.2 delay:expanded ? 0 : 0.12
                        options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        self->_strip.alpha = expanded ? 0 : 1;
        for (UIView *bar in self->_bars) bar.alpha = expanded ? 0.6 : 1;
    } completion:nil];
    NLSpring(expanded ? 0.45 : 0.25, 1, ^{
        self->_titleLabel.alpha = expanded ? 1 : 0;
        self->_lineLabel.alpha = expanded ? 1 : 0;
        self->_titleLabel.transform = expanded ? CGAffineTransformIdentity : small;
        self->_lineLabel.transform = expanded ? CGAffineTransformIdentity : small;
    });

    if (!expanded) {
        // Pick the cycle up again where it stopped.
        NSUInteger generation = ++_generation;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NLIslandPreviewCell *cell = weakSelf;
            if (cell && cell->_generation == generation && cell.window && !cell->_expanded) [cell nlNextLine];
        });
    }
}

// The waveform: bars bouncing at slightly different rates.
- (void)nlAnimateBars {
    [_bars enumerateObjectsUsingBlock:^(UIView *bar, NSUInteger i, BOOL *stop) {
        if ([bar.layer animationForKey:@"bounce"]) return;
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"transform.scale.y"];
        a.fromValue = @(0.25 + 0.1 * (i % 3));
        a.toValue = @(0.9 - 0.12 * (i % 2));
        a.duration = 0.32 + 0.07 * ((i * 5) % 4);
        a.autoreverses = YES;
        a.repeatCount = HUGE_VALF;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        a.removedOnCompletion = NO;
        [bar.layer addAnimation:a forKey:@"bounce"];
    }];
}

@end
