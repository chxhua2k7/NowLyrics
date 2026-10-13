//
//  NLHistoryActivity.m
//  Screen Time's charts for the listening history (the first page's This
//  Week card and All Activity share them), laid out as Screen Time's, by app
//  instead of by category:
//  - NLHistoryApps: the apps told apart, each with its color, the rest as Other Apps
//  - NLActivityPeriod: a week (a bar a day) or a day (a bar an hour), each bar
//    the time listened per app; a play across an edge counts the part inside
//  - NLActivityChartView: stacked bars, the scale on the right, weekdays or
//    hours under them, the week's average dashed; a tap selects a bar, a
//    press shows its day and time in a green callout over the card
//  - NLActivityCardCell, NLUsageCell: the card and Most Played's rows
//  - NLDateBar: the period under the navigation bar, round buttons to the
//    one before and after
//  - With Screen Time's own charts (NLScreenTime.m) the graphs, their titles,
//    the legend and the date bar are Screen Time's; ours where an iOS lacks them
//  - NLHistoryActivityController: All Activity. Week | Day on top; the chart
//    pages back to the first week or day with plays (a day's hours under its
//    week, which stays as they page, the other days grey). As Screen Time's,
//    a day tapped on a week opens that day; an hour tapped on a day (ours)
//    narrows the card and the lists to it. A week has its trend and its
//    total under the card; once Week | Day has scrolled away the date bar
//    steps through them. Most Played (to the
//    song's page) or, with Show Categories, its artists, albums or apps (to
//    theirs, NLHistoryGroupController); what was listened to, and for one
//    day its timeline.
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
    _contextIndex = NSNotFound;
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

