//
//  NLHistoryController.m
//  Listening History (NLHistory.h, NLHistoryPages.h): what SpringBoard wrote down.
//
//  - The first page, as Screen Time's: This Week (the daily average, a bar a
//    day stacked by app, the apps' times) and Show All Activity
//    (NLHistoryActivity.m); this week's Most Played; the switch, how long to
//    keep it, and Delete All History.
//  - A day's timeline: each song in order, the pauses of five minutes or more
//    between them; the toolbar goes to the day before or after with plays.
//    Swipe to delete.
//  - A song: how often and how long it was played, its lyrics in the app that
//    played it (to the editor) and its own offset, as Now Playing has them
//    for the song on now.
//
//  The pages load again when SpringBoard writes (NL_HISTORY_WRITTEN_NOTIFICATION).
//

#import "NLHistoryPages.h"
#import "NLOffsetControl.h"

static const NSTimeInterval kNLHistoryGapShown = 5 * 60;   // pauses this long or longer get a row
static const CGFloat kNLHistoryCoverSide = 44;
static const NSUInteger kNLTopSongs = 5;                   // this week's Most Played on the first page

#pragma mark - Model

@implementation NLHistoryItem

+ (instancetype)itemWithEntry:(NSDictionary *)entry day:(NSString *)day {
    NLHistoryItem *item = [self new];
    item.identifier = entry[NL_HP_ID];
    item.day = day;
    item.title = NLString(entry, NL_HP_TITLE) ?: @"";
    item.artist = NLString(entry, NL_HP_ARTIST);
    item.album = NLString(entry, NL_HP_ALBUM);
    // Safari's web audio is named by WebKit's media process.
    NSString *app = NLString(entry, NL_HP_APP);
    item.app = [app hasPrefix:@"com.apple.WebKit."] ? @"com.apple.mobilesafari" : app;
    item.key = NLString(entry, NL_HP_KEY);
    item.art = NLString(entry, NL_HP_ART);
    item.start = [NSDate dateWithTimeIntervalSince1970:NLNum(entry[NL_HP_START], 0)];
    double end = NLNum(entry[NL_HP_END], 0);
    item.end = end > 0 ? [NSDate dateWithTimeIntervalSince1970:end] : item.start;
    item.listened = NLNum(entry[NL_HP_LISTENED], 0);
    item.duration = NLNum(entry[NL_HP_DURATION], 0);
    return item;
}

// The same song: by its track key, or its title and artist when it has none.
- (BOOL)isSameSongAs:(NLHistoryItem *)other {
    if (self.key.length && other.key.length) return [self.key isEqualToString:other.key];
    return [self.title isEqualToString:other.title] && NLSame(self.artist ?: @"", other.artist ?: @"");
}

- (NSTimeInterval)listenedFrom:(NSDate *)start to:(NSDate *)end {
    NSTimeInterval from = self.start.timeIntervalSinceReferenceDate;
    NSTimeInterval to = MAX(self.end.timeIntervalSinceReferenceDate, from + 1);
    double overlap = MIN(to, end.timeIntervalSinceReferenceDate) - MAX(from, start.timeIntervalSinceReferenceDate);
    return overlap > 0 ? overlap * MIN(self.listened / (to - from), 1) : 0;
}

@end

// Read again only once its file has changed: the pages load every day
// whenever SpringBoard writes (each minute while a song plays), and it is
// mostly today's that did.
NSArray<NLHistoryItem *> *NLHistoryItemsOfDay(NSString *day) {
    static NSMutableDictionary<NSString *, NSArray *> *cache;   // day → @[@[file date, size], items]
    NSLock *lock = NL_ONCE([NSLock new]);
    NSDictionary *attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:NLHistoryDayPath(day) error:nil];
    if (!attributes) return @[];
    NSArray *version = @[attributes.fileModificationDate ?: NSDate.distantPast, @(attributes.fileSize)];
    [lock lock];
    NSArray *cached = cache[day];
    [lock unlock];
    if ([cached.firstObject isEqual:version]) return cached.lastObject;

    NSMutableArray<NLHistoryItem *> *items = [NSMutableArray array];
    for (NSDictionary *entry in NLHistoryReadDay(day)) [items addObject:[NLHistoryItem itemWithEntry:entry day:day]];
    [lock lock];
    if (!cache) cache = [NSMutableDictionary dictionary];
    cache[day] = @[version, [items copy]];
    [lock unlock];
    return items;
}

