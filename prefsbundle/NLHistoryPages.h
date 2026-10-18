//
//  NLHistoryPages.h
//  The Listening History pages (NLHistory.h has the files): the first page
//  and its This Week card, All Activity (Screen Time's charts, by app), an
//  artist's, album's or app's songs, a day's timeline and a song's page.
//  NLHistoryController.m has the pages, NLHistoryActivity.m the charts, the
//  date bar, All Activity and the artist's, album's or app's.
//

#import "NLLyricsPages.h"
#import "../NLHistory.h"

// One play as the pages show it.
@interface NLHistoryItem : NSObject
@property (nonatomic, copy) NSString *identifier, *day, *title, *artist, *album, *app, *key, *art;
@property (nonatomic, strong) NSDate *start, *end;
@property (nonatomic, assign) double listened, duration;
@property (nonatomic, assign) BOOL skipped;   // it ended before it counted (NL_HP_SKIPPED)
- (BOOL)isSameSongAs:(NLHistoryItem *)other;
// The time it played inside [start, end): its listening spread over the
// span from its start to its end.
- (NSTimeInterval)listenedFrom:(NSDate *)start to:(NSDate *)end;
@end

// Every play of every day, newest first; a day's, oldest first. `skipped`:
// the skipped ones too (Show Skipped Songs, NLHistoryShowsSkipped). A day's
// file is read again only once it has changed. Any queue.
NSArray<NLHistoryItem *> *NLHistoryLoadAll(BOOL skipped);
NSArray<NLHistoryItem *> *NLHistoryItemsOfDay(NSString *day, BOOL skipped);
BOOL NLHistoryShowsSkipped(PSViewController *page);   // read through the page; on by default

// A formatter by `name`, made by `make` the first time and kept until the
// region or the time zone changes (they cost to make). Main queue.
id NLHistoryFormatter(NSString *name, id (^make)(void));
NSString *NLHistoryDayTitle(NSDate *date);       // Today, Oct 14; Sunday, Oct 11 (10月14日 今天), as Screen Time's
NSString *NLHistoryDuration(double seconds);     // 1 hr 32 min, 2 min 35 sec, 45 sec; 0 min for none
UIImage *NLHistoryCover(NSString *art, CGFloat side);   // rounded; a note on grey without one
UIImage *NLHistoryAppIcon(NSString *bundleID, CGFloat side);   // the app's icon, rounded; a cover tile without one
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
// A press shows the bar's day and time over the card it is on (Screen Time's
// green callout); sliding goes along the bars. With contextIndex the chart is
// the week around that day: the other days grey, the average too.
@interface NLActivityChartView : UIView
@property (nonatomic, strong) NLActivityPeriod *period;
@property (nonatomic) NSInteger selectedIndex;
@property (nonatomic) NSInteger contextIndex;   // NSNotFound (the default): every bar in its colors
@property (nonatomic, copy) void (^didSelectBar)(NSInteger index);
@end

// A week's daily average against the week before's: "34% from last week",
// `rising` set; nil when either has none. Main queue.
NSString *NLActivityTrend(NLActivityPeriod *period, NLActivityPeriod *previous, BOOL *rising);

// The card, as Screen Time's: a grey title (Daily Average, a day), the big
// time with the trend on its right, the chart (chartHeight tall; on a day the
// week around it above, headChartView) and the three apps listened to
// longest. With Screen Time's charts the title is theirs, the legend too.
@interface NLActivityCardCell : UITableViewCell
- (instancetype)initWithScreenTime:(BOOL)screenTime;   // NO: ours even where Screen Time's are (initWithStyle: picks)
@property (nonatomic, strong) UIView *chartView;
@property (nonatomic) CGFloat chartHeight;
@property (nonatomic, strong) UIView *headChartView;   // nil: none
@property (nonatomic) CGFloat headChartHeight;
- (void)showTitle:(NSString *)title value:(NSString *)value trend:(NSString *)trend rising:(BOOL)rising
        durations:(NSArray<NSNumber *> *)durations apps:(NLHistoryApps *)apps;
@end

// Screen Time's own charts (NLScreenTime.m, ScreenTimeSettingsUI): whether
// this iOS has them, and its date bar.
BOOL NLScreenTimeChartsAvailable(void);
BOOL NLScreenTimeDateBarAvailable(void);

// One Screen Time graph: a week, titled (its title above it and the paddle a
// press shows), or a day's hours, untitled. With selectedDay the week has that
// day in its colors and the others grey.
@interface NLScreenTimeChartView : UIView
+ (CGFloat)heightTitled:(BOOL)titled;
- (instancetype)initTitled:(BOOL)titled;
@property (nonatomic, readonly) BOOL titled;
@property (nonatomic, copy) void (^didTapDay)(NSDate *day);   // a day tapped on a week, one that has begun
- (void)showPeriod:(NLActivityPeriod *)period selectedDay:(NSDate *)day title:(NSString *)title value:(NSString *)value
             trend:(NSString *)trend rising:(BOOL)rising;