- (void)setContextIndex:(NSInteger)contextIndex {
    _contextIndex = contextIndex;
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

// As Screen Time draws it: lines across at each quarter, the scale on the
// right at the top and 0 (a day's half too); dotted lines down between a
// week's days and a day's six hours, the weekdays and hours just right of
// them; the week's average dashed.
- (void)drawRect:(CGRect)rect {
    NSArray<NLActivityBar *> *bars = self.period.bars;
    CGRect chart = [self nlChartRect];
    if (!bars.count || chart.size.width <= 0 || chart.size.height <= 0) return;
    CGContextRef context = UIGraphicsGetCurrentContext();
    BOOL week = self.period.scale == NLActivityScaleWeek;
    BOOL aroundDay = self.contextIndex != NSNotFound;
    NSTimeInterval maximum = [self nlMaximum];
    UIFont *font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightRegular];
    NSDictionary *axis = @{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.secondaryLabelColor};
    NSDictionary *selectedAxis = @{NSFontAttributeName: [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightSemibold],
                                   NSForegroundColorAttributeName: UIColor.labelColor};
    CGFloat hairline = 1 / MAX(self.traitCollection.displayScale, 1);
    CGFloat column = chart.size.width / bars.count;
    // The bar pressed, else the one picked, stands out; the others fade.
    NSInteger highlighted = _pressedIndex != NSNotFound ? _pressedIndex : self.selectedIndex;

    // The week's average: green as Screen Time's, grey on the week above a day.
    NSTimeInterval average = week ? self.period.dailyAverage : 0;
    CGFloat averageY = CGRectGetMaxY(chart) - MIN(average / maximum, 1) * chart.size.height;
    UIColor *averageColor = aroundDay ? UIColor.secondaryLabelColor : UIColor.systemGreenColor;

    [UIColor.separatorColor setStroke];
    for (NSInteger i = 0; i <= 4; i++) {
        CGFloat y = CGRectGetMaxY(chart) - chart.size.height * i / 4;
        UIBezierPath *line = [UIBezierPath bezierPath];
        [line moveToPoint:CGPointMake(CGRectGetMinX(chart), y)];
        [line addLineToPoint:CGPointMake(CGRectGetMaxX(chart), y)];
        line.lineWidth = hairline;
        [line stroke];
        // A label too close to the average gives way to it.
        BOOL labeled = i == 0 || i == 4 || (!week && i == 2);
        if (!labeled || (average > 0 && fabs(y - averageY) < font.lineHeight)) continue;
        NSString *label = i == 0 ? @"0" : NLAxisString(maximum * i / 4, week);
        [label drawAtPoint:CGPointMake(CGRectGetMaxX(chart) + 6, y - font.lineHeight / 2) withAttributes:axis];
    }
    for (NSUInteger i = 0; i <= bars.count; i += week ? 1 : 6) {
        CGFloat x = round(CGRectGetMinX(chart) + column * i) + hairline / 2;
        UIBezierPath *line = [UIBezierPath bezierPath];
        [line moveToPoint:CGPointMake(x, CGRectGetMinY(chart))];
        [line addLineToPoint:CGPointMake(x, CGRectGetMaxY(chart) + kNLChartLabelHeight)];
        line.lineWidth = hairline;
        const CGFloat dashes[] = {2, 2};
        [line setLineDash:dashes count:2 phase:0];
        [line stroke];
    }

    NLHistoryApps *apps = self.period.apps;
    NSCalendar *calendar = NSCalendar.currentCalendar;
    CGFloat barWidth = week ? MIN(column * 0.5, 28) : MAX(column * 0.6, 2);
    CGFloat radius = week ? 3 : 1.5;
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
            if (aroundDay && (NSInteger)i != self.contextIndex) {
                [UIColor.systemGray3Color setFill];   // the week's other days
                UIRectFill(frame);
            } else {
                CGFloat y = CGRectGetMaxY(chart);
                for (NSUInteger c = 0; c < bar.durations.count; c++) {
                    CGFloat segment = bar.durations[c].doubleValue / bar.total * height;
                    if (segment <= 0) continue;
                    [[apps colorForCategory:c] setFill];
                    UIRectFillUsingBlendMode(CGRectMake(x, y - segment, barWidth, segment), kCGBlendModeNormal);
                    y -= segment;
                }
            }
            CGContextRestoreGState(context);
        }
        CGPoint labelPoint = CGPointMake(CGRectGetMinX(chart) + column * i + 4, CGRectGetMaxY(chart) + 4);
        if (week) {
            NSString *label = calendar.veryShortStandaloneWeekdaySymbols[[calendar component:NSCalendarUnitWeekday fromDate:bar.start] - 1];
            [label drawAtPoint:labelPoint withAttributes:selected ? selectedAxis : axis];
        } else if (i % 6 == 0) {
            [NLHourString(bar.start) drawAtPoint:labelPoint withAttributes:axis];
        }
    }

    if (average > 0) {
        UIBezierPath *line = [UIBezierPath bezierPath];
        [line moveToPoint:CGPointMake(CGRectGetMinX(chart), averageY)];
        [line addLineToPoint:CGPointMake(CGRectGetMaxX(chart), averageY)];
        line.lineWidth = 1;
        const CGFloat dashes[] = {3, 3};
        [line setLineDash:dashes count:2 phase:0];
        [averageColor setStroke];
        [line stroke];
        NSDictionary *label = @{NSFontAttributeName: font, NSForegroundColorAttributeName: averageColor};
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

static const CGFloat kNLWeekChartHeight = 132;   // our chart under a card: a week's bars, or a day's hours

NSString *NLActivityTrend(NLActivityPeriod *period, NLActivityPeriod *previous, BOOL *rising) {
    NSTimeInterval now = period.dailyAverage, before = previous.dailyAverage;
    if (now <= 0 || before <= 0) return nil;
    double change = (now - before) / before;
    if (fabs(change) < 0.005) return nil;
    if (rising) *rising = change > 0;
    NSNumberFormatter *percent = NLHistoryFormatter(@"percent", ^id {
        NSNumberFormatter *made = [NSNumberFormatter new];
        made.numberStyle = NSNumberFormatterPercentStyle;
        made.maximumFractionDigits = 0;
        return made;
    });
    return [NSString stringWithFormat:NLL(@"%@ from last week"), [percent stringFromNumber:@(fabs(change))]];
}

// The arrow in a grey circle, then the words, as Screen Time's.
static NSAttributedString *NLTrendString(NSString *text, BOOL rising, UIFont *font) {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithFont:font];
    UIImage *arrow = [[UIImage systemImageNamed:rising ? @"arrow.up.circle.fill" : @"arrow.down.circle.fill" withConfiguration:configuration]
                      imageWithTintColor:UIColor.secondaryLabelColor renderingMode:UIImageRenderingModeAlwaysOriginal];
    NSMutableAttributedString *string = [NSMutableAttributedString new];
    [string appendAttributedString:[NSAttributedString attributedStringWithAttachment:[NSTextAttachment textAttachmentWithImage:arrow]]];
    [string appendAttributedString:[[NSAttributedString alloc] initWithString:[@" " stringByAppendingString:text]
                                                                   attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: UIColor.secondaryLabelColor}]];
    return string;
}