NSArray<NLHistoryItem *> *NLHistoryLoadAll(void) {
    NSMutableArray<NLHistoryItem *> *all = [NSMutableArray array];
    for (NSString *day in NLHistoryDays()) {   // newest first
        [all addObjectsFromArray:NLHistoryItemsOfDay(day).reverseObjectEnumerator.allObjects];
    }
    return all;
}

static double NLHistoryTotalListened(NSArray<NLHistoryItem *> *items) {
    double total = 0;
    for (NLHistoryItem *item in items) total += item.listened;
    return total;
}

#pragma mark - Formatting

id NLHistoryFormatter(NSString *name, id (^make)(void)) {
    static NSMutableDictionary<NSString *, id> *made;
    if (!made) {
        made = [NSMutableDictionary dictionary];
        for (NSNotificationName change in @[NSCurrentLocaleDidChangeNotification, NSSystemTimeZoneDidChangeNotification]) {
            [NSNotificationCenter.defaultCenter addObserverForName:change object:nil queue:NSOperationQueue.mainQueue
                                                        usingBlock:^(NSNotification *note) { [made removeAllObjects]; }];
        }
    }
    id formatter = made[name];
    if (!formatter) made[name] = formatter = make();
    return formatter;
}

NSString *NLHistoryDayTitle(NSDate *date) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    if ([calendar isDateInToday:date]) return NLL(@"Today");
    if ([calendar isDateInYesterday:date]) return NLL(@"Yesterday");
    BOOL thisYear = [calendar component:NSCalendarUnitYear fromDate:date] == [calendar component:NSCalendarUnitYear fromDate:[NSDate date]];
    NSString *template = thisYear ? @"MMMdEEEE" : @"yMMMdEEEE";
    NSDateFormatter *formatter = NLHistoryFormatter(template, ^id {
        NSDateFormatter *made = [NSDateFormatter new];
        [made setLocalizedDateFormatFromTemplate:template];
        return made;
    });
    return [formatter stringFromDate:date];
}

static NSString *NLHistoryTime(NSDate *date) {
    NSDateFormatter *formatter = NLHistoryFormatter(@"time", ^id {
        NSDateFormatter *made = [NSDateFormatter new];
        made.timeStyle = NSDateFormatterShortStyle;
        return made;
    });
    return [formatter stringFromDate:date];
}

// `toTheSecond`: below an hour, minutes and seconds (listening); else whole minutes (a pause).
static NSString *NLHistoryFormatDuration(double seconds, BOOL toTheSecond) {
    seconds = MAX(round(seconds), 0);
    NSCalendarUnit units = NSCalendarUnitMinute;
    if (seconds >= 3600) units = NSCalendarUnitHour | NSCalendarUnitMinute;
    else if (seconds >= 60 && toTheSecond) units = NSCalendarUnitMinute | NSCalendarUnitSecond;
    else if (seconds > 0 && seconds < 60) units = NSCalendarUnitSecond;
    BOOL none = seconds == 0;
    NSString *name = [NSString stringWithFormat:@"duration %lu%@", (unsigned long)units, none ? @" none" : @""];
    NSDateComponentsFormatter *formatter = NLHistoryFormatter(name, ^id {
        NSDateComponentsFormatter *made = [NSDateComponentsFormatter new];
        made.unitsStyle = NSDateComponentsFormatterUnitsStyleShort;
        made.allowedUnits = units;
        // 2 hr rather than 2 hr 0 min; nothing at all still reads 0 min.
        made.zeroFormattingBehavior = none ? NSDateComponentsFormatterZeroFormattingBehaviorDefault
                                           : NSDateComponentsFormatterZeroFormattingBehaviorDropAll;
        return made;
    });
    return [formatter stringFromTimeInterval:seconds] ?: @"";
}

NSString *NLHistoryDuration(double seconds) {
    return NLHistoryFormatDuration(seconds, YES);
}

static NSString *NLHistoryCount(NSUInteger count, NSString *one, NSString *many) {
    return count == 1 ? NLL(one) : [NSString stringWithFormat:NLL(many), (unsigned long)count];
}

static NSString *NLHistorySongCount(NSUInteger count) { return NLHistoryCount(count, @"1 song", @"%lu songs"); }

