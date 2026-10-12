//
//  NLHistoryActivity.m
//  Screen Time's charts for the listening history (the first page's This
//  Week card and All Activity share them), by app instead of by category:
//  - NLHistoryApps: the apps told apart, each with its color, the rest as Other Apps
//  - NLActivityPeriod: a week (a bar a day) or a day (a bar an hour), each bar
//    the time listened per app; a play across an edge counts the part inside
//  - NLActivityChartView: stacked bars, the scale on the right, weekdays or
//    hours under them, the week's average dashed; a tap selects a bar, a
//    press shows its day and time in a green callout over the card
//  - NLActivityCardCell, NLUsageCell: the card and Most Played's rows
//  - NLDateBar: the period under the navigation bar, round buttons to the
//    one before and after
//  - NLHistoryActivityController: All Activity. Week | Day on top; the chart
//    pages back to the first week or day with plays; a tapped bar narrows the
//    card and the lists to it; once the chart has scrolled away the date bar
//    steps through them. Most Played (to the song's page) or, with Show
//    Categories, its artists, albums or apps (to theirs,
//    NLHistoryGroupController); what was listened to, and for one day its
//    timeline.
//

#import "NLHistoryPages.h"

#pragma mark - Apps

// Known players keep their own color; others take one of these in turn.
static UIColor *NLKnownAppColor(NSString *bundleID) {
    NSDictionary<NSString *, NSString *> *known = NL_ONCE((@{
        @"com.spotify.client": @"#1ED760",
        @"com.apple.Music": @"#FA2D48",
        @"com.google.ios.youtubemusic": @"#FF3B30",
        @"com.netease.cloudmusic": @"#E33D3D",
        @"com.apple.mobilesafari": @"#0A84FF",
        @"com.apple.podcasts": @"#9B59D0",
        @"com.soundcloud.TouchApp": @"#FF7700",
        @"com.tencent.QQMusic": @"#31C27C",
        @"com.kkbox.kkbox": @"#09CEF6",
    }));
    return NLColorFromHex(known[bundleID]);
}

static const NSUInteger kNLNamedApps = 4;

@implementation NLHistoryApps {
    NSArray<NSString *> *_apps;
    NSArray<UIColor *> *_colors;
}

+ (instancetype)appsForItems:(NSArray<NLHistoryItem *> *)items {
    NSMutableDictionary<NSString *, NSNumber *> *totals = [NSMutableDictionary dictionary];
    for (NLHistoryItem *item in items) {
        if (item.app.length) totals[item.app] = @(totals[item.app].doubleValue + item.listened);
    }
    NSArray<NSString *> *sorted = [totals keysSortedByValueUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) { return [b compare:a]; }];
    NLHistoryApps *apps = [NLHistoryApps new];
    apps->_apps = [sorted subarrayWithRange:NSMakeRange(0, MIN(sorted.count, kNLNamedApps))];
    NSArray<UIColor *> *palette = @[UIColor.systemTealColor, UIColor.systemOrangeColor, UIColor.systemIndigoColor, UIColor.systemPinkColor];
    NSMutableArray<UIColor *> *colors = [NSMutableArray array];
    NSUInteger next = 0;
    for (NSString *app in apps->_apps) [colors addObject:NLKnownAppColor(app) ?: palette[next++ % palette.count]];
    [colors addObject:UIColor.systemGrayColor];
    apps->_colors = colors;
    return apps;
}

- (NSUInteger)count {
    return _apps.count + 1;
}

- (NSUInteger)categoryForApp:(NSString *)bundleID {
    NSUInteger index = bundleID ? [_apps indexOfObject:bundleID] : NSNotFound;
    return index == NSNotFound ? _apps.count : index;
}

- (UIColor *)colorForCategory:(NSUInteger)category {
    return _colors[MIN(category, _colors.count - 1)];
}

- (NSString *)nameForCategory:(NSUInteger)category {
    return category < _apps.count ? (NLAppName(_apps[category]) ?: _apps[category]) : NLL(@"Other Apps");
}

@end

#pragma mark - Periods

static NSTimeInterval NLSum(NSArray<NSNumber *> *values) {
    return [[values valueForKeyPath:@"@sum.self"] doubleValue];
}

// The time per app in [start, end), one value per category.
static NSArray<NSNumber *> *NLAppDurations(NSArray<NLHistoryItem *> *items, NLHistoryApps *apps, NSDate *start, NSDate *end) {
    NSUInteger count = apps.count;
    double sums[count];
    for (NSUInteger c = 0; c < count; c++) sums[c] = 0;
    for (NLHistoryItem *item in items) sums[[apps categoryForApp:item.app]] += [item listenedFrom:start to:end];
    NSMutableArray<NSNumber *> *durations = [NSMutableArray arrayWithCapacity:count];
    for (NSUInteger c = 0; c < count; c++) [durations addObject:@(sums[c])];
    return durations;
}

@interface NLActivityBar ()
@property (nonatomic, readwrite) NSDate *start, *end;
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *durations;
@property (nonatomic, readwrite) NSTimeInterval total;
@end

@implementation NLActivityBar
@end

@interface NLActivityPeriod ()
@property (nonatomic, readwrite) NLActivityScale scale;
@property (nonatomic, readwrite) NSDate *start, *end;
@property (nonatomic, readwrite) NLHistoryApps *apps;
@property (nonatomic, readwrite, copy) NSArray<NLActivityBar *> *bars;
@property (nonatomic, readwrite, copy) NSArray<NLHistoryItem *> *items;
@property (nonatomic, readwrite, copy) NSArray<NSNumber *> *durations;
@property (nonatomic, readwrite) NSTimeInterval total;
@property (nonatomic, strong) NSDate *dataStart;   // the first play's start
@end

// 10:00 – 11:00 AM, as the region writes an hour.
static NSString *NLHourRange(NSDate *start, NSDate *end) {
    NSDateIntervalFormatter *formatter = NLHistoryFormatter(@"hour", ^id {
        NSDateIntervalFormatter *made = [NSDateIntervalFormatter new];
        made.dateStyle = NSDateIntervalFormatterNoStyle;
        made.timeStyle = NSDateIntervalFormatterShortStyle;
        return made;
    });
    return [formatter stringFromDate:start toDate:end];
}

@implementation NLActivityPeriod

+ (NSDate *)startOfPeriodWithScale:(NLActivityScale)scale containingDate:(NSDate *)date {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    if (scale == NLActivityScaleDay) return [calendar startOfDayForDate:date];
    NSDate *start = nil;
    [calendar rangeOfUnit:NSCalendarUnitWeekOfYear startDate:&start interval:NULL forDate:date];
    return start;
}

+ (instancetype)periodWithScale:(NLActivityScale)scale containingDate:(NSDate *)date
                          items:(NSArray<NLHistoryItem *> *)items apps:(NLHistoryApps *)apps {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NLActivityPeriod *period = [NLActivityPeriod new];
    period.scale = scale;
    period.apps = apps;
    period.start = [self startOfPeriodWithScale:scale containingDate:date];

    // The bars' edges: days (the week starts where the region says), or hours.
    NSMutableArray<NSDate *> *edges = [NSMutableArray array];
    if (scale == NLActivityScaleWeek) {
        for (NSInteger day = 0; day <= 7; day++) [edges addObject:[calendar dateByAddingUnit:NSCalendarUnitDay value:day toDate:period.start options:0]];
    } else {
        NSDate *end = [calendar dateByAddingUnit:NSCalendarUnitDay value:1 toDate:period.start options:0];
        for (NSInteger hour = 0; hour <= 24; hour++) [edges addObject:[[period.start dateByAddingTimeInterval:hour * 3600] earlierDate:end]];
    }
    period.end = edges.lastObject;
    period.dataStart = items.lastObject.start;   // newest first

    NSMutableArray<NLHistoryItem *> *inside = [NSMutableArray array];
    for (NLHistoryItem *item in items) {
        if ([item.start compare:period.end] != NSOrderedAscending) continue;
        if ([item.end compare:period.start] == NSOrderedAscending) continue;
        [inside addObject:item];
    }
    period.items = inside;

    NSMutableArray<NLActivityBar *> *bars = [NSMutableArray arrayWithCapacity:edges.count - 1];
    for (NSUInteger i = 0; i + 1 < edges.count; i++) {
        NLActivityBar *bar = [NLActivityBar new];
        bar.start = edges[i];
        bar.end = edges[i + 1];
        bar.durations = NLAppDurations(inside, apps, bar.start, bar.end);
        bar.total = NLSum(bar.durations);
        [bars addObject:bar];
    }
    period.bars = bars;
    period.durations = NLAppDurations(inside, apps, period.start, period.end);
    period.total = NLSum(period.durations);
    return period;
}

