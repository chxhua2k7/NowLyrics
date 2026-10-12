//
//  NLHistoryPages.h
//  The Listening History pages (NLHistory.h has the files): the first page
//  and its This Week card, All Activity (Screen Time's charts, by app), a
//  day's timeline and a song's page. NLHistoryController.m has the pages,
//  NLHistoryActivity.m the charts and All Activity.
//

#import "NLLyricsPages.h"
#import "../NLHistory.h"

// One play as the pages show it.
@interface NLHistoryItem : NSObject
@property (nonatomic, copy) NSString *identifier, *day, *title, *artist, *album, *app, *key, *art;
@property (nonatomic, strong) NSDate *start, *end;
@property (nonatomic, assign) double listened, duration;
- (BOOL)isSameSongAs:(NLHistoryItem *)other;
// The time it played inside [start, end): its listening spread over the
// span from its start to its end.
- (NSTimeInterval)listenedFrom:(NSDate *)start to:(NSDate *)end;
@end

// Every play of every day, newest first; a day's, oldest first. A day's file
// is read again only once it has changed. Any queue.
NSArray<NLHistoryItem *> *NLHistoryLoadAll(void);
NSArray<NLHistoryItem *> *NLHistoryItemsOfDay(NSString *day);

// A formatter by `name`, made by `make` the first time and kept until the
// region or the time zone changes (they cost to make). Main queue.
id NLHistoryFormatter(NSString *name, id (^make)(void));
NSString *NLHistoryDayTitle(NSDate *date);       // Today, Yesterday, Saturday, October 4
NSString *NLHistoryDuration(double seconds);     // 1 hr 32 min, 2 min 35 sec, 45 sec; 0 min for none
UIImage *NLHistoryCover(NSString *art, CGFloat side);   // rounded; a note on grey without one
void NLHistoryObserve(id observer, SEL selector);       // `selector` whenever SpringBoard writes a play
void NLHistoryPush(PSViewController *from, PSViewController *page);   // reading prefs through the same list page

// The apps the charts tell apart, by how long each was listened to, at most
// four; the rest are one "Other Apps". Colors and names follow.
@interface NLHistoryApps : NSObject
+ (instancetype)appsForItems:(NSArray<NLHistoryItem *> *)items;
@property (nonatomic, readonly) NSUInteger count;          // the named ones plus Other Apps
- (NSUInteger)categoryForApp:(NSString *)bundleID;
- (UIColor *)colorForCategory:(NSUInteger)category;
- (NSString *)nameForCategory:(NSUInteger)category;
@end

typedef NS_ENUM(NSInteger, NLActivityScale) {
    NLActivityScaleWeek = 0,   // a week, a bar a day
    NLActivityScaleDay,        // a day, a bar an hour
};

// One bar: the time each app was listened to in it.
@interface NLActivityBar : NSObject
@property (nonatomic, readonly) NSDate *start, *end;
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *durations;   // one per category, seconds
@property (nonatomic, readonly) NSTimeInterval total;
@end

// A week or a day; a play across its edge counts the part inside.
@interface NLActivityPeriod : NSObject
+ (NSDate *)startOfPeriodWithScale:(NLActivityScale)scale containingDate:(NSDate *)date;
+ (instancetype)periodWithScale:(NLActivityScale)scale containingDate:(NSDate *)date
                          items:(NSArray<NLHistoryItem *> *)items apps:(NLHistoryApps *)apps;
@property (nonatomic, readonly) NLActivityScale scale;
@property (nonatomic, readonly) NSDate *start, *end;
@property (nonatomic, readonly) NLHistoryApps *apps;
@property (nonatomic, readonly, copy) NSArray<NLActivityBar *> *bars;
@property (nonatomic, readonly, copy) NSArray<NLHistoryItem *> *items;     // the plays in it, newest first
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *durations;
@property (nonatomic, readonly) NSTimeInterval total;
@property (nonatomic, readonly) NSTimeInterval dailyAverage;               // a week: over its days that are over
@property (nonatomic, readonly, copy) NSString *title;                     // This Week, Last Week, a range; a day's title
- (NSString *)titleForBarAtIndex:(NSUInteger)index;
@end

// Stacked bars, the scale on the right, weekdays or hours under them, the
// week's average dashed. With didSelectBar a tap selects a bar (NSNotFound: none).
@interface NLActivityChartView : UIView
@property (nonatomic, strong) NLActivityPeriod *period;
@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic, copy) void (^didSelectBar)(NSInteger index);
@end

// The card: title, caption (Daily Average), the big time, the chart and the apps' times.
@interface NLActivityCardCell : UITableViewCell
@property (nonatomic, strong) UIView *chartView;
- (void)showTitle:(NSString *)title caption:(NSString *)caption value:(NSString *)value
        durations:(NSArray<NSNumber *> *)durations apps:(NLHistoryApps *)apps;
@end

// A song in Most Played: cover, title and a bar as long as its share, its time on the right.
@interface NLSongUsage : NSObject
@property (nonatomic, strong) NLHistoryItem *item;   // its latest play in the range
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSUInteger plays;
@end

@interface NLUsageCell : UITableViewCell
- (void)showUsage:(NLSongUsage *)usage fraction:(CGFloat)fraction color:(UIColor *)color;
@end

// The songs played in [start, end), longest first.
NSArray<NLSongUsage *> *NLSongUsages(NSArray<NLHistoryItem *> *items, NSDate *start, NSDate *end);

@interface NLHistoryActivityController : PSViewController
- (instancetype)initWithScale:(NLActivityScale)scale date:(NSDate *)date;
@end

@interface NLHistoryDayController : PSViewController
- (instancetype)initWithDay:(NSString *)day;
@end

@interface NLHistorySongController : PSViewController
- (instancetype)initWithItem:(NLHistoryItem *)item;
@end