UIImage *NLHistoryCover(NSString *art, CGFloat side) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *cacheKey = [NSString stringWithFormat:@"%@@%.0f", art ?: @"", side];
    UIImage *cached = [cache objectForKey:cacheKey];
    if (cached) return cached;
    NSString *path = NLHistoryArtworkPath(art);
    UIImage *cover = path ? [UIImage imageWithContentsOfFile:path] : nil;
    CGRect tile = CGRectMake(0, 0, side, side);
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:tile.size] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithRoundedRect:tile cornerRadius:side * 0.14] addClip];
        if (cover) {
            [cover drawInRect:tile];
            return;
        }
        [UIColor.tertiarySystemFillColor setFill];
        UIRectFill(tile);
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:side * 0.4 weight:UIImageSymbolWeightMedium];
        UIImage *note = [[UIImage systemImageNamed:@"music.note" withConfiguration:config] imageWithTintColor:UIColor.secondaryLabelColor
                                                                                                 renderingMode:UIImageRenderingModeAlwaysOriginal];
        [note drawAtPoint:CGPointMake((side - note.size.width) / 2, (side - note.size.height) / 2)];
    }];
    [cache setObject:image forKey:cacheKey];
    return image;
}

#pragma mark - Change notices and pushes

static NSString *const NLHistoryChangedNotification = @"NLHistoryChanged";

static void NLHistoryWritten(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:NLHistoryChangedNotification object:nil];
    });
}

void NLHistoryObserve(id observer, SEL selector) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NLObserveDarwin(NL_HISTORY_WRITTEN_NOTIFICATION, NLHistoryWritten, CFNotificationSuspensionBehaviorCoalesce);
    });
    [NSNotificationCenter.defaultCenter addObserver:observer selector:selector name:NLHistoryChangedNotification object:nil];
}

void NLHistoryPush(PSViewController *from, PSViewController *page) {
    page.parentController = from.parentController;
    page.rootController = from.rootController;
    [from.navigationController pushViewController:page animated:YES];
}

#pragma mark - A song

@interface NLHistorySongController () <UITableViewDataSource, UITableViewDelegate>
@end

typedef NS_ENUM(NSInteger, NLSongSection) { NLSongSectionStats, NLSongSectionLyrics, NLSongSectionOffset };

@implementation NLHistorySongController {
    NLHistoryItem *_item;
    UITableView *_table;
    NSArray<NSNumber *> *_sections;
    NSString *_folder;        // the app's Library/NowLyrics; nil when NowLyrics never ran there
    NSString *_lyricsPath;    // the song's lyrics there, added by hand or saved; nil without
    NSUInteger _plays;
    double _listened;
    NSDate *_first;
    BOOL _statsLoaded;
}

- (instancetype)initWithItem:(NLHistoryItem *)item {
    if ((self = [super init])) _item = item;
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = _item.title;
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = NLApplyButton(self);
    _table = NLMakeTable(self);
    _table.tableHeaderView = [self nlHeader];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self nlLoad];   // again after the editor saved or deleted
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    UIView *header = _table.tableHeaderView;
    CGFloat height = [header systemLayoutSizeFittingSize:CGSizeMake(_table.bounds.size.width, 0)
                           withHorizontalFittingPriority:UILayoutPriorityRequired
                                 verticalFittingPriority:UILayoutPriorityFittingSizeLevel].height;
    if (fabs(header.frame.size.height - height) > 0.5 || fabs(header.frame.size.width - _table.bounds.size.width) > 0.5) {
        header.frame = CGRectMake(0, 0, _table.bounds.size.width, height);
        _table.tableHeaderView = header;
    }
}

// The cover, the title, the artist and album.
- (UIView *)nlHeader {
    UIView *header = [UIView new];
    UIImageView *cover = [[UIImageView alloc] initWithImage:NLHistoryCover(_item.art, 120)];
    cover.translatesAutoresizingMaskIntoConstraints = NO;
    UILabel *title = [UILabel new];
    title.text = _item.title;
    title.font = [UIFont fontWithDescriptor:[[UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleTitle3]
                                             fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold] size:0];
    title.numberOfLines = 0;
    title.textAlignment = NSTextAlignmentCenter;
    UILabel *detail = [UILabel new];
    detail.text = NLJoinNonEmpty(_item.artist, _item.album, @" — ");
    detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
    detail.textColor = UIColor.secondaryLabelColor;
    detail.numberOfLines = 0;
    detail.textAlignment = NSTextAlignmentCenter;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[cover, title, detail]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 4;
    [stack setCustomSpacing:12 afterView:cover];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [header addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [cover.widthAnchor constraintEqualToConstant:120],
        [cover.heightAnchor constraintEqualToConstant:120],
        [stack.topAnchor constraintEqualToAnchor:header.topAnchor constant:16],
        [stack.bottomAnchor constraintEqualToAnchor:header.bottomAnchor constant:-8],
        [stack.leadingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:header.layoutMarginsGuide.trailingAnchor constant:-16],
    ]];
    return header;
}