// Over the days that are over and come after the first play; today until a
// day is over.
- (NSTimeInterval)dailyAverage {
    NSDate *now = [NSDate date];
    NSTimeInterval sum = 0;
    NSUInteger days = 0;
    for (NLActivityBar *bar in self.bars) {
        if ([bar.end compare:now] == NSOrderedDescending) continue;
        if (self.dataStart && [bar.end compare:self.dataStart] != NSOrderedDescending) continue;
        sum += bar.total;
        days++;
    }
    return days ? sum / days : self.total;
}

- (NSString *)title {
    if (self.scale == NLActivityScaleDay) return NLHistoryDayTitle(self.start);
    NSDate *thisWeek = [NLActivityPeriod startOfPeriodWithScale:NLActivityScaleWeek containingDate:[NSDate date]];
    if ([self.start isEqualToDate:thisWeek]) return NLL(@"This Week");
    NSDate *lastWeek = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitWeekOfYear value:-1 toDate:thisWeek options:0];
    if ([self.start isEqualToDate:lastWeek]) return NLL(@"Last Week");
    NSDateIntervalFormatter *formatter = NLHistoryFormatter(@"week", ^id {
        NSDateIntervalFormatter *made = [NSDateIntervalFormatter new];
        made.dateStyle = NSDateIntervalFormatterMediumStyle;
        made.timeStyle = NSDateIntervalFormatterNoStyle;
        return made;
    });
    return [formatter stringFromDate:self.start toDate:[self.end dateByAddingTimeInterval:-1]];
}

- (NSString *)titleForBarAtIndex:(NSUInteger)index {
    NLActivityBar *bar = self.bars[index];
    if (self.scale == NLActivityScaleWeek) return NLHistoryDayTitle(bar.start);
    return [NSString stringWithFormat:@"%@ %@", NLHistoryDayTitle(bar.start), NLHourRange(bar.start, bar.end)];
}

@end

#pragma mark - Chart

static const CGFloat kNLChartAxisWidth = 44;
static const CGFloat kNLChartLabelHeight = 20;
static const CGFloat kNLChartTopInset = 8;

// The scale: hours on a week (12h), minutes on a day (30m).
static NSString *NLAxisString(NSTimeInterval seconds, BOOL hours) {
    NSDateComponentsFormatter *formatter = NLHistoryFormatter(hours ? @"axis hours" : @"axis minutes", ^id {
        NSDateComponentsFormatter *made = [NSDateComponentsFormatter new];
        made.unitsStyle = NSDateComponentsFormatterUnitsStyleAbbreviated;
        made.allowedUnits = hours ? NSCalendarUnitHour : NSCalendarUnitMinute;
        return made;
    });
    return [formatter stringFromTimeInterval:seconds] ?: @"";
}

// 0時, 6 AM, as the user's 12/24-hour setting has it.
static NSString *NLHourString(NSDate *date) {
    NSDateFormatter *formatter = NLHistoryFormatter(@"axis hour", ^id {
        NSDateFormatter *made = [NSDateFormatter new];
        [made setLocalizedDateFormatFromTemplate:@"j"];
        return made;
    });
    return [formatter stringFromDate:date];
}

static UILabel *NLCardLabel(UIFontTextStyle style, BOOL bold, UIColor *color) {
    UILabel *label = [UILabel new];
    UIFontDescriptor *descriptor = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    if (bold) descriptor = [descriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    label.font = [UIFont fontWithDescriptor:descriptor size:0];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = color;
    return label;
}

// A date by a template (EEEE, MMMd), as the region orders it.
static NSString *NLTemplateDate(NSString *template, NSDate *date) {
    NSDateFormatter *formatter = NLHistoryFormatter(template, ^id {
        NSDateFormatter *made = [NSDateFormatter new];
        [made setLocalizedDateFormatFromTemplate:template];
        return made;
    });
    return [formatter stringFromDate:date];
}

// A pressed bar's day and time, green as Screen Time's, over the card the
// chart is on, with a line down to the bar.
@interface NLChartCallout : UIView
// In its superview's space: `barTop` where the line ends, `bottom` the
// callout's bottom (the chart's top), kept between `minX` and `maxX`.
- (void)showTitle:(NSString *)title detail:(NSString *)detail value:(NSString *)value
       pointingAt:(CGPoint)barTop bottom:(CGFloat)bottom minX:(CGFloat)minX maxX:(CGFloat)maxX;
@end

@implementation NLChartCallout {
    UIView *_bubble, *_line;
    UILabel *_titleLabel, *_detailLabel, *_valueLabel;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _line = [UIView new];
    _bubble = [UIView new];
    _line.backgroundColor = UIColor.systemGreenColor;
    _bubble.backgroundColor = UIColor.systemGreenColor;
    _bubble.layer.cornerRadius = 8;
    _bubble.layer.cornerCurve = kCACornerCurveContinuous;
    _titleLabel = NLCardLabel(UIFontTextStyleCaption1, NO, UIColor.whiteColor);
    _detailLabel = NLCardLabel(UIFontTextStyleCaption1, NO, UIColor.whiteColor);
    _valueLabel = NLCardLabel(UIFontTextStyleTitle3, YES, UIColor.whiteColor);
    [self addSubview:_line];
    [self addSubview:_bubble];
    for (UILabel *label in @[_titleLabel, _detailLabel, _valueLabel]) [_bubble addSubview:label];
    return self;
}

// The weekday on top; the date and the time under it, on one baseline.
- (void)showTitle:(NSString *)title detail:(NSString *)detail value:(NSString *)value
       pointingAt:(CGPoint)barTop bottom:(CGFloat)bottom minX:(CGFloat)minX maxX:(CGFloat)maxX {
    _titleLabel.text = title;
    _detailLabel.text = detail;
    _valueLabel.text = value;
    for (UILabel *label in @[_titleLabel, _detailLabel, _valueLabel]) [label sizeToFit];
    const CGFloat padding = 10, verticalPadding = 6, gap = 6;
    CGSize titleSize = _titleLabel.bounds.size, detailSize = _detailLabel.bounds.size, valueSize = _valueLabel.bounds.size;
    CGFloat width = MIN(MAX(titleSize.width, detailSize.width + gap + valueSize.width) + 2 * padding, MAX(maxX - minX, 0));
    UIFont *detailFont = _detailLabel.font, *valueFont = _valueLabel.font;
    CGFloat ascent = MAX(detailFont.ascender, valueFont.ascender);
    CGFloat height = verticalPadding + titleSize.height + ascent + MAX(-detailFont.descender, -valueFont.descender) + verticalPadding;
    CGFloat x = MAX(MIN(barTop.x - width / 2, maxX - width), minX);
    _bubble.frame = CGRectMake(x, bottom - height, width, height);
    CGFloat inner = width - 2 * padding;
    _titleLabel.frame = CGRectMake(padding, verticalPadding, MIN(titleSize.width, inner), titleSize.height);
    CGFloat baseline = verticalPadding + titleSize.height + ascent;
    _detailLabel.frame = CGRectMake(padding, baseline - detailFont.ascender, MIN(detailSize.width, inner), detailSize.height);
    CGFloat valueX = padding + detailSize.width + gap;
    _valueLabel.frame = CGRectMake(valueX, baseline - valueFont.ascender, MAX(MIN(valueSize.width, width - padding - valueX), 0), valueSize.height);
    const CGFloat lineWidth = 1.5;
    _line.frame = CGRectMake(barTop.x - lineWidth / 2, bottom - 1, lineWidth, MAX(barTop.y - bottom + 1, 0));
}

@end

@implementation NLActivityChartView {
    UITapGestureRecognizer *_tap;
    UILongPressGestureRecognizer *_press;
    UISelectionFeedbackGenerator *_feedback;
    NLChartCallout *_callout;
    NSInteger _pressedIndex;   // the bar under a press, else NSNotFound
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    _selectedIndex = NSNotFound;
    _pressedIndex = NSNotFound;
    _press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(nlPressed:)];
    _press.minimumPressDuration = 0.3;
    [self addGestureRecognizer:_press];
    _tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(nlTapped:)];
    _tap.enabled = NO;   // the first page's card opens All Activity instead
    [_tap requireGestureRecognizerToFail:_press];
    [self addGestureRecognizer:_tap];
    return self;
}

