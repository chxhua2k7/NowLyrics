//
//  NLHistoryActivity.m
//  Screen Time's charts for the listening history (the first page's This
//  Week card and All Activity share them), by app instead of by category:
//  - NLHistoryApps: the apps told apart, each with its color, the rest as Other Apps
//  - NLActivityPeriod: a week (a bar a day) or a day (a bar an hour), each bar
//    the time listened per app; a play across an edge counts the part inside
//  - NLActivityChartView: stacked bars, the scale on the right, weekdays or
//    hours under them, the week's average dashed; a tap selects a bar
//  - NLActivityCardCell, NLUsageCell: the card and Most Played's rows
//  - NLHistoryActivityController: All Activity. Week | Day on top; the chart
//    pages back to the first week or day with plays; a tapped bar narrows the
//    card and the lists to it. Most Played (to the song's page), what was
//    listened to, and for one day its timeline.
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
    NSDateIntervalFormatter *formatter = NLHistoryFormatter(@"hour", ^id {
        NSDateIntervalFormatter *made = [NSDateIntervalFormatter new];
        made.dateStyle = NSDateIntervalFormatterNoStyle;
        made.timeStyle = NSDateIntervalFormatterShortStyle;
        return made;
    });
    return [NSString stringWithFormat:@"%@ %@", NLHistoryDayTitle(bar.start), [formatter stringFromDate:bar.start toDate:bar.end]];
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

@implementation NLActivityChartView {
    UITapGestureRecognizer *_tap;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.opaque = NO;
    self.backgroundColor = UIColor.clearColor;
    self.contentMode = UIViewContentModeRedraw;
    _selectedIndex = NSNotFound;
    _tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(nlTapped:)];
    _tap.enabled = NO;   // the first page's card opens All Activity instead
    [self addGestureRecognizer:_tap];
    return self;
}

- (void)setPeriod:(NLActivityPeriod *)period {
    _period = period;
    [self setNeedsDisplay];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
    _selectedIndex = selectedIndex;
    [self setNeedsDisplay];
}