- (void)nlLoad {
    NLHistoryItem *item = _item;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSUInteger plays = 0;
        double listened = 0;
        NSDate *first = nil;
        for (NLHistoryItem *other in NLHistoryLoadAll()) {   // newest first
            if (![other isSameSongAs:item]) continue;
            plays++;
            listened += other.listened;
            first = other.start;
        }
        // Its lyrics in the app that played it: added by hand first, as the app looks.
        NSString *folder = NLLyricsFolderForBundle(item.app);
        BOOL isDir = NO;
        if (![[NSFileManager defaultManager] fileExistsAtPath:folder isDirectory:&isDir] || !isDir) folder = nil;
        NSString *lyrics = nil;
        if (folder) {
            NSMutableArray<NSString *> *candidates = [NSMutableArray array];
            NSString *manualName = NLManualFileName(item.title, item.artist);
            if (manualName.length) [candidates addObject:[[folder stringByAppendingPathComponent:NL_MANUAL_FOLDER] stringByAppendingPathComponent:manualName]];
            if (item.key.length) [candidates addObject:[folder stringByAppendingPathComponent:NLCacheFileName(item.key)]];
            for (NSString *path in candidates) {
                if ([[NSFileManager defaultManager] fileExistsAtPath:path]) { lyrics = path; break; }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_plays = plays;
            self->_listened = listened;
            self->_first = first;
            self->_folder = folder;
            self->_lyricsPath = lyrics;
            self->_statsLoaded = YES;
            NSMutableArray *sections = [NSMutableArray arrayWithObject:@(NLSongSectionStats)];
            if (folder) [sections addObject:@(NLSongSectionLyrics)];
            if (folder && item.key.length) [sections addObject:@(NLSongSectionOffset)];
            self->_sections = sections;
            [self->_table reloadData];
        });
    });
}

- (NLSongSection)nlSection:(NSInteger)section {
    return (NLSongSection)_sections[section].integerValue;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _statsLoaded ? (NSInteger)_sections.count : 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ([self nlSection:section]) {
        case NLSongSectionStats: return _item.app.length ? 4 : 3;
        case NLSongSectionLyrics: return 1;
        case NLSongSectionOffset: return 1;
    }
    return 0;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ([self nlSection:section]) {
        case NLSongSectionStats: return NLL(@"This Song");
        case NLSongSectionLyrics: return NLL(@"Lyrics");
        case NLSongSectionOffset: return nil;
    }
    return nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if ([self nlSection:section] == NLSongSectionOffset) return NLL(@"This song's own offset, on top of the default one.");
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self nlSection:indexPath.section] == NLSongSectionOffset ? kNLStackedRowHeight : UITableViewAutomaticDimension;
}

- (UITableViewCell *)nlValueCell:(NSString *)title value:(NSString *)value {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = value;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch ([self nlSection:indexPath.section]) {
        case NLSongSectionStats: {
            if (indexPath.row == 0) return [self nlValueCell:NLL(@"Plays") value:NLHistoryCount(_plays, @"1 time", @"%lu times")];
            if (indexPath.row == 1) return [self nlValueCell:NLL(@"Listening Time") value:NLHistoryDuration(_listened)];
            if (indexPath.row == 2) {
                NSDateFormatter *dates = NLHistoryFormatter(@"first played", ^id {
                    NSDateFormatter *made = [NSDateFormatter new];
                    made.dateStyle = NSDateFormatterMediumStyle;
                    made.timeStyle = NSDateFormatterShortStyle;
                    made.doesRelativeDateFormatting = YES;
                    return made;
                });
                return [self nlValueCell:NLL(@"First Played") value:_first ? [dates stringFromDate:_first] : @""];
            }
            UITableViewCell *cell = [self nlValueCell:NLL(@"Played In") value:NLAppName(_item.app)];
            UIImage *icon = NLAppIcon(_item.app);
            if (icon) cell.imageView.image = NLRowSizedImage(icon, YES);
            return cell;
        }
        case NLSongSectionLyrics: {
            if (!_lyricsPath) return NLNoteCell(NLL(@"No lyrics saved for this song yet."));
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.textLabel.text = NLL(@"Edit Lyrics");
            cell.imageView.image = NLSettingsIcon(@"text.quote", @"#FF2D55");
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        case NLSongSectionOffset: {
            double offset = [self nlDefaultOffset] + NLTrackOffset(@{NL_TRACK_OFFSETS_KEY: [self nlOffsets]}, _item.key);
            return NLSongOffsetRow(offset, self, @selector(nlOffsetChanged:));
        }
    }
    return [UITableViewCell new];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self nlSection:indexPath.section] != NLSongSectionLyrics || !_lyricsPath) return;
    NLLyricsEditorController *editor = [[NLLyricsEditorController alloc] initWithPath:_lyricsPath title:_item.title];
    [self.navigationController pushViewController:editor animated:YES];
}