- (void)setPeriod:(NLActivityPeriod *)period {
    _period = period;
    [self setNeedsDisplay];
    // Loaded again under a press: the same bar's new time, or the press ends.
    if (_pressedIndex == NSNotFound) return;
    if (_pressedIndex < (NSInteger)period.bars.count) [self nlShowCallout];
    else [self nlCancelPress];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = selectedIndex;
    [self setNeedsDisplay];
}

- (void)setDidSelectBar:(void (^)(NSInteger))didSelectBar {
    _didSelectBar = [didSelectBar copy];
    _tap.enabled = didSelectBar != nil;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self nlCancelPress];
}

- (CGRect)nlChartRect {
    CGRect bounds = self.bounds;
    return CGRectMake(CGRectGetMinX(bounds), CGRectGetMinY(bounds) + kNLChartTopInset,
                      MAX(0, bounds.size.width - kNLChartAxisWidth), MAX(0, bounds.size.height - kNLChartTopInset - kNLChartLabelHeight));
}

// The scale's top: a week rounds up to 1, 2, 4, 8, 12, 16, 20 or 24 hours (listening is
// shorter than a day spent somewhere); a day's hour is always 60 minutes.
- (NSTimeInterval)nlMaximum {
    if (self.period.scale == NLActivityScaleDay) return 3600;
    double hours = [[self.period.bars valueForKeyPath:@"@max.total"] doubleValue] / 3600;
    for (NSNumber *step in @[@1, @2, @4, @8, @12, @16, @20]) {
        if (hours <= step.doubleValue) return step.doubleValue * 3600;
    }
    return 24 * 3600;
}

- (void)drawRect:(CGRect)rect {
    NSArray<NLActivityBar *> *bars = self.period.bars;
    CGRect chart = [self nlChartRect];
    if (!bars.count || chart.size.width <= 0 || chart.size.height <= 0) return;
    CGContextRef context = UIGraphicsGetCurrentContext();
    BOOL week = self.period.scale == NLActivityScaleWeek;
    NSTimeInterval maximum = [self nlMaximum];
    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    NSDictionary *axis = @{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.secondaryLabelColor};
    NSDictionary *selectedAxis = @{NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold],
                                   NSForegroundColorAttributeName: UIColor.labelColor};
    CGFloat hairline = 1 / MAX(self.traitCollection.displayScale, 1);
    // The bar pressed, else the one picked, stands out; the others fade.
    NSInteger highlighted = _pressedIndex != NSNotFound ? _pressedIndex : self.selectedIndex;

    // The week's average (dashed green, as Screen Time); a scale label too close gives way to it.
    NSTimeInterval average = week ? self.period.dailyAverage : 0;
    CGFloat averageY = CGRectGetMaxY(chart) - MIN(average / maximum, 1) * chart.size.height;

    for (NSInteger i = 0; i <= 2; i++) {
        CGFloat y = CGRectGetMaxY(chart) - chart.size.height * i / 2;
        UIBezierPath *line = [UIBezierPath bezierPath];
        [line moveToPoint:CGPointMake(CGRectGetMinX(chart), y)];
        [line addLineToPoint:CGPointMake(CGRectGetMaxX(chart), y)];
        line.lineWidth = hairline;
        if (i > 0) {
            const CGFloat dashes[] = {2, 3};
            [line setLineDash:dashes count:2 phase:0];
        }
        [UIColor.separatorColor setStroke];
        [line stroke];
        if (i == 0 || (average > 0 && fabs(y - averageY) < font.lineHeight)) continue;
        // Half of an hour is 30 minutes, which the hour formatter cannot say.
        BOOL inHours = week && fmod(maximum * i / 2, 3600) == 0;
        [NLAxisString(maximum * i / 2, inHours) drawAtPoint:CGPointMake(CGRectGetMaxX(chart) + 6, y - font.lineHeight / 2) withAttributes:axis];
    }

    NLHistoryApps *apps = self.period.apps;
    NSCalendar *calendar = NSCalendar.currentCalendar;
    CGFloat column = chart.size.width / bars.count;
    CGFloat barWidth = week ? MIN(column * 0.55, 32) : MAX(column * 0.6, 2);
    CGFloat radius = week ? 4 : 2;
    for (NSUInteger i = 0; i < bars.count; i++) {
        NLActivityBar *bar = bars[i];
        BOOL selected = (NSInteger)i == highlighted;
        CGFloat x = CGRectGetMinX(chart) + column * i + (column - barWidth) / 2;
        CGFloat height = MIN(bar.total / maximum, 1) * chart.size.height;
        if (height >= 0.5) {
            CGContextSaveGState(context);
            if (highlighted != NSNotFound && !selected) CGContextSetAlpha(context, 0.3);
            CGRect frame = CGRectMake(x, CGRectGetMaxY(chart) - height, barWidth, height);
            [[UIBezierPath bezierPathWithRoundedRect:frame byRoundingCorners:UIRectCornerTopLeft | UIRectCornerTopRight
                                         cornerRadii:CGSizeMake(radius, radius)] addClip];
            CGFloat y = CGRectGetMaxY(chart);
            for (NSUInteger c = 0; c < bar.durations.count; c++) {
                CGFloat segment = bar.durations[c].doubleValue / bar.total * height;
                if (segment <= 0) continue;
                [[apps colorForCategory:c] setFill];
                UIRectFillUsingBlendMode(CGRectMake(x, y - segment, barWidth, segment), kCGBlendModeNormal);
                y -= segment;
            }
            CGContextRestoreGState(context);
        }
        NSDictionary *attributes = selected ? selectedAxis : axis;
        if (week) {
            NSString *label = calendar.veryShortStandaloneWeekdaySymbols[[calendar component:NSCalendarUnitWeekday fromDate:bar.start] - 1];
            CGSize size = [label sizeWithAttributes:attributes];
            [label drawAtPoint:CGPointMake(CGRectGetMinX(chart) + column * i + (column - size.width) / 2, CGRectGetMaxY(chart) + 4) withAttributes:attributes];
        } else if (i % 6 == 0) {
            [NLHourString(bar.start) drawAtPoint:CGPointMake(x, CGRectGetMaxY(chart) + 4) withAttributes:axis];
        }
    }

    if (average > 0) {
        UIBezierPath *line = [UIBezierPath bezierPath];
        [line moveToPoint:CGPointMake(CGRectGetMinX(chart), averageY)];
        [line addLineToPoint:CGPointMake(CGRectGetMaxX(chart), averageY)];
        line.lineWidth = 1;
        const CGFloat dashes[] = {3, 3};
        [line setLineDash:dashes count:2 phase:0];
        [UIColor.systemGreenColor setStroke];
        [line stroke];
        NSDictionary *label = @{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.systemGreenColor};
        [NLL(@"avg") drawAtPoint:CGPointMake(CGRectGetMaxX(chart) + 6, averageY - font.lineHeight / 2) withAttributes:label];
    }
}

// A tap selects a bar, again (or outside) deselects; days and hours still to come can't be.
- (void)nlTapped:(UITapGestureRecognizer *)tap {
    NSArray<NLActivityBar *> *bars = self.period.bars;
    if (!self.didSelectBar || !bars.count) return;
    CGRect chart = [self nlChartRect];
    CGPoint point = [tap locationInView:self];
    NSInteger index = NSNotFound;
    if (point.x >= CGRectGetMinX(chart) && point.x < CGRectGetMaxX(chart)) {
        index = MIN(MAX((NSInteger)floor((point.x - CGRectGetMinX(chart)) / (chart.size.width / bars.count)), 0), (NSInteger)bars.count - 1);
        if ([bars[index].start compare:[NSDate date]] == NSOrderedDescending || index == self.selectedIndex) index = NSNotFound;
    }
    if (index == self.selectedIndex) return;
    self.selectedIndex = index;
    self.didSelectBar(index);
}

#pragma mark Press

// A press shows the bar under the finger, sliding goes along the bars, each
// with a tick; letting go hides it.
- (void)nlPressed:(UILongPressGestureRecognizer *)press {
    if (press.state != UIGestureRecognizerStateBegan && press.state != UIGestureRecognizerStateChanged) {
        [self nlEndPress];
        return;
    }
    NSInteger index = [self nlBarAtX:[press locationInView:self].x];
    if (index == NSNotFound || index == _pressedIndex) return;
    _pressedIndex = index;
    if (!_feedback) _feedback = [UISelectionFeedbackGenerator new];
    [_feedback selectionChanged];
    [self setNeedsDisplay];
    [self nlShowCallout];
}

