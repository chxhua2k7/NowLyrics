//
//  NLScreenTime.m
//  Screen Time's own charts for the listening history (ScreenTimeSettingsUI,
//  there from iOS 16 to 26): the graph and the title above it
//  (STUsageGraphViewController, STUsageSummaryTitleView), its legend
//  (STHorizontallySegmentedView) and the date bar (STDatePickerBar). The
//  bars, the scale, the average and the green paddle a press brings up are
//  then Screen Time's to the pixel. Where an iOS lacks any of them, the pages
//  draw their own (NLActivityChartView).
//
//  The graph takes a data set: a point per day (a week) or per hour (a day),
//  each with a segment per app in its color.
//

#import "NLHistoryPages.h"
#import <dlfcn.h>

@protocol NLSTSegment <NSObject>
- (instancetype)initWithAmount:(NSNumber *)amount amountAsPercentageOfDataPointTotal:(double)share color:(UIColor *)color;
@end

@protocol NLSTDataPoint <NSObject>
- (instancetype)initWithTimePeriod:(NSUInteger)period itemType:(NSUInteger)type dateInterval:(NSDateInterval *)interval
                             total:(NSNumber *)total totalAsPercentageOfMax:(double)share segments:(NSArray *)segments;
@end

@protocol NLSTDataSet <NSObject>
- (instancetype)initWithTimePeriod:(NSUInteger)period itemType:(NSUInteger)type total:(NSNumber *)total max:(NSNumber *)max
                           average:(NSNumber *)average averageAsPercentageOfMax:(double)share dataPoints:(NSArray *)points;
@end

@protocol NLSTTitleView <NSObject>
- (instancetype)initWithVibrancy:(BOOL)vibrancy usageItemType:(NSUInteger)type truncateAverageLabel:(BOOL)truncate;
- (UILabel *)titleLabel;
- (UILabel *)usageLabel;
- (UILabel *)deltaAverageLabel;
- (UIImageView *)deltaAverageImageView;
- (NSLayoutConstraint *)deltaAverageImageViewWidthConstraint;
- (NSLayoutConstraint *)deltaAverageImageViewHeightConstraint;
- (NSLayoutConstraint *)deltaAverageImageViewVerticalPosition;   // its bottom on the label's first baseline
- (void)_setUpConstraints;
@end

@protocol NLSTGraph <NSObject>
- (instancetype)initWithTitleView:(UIView *)titleView graphHeight:(double)height includePaddle:(BOOL)paddle useVibrancy:(BOOL)vibrancy;
- (void)setDataSet:(id)dataSet animated:(BOOL)animated;
- (void)setSelectedWeekday:(NSInteger)weekday;
- (NSArray<UIView *> *)barViews;
@end

@protocol NLSTLegend <NSObject>
- (instancetype)initWithVibrancy:(BOOL)vibrancy maximumNumberOfLines:(NSUInteger)lines truncateLabels:(BOOL)truncate;
- (void)setSegmentItems:(NSArray *)items;
@end

@protocol NLSTSegmentItem <NSObject>
- (instancetype)initWithTitleText:(NSString *)title detailText:(NSString *)detail titleColor:(UIColor *)color
                      detailImage:(UIImage *)image detailImageTintColor:(UIColor *)tint;
@end

@protocol NLSTDatePickerBar <NSObject>
- (UILabel *)dateLabel;
- (UIButton *)leftArrowButton;
- (UIButton *)rightArrowButton;
@end

static const NSUInteger kNLSTWeek = 2, kNLSTDay = 1;   // the data sets' time periods: a point a day, a point an hour
static const NSUInteger kNLSTScreenTime = 1;            // the item type: time, as Screen Time's screen time
static const CGFloat kNLSTGraphHeight = 90;             // the bars' height, as Screen Time's cards

static Class NLSTClass(const char *name) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/ScreenTimeSettingsUI.framework/ScreenTimeSettingsUI", RTLD_NOW);
    });
    return objc_getClass(name);
}

static BOOL NLSTResponds(const char *name, NSArray<NSString *> *selectors) {
    Class cls = NLSTClass(name);
    if (!cls) return NO;
    for (NSString *selector in selectors) {
        if (![cls instancesRespondToSelector:NSSelectorFromString(selector)]) return NO;
    }
    return YES;
}