#pragma mark Offset

- (double)nlDefaultOffset {
    return NLLooseNum([self nlPref:@"offset"], 0);
}

- (NSDictionary *)nlOffsets {
    id value = [self nlPref:NL_TRACK_OFFSETS_KEY];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

// The song's own entry in trackOffsets (none when it is 0), as the Now Playing page keeps it.
- (void)nlOffsetChanged:(NLOffsetControl *)control {
    if (_item.key.length == 0) return;
    double value = round((control.value - [self nlDefaultOffset]) * 100) / 100;
    [self nlSetPref:NLSettingTrackEntry([self nlOffsets], _item.key, value == 0 ? nil : @(value)) forKey:NL_TRACK_OFFSETS_KEY];
}

@end

#pragma mark - A day

// A row of the day: a play, or a pause between two.
@interface NLHistoryRow : NSObject
@property (nonatomic, strong) NLHistoryItem *item;   // nil for a pause
@property (nonatomic, assign) double pause;
@end

@implementation NLHistoryRow
@end

@interface NLHistoryDayController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation NLHistoryDayController {
    NSString *_day;
    NSArray<NSString *> *_days;              // every day with plays, newest first
    NSArray<NLHistoryItem *> *_items;        // the day's, oldest first
    NSArray<NLHistoryRow *> *_rows;
    UITableView *_table;
    UIBarButtonItem *_previousItem, *_nextItem;
    UILabel *_statusLabel;
    BOOL _loaded;
    NSUInteger _loads;                       // each load counts up; an older one's answer is dropped
}

- (instancetype)initWithDay:(NSString *)day {
    if ((self = [super init])) _day = [day copy];
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = NLApplyButton(self);
    _table = NLMakeTable(self);
    _table.estimatedRowHeight = 60;

    _previousItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.backward"]
                                                     style:UIBarButtonItemStylePlain target:self action:@selector(nlPreviousDay)];
    _previousItem.accessibilityLabel = NLL(@"Previous Day");
    _nextItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"chevron.forward"]
                                                 style:UIBarButtonItemStylePlain target:self action:@selector(nlNextDay)];
    _nextItem.accessibilityLabel = NLL(@"Next Day");
    _statusLabel = [UILabel new];
    _statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.adjustsFontForContentSizeCategory = YES;
    self.toolbarItems = @[_previousItem, [UIBarButtonItem flexibleSpaceItem],
                          [[UIBarButtonItem alloc] initWithCustomView:_statusLabel],
                          [UIBarButtonItem flexibleSpaceItem], _nextItem];
    // The toolbar's background follows the list, not a scroll view it finds itself.
    [self setContentScrollView:_table forEdge:NSDirectionalRectEdgeBottom];

    NLHistoryObserve(self, @selector(nlLoad));
    [self nlShowDay:_day];
}

// The toolbar is this page's only.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setToolbarHidden:NO animated:animated];
    if (_loaded) [self nlLoad];   // back from a song: its plays may be gone
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self.navigationController setToolbarHidden:YES animated:animated];
}

- (void)nlShowDay:(NSString *)day {
    _day = [day copy];
    NSDate *date = NLHistoryDayDate(day);
    self.title = date ? NLHistoryDayTitle(date) : day;
    _items = nil;
    _rows = nil;
    _loaded = NO;
    [_table reloadData];
    [_table setContentOffset:CGPointMake(0, -_table.adjustedContentInset.top) animated:NO];
    [self nlLoad];
}