@end

// Its legend, the apps given (categories, longest first) each in its color
// with its time; and its date bar, the label and arrows handed out.
UIView *NLScreenTimeMakeLegend(void);
void NLScreenTimeShowLegend(UIView *legend, NSArray<NSNumber *> *categories, NSArray<NSNumber *> *durations, NLHistoryApps *apps);
UIView *NLScreenTimeMakeDateBar(UILabel **label, UIButton **previous, UIButton **next);

// What Most Played ranks: songs, or (Show Categories, as Screen Time's) their
// artists, albums or apps.
typedef NS_ENUM(NSInteger, NLUsageKind) {
    NLUsageKindSongs = 0,
    NLUsageKindArtists,
    NLUsageKindAlbums,
    NLUsageKindApps,
};

// One row of Most Played: cover (an app's icon), name and a bar in its app's color as long as its share, its time after it.
@interface NLUsage : NSObject
@property (nonatomic) NLUsageKind kind;
@property (nonatomic, copy) NSString *key;           // what its plays share (NLUsageKey)
@property (nonatomic, copy) NSString *name;
@property (nonatomic, strong) NLHistoryItem *item;   // its latest play in the range
@property (nonatomic) NSTimeInterval duration;
@property (nonatomic) NSUInteger plays;
@end

@interface NLUsageCell : UITableViewCell
- (void)showUsage:(NLUsage *)usage fraction:(CGFloat)fraction color:(UIColor *)color;
@end

// What a play is ranked by in `kind`: the song's key, its artist, album or
// app; nil when it has none (left out of that ranking).
NSString *NLUsageKey(NLHistoryItem *item, NLUsageKind kind);
// What was played in [start, end), by `kind`, longest first.
NSArray<NLUsage *> *NLUsages(NSArray<NLHistoryItem *> *items, NSDate *start, NSDate *end, NLUsageKind kind);

@interface NLHistoryActivityController : PSViewController
- (instancetype)initWithScale:(NLActivityScale)scale date:(NSDate *)date;
@end

// An artist, album or app from Most Played: its time and plays in the same
// range (`range` names it), its songs longest first.
@interface NLHistoryGroupController : PSViewController
- (instancetype)initWithUsage:(NLUsage *)usage items:(NSArray<NLHistoryItem *> *)items range:(NSString *)range
                        start:(NSDate *)start end:(NSDate *)end apps:(NLHistoryApps *)apps;
@end

// Screen Time's bar under the navigation bar: what the page shows, round
// buttons to the one before and after. Pinned to the top of `page`'s view,
// hidden until shown; while it shows, the navigation bar keeps its material
// even at the top.
@interface NLDateBar : UIView
+ (instancetype)barOnPage:(UIViewController *)page;
+ (CGFloat)height;
@property (nonatomic, readonly) UILabel *titleLabel;
@property (nonatomic, readonly) UIButton *previousButton, *nextButton;
@property (nonatomic, readonly, getter=isShown) BOOL shown;
- (void)setShown:(BOOL)shown animated:(BOOL)animated;
@end

// A song listened to again (NLListen.m), as Shazam's More Ways to Listen:
// the apps it can be, the one it played in first while it is installed, then
// the music apps on this iPhone; each one's name, its button's title and
// colors (`text` the title's) and its icon for a menu. NLListen opens the
// song there: Apple Music's own page of it, or the app's search for it.
NSArray<NSString *> *NLListenApps(NLHistoryItem *item);
NSString *NLListenName(NSString *bundleID);    // Apple Music, Spotify
NSString *NLListenTitle(NSString *bundleID);   // Listen in Spotify; Open Safari for one that is not a music app
UIColor *NLListenColor(NSString *bundleID, UIColor **text);
UIImage *NLListenIcon(NSString *bundleID);
void NLListen(NLHistoryItem *item, NSString *bundleID);
void NLShareSong(NLHistoryItem *item, UIViewController *from, UIView *source);   // its title and artist
// Other Apps (`apps`) and Share, the song page's More Ways to Listen; and a
// song row's long press: the app it played in above them.
UIMenu *NLListenMenu(NLHistoryItem *item, NSArray<NSString *> *apps, UIViewController *from, UIView *source);
UIContextMenuConfiguration *NLSongContextMenu(NLHistoryItem *item, UIViewController *from);

@interface NLHistoryDayController : PSViewController
- (instancetype)initWithDay:(NSString *)day;
@end

@interface NLHistorySongController : PSViewController
- (instancetype)initWithItem:(NLHistoryItem *)item;
@end
