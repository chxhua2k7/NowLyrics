//
//  NLOffsetCell.m
//  The slider rows: a slider that applies as you drag plus a field the value
//  can be typed into. Used for the lyrics offset and the Dynamic Island sizes;
//  the specifier's min, max, step and unit (plist keys) set the range and how
//  the value reads. Everything else on the page is stock Preferences cells
//  driven by prefs/NowLyrics.plist.
//
//  This bundle is also where AltList gets loaded from. Its framework used to
//  be this bundle's executable (a symlink); now that the bundle has code of its
//  own, it is dlopen'ed here so ATLApplicationListMultiSelectionController
//  resolves when the plist names it.
//

#import <UIKit/UIKit.h>
#import <Preferences/PSControlTableCell.h>
#import <Preferences/PSSpecifier.h>
#import <dlfcn.h>
#import <rootless.h>

__attribute__((constructor))
static void NLLoadAltList(void) {
    dlopen(ROOT_PATH("/Library/Frameworks/AltList.framework/AltList"), RTLD_NOW);
}

// Defaults are the lyrics offset row's: seconds, ±3, tenths.
static const double kNLDefaultLimit = 3.0;
static const double kNLDefaultStep = 0.1;

#pragma mark - Control

// A UIControl so PSControlTableCell can treat it like any other: it fires
// UIControlEventValueChanged whenever the committed value changes, whether
// that came from the slider or from the field.
@interface NLOffsetControl : UIControl <UITextFieldDelegate>
@property (nonatomic, assign) double value;   // for the offset: seconds, positive means lyrics appear earlier
@property (nonatomic, assign) BOOL stacked;   // value pill on the first line, slider full width below
@property (nonatomic, assign) double minimum;
@property (nonatomic, assign) double maximum;
@property (nonatomic, assign) double step;    // dragging snaps to this; typing can be finer
@property (nonatomic, copy) NSString *unit;   // "s" also accepts "300ms" when typing
- (void)setMinimum:(double)minimum maximum:(double)maximum step:(double)step unit:(NSString *)unit;
@end

@implementation NLOffsetControl {
    UISlider *_slider;
    UITextField *_field;
    BOOL _commitPending;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _minimum = -kNLDefaultLimit;
        _maximum = kNLDefaultLimit;
        _step = kNLDefaultStep;
        _unit = @"s";
        _slider = [[UISlider alloc] init];
        _slider.minimumValue = (float)_minimum;
        _slider.maximumValue = (float)_maximum;
        [_slider addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
        [_slider addTarget:self action:@selector(sliderReleased:)
          forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        [self addSubview:_slider];

        _field = [[UITextField alloc] init];
        _field.borderStyle = UITextBorderStyleNone;
        _field.backgroundColor = [UIColor tertiarySystemFillColor];
        _field.layer.cornerRadius = 8;
        _field.layer.cornerCurve = kCACornerCurveContinuous;
        _field.keyboardType = UIKeyboardTypeNumbersAndPunctuation;   // has both "-" and "."
        _field.returnKeyType = UIReturnKeyDone;
        _field.textAlignment = NSTextAlignmentCenter;
        _field.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightRegular];
        _field.autocorrectionType = UITextAutocorrectionTypeNo;
        _field.delegate = self;
        [self addSubview:_field];

        [self showValue];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect b = self.bounds;
    CGFloat fieldWidth = 84, fieldHeight = 30;
    if (_stacked) {
        // First line is the row's own title line (44pt); the slider takes the rest.
        _field.frame = CGRectMake(CGRectGetMaxX(b) - fieldWidth, (44 - fieldHeight) / 2, fieldWidth, fieldHeight);
        _slider.frame = CGRectMake(CGRectGetMinX(b), 44, b.size.width, b.size.height - 44);
    } else {
        _field.frame = CGRectMake(CGRectGetMaxX(b) - fieldWidth, (b.size.height - fieldHeight) / 2, fieldWidth, fieldHeight);
        _slider.frame = CGRectMake(CGRectGetMinX(b), 0, CGRectGetMinX(_field.frame) - 12 - CGRectGetMinX(b), b.size.height);
    }
}

- (void)setMinimum:(double)minimum maximum:(double)maximum step:(double)step unit:(NSString *)unit {
    if (maximum > minimum) { _minimum = minimum; _maximum = maximum; }
    if (step > 0) _step = step;
    if (unit.length) _unit = [unit copy];
    _slider.minimumValue = (float)_minimum;
    _slider.maximumValue = (float)_maximum;
    self.value = _value;
}

- (double)clamp:(double)v {
    if (isnan(v)) return MIN(MAX(0, _minimum), _maximum);
    return MIN(MAX(v, _minimum), _maximum);
}

- (void)setValue:(double)value {
    _value = [self clamp:value];
    _slider.value = (float)_value;
    if (!_field.isEditing) [self showValue];
}

// Seconds keep the sign and two decimals ("+0.25 s"); other units show only the
// decimals the step needs, signed when the range goes below zero ("-1.5 pt").
- (void)showValue {
    if ([_unit isEqualToString:@"s"]) {
        _field.text = _value == 0 ? @"0.00 s" : [NSString stringWithFormat:@"%+.2f s", _value];
        return;
    }
    int decimals = _step >= 1 ? 0 : (_step >= 0.1 ? 1 : 2);
    NSString *format = (_minimum < 0 && _value != 0) ? @"%+.*f %@" : @"%.*f %@";
    _field.text = [NSString stringWithFormat:format, decimals, _value, _unit];
}

// Applies live, so the line on the lock screen can be watched moving while the
// thumb is still held. Every commit is a Darwin notification that makes each
// process with the tweak loaded re-read the file, so while dragging they are
// coalesced to a few per second; letting go commits at once.
- (void)sliderMoved:(UISlider *)slider {
    double snapped = round(slider.value / _step) * _step;
    if (fabs(snapped - _value) < _step / 2) return;
    _value = [self clamp:snapped];
    [self showValue];
    if (_commitPending) return;
    _commitPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_commitPending) [self commit];
    });
}