- (void)nlLoad {
    NSString *day = _day;
    NSUInteger load = ++_loads;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSString *> *days = NLHistoryDays();
        NSArray<NLHistoryItem *> *items = NLHistoryItemsOfDay(day);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (load != self->_loads) return;
            self->_days = days;
            self->_items = items;
            self->_loaded = YES;
            [self nlBuildRows];
        });
    });
}

// The plays in order, a pause row before one that came five minutes or more after the last ended.
- (void)nlBuildRows {
    NSMutableArray<NLHistoryRow *> *rows = [NSMutableArray array];
    NLHistoryItem *previous = nil;
    for (NLHistoryItem *item in _items) {
        double gap = previous ? [item.start timeIntervalSinceDate:previous.end] : 0;
        if (gap >= kNLHistoryGapShown) {
            NLHistoryRow *pause = [NLHistoryRow new];
            pause.pause = gap;
            [rows addObject:pause];
        }
        NLHistoryRow *row = [NLHistoryRow new];
        row.item = item;
        [rows addObject:row];
        previous = item;
    }
    _rows = rows;

    _previousItem.enabled = [self nlNeighbour:+1] != nil;
    _nextItem.enabled = [self nlNeighbour:-1] != nil;
    _statusLabel.text = _items.count ? [NSString stringWithFormat:@"%@ · %@", NLHistorySongCount(_items.count),
                                        NLHistoryDuration(NLHistoryTotalListened(_items))] : nil;
    [_statusLabel sizeToFit];
    _table.backgroundView = _items.count ? nil : [self nlEmptyView];
    [_table reloadData];
}

// The day with plays before (+1, older) or after (-1) this one; nil at either end.
- (NSString *)nlNeighbour:(NSInteger)step {
    // Days are newest first; this day may have no file (all of it deleted).
    if (step > 0) {
        for (NSString *day in _days) if ([day compare:_day] == NSOrderedAscending) return day;
    } else {
        for (NSString *day in _days.reverseObjectEnumerator) if ([day compare:_day] == NSOrderedDescending) return day;
    }
    return nil;
}

- (void)nlPreviousDay {
    NSString *day = [self nlNeighbour:+1];
    if (day) [self nlShowDay:day];
}

- (void)nlNextDay {
    NSString *day = [self nlNeighbour:-1];
    if (day) [self nlShowDay:day];
}

- (UIView *)nlEmptyView {
    UIListContentConfiguration *content = [UIListContentConfiguration cellConfiguration];
    content.text = NLL(@"There are no plays on this day.");
    content.textProperties.color = UIColor.secondaryLabelColor;
    content.textProperties.alignment = UIListContentTextAlignmentCenter;
    UIView *view = [UIView new];
    UIView *label = [content makeContentView];
    label.translatesAutoresizingMaskIntoConstraints = NO;
    [view addSubview:label];
    [NSLayoutConstraint activateConstraints:@[
        [label.centerYAnchor constraintEqualToAnchor:view.centerYAnchor],
        [label.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:20],
        [label.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-20],
    ]];
    return view;
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _items.count ? 1 : 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NLHistoryRow *row = _rows[indexPath.row];
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"row"] ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:@"row"];
    UIListContentConfiguration *content;
    if (row.item) {
        NLHistoryItem *item = row.item;
        content = [UIListContentConfiguration subtitleCellConfiguration];
        content.image = NLHistoryCover(item.art, kNLHistoryCoverSide);
        content.imageProperties.maximumSize = CGSizeMake(kNLHistoryCoverSide, kNLHistoryCoverSide);
        content.text = item.title;
        content.textProperties.numberOfLines = 1;
        NSString *when = NLHistoryTime(item.start);
        content.secondaryText = item.artist.length ? [NSString stringWithFormat:@"%@ · %@", item.artist, when] : when;
        content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
        content.secondaryTextProperties.numberOfLines = 1;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
        cell.selectionStyle = UITableViewCellSelectionStyleDefault;
    } else {
        content = [UIListContentConfiguration valueCellConfiguration];
        UIImageSymbolConfiguration *symbol = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleSubheadline];
        content.image = [UIImage systemImageNamed:@"pause.circle" withConfiguration:symbol];
        content.imageProperties.tintColor = UIColor.secondaryLabelColor;
        content.imageProperties.reservedLayoutSize = CGSizeMake(kNLHistoryCoverSide, 0);   // in line with the covers
        content.text = NLL(@"Paused");
        content.textProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        content.textProperties.color = UIColor.secondaryLabelColor;
        content.secondaryText = NLHistoryFormatDuration(row.pause, NO);
        content.secondaryTextProperties.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    cell.contentConfiguration = content;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NLHistoryItem *item = _rows[indexPath.row].item;
    if (item) NLHistoryPush(self, [[NLHistorySongController alloc] initWithItem:item]);
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NLHistoryItem *item = _rows[indexPath.row].item;
    if (!item) return [UISwipeActionsConfiguration configurationWithActions:@[]];
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                         title:NLL(@"Delete")
                                                                       handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        NLHistoryDeletePlays(item.day, [NSSet setWithObject:item.identifier], ^{ [self nlLoad]; });
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