// The bar at `x`, the nearest for a point beside them; the latest that has
// begun for one still to come.
- (NSInteger)nlBarAtX:(CGFloat)x {
    NSArray<NLActivityBar *> *bars = self.period.bars;
    CGRect chart = [self nlChartRect];
    if (!bars.count || chart.size.width <= 0) return NSNotFound;
    NSInteger index = MIN(MAX((NSInteger)floor((x - CGRectGetMinX(chart)) / (chart.size.width / bars.count)), 0), (NSInteger)bars.count - 1);
    NSDate *now = [NSDate date];
    while (index > 0 && [bars[index].start compare:now] == NSOrderedDescending) index--;
    return [bars[index].start compare:now] == NSOrderedDescending ? NSNotFound : index;
}

// Over the card the chart is on (its cell's content), the card's title and
// time under it, as Screen Time's; else over the chart's superview.
- (void)nlShowCallout {
    NSArray<NLActivityBar *> *bars = self.period.bars;
    if (_pressedIndex == NSNotFound || _pressedIndex >= (NSInteger)bars.count) return;
    UIView *host = nil;
    for (UIView *view = self.superview; view && !host; view = view.superview) {
        if ([view isKindOfClass:UITableViewCell.class]) host = ((UITableViewCell *)view).contentView;
    }
    host = host ?: self.superview;
    if (!host) return;
    if (_callout.superview != host) {
        [_callout removeFromSuperview];
        _callout = [[NLChartCallout alloc] initWithFrame:host.bounds];
        _callout.alpha = 0;
        [host addSubview:_callout];
        NLChartCallout *callout = _callout;
        [UIView animateWithDuration:0.15 animations:^{ callout.alpha = 1; }];
    }
    NLActivityBar *bar = bars[_pressedIndex];
    CGRect chart = [self nlChartRect];
    CGFloat height = MIN(bar.total / [self nlMaximum], 1) * chart.size.height;
    CGPoint barTop = CGPointMake(CGRectGetMinX(chart) + chart.size.width / bars.count * (_pressedIndex + 0.5), CGRectGetMaxY(chart) - height);
    NSString *title, *detail;
    if (self.period.scale == NLActivityScaleWeek) {
        title = NLTemplateDate(@"EEEE", bar.start);
        detail = NLTemplateDate(@"MMMd", bar.start);
    } else {
        title = NLTemplateDate(@"MMMdEEEE", bar.start);
        detail = NLHourRange(bar.start, bar.end);
    }
    [_callout showTitle:title detail:detail value:NLHistoryDuration(bar.total)
             pointingAt:[self convertPoint:barTop toView:host] bottom:[self convertPoint:CGPointZero toView:host].y
                   minX:host.layoutMargins.left maxX:host.bounds.size.width - host.layoutMargins.right];
}

// Off screen or loaded again without the bar: the press is over.
- (void)nlCancelPress {
    if (_press.state == UIGestureRecognizerStateBegan || _press.state == UIGestureRecognizerStateChanged) {
        _press.enabled = NO;
        _press.enabled = YES;
    }
    [self nlEndPress];
}

- (void)nlEndPress {
    if (_pressedIndex != NSNotFound) {
        _pressedIndex = NSNotFound;
        [self setNeedsDisplay];
    }
    NLChartCallout *callout = _callout;
    _callout = nil;
    if (!callout) return;
    [UIView animateWithDuration:0.15 animations:^{ callout.alpha = 0; } completion:^(BOOL finished) { [callout removeFromSuperview]; }];
}

@end

#pragma mark - Card

@implementation NLActivityCardCell {
    UILabel *_titleLabel, *_captionLabel, *_valueLabel;
    UIView *_chartHost;
    UIStackView *_legend;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) return nil;
    _titleLabel = NLCardLabel(UIFontTextStyleSubheadline, YES, UIColor.secondaryLabelColor);
    _captionLabel = NLCardLabel(UIFontTextStyleFootnote, NO, UIColor.secondaryLabelColor);
    _valueLabel = NLCardLabel(UIFontTextStyleTitle1, YES, UIColor.labelColor);
    _valueLabel.adjustsFontSizeToFitWidth = YES;
    _valueLabel.minimumScaleFactor = 0.6;
    _chartHost = [UIView new];
    [_chartHost.heightAnchor constraintEqualToConstant:190].active = YES;
    _legend = [UIStackView new];
    _legend.axis = UILayoutConstraintAxisHorizontal;
    _legend.alignment = UIStackViewAlignmentTop;
    _legend.spacing = 16;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _captionLabel, _valueLabel, _chartHost, _legend]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 2;
    [stack setCustomSpacing:12 afterView:_valueLabel];
    [stack setCustomSpacing:10 afterView:_chartHost];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:margins.topAnchor constant:4],
        [stack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor constant:-4],
        [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
    ]];
    return self;
}

- (void)setChartView:(UIView *)chartView {
    [_chartView removeFromSuperview];
    _chartView = chartView;
    if (!chartView) return;
    chartView.translatesAutoresizingMaskIntoConstraints = NO;
    [_chartHost addSubview:chartView];
    [NSLayoutConstraint activateConstraints:@[
        [chartView.topAnchor constraintEqualToAnchor:_chartHost.topAnchor],
        [chartView.bottomAnchor constraintEqualToAnchor:_chartHost.bottomAnchor],
        [chartView.leadingAnchor constraintEqualToAnchor:_chartHost.leadingAnchor],
        [chartView.trailingAnchor constraintEqualToAnchor:_chartHost.trailingAnchor],
    ]];
}

// The legend: the apps with time, longest first, each named in its color with its time under it.
- (void)showTitle:(NSString *)title caption:(NSString *)caption value:(NSString *)value
        durations:(NSArray<NSNumber *> *)durations apps:(NLHistoryApps *)apps {
    _titleLabel.text = title;
    _titleLabel.hidden = !title.length;
    _captionLabel.text = caption;
    _captionLabel.hidden = !caption.length;
    _valueLabel.text = value;
    for (UIView *view in _legend.arrangedSubviews) {
        [_legend removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    for (NSUInteger c = 0; c < durations.count; c++) if (durations[c].doubleValue >= 60) [order addObject:@(c)];
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [durations[b.unsignedIntegerValue] compare:durations[a.unsignedIntegerValue]];
    }];
    for (NSNumber *category in order) {
        UILabel *name = NLCardLabel(UIFontTextStyleFootnote, YES, [apps colorForCategory:category.unsignedIntegerValue]);
        name.text = [apps nameForCategory:category.unsignedIntegerValue];
        UILabel *time = NLCardLabel(UIFontTextStyleFootnote, NO, UIColor.secondaryLabelColor);
        time.text = NLHistoryDuration(durations[category.unsignedIntegerValue].doubleValue);
        for (UILabel *label in @[name, time]) {
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.7;
        }
        UIStackView *item = [[UIStackView alloc] initWithArrangedSubviews:@[name, time]];
        item.axis = UILayoutConstraintAxisVertical;
        item.spacing = 1;
        [_legend addArrangedSubview:item];
    }
    UIView *spacer = [UIView new];
    [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal];
    [spacer setContentCompressionResistancePriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal];
    [_legend addArrangedSubview:spacer];
    _legend.hidden = order.count == 0;
}

@end

#pragma mark - Most Played

@implementation NLUsage
@end

NSString *NLUsageKey(NLHistoryItem *item, NLUsageKind kind) {
    NSString *key = nil;
    switch (kind) {
        case NLUsageKindSongs: return item.key.length ? item.key : [NSString stringWithFormat:@"%@|%@", item.title, item.artist ?: @""];
        case NLUsageKindArtists: key = item.artist; break;
        case NLUsageKindAlbums: key = item.album; break;
        case NLUsageKindApps: key = item.app; break;
    }
    return key.length ? key : nil;
}

static NSString *NLUsageName(NLUsage *usage) {
    switch (usage.kind) {
        case NLUsageKindSongs: return usage.item.title;
        case NLUsageKindApps: return NLAppName(usage.key);
        default: return usage.key;   // the artist or the album
    }
}

NSArray<NLUsage *> *NLUsages(NSArray<NLHistoryItem *> *items, NSDate *start, NSDate *end, NLUsageKind kind) {
    NSMutableArray<NLUsage *> *usages = [NSMutableArray array];
    NSMutableDictionary<NSString *, NLUsage *> *byKey = [NSMutableDictionary dictionary];
    for (NLHistoryItem *item in items) {   // newest first: each keeps its latest play
        NSString *key = NLUsageKey(item, kind);
        NSTimeInterval duration = key ? [item listenedFrom:start to:end] : 0;
        if (duration <= 0) continue;
        NLUsage *usage = byKey[key];
        if (!usage) {
            usage = [NLUsage new];
            usage.kind = kind;
            usage.key = key;
            usage.item = item;
            byKey[key] = usage;
            [usages addObject:usage];
        }
        usage.duration += duration;
        usage.plays++;
    }
    for (NLUsage *usage in usages) usage.name = NLUsageName(usage);
    [usages sortUsingComparator:^NSComparisonResult(NLUsage *a, NLUsage *b) {
        if (a.duration != b.duration) return a.duration > b.duration ? NSOrderedAscending : NSOrderedDescending;
        return [a.name localizedStandardCompare:b.name];
    }];
    return usages;
}