- (void)setDidSelectBar:(void (^)(NSInteger))didSelectBar {
    _didSelectBar = [didSelectBar copy];
    _tap.enabled = didSelectBar != nil;
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
        BOOL selected = (NSInteger)i == self.selectedIndex;
        CGFloat x = CGRectGetMinX(chart) + column * i + (column - barWidth) / 2;
        CGFloat height = MIN(bar.total / maximum, 1) * chart.size.height;
        if (height >= 0.5) {
            CGContextSaveGState(context);
            if (self.selectedIndex != NSNotFound && !selected) CGContextSetAlpha(context, 0.3);
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

@end

#pragma mark - Card

static UILabel *NLCardLabel(UIFontTextStyle style, BOOL bold, UIColor *color) {
    UILabel *label = [UILabel new];
    UIFontDescriptor *descriptor = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    if (bold) descriptor = [descriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    label.font = [UIFont fontWithDescriptor:descriptor size:0];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = color;
    return label;
}

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

@implementation NLSongUsage
@end

NSArray<NLSongUsage *> *NLSongUsages(NSArray<NLHistoryItem *> *items, NSDate *start, NSDate *end) {
    NSMutableArray<NLSongUsage *> *usages = [NSMutableArray array];
    NSMutableDictionary<NSString *, NLSongUsage *> *bySong = [NSMutableDictionary dictionary];
    for (NLHistoryItem *item in items) {   // newest first: each song keeps its latest play
        NSTimeInterval duration = [item listenedFrom:start to:end];
        if (duration <= 0) continue;
        NSString *song = item.key.length ? item.key : [NSString stringWithFormat:@"%@|%@", item.title, item.artist ?: @""];
        NLSongUsage *usage = bySong[song];
        if (!usage) {
            usage = [NLSongUsage new];
            usage.item = item;
            bySong[song] = usage;
            [usages addObject:usage];
        }
        usage.duration += duration;
        usage.plays++;
    }
    [usages sortUsingComparator:^NSComparisonResult(NLSongUsage *a, NLSongUsage *b) {
        if (a.duration != b.duration) return a.duration > b.duration ? NSOrderedAscending : NSOrderedDescending;
        return [a.item.title localizedStandardCompare:b.item.title];
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

- (void)showUsage:(NLSongUsage *)usage fraction:(CGFloat)fraction color:(UIColor *)color {
    _coverView.image = NLHistoryCover(usage.item.art, 34);
    _nameLabel.text = usage.item.title;
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

#pragma mark - All Activity

typedef NS_ENUM(NSInteger, NLActivitySection) {
    NLActivitySectionChart,
    NLActivitySectionSongs,
    NLActivitySectionListening,
    NLActivitySectionCount,
};

typedef NS_ENUM(NSInteger, NLListeningRow) {
    NLListeningRowPlays,
    NLListeningRowSongs,
    NLListeningRowArtists,
    NLListeningRowTimeline,   // one day only
};

static const NSUInteger kNLCollapsedSongs = 5;

@interface NLHistoryActivityController () <UITableViewDataSource, UITableViewDelegate, UICollectionViewDataSource, UICollectionViewDelegate>
@end

@implementation NLHistoryActivityController {
    UITableView *_table;
    NLActivityScale _scale;
    NSDate *_initialDate;
    NSArray<NLHistoryItem *> *_items;                               // every play, newest first
    NLHistoryApps *_apps;
    NSDate *_firstStart;                                            // page 0's start
    NSInteger _pageCount;
    NSMutableDictionary<NSNumber *, NLActivityPeriod *> *_periods;
    NSInteger _selectedBar;
    UISegmentedControl *_scaleControl;
    NLActivityCardCell *_cardCell;
    NLPagerView *_pager;
    NSArray<NLSongUsage *> *_usages;
    BOOL _showAllSongs;
    NSUInteger _playCount, _artistCount;
    NSString *_timelineDay;                                         // the day shown or picked, else nil
    BOOL _loaded;
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

    NLHistoryObserve(self, @selector(nlLoad));
    [self nlLoad];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_loaded) [self nlLoad];   // back from a song or a day: plays may be gone
}

- (void)nlLoad {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NLHistoryItem *> *items = NLHistoryLoadAll();
        NLHistoryApps *apps = [NLHistoryApps appsForItems:items];
        dispatch_async(dispatch_get_main_queue(), ^{
            // Loaded again (SpringBoard writes each minute while a song
            // plays): the same page, with the bar picked still picked.
            BOOL again = self->_loaded;
            NSDate *showing = again ? [self nlPeriodAtPage:self->_pager.page].start : self->_initialDate;
            self->_items = items;
            self->_apps = apps;
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

    if (bar) {
        [_cardCell showTitle:[period titleForBarAtIndex:_selectedBar] caption:nil value:NLHistoryDuration(bar.total)
                   durations:bar.durations apps:_apps];
    } else if (_scale == NLActivityScaleWeek) {
        [_cardCell showTitle:period.title caption:NLL(@"Daily Average") value:NLHistoryDuration(period.dailyAverage)
                   durations:period.durations apps:_apps];
    } else {
        [_cardCell showTitle:period.title caption:nil value:NLHistoryDuration(period.total) durations:period.durations apps:_apps];
    }

    _usages = NLSongUsages(period.items, start, end);
    NSUInteger plays = 0;
    NSMutableSet<NSString *> *artists = [NSMutableSet set];
    for (NLHistoryItem *item in period.items) {
        if ([item.start compare:start] == NSOrderedAscending || [item.start compare:end] != NSOrderedAscending) continue;
        plays++;
        if (item.artist.length) [artists addObject:item.artist];
    }
    _playCount = plays;
    _artistCount = artists.count;
    NSDate *day = _scale == NLActivityScaleDay ? period.start : (bar ? bar.start : nil);
    _timelineDay = day ? NLHistoryDayKey(day) : nil;

    // Off screen, or the first load (the table has no sections yet to reload): all of it.
    if (!_table.window || _table.numberOfSections != NLActivitySectionCount) {
        [_table reloadData];
        return;
    }
    [UIView performWithoutAnimation:^{
        [self->_table beginUpdates];
        [self->_table reloadSections:[NSIndexSet indexSetWithIndexesInRange:NSMakeRange(NLActivitySectionSongs, 2)]
                    withRowAnimation:UITableViewRowAnimationNone];
        [self->_table endUpdates];
    }];
}

- (void)nlSelectBar:(NSInteger)index onPage:(NSInteger)page {
    if (page != _pager.page) return;
    _selectedBar = index;
    [self nlUpdateContent];
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

// The table calls these too (both are scroll views): the chart's only.
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
    NSInteger previousPage = _pager.page;
    _pager.page = page;
    if (page == previousPage) return;
    NLActivityPageCell *previous = (NLActivityPageCell *)[_pager cellForItemAtIndexPath:[NSIndexPath indexPathForItem:previousPage inSection:0]];
    previous.chartView.selectedIndex = NSNotFound;
    _selectedBar = NSNotFound;
    [self nlUpdateContent];
}

#pragma mark Table

- (NSUInteger)nlShownSongCount {
    return _showAllSongs ? _usages.count : MIN(_usages.count, kNLCollapsedSongs);
}

- (BOOL)nlCanExpandSongs {
    return _usages.count > kNLCollapsedSongs;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _loaded ? NLActivitySectionCount : 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case NLActivitySectionChart: return 1;
        case NLActivitySectionSongs: return MAX([self nlShownSongCount], 1) + ([self nlCanExpandSongs] ? 1 : 0);
        default: return _timelineDay ? NLListeningRowTimeline + 1 : NLListeningRowTimeline;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch (section) {
        case NLActivitySectionSongs: return NLL(@"Most Played");
        case NLActivitySectionListening: return NLL(@"Listening");
        default: return nil;
    }
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if (indexPath.section == NLActivitySectionChart) return _cardCell;
    if (indexPath.section == NLActivitySectionSongs && indexPath.row < (NSInteger)[self nlShownSongCount]) {
        NLUsageCell *cell = [tableView dequeueReusableCellWithIdentifier:@"usage" forIndexPath:indexPath];
        NLSongUsage *usage = _usages[indexPath.row];
        NSTimeInterval longest = _usages.firstObject.duration;
        [cell showUsage:usage fraction:longest > 0 ? usage.duration / longest : 0
                  color:[_apps colorForCategory:[_apps categoryForApp:usage.item.app]]];
        return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"cell" forIndexPath:indexPath];
    cell.accessoryType = UITableViewCellAccessoryNone;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    UIListContentConfiguration *content;
    if (indexPath.section == NLActivitySectionSongs) {
        content = [UIListContentConfiguration cellConfiguration];
        if (!_usages.count) {
            content.text = NLL(@"No Plays");
            content.textProperties.color = UIColor.secondaryLabelColor;
        } else {
            content.text = _showAllSongs ? NLL(@"Show Less") : NLL(@"Show More");
            content.textProperties.color = UIColor.tintColor;   // the theme's, when it changes too
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
        }
    } else if (indexPath.row == NLListeningRowTimeline) {
        content = [UIListContentConfiguration cellConfiguration];
        content.image = [UIImage systemImageNamed:@"list.bullet.rectangle"];
        content.text = NLL(@"Timeline");
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        content = [UIListContentConfiguration valueCellConfiguration];
        NSUInteger count = indexPath.row == NLListeningRowPlays ? _playCount : indexPath.row == NLListeningRowSongs ? _usages.count : _artistCount;
        content.text = NLL(indexPath.row == NLListeningRowPlays ? @"Plays" : indexPath.row == NLListeningRowSongs ? @"Songs" : @"Artists");
        content.secondaryText = [NSString localizedStringWithFormat:@"%lu", (unsigned long)count];
    }
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == NLActivitySectionSongs) {
        if (indexPath.row < (NSInteger)[self nlShownSongCount]) {
            NLHistoryPush(self, [[NLHistorySongController alloc] initWithItem:_usages[indexPath.row].item]);
        } else if ([self nlCanExpandSongs]) {
            _showAllSongs = !_showAllSongs;
            [tableView reloadSections:[NSIndexSet indexSetWithIndex:NLActivitySectionSongs] withRowAnimation:UITableViewRowAnimationAutomatic];
        }
    } else if (indexPath.section == NLActivitySectionListening && indexPath.row == NLListeningRowTimeline && _timelineDay) {
        NLHistoryPush(self, [[NLHistoryDayController alloc] initWithDay:_timelineDay]);
    }
}

@end