BOOL NLScreenTimeChartsAvailable(void) {
    return NL_ONCE(@(NLSTResponds("STUsageGraphViewController", @[@"initWithTitleView:graphHeight:includePaddle:useVibrancy:",
                                                                  @"setDataSet:animated:", @"setSelectedWeekday:", @"barViews"])
                    && NLSTResponds("STUsageSummaryTitleView", @[@"initWithVibrancy:usageItemType:truncateAverageLabel:", @"titleLabel",
                                                                 @"usageLabel", @"deltaAverageLabel", @"deltaAverageImageView",
                                                                 @"deltaAverageImageViewWidthConstraint", @"deltaAverageImageViewHeightConstraint",
                                                                 @"deltaAverageImageViewVerticalPosition", @"_setUpConstraints"])
                    && NLSTResponds("STUsageReportGraphDataSet", @[@"initWithTimePeriod:itemType:total:max:average:averageAsPercentageOfMax:dataPoints:"])
                    && NLSTResponds("STUsageReportGraphDataPoint", @[@"initWithTimePeriod:itemType:dateInterval:total:totalAsPercentageOfMax:segments:"])
                    && NLSTResponds("STUsageReportGraphSegment", @[@"initWithAmount:amountAsPercentageOfDataPointTotal:color:"])
                    && NLSTResponds("STHorizontallySegmentedView", @[@"initWithVibrancy:maximumNumberOfLines:truncateLabels:", @"setSegmentItems:"])
                    && NLSTResponds("STSegmentItem", @[@"initWithTitleText:detailText:titleColor:detailImage:detailImageTintColor:"]))).boolValue;
}

BOOL NLScreenTimeDateBarAvailable(void) {
    return NL_ONCE(@(NLSTResponds("STDatePickerBar", @[@"dateLabel", @"leftArrowButton", @"rightArrowButton"]))).boolValue;
}

#pragma mark - Data

// The scale's top, as Screen Time rounds it: a day's hour is 60 minutes; a
// week's tallest day goes up to an even number of hours, two at least (its
// scale is in whole hours, the middle line's too: under them it reads 0 hr).
static NSTimeInterval NLSTMaximum(NLActivityPeriod *period) {
    if (period.scale == NLActivityScaleDay) return 3600;
    double most = [[period.bars valueForKeyPath:@"@max.total"] doubleValue];
    return MAX(ceil(most / 7200), 1) * 7200;
}

static id NLSTDataSet(NLActivityPeriod *period) {
    NSUInteger timePeriod = period.scale == NLActivityScaleWeek ? kNLSTWeek : kNLSTDay;
    NSTimeInterval maximum = NLSTMaximum(period);
    NSMutableArray *points = [NSMutableArray arrayWithCapacity:period.bars.count];
    for (NLActivityBar *bar in period.bars) {
        NSMutableArray *segments = [NSMutableArray array];
        for (NSUInteger c = 0; c < bar.durations.count; c++) {
            double amount = bar.durations[c].doubleValue;
            if (amount <= 0) continue;
            [segments addObject:[(id<NLSTSegment>)[NLSTClass("STUsageReportGraphSegment") alloc] initWithAmount:@(amount)
                                     amountAsPercentageOfDataPointTotal:bar.total > 0 ? amount / bar.total : 0 color:[period.apps colorForCategory:c]]];
        }
        NSDateInterval *interval = [[NSDateInterval alloc] initWithStartDate:bar.start endDate:bar.end];
        [points addObject:[(id<NLSTDataPoint>)[NLSTClass("STUsageReportGraphDataPoint") alloc] initWithTimePeriod:timePeriod itemType:kNLSTScreenTime
                              dateInterval:interval total:@(bar.total) totalAsPercentageOfMax:MIN(bar.total / maximum, 1) segments:segments]];
    }
    double average = period.scale == NLActivityScaleWeek ? period.dailyAverage : 0;
    return [(id<NLSTDataSet>)[NLSTClass("STUsageReportGraphDataSet") alloc] initWithTimePeriod:timePeriod itemType:kNLSTScreenTime
               total:@(period.total) max:@(maximum) average:@(average) averageAsPercentageOfMax:MIN(average / maximum, 1) dataPoints:points];
}

#pragma mark - Title

static UIView<NLSTTitleView> *NLSTMakeTitle(void) {
    UIView<NLSTTitleView> *title = (UIView<NLSTTitleView> *)[(id<NLSTTitleView>)[NLSTClass("STUsageSummaryTitleView") alloc] initWithVibrancy:NO
                                                                     usageItemType:kNLSTScreenTime truncateAverageLabel:NO];
    title.translatesAutoresizingMaskIntoConstraints = NO;   // the graph places it with constraints
    return title;
}