@interface NLUsageBar : UIView
@property (nonatomic) CGFloat fraction;
@property (nonatomic, strong) UIColor *color;
@end

@implementation NLUsageBar

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.opaque = NO;
        self.backgroundColor = UIColor.clearColor;
        self.contentMode = UIViewContentModeRedraw;
    }
    return self;
}

- (void)setFraction:(CGFloat)fraction { _fraction = fraction; [self setNeedsDisplay]; }
- (void)setColor:(UIColor *)color { _color = color; [self setNeedsDisplay]; }

- (void)drawRect:(CGRect)rect {
    CGRect bounds = self.bounds;
    CGFloat width = MAX(bounds.size.height, bounds.size.width * MIN(MAX(self.fraction, 0), 1));
    [self.color ?: UIColor.systemGrayColor setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, width, bounds.size.height) cornerRadius:bounds.size.height / 2] fill];
}

@end

@implementation NLUsageCell {
    UIImageView *_coverView;
    UILabel *_nameLabel, *_timeLabel;
    NLUsageBar *_bar;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) return nil;
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    _coverView = [UIImageView new];
    _nameLabel = NLCardLabel(UIFontTextStyleBody, NO, UIColor.labelColor);
    _timeLabel = NLCardLabel(UIFontTextStyleSubheadline, NO, UIColor.secondaryLabelColor);
    [_timeLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_timeLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    _bar = [NLUsageBar new];
    for (UIView *view in @[_coverView, _nameLabel, _timeLabel, _bar]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:view];
    }
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_coverView.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [_coverView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_coverView.widthAnchor constraintEqualToConstant:34],
        [_coverView.heightAnchor constraintEqualToConstant:34],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:_coverView.trailingAnchor constant:12],
        [_nameLabel.topAnchor constraintEqualToAnchor:margins.topAnchor constant:2],
        [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_timeLabel.leadingAnchor constant:-12],
        [_bar.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_bar.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:6],
        [_bar.trailingAnchor constraintEqualToAnchor:_timeLabel.leadingAnchor constant:-12],
        [_bar.heightAnchor constraintEqualToConstant:6],
        [_bar.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor constant:-2],
        [_timeLabel.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [_timeLabel.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
    ]];
    return self;
}

- (void)showUsage:(NLUsage *)usage fraction:(CGFloat)fraction color:(UIColor *)color {
    _coverView.image = usage.kind == NLUsageKindApps ? NLHistoryAppIcon(usage.key, 34) : NLHistoryCover(usage.item.art, 34);
    _nameLabel.text = usage.name;
    _timeLabel.text = NLHistoryDuration(usage.duration);
    _bar.color = color;
    _bar.fraction = fraction;
}

@end

#pragma mark - Pager

@interface NLActivityPageCell : UICollectionViewCell
@property (nonatomic, readonly) NLActivityChartView *chartView;
@end

@implementation NLActivityPageCell

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    _chartView = [[NLActivityChartView alloc] initWithFrame:self.contentView.bounds];
    _chartView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.contentView addSubview:_chartView];
    return self;
}

@end

// The chart, a page per week or day, a page the full width; it stays on its page when resized.
@interface NLPagerView : UICollectionView
@property (nonatomic) NSInteger page;
- (void)scrollToPage:(NSInteger)page;
@end

@implementation NLPagerView {
    CGSize _laidOutSize;
}

- (void)layoutSubviews {
    CGSize size = self.bounds.size;
    BOOL resized = size.width > 0 && size.height > 0 && !CGSizeEqualToSize(size, _laidOutSize);
    if (resized) {
        _laidOutSize = size;
        ((UICollectionViewFlowLayout *)self.collectionViewLayout).itemSize = size;
        [self.collectionViewLayout invalidateLayout];
    }
    [super layoutSubviews];
    if (resized) self.contentOffset = CGPointMake(self.page * size.width, 0);
}

- (void)scrollToPage:(NSInteger)page {
    self.page = page;
    CGFloat width = self.bounds.size.width;
    if (width <= 0) return;   // laid out later, onto this page
    [self layoutIfNeeded];
    self.contentOffset = CGPointMake(page * width, 0);
}

@end

#pragma mark - Date bar

static const CGFloat kNLDateBarHeight = 52;

// The circle is small; a finger gets room around it.
@interface NLDateBarButton : UIButton
@end

@implementation NLDateBarButton

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds, -10, -10), point);
}

@end

static UIButton *NLDateBarArrow(NSString *symbol) {
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
    configuration.image = [UIImage systemImageNamed:symbol];
    configuration.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightBold];
    configuration.contentInsets = NSDirectionalEdgeInsetsZero;
    UIButton *button = [NLDateBarButton buttonWithType:UIButtonTypeSystem];
    button.configuration = configuration;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [button.widthAnchor constraintEqualToConstant:28],
        [button.heightAnchor constraintEqualToConstant:28],
    ]];
    return button;
}

@implementation NLDateBar {
    __weak UIViewController *_page;
}

+ (CGFloat)height {
    return kNLDateBarHeight;
}