@implementation NLActivityCardCell {
    BOOL _screenTime;                 // Screen Time's charts: the title is in them, the legend is theirs
    UILabel *_titleLabel, *_valueLabel, *_trendLabel;
    UIView *_headHost, *_chartHost;
    NSLayoutConstraint *_headHostHeight, *_chartHostHeight;
    UIStackView *_legend;             // ours
    UIView *_screenTimeLegend;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) return nil;
    _titleLabel = NLCardLabel(UIFontTextStyleBody, NO, UIColor.secondaryLabelColor);
    _titleLabel.adjustsFontSizeToFitWidth = YES;
    _titleLabel.minimumScaleFactor = 0.7;
    _valueLabel = NLCardLabel(UIFontTextStyleLargeTitle, NO, UIColor.labelColor);
    _valueLabel.adjustsFontSizeToFitWidth = YES;
    _valueLabel.minimumScaleFactor = 0.6;
    _trendLabel = NLCardLabel(UIFontTextStyleBody, NO, UIColor.secondaryLabelColor);
    [_trendLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *valueRow = [[UIStackView alloc] initWithArrangedSubviews:@[_valueLabel, _trendLabel]];
    valueRow.axis = UILayoutConstraintAxisHorizontal;
    valueRow.alignment = UIStackViewAlignmentLastBaseline;
    valueRow.spacing = 8;
    _headHost = [UIView new];
    _headHostHeight = [_headHost.heightAnchor constraintEqualToConstant:0];
    _headHostHeight.active = YES;
    _headHost.hidden = YES;
    _chartHost = [UIView new];
    _chartHostHeight = [_chartHost.heightAnchor constraintEqualToConstant:kNLWeekChartHeight];
    _chartHostHeight.active = YES;
    _screenTime = NLScreenTimeChartsAvailable();
    UIView *legend;
    if (_screenTime) {
        legend = _screenTimeLegend = NLScreenTimeMakeLegend();
        _titleLabel.hidden = YES;
        valueRow.hidden = YES;
    } else {
        legend = _legend = [UIStackView new];
        _legend.axis = UILayoutConstraintAxisHorizontal;
        _legend.alignment = UIStackViewAlignmentTop;
        _legend.spacing = 12;
    }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, valueRow, _headHost, _chartHost, legend]];
    stack.axis = UILayoutConstraintAxisVertical;
    [stack setCustomSpacing:12 afterView:valueRow];
    [stack setCustomSpacing:16 afterView:_headHost];
    [stack setCustomSpacing:12 afterView:_chartHost];
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

- (CGFloat)chartHeight {
    return _chartHostHeight.constant;
}

- (void)setChartHeight:(CGFloat)chartHeight {
    _chartHostHeight.constant = chartHeight;
}

- (CGFloat)headChartHeight {
    return _headHostHeight.constant;
}

- (void)setHeadChartHeight:(CGFloat)headChartHeight {
    _headHostHeight.constant = headChartHeight;
}

static void NLFill(UIView *host, UIView *view) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [host addSubview:view];
    [NSLayoutConstraint activateConstraints:@[
        [view.topAnchor constraintEqualToAnchor:host.topAnchor],
        [view.bottomAnchor constraintEqualToAnchor:host.bottomAnchor],
        [view.leadingAnchor constraintEqualToAnchor:host.leadingAnchor],
        [view.trailingAnchor constraintEqualToAnchor:host.trailingAnchor],
    ]];
}

- (void)setChartView:(UIView *)chartView {
    [_chartView removeFromSuperview];
    _chartView = chartView;
    if (chartView) NLFill(_chartHost, chartView);
}

- (void)setHeadChartView:(UIView *)headChartView {
    if (headChartView == _headChartView) return;
    [_headChartView removeFromSuperview];
    _headChartView = headChartView;
    if (headChartView) NLFill(_headHost, headChartView);
    _headHost.hidden = !headChartView;
}