@end

#pragma mark - The first page

@interface NLHistoryController : NLTablePage
@end

typedef NS_ENUM(NSInteger, NLHistorySection) {
    NLHistorySectionWeek,
    NLHistorySectionTopSongs,
    NLHistorySectionSettings,
    NLHistorySectionDelete,
    NLHistorySectionCount,
};

@interface NLHistoryController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation NLHistoryController {
    NSArray<NLHistoryItem *> *_items;      // every play, newest first
    NLHistoryApps *_apps;
    NLActivityPeriod *_week;
    NSArray<NLSongUsage *> *_topSongs;
    NLActivityCardCell *_cardCell;
    NLActivityChartView *_chart;
    BOOL _loaded;
    NSUInteger _loads;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NLL(@"Listening History");
    [_table registerClass:[NLUsageCell class] forCellReuseIdentifier:@"usage"];
    _chart = [NLActivityChartView new];
    _chart.userInteractionEnabled = NO;   // the whole card opens All Activity
    _cardCell = [[NLActivityCardCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    _cardCell.chartView = _chart;
    NLHistoryObserve(self, @selector(nlLoad));
    // The root page re-themes the list pages only; this one sets its switch itself.
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(nlThemeChanged)
                                               name:NLThemeChangedNotification object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self nlLoad];
}

- (void)nlThemeChanged {
    NLThemeTable(_table);
}

- (void)nlLoad {
    NSUInteger load = ++_loads;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NLHistoryItem *> *items = NLHistoryLoadAll();
        NLHistoryApps *apps = [NLHistoryApps appsForItems:items];
        NLActivityPeriod *week = [NLActivityPeriod periodWithScale:NLActivityScaleWeek containingDate:[NSDate date] items:items apps:apps];
        NSArray<NLSongUsage *> *top = NLSongUsages(week.items, week.start, week.end);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (load != self->_loads) return;
            self->_items = items;
            self->_apps = apps;
            self->_week = week;
            self->_topSongs = [top subarrayWithRange:NSMakeRange(0, MIN(top.count, kNLTopSongs))];
            self->_loaded = YES;
            self->_chart.period = week;
            [self->_cardCell showTitle:week.title caption:NLL(@"Daily Average") value:NLHistoryDuration(week.dailyAverage)
                             durations:week.durations apps:apps];
            [self->_table reloadData];
        });
    });
}

#pragma mark Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _loaded ? (_items.count ? NLHistorySectionCount : NLHistorySectionDelete) : 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch (section) {
        case NLHistorySectionWeek: return 2;
        case NLHistorySectionTopSongs: return MAX(_topSongs.count, 1);
        case NLHistorySectionSettings: return 2;
        default: return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == NLHistorySectionTopSongs ? NLL(@"Most Played This Week") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == NLHistorySectionSettings) return NLL(@"SpringBoard writes down every song you play for 30 seconds or half its length, in any app. The history stays on this iPhone.");
    return nil;
}

- (BOOL)nlOn {
    return [self nlBoolPref:NL_HISTORY_PREF fallback:NO];
}

- (NSInteger)nlKeepDays {
    return MAX((NSInteger)NLLooseNum([self nlPref:NL_HISTORY_DAYS_PREF], kNLHistoryDefaultDays), 0);
}