+ (instancetype)barOnPage:(UIViewController *)page {
    NLDateBar *bar = [[self alloc] initWithFrame:CGRectZero];
    bar->_page = page;
    bar.translatesAutoresizingMaskIntoConstraints = NO;
    [page.view addSubview:bar];
    [NSLayoutConstraint activateConstraints:@[
        [bar.topAnchor constraintEqualToAnchor:page.view.safeAreaLayoutGuide.topAnchor],
        [bar.leadingAnchor constraintEqualToAnchor:page.view.leadingAnchor],
        [bar.trailingAnchor constraintEqualToAnchor:page.view.trailingAnchor],
        [bar.heightAnchor constraintEqualToConstant:kNLDateBarHeight],
    ]];
    return bar;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hidden = YES;
    self.alpha = 0;
    // The navigation bar's material, and the line it has under it.
    UINavigationBarAppearance *standard = [UINavigationBarAppearance new];
    [standard configureWithDefaultBackground];
    UIVisualEffectView *material = [[UIVisualEffectView alloc] initWithEffect:standard.backgroundEffect];
    material.frame = self.bounds;
    material.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    material.contentView.backgroundColor = standard.backgroundColor;
    [self addSubview:material];
    UIView *line = [UIView new];
    line.backgroundColor = standard.shadowColor ?: UIColor.separatorColor;
    line.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:line];

    _previousButton = NLDateBarArrow(@"chevron.backward");
    _nextButton = NLDateBarArrow(@"chevron.forward");
    _titleLabel = [UILabel new];
    _titleLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleHeadline];
    _titleLabel.adjustsFontForContentSizeCategory = YES;
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.7;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    for (UIView *view in @[_previousButton, _nextButton, _titleLabel]) [self addSubview:view];
    UILayoutGuide *safe = self.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [line.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [line.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [line.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [line.heightAnchor constraintEqualToConstant:1 / UIScreen.mainScreen.scale],
        [_previousButton.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:28],
        [_previousButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_nextButton.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-28],
        [_nextButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_titleLabel.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [_titleLabel.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [_titleLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_previousButton.trailingAnchor constant:8],
        [_titleLabel.trailingAnchor constraintLessThanOrEqualToAnchor:_nextButton.leadingAnchor constant:-8],
    ]];
    return self;
}

- (void)setShown:(BOOL)shown animated:(BOOL)animated {
    if (shown == _shown) return;
    _shown = shown;
    // The page's navigation bar keeps its material even at the top and drops
    // its line: one bar with this one.
    UINavigationBarAppearance *appearance = nil;
    if (shown) {
        appearance = [UINavigationBarAppearance new];
        [appearance configureWithDefaultBackground];
        appearance.shadowColor = nil;
    }
    UINavigationItem *item = _page.navigationItem;
    item.standardAppearance = appearance;
    item.compactAppearance = appearance;
    item.scrollEdgeAppearance = appearance;
    item.compactScrollEdgeAppearance = appearance;
    self.hidden = NO;
    [UIView animateWithDuration:animated ? 0.2 : 0 animations:^{
        self.alpha = shown ? 1 : 0;
    } completion:^(BOOL finished) {
        if (!self->_shown) self.hidden = YES;
    }];
}

@end

#pragma mark - All Activity

typedef NS_ENUM(NSInteger, NLActivitySection) {
    NLActivitySectionChart,
    NLActivitySectionUsages,
    NLActivitySectionListening,
    NLActivitySectionCount,
};

typedef NS_ENUM(NSInteger, NLListeningRow) {
    NLListeningRowPlays,
    NLListeningRowSongs,
    NLListeningRowArtists,
    NLListeningRowSkipped,    // with Show Skipped Songs
    NLListeningRowTimeline,   // one day only
};

static const NSUInteger kNLCollapsedUsages = 5;

// Most Played's header: its title, and on the right Show Categories (a menu
// of them) or, with one shown, Show Songs, as Screen Time's.
@interface NLUsageHeader : UITableViewHeaderFooterView
@property (nonatomic, readonly) UIButton *button;
- (void)showTitle:(NSString *)title button:(NSString *)button;
@end

@implementation NLUsageHeader {
    NSLayoutConstraint *_baseline;
}

- (instancetype)initWithReuseIdentifier:(NSString *)reuseIdentifier {
    if (!(self = [super initWithReuseIdentifier:reuseIdentifier])) return nil;
    // Set first: the content view it makes is the one the button lines up with.
    self.contentConfiguration = [UIListContentConfiguration groupedHeaderConfiguration];
    _button = [UIButton buttonWithType:UIButtonTypeSystem];
    _button.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_button];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    _baseline = [_button.lastBaselineAnchor constraintEqualToAnchor:margins.bottomAnchor];
    [NSLayoutConstraint activateConstraints:@[[_button.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor], _baseline]];
    return self;
}

// The button in the title's font and case, on its baseline (the title ends at the margin).
- (void)showTitle:(NSString *)title button:(NSString *)button {
    UIListContentConfiguration *content = [UIListContentConfiguration groupedHeaderConfiguration];
    content.text = title;
    self.contentConfiguration = content;
    UIFont *font = content.textProperties.font;
    BOOL uppercase = content.textProperties.transform == UIListContentTextTransformUppercase;
    _button.titleLabel.font = font;
    [_button setTitle:uppercase ? button.localizedUppercaseString : button forState:UIControlStateNormal];
    _baseline.constant = font.descender;
}

@end

@interface NLHistoryActivityController () <UITableViewDataSource, UITableViewDelegate, UICollectionViewDataSource, UICollectionViewDelegate>
@end

@implementation NLHistoryActivityController {
    UITableView *_table;
    NLActivityScale _scale;
    NSDate *_initialDate;
    NSArray<NLHistoryItem *> *_items;                               // every play, newest first
    NLHistoryApps *_apps;
    BOOL _showsSkipped;                                             // Show Skipped Songs, as loaded
    NSDate *_firstStart;                                            // page 0's start
    NSInteger _pageCount;
    NSMutableDictionary<NSNumber *, NLActivityPeriod *> *_periods;
    NSInteger _selectedBar;
    UISegmentedControl *_scaleControl;
    NLActivityCardCell *_cardCell;
    NLPagerView *_pager;
    NLDateBar *_dateBar;
    NSDate *_rangeStart, *_rangeEnd;                                // what the card and the lists show
    NSString *_rangeTitle;
    NLUsageKind _usageKind;                                         // what Most Played ranks
    NSArray<NLUsage *> *_usages;
    BOOL _showAll;
    NSArray<NSNumber *> *_listening;                                // the NLListeningRow rows shown
    NSUInteger _playCount, _songCount, _artistCount, _skipCount;
    NSString *_timelineDay;                                         // the day shown or picked, else nil
    BOOL _loaded;
    NSUInteger _loads;
}

- (instancetype)initWithScale:(NLActivityScale)scale date:(NSDate *)date {
    if ((self = [super init])) {
        _scale = scale;
        _initialDate = date ?: [NSDate date];
        _selectedBar = NSNotFound;
        _periods = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NLL(@"All Activity");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = NLApplyButton(self);
    _table = NLMakeTable(self);
    [_table registerClass:[NLUsageCell class] forCellReuseIdentifier:@"usage"];
    [_table registerClass:[UITableViewCell class] forCellReuseIdentifier:@"cell"];
    [_table registerClass:[NLUsageHeader class] forHeaderFooterViewReuseIdentifier:@"usages"];

    _scaleControl = [[UISegmentedControl alloc] initWithItems:@[NLL(@"Week"), NLL(@"Day")]];
    _scaleControl.selectedSegmentIndex = _scale;
    [_scaleControl addTarget:self action:@selector(nlScaleChanged) forControlEvents:UIControlEventValueChanged];
    _scaleControl.translatesAutoresizingMaskIntoConstraints = NO;
    UIView *header = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 320, 48)];
    header.preservesSuperviewLayoutMargins = YES;
    [header addSubview:_scaleControl];
    [NSLayoutConstraint activateConstraints:@[
        [_scaleControl.leadingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.leadingAnchor],
        [_scaleControl.trailingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.trailingAnchor],
        [_scaleControl.centerYAnchor constraintEqualToAnchor:header.centerYAnchor constant:4],
    ]];
    _table.tableHeaderView = header;

    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.minimumLineSpacing = 0;
    layout.minimumInteritemSpacing = 0;
    layout.estimatedItemSize = CGSizeZero;
    _pager = [[NLPagerView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    _pager.pagingEnabled = YES;
    _pager.showsHorizontalScrollIndicator = NO;
    _pager.backgroundColor = UIColor.clearColor;
    _pager.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    _pager.dataSource = self;
    _pager.delegate = self;
    [_pager registerClass:[NLActivityPageCell class] forCellWithReuseIdentifier:@"page"];
    _cardCell = [[NLActivityCardCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    _cardCell.selectionStyle = UITableViewCellSelectionStyleNone;
    _cardCell.chartView = _pager;

    // Once the chart has scrolled away, what it shows stays on top with
    // buttons to the one before and after, as Screen Time's.
    _dateBar = [NLDateBar barOnPage:self];
    [_dateBar.previousButton addTarget:self action:@selector(nlPrevious) forControlEvents:UIControlEventTouchUpInside];
    [_dateBar.nextButton addTarget:self action:@selector(nlNext) forControlEvents:UIControlEventTouchUpInside];
    _dateBar.previousButton.accessibilityLabel = NLL(@"Previous");
    _dateBar.nextButton.accessibilityLabel = NLL(@"Next");

    NLHistoryObserve(self, @selector(nlLoad));
    [self nlLoad];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_loaded) [self nlLoad];   // back from a song or a day: plays may be gone
}

- (void)nlLoad {
    BOOL skipped = NLHistoryShowsSkipped(self);
    NSUInteger load = ++_loads;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NLHistoryItem *> *items = NLHistoryLoadAll(skipped);
        NLHistoryApps *apps = [NLHistoryApps appsForItems:items];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (load != self->_loads) return;
            // Loaded again (SpringBoard writes each minute while a song
            // plays): the same page, with the bar picked still picked.
            BOOL again = self->_loaded;
            NSDate *showing = again ? [self nlPeriodAtPage:self->_pager.page].start : self->_initialDate;
            self->_items = items;
            self->_apps = apps;
            self->_showsSkipped = skipped;
            self->_loaded = YES;
            [self nlReloadPagesShowingDate:showing selectedBar:again ? self->_selectedBar : NSNotFound];
        });
    });
}

#pragma mark Pages

- (NSCalendarUnit)nlPageUnit {
    return _scale == NLActivityScaleWeek ? NSCalendarUnitWeekOfYear : NSCalendarUnitDay;
}

- (NSInteger)nlPagesFrom:(NSDate *)start to:(NSDate *)end {
    NSDateComponents *components = [NSCalendar.currentCalendar components:[self nlPageUnit] fromDate:start toDate:end options:0];
    return _scale == NLActivityScaleWeek ? components.weekOfYear : components.day;
}

// `bar`: the bar to show picked on the page with `date`, NSNotFound for none.
- (void)nlReloadPagesShowingDate:(NSDate *)date selectedBar:(NSInteger)bar {
    NSDate *current = [NLActivityPeriod startOfPeriodWithScale:_scale containingDate:[NSDate date]];
    NSDate *oldest = _items.lastObject.start;
    _firstStart = oldest ? [NLActivityPeriod startOfPeriodWithScale:_scale containingDate:[oldest earlierDate:current]] : current;
    _pageCount = [self nlPagesFrom:_firstStart to:current] + 1;
    NSDate *target = [NLActivityPeriod startOfPeriodWithScale:_scale containingDate:date];
    _pager.page = MIN(MAX([self nlPagesFrom:_firstStart to:target], 0), _pageCount - 1);
    [_periods removeAllObjects];
    _selectedBar = bar >= 0 && bar < (NSInteger)[self nlPeriodAtPage:_pager.page].bars.count ? bar : NSNotFound;
    [_pager reloadData];
    [_pager scrollToPage:_pager.page];
    [self nlUpdateContent];
}