// The legend, as Screen Time's three categories: the three apps listened to
// longest, spread across, each named in its color with its time under it.
- (void)showTitle:(NSString *)title value:(NSString *)value trend:(NSString *)trend rising:(BOOL)rising
        durations:(NSArray<NSNumber *> *)durations apps:(NLHistoryApps *)apps {
    if (!_screenTime) {
        _titleLabel.text = title;
        _titleLabel.hidden = !title.length;
        _valueLabel.text = value;
        _trendLabel.attributedText = trend ? NLTrendString(trend, rising, _trendLabel.font) : nil;
        _trendLabel.hidden = !trend;
    }
    for (UIView *view in _legend.arrangedSubviews) {
        [_legend removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    NSMutableArray<NSNumber *> *order = [NSMutableArray array];
    for (NSUInteger c = 0; c < durations.count; c++) if (durations[c].doubleValue >= 60) [order addObject:@(c)];
    [order sortUsingComparator:^NSComparisonResult(NSNumber *a, NSNumber *b) {
        return [durations[b.unsignedIntegerValue] compare:durations[a.unsignedIntegerValue]];
    }];
    if (order.count > 3) [order removeObjectsInRange:NSMakeRange(3, order.count - 3)];
    if (_screenTime) {
        NLScreenTimeShowLegend(_screenTimeLegend, order, durations, apps);
        _screenTimeLegend.hidden = order.count == 0;
        return;
    }
    for (NSNumber *category in order) {
        UILabel *name = NLCardLabel(UIFontTextStyleSubheadline, NO, [apps colorForCategory:category.unsignedIntegerValue]);
        name.text = [apps nameForCategory:category.unsignedIntegerValue];
        UILabel *time = NLCardLabel(UIFontTextStyleSubheadline, NO, UIColor.labelColor);
        time.text = NLHistoryDuration(durations[category.unsignedIntegerValue].doubleValue);
        for (UILabel *label in @[name, time]) {
            label.adjustsFontSizeToFitWidth = YES;
            label.minimumScaleFactor = 0.7;
        }
        UIStackView *item = [[UIStackView alloc] initWithArrangedSubviews:@[name, time]];
        item.axis = UILayoutConstraintAxisVertical;
        item.spacing = 2;
        [_legend addArrangedSubview:item];
    }
    // One alone stays on the left.
    _legend.distribution = order.count > 1 ? UIStackViewDistributionEqualSpacing : UIStackViewDistributionFill;
    if (order.count == 1) {
        UIView *spacer = [UIView new];
        [spacer setContentHuggingPriority:UILayoutPriorityDefaultLow - 1 forAxis:UILayoutConstraintAxisHorizontal];
        [_legend addArrangedSubview:spacer];
    }
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

static const CGFloat kNLUsageIconSide = 30;
static const CGFloat kNLUsageTimeRoom = 76;   // after the longest bar, for its time

@implementation NLUsageCell {
    UIImageView *_coverView;
    UILabel *_nameLabel, *_timeLabel;
    UIView *_bar;
    UILayoutGuide *_track;           // the room the bars share: the longest fills it
    NSLayoutConstraint *_barWidth;
}

// As Screen Time's rows: the icon, the name, and under it a bar as long as
// its share (in its app's color) with the time right after it.
- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) return nil;
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    _coverView = [UIImageView new];
    _nameLabel = NLCardLabel(UIFontTextStyleBody, NO, UIColor.labelColor);
    _timeLabel = NLCardLabel(UIFontTextStyleSubheadline, NO, UIColor.secondaryLabelColor);
    _bar = [UIView new];
    _bar.layer.cornerRadius = 2;
    _track = [UILayoutGuide new];
    [self.contentView addLayoutGuide:_track];
    for (UIView *view in @[_coverView, _nameLabel, _timeLabel, _bar]) {
        view.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:view];
    }
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    _barWidth = [_bar.widthAnchor constraintEqualToAnchor:_track.widthAnchor];
    _barWidth.priority = UILayoutPriorityRequired - 1;   // a tiny share is still a dot
    [NSLayoutConstraint activateConstraints:@[
        [_coverView.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [_coverView.centerYAnchor constraintEqualToAnchor:self.contentView.centerYAnchor],
        [_coverView.widthAnchor constraintEqualToConstant:kNLUsageIconSide],
        [_coverView.heightAnchor constraintEqualToConstant:kNLUsageIconSide],
        [_nameLabel.leadingAnchor constraintEqualToAnchor:_coverView.trailingAnchor constant:14],
        [_nameLabel.topAnchor constraintEqualToAnchor:margins.topAnchor],
        [_nameLabel.trailingAnchor constraintLessThanOrEqualToAnchor:margins.trailingAnchor],
        [_track.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_track.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor constant:-kNLUsageTimeRoom],
        [_bar.leadingAnchor constraintEqualToAnchor:_nameLabel.leadingAnchor],
        [_bar.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:9],
        [_bar.heightAnchor constraintEqualToConstant:4],
        [_bar.widthAnchor constraintGreaterThanOrEqualToConstant:4],
        _barWidth,
        [_bar.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor constant:-5],
        [_timeLabel.leadingAnchor constraintEqualToAnchor:_bar.trailingAnchor constant:8],
        [_timeLabel.centerYAnchor constraintEqualToAnchor:_bar.centerYAnchor],
        [_timeLabel.trailingAnchor constraintLessThanOrEqualToAnchor:margins.trailingAnchor],
    ]];
    return self;
}

- (void)showUsage:(NLUsage *)usage fraction:(CGFloat)fraction color:(UIColor *)color {
    _bar.backgroundColor = color ?: UIColor.systemGrayColor;
    _coverView.image = usage.kind == NLUsageKindApps ? NLHistoryAppIcon(usage.key, kNLUsageIconSide) : NLHistoryCover(usage.item.art, kNLUsageIconSide);
    _nameLabel.text = usage.name;
    _timeLabel.text = NLHistoryDuration(usage.duration);
    _barWidth.active = NO;
    _barWidth = [_bar.widthAnchor constraintEqualToAnchor:_track.widthAnchor multiplier:MIN(MAX(fraction, 0.001), 1)];
    _barWidth.priority = UILayoutPriorityRequired - 1;
    _barWidth.active = YES;
}

@end

#pragma mark - Pager

@interface NLActivityPageCell : UICollectionViewCell
@property (nonatomic, strong) UIView *content;   // the page's chart, ours or Screen Time's
@end

@implementation NLActivityPageCell

- (void)setContent:(UIView *)content {
    [_content removeFromSuperview];
    _content = content;
    if (content) [self.contentView addSubview:content];
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _content.frame = self.contentView.bounds;
}

@end

// The chart, a page per week or day, a page the full width; it stays on its page when resized.
@interface NLPagerView : UICollectionView
@property (nonatomic) NSInteger page;
- (void)scrollToPage:(NSInteger)page;
- (void)reloadShowingPage:(NSInteger)page;
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
    if (resized) [self setContentOffset:CGPointMake(self.page * size.width, 0) animated:NO];
}

// Not animated: that also stops one under way.
- (void)scrollToPage:(NSInteger)page {
    self.page = page;
    CGFloat width = self.bounds.size.width;
    if (width <= 0) return;   // laid out later, onto this page
    [self layoutIfNeeded];
    [self setContentOffset:CGPointMake(page * width, 0) animated:NO];
}