- (void)sliderReleased:(UISlider *)slider {
    slider.value = (float)_value;   // park the thumb on the step it committed
    [self commit];
}

- (void)commit {
    _commitPending = NO;
    [self sendActionsForControlEvents:UIControlEventValueChanged];
}

#pragma mark Typing

- (void)textFieldDidBeginEditing:(UITextField *)field {
    field.text = [NSString stringWithFormat:@"%g", _value];   // plain number, easier to edit
    [field selectAll:nil];
}

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    [field resignFirstResponder];
    return YES;
}

// Accepts "0.3", "-0.25", "+1", "0,3", and for seconds "300ms". Anything else
// puts the old value back.
- (void)textFieldDidEndEditing:(UITextField *)field {
    NSString *text = [[field.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]]
                      stringByReplacingOccurrencesOfString:@"," withString:@"."];
    NSScanner *scanner = [NSScanner scannerWithString:text];
    double typed = 0;
    if (text.length && [scanner scanDouble:&typed]) {
        NSString *rest = [[text substringFromIndex:scanner.scanLocation] lowercaseString];
        if ([_unit isEqualToString:@"s"] && [rest containsString:@"ms"]) typed /= 1000.0;
        typed = [self clamp:round(typed * 100) / 100];   // hundredths are plenty
        if (typed != _value) {
            _value = typed;
            _slider.value = (float)_value;
            [self commit];
        }
    }
    [self showValue];
}

@end

#pragma mark - Cell

@interface PSControlTableCell (NLPrivate)
- (UIControl *)newControl;
- (id)controlValue;
@end

@interface NLOffsetCell : PSControlTableCell
@end

@implementation NLOffsetCell {
    NSNumber *_lastSent;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier])) {
        // The base class hands controls to the accessory slot, which is far too
        // narrow for a slider; lay it out ourselves instead.
        self.accessoryView = nil;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        if (!self.control) self.control = [self newControl];   // in case the base class did not ask
        if (self.control.superview != self.contentView) [self.contentView addSubview:self.control];
        [self applyRangeFromSpecifier:specifier];
        [self.control addTarget:self action:@selector(controlChanged:) forControlEvents:UIControlEventValueChanged];
    }
    return self;
}

- (UIControl *)newControl {
    return [[NLOffsetControl alloc] initWithFrame:CGRectZero];
}

static double NLProp(PSSpecifier *specifier, NSString *key, double fallback) {
    id v = [specifier propertyForKey:key];
    return [v respondsToSelector:@selector(doubleValue)] ? [v doubleValue] : fallback;
}

- (void)applyRangeFromSpecifier:(PSSpecifier *)specifier {
    NSString *unit = [specifier propertyForKey:@"unit"];
    [(NLOffsetControl *)self.control setMinimum:NLProp(specifier, @"min", -kNLDefaultLimit)
                                        maximum:NLProp(specifier, @"max", kNLDefaultLimit)
                                           step:NLProp(specifier, @"step", kNLDefaultStep)
                                           unit:[unit isKindOfClass:NSString.class] ? unit : @"s"];
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self applyRangeFromSpecifier:specifier];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect content = self.contentView.bounds;
    CGFloat inset = 16;
    NLOffsetControl *control = (NLOffsetControl *)self.control;

    // Tall row: icon, title and the value on a normal-looking first line, the
    // slider across the full width underneath. Short row: everything side by side.
    if (content.size.height >= 64) {
        CGFloat line = 44;
        CGRect icon = self.imageView.frame;
        icon.origin.y = round((line - icon.size.height) / 2);
        self.imageView.frame = icon;

        CGRect title = self.textLabel.frame;
        title.origin.y = round((line - title.size.height) / 2);
        title.size.width = MIN(title.size.width, content.size.width - inset - 84 - 12 - title.origin.x);
        self.textLabel.frame = title;

        control.stacked = YES;
        control.frame = CGRectMake(inset, 0, content.size.width - inset * 2, content.size.height - 6);
    } else {
        control.stacked = NO;
        CGFloat left = MAX(CGRectGetMaxX(self.textLabel.frame) + 12, 96);
        control.frame = CGRectMake(left, 0, content.size.width - left - inset, content.size.height);
    }
}

- (id)controlValue {
    return @(((NLOffsetControl *)self.control).value);
}

- (void)setValue:(id)value {
    [super setValue:value];
    id fallback = [self.specifier propertyForKey:@"default"];
    double v = [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue]
             : ([fallback respondsToSelector:@selector(doubleValue)] ? [fallback doubleValue] : 0);
    ((NLOffsetControl *)self.control).value = v;
    _lastSent = @(((NLOffsetControl *)self.control).value);
}

// Writes the preference and posts the specifier's notification, once per
// distinct value: the base class may have wired this event too.
- (void)controlChanged:(UIControl *)control {
    NSNumber *v = [self controlValue];
    if (_lastSent && [_lastSent isEqualToNumber:v]) return;
    _lastSent = v;
    [self.specifier performSetterWithValue:v];
}

@end