- (NLActivityPeriod *)nlPeriodAtPage:(NSInteger)page {
    NLActivityPeriod *period = _periods[@(page)];
    if (period) return period;
    NSDate *start = [NSCalendar.currentCalendar dateByAddingUnit:[self nlPageUnit] value:page toDate:_firstStart options:0];
    period = [NLActivityPeriod periodWithScale:_scale containingDate:start items:_items ?: @[] apps:_apps];
    _periods[@(page)] = period;
    return period;
}

- (void)nlScaleChanged {
    NLActivityScale scale = _scaleControl.selectedSegmentIndex;
    if (scale == _scale) return;
    NLActivityPeriod *period = [self nlPeriodAtPage:_pager.page];
    NSDate *date = period.start;   // day → week: the week with this day
    if (scale == NLActivityScaleDay) {
        // week → day: the day picked; else today in this week, a past week's last day.
        NSDate *now = [NSDate date];
        if (_selectedBar != NSNotFound) date = period.bars[_selectedBar].start;
        else date = [period.end compare:now] == NSOrderedDescending ? now : [period.end dateByAddingTimeInterval:-1];
    }
    _scale = scale;
    [self nlReloadPagesShowingDate:date selectedBar:NSNotFound];
}

#pragma mark Content

- (void)nlUpdateContent {
    NLActivityPeriod *period = [self nlPeriodAtPage:_pager.page];
    BOOL selected = _selectedBar != NSNotFound && _selectedBar < (NSInteger)period.bars.count;
    NLActivityBar *bar = selected ? period.bars[_selectedBar] : nil;
    NSDate *start = bar ? bar.start : period.start;
    NSDate *end = bar ? bar.end : period.end;
    _rangeStart = start;
    _rangeEnd = end;
    _rangeTitle = bar ? [period titleForBarAtIndex:_selectedBar] : period.title;

    if (bar) {
        [_cardCell showTitle:_rangeTitle caption:nil value:NLHistoryDuration(bar.total) durations:bar.durations apps:_apps];
    } else if (_scale == NLActivityScaleWeek) {
        [_cardCell showTitle:_rangeTitle caption:NLL(@"Daily Average") value:NLHistoryDuration(period.dailyAverage)
                   durations:period.durations apps:_apps];
    } else {
        [_cardCell showTitle:_rangeTitle caption:nil value:NLHistoryDuration(period.total) durations:period.durations apps:_apps];
    }

    NSArray<NLUsage *> *songs = NLUsages(period.items, start, end, NLUsageKindSongs);
    _usages = _usageKind == NLUsageKindSongs ? songs : NLUsages(period.items, start, end, _usageKind);
    _songCount = songs.count;
    NSUInteger plays = 0, skips = 0;
    NSMutableSet<NSString *> *artists = [NSMutableSet set];
    for (NLHistoryItem *item in period.items) {
        if ([item.start compare:start] == NSOrderedAscending || [item.start compare:end] != NSOrderedAscending) continue;
        plays++;
        if (item.skipped) skips++;
        if (item.artist.length) [artists addObject:item.artist];
    }
    _playCount = plays;
    _skipCount = skips;
    _artistCount = artists.count;
    NSDate *day = _scale == NLActivityScaleDay ? period.start : (bar ? bar.start : nil);
    _timelineDay = day ? NLHistoryDayKey(day) : nil;
    NSMutableArray<NSNumber *> *listening = [NSMutableArray arrayWithArray:@[@(NLListeningRowPlays), @(NLListeningRowSongs), @(NLListeningRowArtists)]];
    if (_showsSkipped) [listening addObject:@(NLListeningRowSkipped)];
    if (_timelineDay) [listening addObject:@(NLListeningRowTimeline)];
    _listening = listening;
    [self nlUpdateDateBar];

    // Off screen, or the first load (the table has no sections yet to reload): all of it.
    if (!_table.window || _table.numberOfSections != NLActivitySectionCount) {
        [_table reloadData];
    } else {
        [UIView performWithoutAnimation:^{
            [self->_table beginUpdates];
            [self->_table reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(NLActivitySectionUsages, 2)]
                        withRowAnimation:UITableViewRowAnimationNone];
            [self->_table endUpdates];
        }];
    }
    [self nlUpdateDateBarShown];
}

- (void)nlSelectBar:(NSInteger)index onPage:(NSInteger)page {
    if (page != _pager.page) return;
    _selectedBar = index;
    [self nlUpdateContent];
}

// The page's chart shows the bar picked; the others none.
- (void)nlSyncChartSelection {
    for (NSIndexPath *indexPath in _pager.indexPathsForVisibleItems) {
        NLActivityPageCell *cell = (NLActivityPageCell *)[_pager cellForItemAtIndexPath:indexPath];
        cell.chartView.selectedIndex = indexPath.item == _pager.page ? _selectedBar : NSNotFound;
    }
}

- (void)nlShowUsageKind:(NLUsageKind)kind {
    if (kind == _usageKind) return;
    _usageKind = kind;
    _showAll = NO;
    [self nlUpdateContent];
}

- (void)nlShowSongs {
    [self nlShowUsageKind:NLUsageKindSongs];
}

#pragma mark Date bar

// Shown once the chart has gone up under the navigation bar.
- (void)nlUpdateDateBarShown {
    BOOL shown = NO;
    if (_loaded && _table.numberOfSections > NLActivitySectionChart) {
        CGFloat chartBottom = _pager.window ? CGRectGetMaxY([_pager convertRect:_pager.bounds toView:_table])
                                            : CGRectGetMaxY([_table rectForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:NLActivitySectionChart]]);
        shown = chartBottom <= _table.contentOffset.y + _table.adjustedContentInset.top;
    }
    [_dateBar setShown:shown animated:YES];
}

- (void)nlUpdateDateBar {
    _dateBar.titleLabel.text = _rangeTitle;
    _dateBar.previousButton.enabled = [self nlStep:-1 apply:NO];
    _dateBar.nextButton.enabled = [self nlStep:+1 apply:NO];
}

// One back (-1) or on (+1): the bar beside the one picked, onto the page
// beside at either end; without one picked, the page beside. NO when there is
// none: before the first page, or still to come.
- (BOOL)nlStep:(NSInteger)step apply:(BOOL)apply {
    NSInteger page = _pager.page, bar = _selectedBar;
    if (bar == NSNotFound) {
        page += step;
    } else {
        bar += step;
        if (bar < 0) {
            page--;
            bar = page >= 0 ? (NSInteger)[self nlPeriodAtPage:page].bars.count - 1 : 0;
        } else if (bar >= (NSInteger)[self nlPeriodAtPage:page].bars.count) {
            page++;
            bar = 0;
        }
    }
    if (page < 0 || page >= _pageCount) return NO;
    if (bar != NSNotFound && [[self nlPeriodAtPage:page].bars[bar].start compare:[NSDate date]] == NSOrderedDescending) return NO;
    if (apply) {
        if (page != _pager.page) [_pager scrollToPage:page];
        _selectedBar = bar;
        [self nlSyncChartSelection];
        [self nlUpdateContent];
    }
    return YES;
}

- (void)nlPrevious {
    [self nlStep:-1 apply:YES];
}

- (void)nlNext {
    [self nlStep:+1 apply:YES];
}

#pragma mark Pager

- (NSInteger)collectionView:(UICollectionView *)collectionView numberOfItemsInSection:(NSInteger)section {
    return _loaded ? _pageCount : 0;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    NLActivityPageCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"page" forIndexPath:indexPath];
    NSInteger page = indexPath.item;
    cell.chartView.period = [self nlPeriodAtPage:page];
    cell.chartView.selectedIndex = page == _pager.page ? _selectedBar : NSNotFound;
    __weak NLHistoryActivityController *weakSelf = self;
    cell.chartView.didSelectBar = ^(NSInteger index) { [weakSelf nlSelectBar:index onPage:page]; };
    return cell;
}

// The table calls these too (both are scroll views).
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == _table) [self nlUpdateDateBarShown];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView == _pager) [self nlPagerDidSettle];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (scrollView == _pager && !decelerate) [self nlPagerDidSettle];
}