// Fewer pages than before leave the offset past their end, and the scroll
// view eases it back to the last one, past the page asked for: it goes there
// first.
- (void)reloadShowingPage:(NSInteger)page {
    CGFloat width = self.bounds.size.width;
    if (width > 0) [self setContentOffset:CGPointMake(MIN(self.contentOffset.x, page * width), 0) animated:NO];
    [self reloadData];
    [self scrollToPage:page];
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

// Screen Time's own bar is a little taller.
+ (CGFloat)height {
    static CGFloat height;
    if (!height) {
        height = kNLDateBarHeight;
        if (NLScreenTimeDateBarAvailable()) {
            UILabel *label;
            UIButton *previous, *next;
            UIView *bar = NLScreenTimeMakeDateBar(&label, &previous, &next);
            height = ceil([bar systemLayoutSizeFittingSize:CGSizeMake(393, 0) withHorizontalFittingPriority:UILayoutPriorityRequired
                                   verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height);
        }
    }
    return height;
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
        [bar.heightAnchor constraintEqualToConstant:[self height]],
    ]];
    return bar;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.hidden = YES;
    self.alpha = 0;
    // Screen Time's own where this iOS has it: its material, date, arrows and line.
    if (NLScreenTimeDateBarAvailable()) {
        UILabel *label;
        UIButton *previous, *next;
        UIView *bar = NLScreenTimeMakeDateBar(&label, &previous, &next);
        _titleLabel = label;
        _previousButton = previous;
        _nextButton = next;
        bar.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:bar];
        [NSLayoutConstraint activateConstraints:@[
            [bar.topAnchor constraintEqualToAnchor:self.topAnchor],
            [bar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
            [bar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [bar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        ]];
        return self;
    }
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
    // The page's navigation bar keeps its material (and its line, as Screen
    // Time's) even at the top while this one shows under it.
    UINavigationBarAppearance *appearance = nil;
    if (shown) {
        appearance = [UINavigationBarAppearance new];
        [appearance configureWithDefaultBackground];
    }
    UINavigationItem *item = _page.navigationItem;
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
    NSMutableDictionary<NSDate *, NLActivityPeriod *> *_weekPeriods;    // a day's week, for the chart above its hours
    BOOL _screenTime;                                               // Screen Time's own charts
    NLPagerView *_headPager;                                        // a day's week above its hours, a page a week, paging on its own
    NSDate *_headFirstStart;                                        // its page 0's week
    NSInteger _headPageCount;
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
    BOOL _showsTotal;                                               // the week's total under the card: a week, no day picked
    NSTimeInterval _total;
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
        _weekPeriods = [NSMutableDictionary dictionary];
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
    // In line with the cards' content, as Screen Time's.
    [NSLayoutConstraint activateConstraints:@[
        [_scaleControl.leadingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.leadingAnchor constant:16],
        [_scaleControl.trailingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.trailingAnchor constant:-16],
        [_scaleControl.centerYAnchor constraintEqualToAnchor:header.centerYAnchor constant:4],
    ]];
    _table.tableHeaderView = header;

    // The chart pages; on a day, its week above it pages on its own.
    _screenTime = NLScreenTimeChartsAvailable();
    _pager = [self nlMakePager];
    _headPager = [self nlMakePager];
    _cardCell = [[NLActivityCardCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    _cardCell.selectionStyle = UITableViewCellSelectionStyleNone;
    _cardCell.chartView = _pager;

    // Once Week | Day has scrolled away, what the chart shows stays on top
    // with buttons to the one before and after, as Screen Time's.
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

- (NLPagerView *)nlMakePager {
    UICollectionViewFlowLayout *layout = [UICollectionViewFlowLayout new];
    layout.scrollDirection = UICollectionViewScrollDirectionHorizontal;
    layout.minimumLineSpacing = 0;
    layout.minimumInteritemSpacing = 0;
    layout.estimatedItemSize = CGSizeZero;
    NLPagerView *pager = [[NLPagerView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
    pager.pagingEnabled = YES;
    pager.showsHorizontalScrollIndicator = NO;
    pager.backgroundColor = UIColor.clearColor;
    pager.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    pager.dataSource = self;
    pager.delegate = self;
    [pager registerClass:[NLActivityPageCell class] forCellWithReuseIdentifier:@"page"];
    return pager;
}

- (NSInteger)nlWeeksFrom:(NSDate *)start to:(NSDate *)date {
    NSDate *week = [NLActivityPeriod startOfPeriodWithScale:NLActivityScaleWeek containingDate:date];
    return [NSCalendar.currentCalendar components:NSCalendarUnitWeekOfYear fromDate:start toDate:week options:0].weekOfYear;
}

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
    [_weekPeriods removeAllObjects];
    BOOL day = _scale == NLActivityScaleDay;
    _cardCell.headChartView = day ? _headPager : nil;
    if (day) {
        _headFirstStart = [NLActivityPeriod startOfPeriodWithScale:NLActivityScaleWeek containingDate:_firstStart];
        _headPageCount = [self nlWeeksFrom:_headFirstStart to:[NSDate date]] + 1;
        _headPager.page = MIN(MAX([self nlWeeksFrom:_headFirstStart to:target], 0), _headPageCount - 1);
    }
    _cardCell.headChartHeight = !day ? 0 : _screenTime ? [NLScreenTimeChartView heightTitled:YES] : kNLWeekChartHeight;
    _cardCell.chartHeight = _screenTime ? [NLScreenTimeChartView heightTitled:!day] : kNLWeekChartHeight;
    _selectedBar = bar >= 0 && bar < (NSInteger)[self nlPeriodAtPage:_pager.page].bars.count ? bar : NSNotFound;
    [_pager reloadShowingPage:_pager.page];
    if (day) [_headPager reloadShowingPage:_headPager.page];
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
        // week → day: today in this week, a past week's last day.
        NSDate *now = [NSDate date];
        date = [period.end compare:now] == NSOrderedDescending ? now : [period.end dateByAddingTimeInterval:-1];
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

    // A week: its daily average (the period named unless it is this one)
    // against the week before's, and its total in a row under the card.
    if (bar) {
        [_cardCell showTitle:_rangeTitle value:NLHistoryDuration(bar.total) trend:nil rising:NO durations:bar.durations apps:_apps];
    } else if (_scale == NLActivityScaleWeek) {
        BOOL rising = NO;
        NSString *trend = _pager.page > 0 ? NLActivityTrend(period, [self nlPeriodAtPage:_pager.page - 1], &rising) : nil;
        [_cardCell showTitle:[self nlAverageTitleAtPage:_pager.page] value:NLHistoryDuration(period.dailyAverage) trend:trend rising:rising
                   durations:period.durations apps:_apps];
    } else {
        [_cardCell showTitle:_rangeTitle value:NLHistoryDuration(period.total) trend:nil rising:NO durations:period.durations apps:_apps];
    }
    if (_scale == NLActivityScaleDay) [self nlSyncHeadPager];
    BOOL hadTotal = _showsTotal;
    _showsTotal = _scale == NLActivityScaleWeek && !bar;
    _total = period.total;

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
    _timelineDay = _scale == NLActivityScaleDay ? NLHistoryDayKey(period.start) : nil;
    NSMutableArray<NSNumber *> *listening = [NSMutableArray arrayWithArray:@[@(NLListeningRowPlays), @(NLListeningRowSongs), @(NLListeningRowArtists)]];
    if (_showsSkipped) [listening addObject:@(NLListeningRowSkipped)];
    if (_timelineDay) [listening addObject:@(NLListeningRowTimeline)];
    _listening = listening;
    [self nlUpdateDateBar];

    // Off screen, or the first load (the table has no sections yet to reload): all of it.
    if (!_table.window || _table.numberOfSections != NLActivitySectionCount) {
        [_table reloadData];
    } else {
        BOOL showsTotal = _showsTotal;
        NSArray<NSIndexPath *> *total = @[[NSIndexPath indexPathForRow:1 inSection:NLActivitySectionChart]];
        [UIView performWithoutAnimation:^{
            [self->_table beginUpdates];
            if (hadTotal && showsTotal) [self->_table reloadRowsAtIndexPaths:total withRowAnimation:UITableViewRowAnimationNone];
            else if (hadTotal) [self->_table deleteRowsAtIndexPaths:total withRowAnimation:UITableViewRowAnimationNone];
            else if (showsTotal) [self->_table insertRowsAtIndexPaths:total withRowAnimation:UITableViewRowAnimationNone];
            [self->_table reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(NLActivitySectionUsages, 2)]
                        withRowAnimation:UITableViewRowAnimationNone];
            [self->_table endUpdates];
        }];
    }
    [self nlUpdateDateBarShown];
}

// A tap on a page's chart (ours): a day on a week opens it; an hour on a day
// narrows the card and the lists to it.
- (void)nlSelectBar:(NSInteger)index onPage:(NSInteger)page {
    if (page != _pager.page) return;
    if (_scale == NLActivityScaleWeek && index != NSNotFound) {
        [self nlTapDay:[self nlPeriodAtPage:page].bars[index].start];
        return;
    }
    _selectedBar = index;
    [self nlUpdateContent];
}

// A day tapped on a week, as Screen Time's: it opens; the day shown, tapped
// again on the week above it, goes back to its week.
- (void)nlTapDay:(NSDate *)day {
    if (_scale == NLActivityScaleDay && [[NSCalendar.currentCalendar startOfDayForDate:day] isEqualToDate:[self nlPeriodAtPage:_pager.page].start]) {
        _scale = NLActivityScaleWeek;
        _scaleControl.selectedSegmentIndex = _scale;
        [self nlReloadPagesShowingDate:day selectedBar:NSNotFound];
        return;
    }
    [self nlOpenDay:day];
}

// A day opened (Day); one before the first day with plays leaves it as it was.
- (void)nlOpenDay:(NSDate *)day {
    if (_scale == NLActivityScaleWeek) {
        _scale = NLActivityScaleDay;
        _scaleControl.selectedSegmentIndex = _scale;
        [self nlReloadPagesShowingDate:day selectedBar:NSNotFound];
        return;
    }
    NSInteger page = [self nlPagesFrom:_firstStart to:[NSCalendar.currentCalendar startOfDayForDate:day]];
    if (page < 0 || page >= _pageCount || page == _pager.page) {
        [self nlConfigureVisibleHeadPages];   // ours marked the one tapped
        return;
    }
    [_pager scrollToPage:page];
    _selectedBar = NSNotFound;
    [self nlConfigureVisiblePages];
    [self nlUpdateContent];
}

// The week pager follows the day shown: onto its week, that day picked.
- (void)nlSyncHeadPager {
    NSInteger page = MIN(MAX([self nlWeeksFrom:_headFirstStart to:[self nlPeriodAtPage:_pager.page].start], 0), _headPageCount - 1);
    if (page != _headPager.page) [_headPager scrollToPage:page];
    [self nlConfigureVisibleHeadPages];
}

// The day picked on a week above the hours: the one shown if it is in it,
// else the same weekday there, kept within the days that have pages.
- (NSDate *)nlDayPickedInWeek:(NLActivityPeriod *)week {
    NSDate *shown = [self nlPeriodAtPage:_pager.page].start;
    if ([shown compare:week.start] != NSOrderedAscending && [shown compare:week.end] == NSOrderedAscending) return shown;
    NSCalendar *calendar = NSCalendar.currentCalendar;
    NSDate *shownWeek = [NLActivityPeriod startOfPeriodWithScale:NLActivityScaleWeek containingDate:shown];
    NSInteger weekday = [calendar components:NSCalendarUnitDay fromDate:shownWeek toDate:shown options:0].day;
    NSDate *day = [calendar dateByAddingUnit:NSCalendarUnitDay value:weekday toDate:week.start options:0];
    NSDate *today = [calendar startOfDayForDate:[NSDate date]];
    return [[day laterDate:_firstStart] earlierDate:today];
}

// A page of the week pager: its week with the day picked in its colors (and,
// Screen Time's, that day's title and time); a day tapped there opens it.
- (void)nlConfigureHeadPage:(NLActivityPageCell *)cell at:(NSInteger)page {
    NSDate *start = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitWeekOfYear value:page toDate:_headFirstStart options:0];
    NLActivityPeriod *week = [self nlWeekAroundDay:start];
    NSDate *day = [self nlDayPickedInWeek:week];
    NSUInteger index = [week.bars indexOfObjectPassingTest:^BOOL(NLActivityBar *bar, NSUInteger i, BOOL *stop) {
        return [bar.start isEqualToDate:day];
    }];
    __weak NLHistoryActivityController *weakSelf = self;
    if (_screenTime) {
        NLScreenTimeChartView *chart = (NLScreenTimeChartView *)cell.content;
        if (![chart isKindOfClass:NLScreenTimeChartView.class]) cell.content = chart = [[NLScreenTimeChartView alloc] initTitled:YES];
        NSTimeInterval total = index != NSNotFound ? week.bars[index].total : 0;
        [chart showPeriod:week selectedDay:day title:NLHistoryDayTitle(day) value:NLHistoryDuration(total) trend:nil rising:NO];
        chart.didTapDay = ^(NSDate *tapped) { [weakSelf nlTapDay:tapped]; };
        return;
    }
    NLActivityChartView *chart = (NLActivityChartView *)cell.content;
    if (![chart isKindOfClass:NLActivityChartView.class]) cell.content = chart = [NLActivityChartView new];
    chart.period = week;
    chart.selectedIndex = NSNotFound;
    chart.contextIndex = index;
    chart.didSelectBar = ^(NSInteger tapped) {
        if (tapped >= 0 && tapped < (NSInteger)week.bars.count) [weakSelf nlTapDay:week.bars[tapped].start];
        else [weakSelf nlConfigureVisibleHeadPages];
    };
}

- (void)nlConfigureVisibleHeadPages {
    for (NSIndexPath *indexPath in _headPager.indexPathsForVisibleItems) {
        [self nlConfigureHeadPage:(NLActivityPageCell *)[_headPager cellForItemAtIndexPath:indexPath] at:indexPath.item];
    }
}

// The week pager let go on another week: the same weekday there.
- (void)nlHeadPagerDidSettle {
    CGFloat width = _headPager.bounds.size.width;
    if (width <= 0 || _headPageCount <= 0) return;
    NSInteger page = MIN(MAX((NSInteger)lround(_headPager.contentOffset.x / width), 0), _headPageCount - 1);
    if (page == _headPager.page) return;
    _headPager.page = page;
    NSDate *start = [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitWeekOfYear value:page toDate:_headFirstStart options:0];
    [self nlOpenDay:[self nlDayPickedInWeek:[self nlWeekAroundDay:start]]];
}

// "Daily Average", the week named unless it is this one.
- (NSString *)nlAverageTitleAtPage:(NSInteger)page {
    NSString *average = NLL(@"Daily Average");
    return page == _pageCount - 1 ? average : [NSString stringWithFormat:@"%@ · %@", [self nlPeriodAtPage:page].title, average];
}

// A page's chart. Ours: its period, the bar picked on the page shown. Screen
// Time's: a week titled with its daily average and trend, a day's hours
// untitled (the week above carries its title).
- (void)nlConfigurePage:(NLActivityPageCell *)cell at:(NSInteger)page {
    NLActivityPeriod *period = [self nlPeriodAtPage:page];
    __weak NLHistoryActivityController *weakSelf = self;
    if (_screenTime) {
        BOOL week = _scale == NLActivityScaleWeek;
        NLScreenTimeChartView *chart = (NLScreenTimeChartView *)cell.content;
        if (![chart isKindOfClass:NLScreenTimeChartView.class] || chart.titled != week) cell.content = chart = [[NLScreenTimeChartView alloc] initTitled:week];
        if (week) {
            BOOL rising = NO;
            NSString *trend = page > 0 ? NLActivityTrend(period, [self nlPeriodAtPage:page - 1], &rising) : nil;
            [chart showPeriod:period selectedDay:nil title:[self nlAverageTitleAtPage:page] value:NLHistoryDuration(period.dailyAverage)
                        trend:trend rising:rising];
            chart.didTapDay = ^(NSDate *day) { [weakSelf nlTapDay:day]; };
        } else {
            [chart showPeriod:period selectedDay:nil title:nil value:nil trend:nil rising:NO];
            chart.didTapDay = nil;
        }
        return;
    }
    NLActivityChartView *chart = (NLActivityChartView *)cell.content;
    if (![chart isKindOfClass:NLActivityChartView.class]) cell.content = chart = [NLActivityChartView new];
    chart.period = period;
    chart.selectedIndex = page == _pager.page ? _selectedBar : NSNotFound;
    chart.didSelectBar = ^(NSInteger index) { [weakSelf nlSelectBar:index onPage:page]; };
}

- (void)nlConfigureVisiblePages {
    for (NSIndexPath *indexPath in _pager.indexPathsForVisibleItems) {
        [self nlConfigurePage:(NLActivityPageCell *)[_pager cellForItemAtIndexPath:indexPath] at:indexPath.item];
    }
}

- (NLActivityPeriod *)nlWeekAroundDay:(NSDate *)day {
    NSDate *start = [NLActivityPeriod startOfPeriodWithScale:NLActivityScaleWeek containingDate:day];
    NLActivityPeriod *week = _weekPeriods[start];
    if (!week) {
        week = [NLActivityPeriod periodWithScale:NLActivityScaleWeek containingDate:start items:_items ?: @[] apps:_apps];
        _weekPeriods[start] = week;
    }
    return week;
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

// Shown once Week | Day has gone up under the navigation bar, as Screen Time's.
- (void)nlUpdateDateBarShown {
    UIView *header = _table.tableHeaderView;
    BOOL shown = _loaded && header && CGRectGetMaxY(header.frame) <= _table.contentOffset.y + _table.adjustedContentInset.top;
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
        [self nlConfigureVisiblePages];
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
    if (collectionView == _headPager) return _loaded && _scale == NLActivityScaleDay ? _headPageCount : 0;
    return _loaded ? _pageCount : 0;
}

- (UICollectionViewCell *)collectionView:(UICollectionView *)collectionView cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    NLActivityPageCell *cell = [collectionView dequeueReusableCellWithReuseIdentifier:@"page" forIndexPath:indexPath];
    if (collectionView == _headPager) [self nlConfigureHeadPage:cell at:indexPath.item];
    else [self nlConfigurePage:cell at:indexPath.item];
    return cell;
}

// The table calls these too (both are scroll views).
- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    if (scrollView == _table) [self nlUpdateDateBarShown];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    if (scrollView == _pager) [self nlPagerDidSettle];
    else if (scrollView == _headPager) [self nlHeadPagerDidSettle];
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    if (decelerate) return;
    if (scrollView == _pager) [self nlPagerDidSettle];
    else if (scrollView == _headPager) [self nlHeadPagerDidSettle];
}

- (void)nlPagerDidSettle {
    CGFloat width = _pager.bounds.size.width;
    if (width <= 0) return;
    NSInteger page = MIN(MAX((NSInteger)lround(_pager.contentOffset.x / width), 0), _pageCount - 1);
    if (page == _pager.page) return;
    _pager.page = page;
    _selectedBar = NSNotFound;
    [self nlConfigureVisiblePages];
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
        case NLActivitySectionChart: return _showsTotal ? 2 : 1;
        case NLActivitySectionUsages: return MAX([self nlShownUsageCount], 1) + ([self nlCanExpandUsages] ? 1 : 0);
        default: return (NSInteger)_listening.count;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case NLActivitySectionChart: return NLL(@"Listening Time");
        case NLActivitySectionListening: return NLL(@"Listening");
        default: return nil;
    }
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
    if (indexPath.section == NLActivitySectionChart && indexPath.row == 0) return _cardCell;
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
    if (indexPath.section == NLActivitySectionChart) {
        content = [UIListContentConfiguration valueCellConfiguration];
        content.text = NLL(@"Total Listening Time");
        content.secondaryText = NLHistoryDuration(_total);
    } else if (indexPath.section == NLActivitySectionUsages) {
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