- (UITableViewCell *)nlSettingsCell:(NSInteger)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (row == 0) {
        cell.textLabel.text = NLL(@"Record Listening History");
        cell.imageView.image = NLSettingsIcon(@"clock.arrow.circlepath", @"#FF9500");
        UISwitch *toggle = [UISwitch new];
        toggle.on = [self nlOn];
        [toggle addTarget:self action:@selector(nlSwitchChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        NLThemeCell(cell);
    } else {
        cell.textLabel.text = NLL(@"Keep History");
        cell.imageView.image = NLSettingsIcon(@"calendar", @"#FF3B30");
        NSArray *titles = @[NLL(@"30 Days"), NLL(@"90 Days"), NLL(@"1 Year"), NLL(@"Forever")];
        __weak typeof(self) weakSelf = self;
        cell.accessoryView = NLPopUpButton(titles, @[@30, @90, @365, @0], @([self nlKeepDays]), ^(id value) { [weakSelf nlKeepChanged:value]; });
    }
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch (indexPath.section) {
        case NLHistorySectionWeek: {
            if (indexPath.row == 0) return _cardCell;
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
            cell.textLabel.text = NLL(@"Show All Activity");
            cell.textLabel.textColor = UIColor.tintColor;   // the theme's, when it changes too
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            return cell;
        }
        case NLHistorySectionTopSongs: {
            if (!_topSongs.count) {
                return NLNoteCell(_items.count ? NLL(@"No plays this week") : [self nlOn] ? NLL(@"No listening history yet")
                                                                                         : NLL(@"Turn on Record Listening History to start."));
            }
            NLUsageCell *cell = [tableView dequeueReusableCellWithIdentifier:@"usage" forIndexPath:indexPath];
            NLSongUsage *usage = _topSongs[indexPath.row];
            NSTimeInterval longest = _topSongs.firstObject.duration;
            [cell showUsage:usage fraction:longest > 0 ? usage.duration / longest : 0
                      color:[_apps colorForCategory:[_apps categoryForApp:usage.item.app]]];
            return cell;
        }
        case NLHistorySectionSettings: return [self nlSettingsCell:indexPath.row];
        default: return NLActionCell(NLL(@"Delete All History…"), @"trash", UIColor.systemRedColor);
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    switch (indexPath.section) {
        case NLHistorySectionWeek:
            NLHistoryPush(self, [[NLHistoryActivityController alloc] initWithScale:NLActivityScaleWeek date:[NSDate date]]);
            break;
        case NLHistorySectionTopSongs:
            if (indexPath.row < (NSInteger)_topSongs.count) NLHistoryPush(self, [[NLHistorySongController alloc] initWithItem:_topSongs[indexPath.row].item]);
            break;
        case NLHistorySectionDelete:
            NLConfirm(self, NLL(@"Delete all listening history?"), NLL(@"This can't be undone."), NLL(@"Delete"), ^{
                NLHistoryDeleteAll(^{ [self nlLoad]; });
            });
            break;
    }
}

#pragma mark Settings

- (void)nlSwitchChanged:(UISwitch *)toggle {
    [self nlSetPref:@(toggle.on) forKey:NL_HISTORY_PREF];
    if (!_topSongs.count) [_table reloadSections:[NSIndexSet indexSetWithIndex:NLHistorySectionTopSongs] withRowAnimation:UITableViewRowAnimationNone];
}

// Fewer days than kept now deletes the older ones: asked first when there are some.
- (void)nlKeepChanged:(NSNumber *)days {
    NSInteger keep = days.integerValue;
    NSDate *oldest = keep > 0 ? [NSCalendar.currentCalendar dateByAddingUnit:NSCalendarUnitDay value:-(keep - 1)
                                                                       toDate:[NSCalendar.currentCalendar startOfDayForDate:[NSDate date]] options:0] : nil;
    BOOL losesSome = oldest && _items.lastObject && [_items.lastObject.start compare:oldest] == NSOrderedAscending;
    // SpringBoard deletes them, and says so (the page loads again).
    void (^apply)(void) = ^{ [self nlSetPref:days forKey:NL_HISTORY_DAYS_PREF]; };
    if (!losesSome) {
        apply();
        return;
    }
    NLPresentAlert(self, NLL(@"Delete older history?"), NLL(@"Days past the new limit are deleted."), @[
        [UIAlertAction actionWithTitle:NLL(@"Cancel") style:UIAlertActionStyleCancel handler:^(UIAlertAction *a) {
            [self->_table reloadSections:[NSIndexSet indexSetWithIndex:NLHistorySectionSettings] withRowAnimation:UITableViewRowAnimationNone];
        }],
        [UIAlertAction actionWithTitle:NLL(@"Delete") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { apply(); }],
    ]);
}

@end