// Its labels set straight, as a usage report would; the trend's arrow in a
// grey circle sized as Screen Time sizes it, none without one.
static void NLSTShowTitle(UIView<NLSTTitleView> *view, NSString *title, NSString *value, NSString *trend, BOOL rising) {
    view.titleLabel.text = title;
    view.usageLabel.text = value;
    UILabel *delta = view.deltaAverageLabel;
    UIImage *arrow = trend ? [UIImage systemImageNamed:rising ? @"arrow.up.circle.fill" : @"arrow.down.circle.fill"
                                     withConfiguration:[UIImageSymbolConfiguration configurationWithFont:delta.font]] : nil;
    // The arrow sits at the label's start: the words begin after it.
    NSMutableParagraphStyle *indent = [NSMutableParagraphStyle new];
    indent.firstLineHeadIndent = arrow.size.width + 4;
    delta.attributedText = trend ? [[NSAttributedString alloc] initWithString:trend attributes:@{NSFontAttributeName: delta.font,
                                                                                              NSForegroundColorAttributeName: delta.textColor,
                                                                                              NSParagraphStyleAttributeName: indent}] : nil;
    view.deltaAverageImageView.image = arrow;
    view.deltaAverageImageViewWidthConstraint.constant = arrow.size.width;
    view.deltaAverageImageViewHeightConstraint.constant = arrow.size.height;
    // Its bottom sits on the words' baseline: lowered by the symbol's own
    // baseline, the circle is centred on them as Screen Time's.
    view.deltaAverageImageViewVerticalPosition.constant = arrow.hasBaseline ? arrow.baselineOffsetFromBottom : 0;
    [view _setUpConstraints];
}

#pragma mark - Chart

@interface NLScreenTimeChartView () <UIGestureRecognizerDelegate>
@end

@implementation NLScreenTimeChartView {
    UIView<NLSTTitleView> *_title;
    UIViewController<NLSTGraph> *_graph;
    NLActivityPeriod *_period;
    NSHashTable<UILabel *> *_hiddenLabels;   // scale labels under the average's, hidden here
}