- (void)nlPagerDidSettle {
    CGFloat width = _pager.bounds.size.width;
    if (width <= 0) return;
    NSInteger page = MIN(MAX((NSInteger)lround(_pager.contentOffset.x / width), 0), _pageCount - 1);
    if (page == _pager.page) return;
    _pager.page = page;
    _selectedBar = NSNotFound;
    [self nlSyncChartSelection];
    [self nlUpdateContent];
}

#pragma mark Table

- (NSUInteger)nlShownUsageCount {
    return _showAll ? _usages.count : MIN(_usages.count, kNLCollapsedUsages);
}

- (BOOL)nlCanExpandUsages {
    return _usages.count > kNLCollapsedUsages;
}

- (NSString *)nlUsageTitle {
    switch (_usageKind) {
        case NLUsageKindSongs: return NLL(@"Most Played");
        case NLUsageKindArtists: return NLL(@"Top Artists");
        case NLUsageKindAlbums: return NLL(@"Top Albums");
        case NLUsageKindApps: return NLL(@"Top Apps");
    }
    return nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _loaded ? NLActivitySectionCount : 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case NLActivitySectionChart: return 1;
        case NLActivitySectionUsages: return MAX([self nlShownUsageCount], 1) + ([self nlCanExpandUsages] ? 1 : 0);
        default: return (NSInteger)_listening.count;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == NLActivitySectionListening ? NLL(@"Listening") : nil;
}

- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    if (section != NLActivitySectionUsages) return nil;
    NLUsageHeader *header = [tableView dequeueReusableHeaderFooterViewWithIdentifier:@"usages"];
    BOOL songs = _usageKind == NLUsageKindSongs;
    [header showTitle:[self nlUsageTitle] button:NLL(songs ? @"Show Categories" : @"Show Songs")];
    UIButton *button = header.button;
    [button removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
    if (songs) {
        __weak typeof(self) weakSelf = self;
        UIAction *(^show)(NSString *, NSString *, NLUsageKind) = ^UIAction *(NSString *title, NSString *symbol, NLUsageKind kind) {
            return [UIAction actionWithTitle:NLL(title) image:[UIImage systemImageNamed:symbol] identifier:nil
                                     handler:^(UIAction *action) { [weakSelf nlShowUsageKind:kind]; }];
        };
        button.menu = [UIMenu menuWithChildren:@[show(@"Artists", @"music.mic", NLUsageKindArtists),
                                                 show(@"Albums", @"square.stack", NLUsageKindAlbums),
                                                 show(@"Apps", @"square.grid.2x2", NLUsageKindApps)]];
        button.showsMenuAsPrimaryAction = YES;
    } else {
        button.menu = nil;
        button.showsMenuAsPrimaryAction = NO;
        [button addTarget:self action:@selector(nlShowSongs) forControlEvents:UIControlEventTouchUpInside];
    }
    return header;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == NLActivitySectionChart) return _cardCell;
    if (indexPath.section == NLActivitySectionUsages && indexPath.row < (NSInteger)[self nlShownUsageCount]) {
        NLUsageCell *cell = [tableView dequeueReusableCellWithIdentifier:@"usage" forIndexPath:indexPath];
        NLUsage *usage = _usages[indexPath.row];
        NSTimeInterval longest = _usages.firstObject.duration;
        [cell showUsage:usage fraction:longest > 0 ? usage.duration / longest : 0
                  color:[_apps colorForCategory:[_apps categoryForApp:usage.item.app]]];
        return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIListContentConfiguration *content;
    NLListeningRow row = indexPath.section == NLActivitySectionListening ? (NLListeningRow)_listening[indexPath.row].integerValue : NLListeningRowPlays;
    if (indexPath.section == NLActivitySectionUsages) {
        content = [UIListContentConfiguration cellConfiguration];
        if (!_usages.count) {
            content.text = NLL(@"No Plays");
            content.textProperties.color = UIColor.secondaryLabelColor;
        } else {
            content.text = _showAll ? NLL(@"Show Less") : NLL(@"Show More");
            content.textProperties.color = UIColor.tintColor;   // the theme's, when it changes too
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else if (row == NLListeningRowTimeline) {
        content = [UIListContentConfiguration cellConfiguration];
        content.image = [UIImage systemImageNamed:@"list.bullet.rectangle"];
        content.text = NLL(@"Timeline");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        content = [UIListContentConfiguration valueCellConfiguration];
        NSString *title = @"Plays";
        NSUInteger count = _playCount;
        switch (row) {
            case NLListeningRowSongs: title = @"Songs"; count = _songCount; break;
            case NLListeningRowArtists: title = @"Artists"; count = _artistCount; break;
            case NLListeningRowSkipped: title = @"Skipped"; count = _skipCount; break;
            default: break;
        }
        content.text = NLL(title);
        content.secondaryText = [NSString localizedStringWithFormat:@"%lu", (unsigned long)count];
    }
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == NLActivitySectionUsages) {
        if (indexPath.row < (NSInteger)[self nlShownUsageCount]) {
            NLUsage *usage = _usages[indexPath.row];
            PSViewController *page = usage.kind == NLUsageKindSongs
                ? [[NLHistorySongController alloc] initWithItem:usage.item]
                : [[NLHistoryGroupController alloc] initWithUsage:usage items:[self nlPeriodAtPage:_pager.page].items range:_rangeTitle
                                                            start:_rangeStart end:_rangeEnd apps:_apps];
            NLHistoryPush(self, page);
        } else if ([self nlCanExpandUsages]) {
            _showAll = !_showAll;
            [tableView reloadSections:[NSIndexSet indexSetWithIndex:NLActivitySectionUsages] withRowAnimation:UITableViewRowAnimationAutomatic];
        }
    } else if (indexPath.section == NLActivitySectionListening && _timelineDay
               && (NLListeningRow)_listening[indexPath.row].integerValue == NLListeningRowTimeline) {
        NLHistoryPush(self, [[NLHistoryDayController alloc] initWithDay:_timelineDay]);
    }
}

@end

#pragma mark - An artist, album or app

typedef NS_ENUM(NSInteger, NLGroupSection) {
    NLGroupSectionSummary,
    NLGroupSectionSongs,
    NLGroupSectionCount,
};

@interface NLHistoryGroupController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation NLHistoryGroupController {
    NLUsage *_usage;
    NSString *_range;
    NLHistoryApps *_apps;
    NSArray<NLUsage *> *_songs;
    UITableView *_table;
}

- (instancetype)initWithUsage:(NLUsage *)usage items:(NSArray<NLHistoryItem *> *)items range:(NSString *)range
                        start:(NSDate *)start end:(NSDate *)end apps:(NLHistoryApps *)apps {
    if (!(self = [super init])) return nil;
    _usage = usage;
    _range = [range copy];
    _apps = apps;
    NSMutableArray<NLHistoryItem *> *mine = [NSMutableArray array];
    for (NLHistoryItem *item in items) {
        if ([NLUsageKey(item, usage.kind) isEqualToString:usage.key]) [mine addObject:item];
    }
    _songs = NLUsages(mine, start, end, NLUsageKindSongs);
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _usage.name;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = NLApplyButton(self);
    _table = NLMakeTable(self);
    [_table registerClass:[NLUsageCell class] forCellReuseIdentifier:@"usage"];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return NLGroupSectionCount;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return section == NLGroupSectionSummary ? 3 : MAX(_songs.count, 1);
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == NLGroupSectionSummary ? _range : NLL(@"Most Played");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == NLGroupSectionSummary) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        NSUInteger count = indexPath.row == 1 ? _usage.plays : _songs.count;
        cell.textLabel.text = NLL(indexPath.row == 0 ? @"Listening Time" : indexPath.row == 1 ? @"Plays" : @"Songs");
        cell.detailTextLabel.text = indexPath.row == 0 ? NLHistoryDuration(_usage.duration)
                                                       : [NSString localizedStringWithFormat:@"%lu", (unsigned long)count];
        return cell;
    }
    if (!_songs.count) return NLNoteCell(NLL(@"No Plays"));
    NLUsageCell *cell = [tableView dequeueReusableCellWithIdentifier:@"usage" forIndexPath:indexPath];
    NLUsage *song = _songs[indexPath.row];
    NSTimeInterval longest = _songs.firstObject.duration;
    [cell showUsage:song fraction:longest > 0 ? song.duration / longest : 0
              color:[_apps colorForCategory:[_apps categoryForApp:song.item.app]]];
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != NLGroupSectionSongs || indexPath.row >= (NSInteger)_songs.count) return;
    NLHistoryPush(self, [[NLHistorySongController alloc] initWithItem:_songs[indexPath.row].item]);
}

@end