+ (CGFloat)heightTitled:(BOOL)titled {
    static CGFloat heights[2];
    if (!heights[titled]) {
        // Measured with a period shown: its axis labels count.
        NLScreenTimeChartView *sample = [[NLScreenTimeChartView alloc] initTitled:titled];
        NLActivityPeriod *empty = [NLActivityPeriod periodWithScale:titled ? NLActivityScaleWeek : NLActivityScaleDay containingDate:[NSDate date]
                                                              items:@[] apps:[NLHistoryApps appsForItems:@[]]];
        [sample showPeriod:empty selectedDay:nil title:titled ? @"Title" : nil value:titled ? @"0" : nil trend:nil rising:NO];
        heights[titled] = ceil([sample->_graph.view systemLayoutSizeFittingSize:CGSizeMake(329, 0) withHorizontalFittingPriority:UILayoutPriorityRequired
                                                         verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height);
    }
    return heights[titled];
}

// Untitled (a day's hours), no paddle: it shows over the title.
- (instancetype)initTitled:(BOOL)titled {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    _titled = titled;
    _title = NLSTMakeTitle();
    _graph = (UIViewController<NLSTGraph> *)[(id<NLSTGraph>)[NLSTClass("STUsageGraphViewController") alloc] initWithTitleView:_title
                                                                    graphHeight:kNLSTGraphHeight includePaddle:titled useVibrancy:NO];
    UIView *graph = _graph.view;
    graph.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:graph];
    [NSLayoutConstraint activateConstraints:@[
        [graph.topAnchor constraintEqualToAnchor:self.topAnchor],
        [graph.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [graph.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(nlTapped:)];
    tap.delegate = self;
    tap.cancelsTouchesInView = NO;
    [graph addGestureRecognizer:tap];
    return self;
}

- (void)showPeriod:(NLActivityPeriod *)period selectedDay:(NSDate *)day title:(NSString *)title value:(NSString *)value
             trend:(NSString *)trend rising:(BOOL)rising {
    _period = period;
    NLSTShowTitle(_title, title, value, trend, rising);
    [_graph setDataSet:NLSTDataSet(period) animated:NO];
    // A day picked on a week (1 Sunday … 7; it asserts a week): that day in
    // its colors, the others grey.
    if (period.scale == NLActivityScaleWeek) {
        [_graph setSelectedWeekday:day ? [NSCalendar.currentCalendar component:NSCalendarUnitWeekday fromDate:day] : 0];
    }
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [_graph.view layoutIfNeeded];
    [self nlHideLabelsUnderAverage];
}

// A scale label the average's label lands on gives way to it (the graph
// leaves both, one over the other); one hidden here comes back once clear.
- (void)nlHideLabelsUnderAverage {
    if (![_graph respondsToSelector:NSSelectorFromString(@"weeklyAverageLabel")] || ![_graph respondsToSelector:NSSelectorFromString(@"horizontalDividers")]) return;
    if (!_hiddenLabels) _hiddenLabels = [NSHashTable weakObjectsHashTable];
    UILabel *average = [_graph valueForKey:@"weeklyAverageLabel"];
    BOOL shown = [average isKindOfClass:UILabel.class] && average.text.length && !average.hidden && average.alpha > 0 && average.superview;
    CGRect averageFrame = shown ? [average convertRect:average.bounds toView:self] : CGRectNull;
    for (UIView *divider in [_graph valueForKey:@"horizontalDividers"]) {
        if (![divider isKindOfClass:UIView.class]) continue;
        for (UILabel *label in divider.subviews) {
            if (![label isKindOfClass:UILabel.class] || !label.text.length) continue;
            BOOL under = shown && CGRectIntersectsRect([label convertRect:label.bounds toView:self], averageFrame);
            if (under && ![_hiddenLabels containsObject:label]) {
                label.alpha = 0;
                [_hiddenLabels addObject:label];
            } else if (!under && [_hiddenLabels containsObject:label]) {
                label.alpha = 1;
                [_hiddenLabels removeObject:label];
            }
        }
    }
}

// The bar nearest a tap on a week, if it has begun.
- (void)nlTapped:(UITapGestureRecognizer *)tap {
    NSArray<UIView *> *bars = [_graph barViews];
    if (!self.didTapDay || _period.scale != NLActivityScaleWeek || bars.count != _period.bars.count) return;
    UIView *graph = _graph.view;
    CGFloat x = [tap locationInView:graph].x, nearest = CGFLOAT_MAX;
    NSUInteger index = 0;
    for (NSUInteger i = 0; i < bars.count; i++) {
        CGFloat distance = fabs(CGRectGetMidX([bars[i] convertRect:bars[i].bounds toView:graph]) - x);
        if (distance < nearest) {
            nearest = distance;
            index = i;
        }
    }
    if (nearest > graph.bounds.size.width / bars.count) return;
    NSDate *day = _period.bars[index].start;
    if ([day compare:[NSDate date]] == NSOrderedDescending) return;
    self.didTapDay(day);
}

// Alongside the graph's own (the paddle's press) and the pager's.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;
}

@end

#pragma mark - Legend and date bar

UIView *NLScreenTimeMakeLegend(void) {
    return (UIView *)[(id<NLSTLegend>)[NLSTClass("STHorizontallySegmentedView") alloc] initWithVibrancy:NO maximumNumberOfLines:1 truncateLabels:YES];
}

void NLScreenTimeShowLegend(UIView *legend, NSArray<NSNumber *> *categories, NSArray<NSNumber *> *durations, NLHistoryApps *apps) {
    NSMutableArray *items = [NSMutableArray array];
    for (NSNumber *category in categories) {
        NSUInteger c = category.unsignedIntegerValue;
        [items addObject:[(id<NLSTSegmentItem>)[NLSTClass("STSegmentItem") alloc] initWithTitleText:[apps nameForCategory:c]
                             detailText:NLHistoryDuration(durations[c].doubleValue) titleColor:[apps colorForCategory:c] detailImage:nil detailImageTintColor:nil]];
    }
    [(id<NLSTLegend>)legend setSegmentItems:items];
}

UIView *NLScreenTimeMakeDateBar(UILabel **label, UIButton **previous, UIButton **next) {
    UIView<NLSTDatePickerBar> *bar = [NLSTClass("STDatePickerBar") new];
    bar.alpha = 1;   // Screen Time fades it in itself
    *label = bar.dateLabel;
    *previous = bar.leftArrowButton;
    *next = bar.rightArrowButton;
    // The arrows take the pages' theme, as the rest of them.
    (*previous).tintColor = nil;
    (*next).tintColor = nil;
    return bar;
}
