//
//  NLHistoryController.m
//  Listening History (NLHistory.h, NLHistoryPages.h): what SpringBoard wrote down.
//
//  - The first page, as Screen Time's: This Week (the daily average, a bar a
//    day stacked by app, the apps' times; a press shows a day's) and Show
//    All Activity (NLHistoryActivity.m); this week's Most Played; the switch,
//    how long to keep it, whether skipped songs show; export and import (one
//    JSON file, covers in it), and Delete All History.
//  - A day's timeline: each song in order (skipped ones greyed), the pauses
//    of five minutes or more between them; the date bar on top goes to the
//    day before or after with plays. Swipe to delete; a long press listens
//    to a song again (NLListen.m), as on every song's row.
//  - A song: its card in its cover's color with its first lines (to the
//    editor), Listen in the app it played in and More Ways to Listen, its
//    plays, time, first and last play as tiles, its week's chart and its own
//    offset, as Now Playing has it for the song on now.
//
//  The pages load again when SpringBoard writes (NL_HISTORY_WRITTEN_NOTIFICATION).
//

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "NLHistoryPages.h"
#import "NLOffsetControl.h"
#import "../NLIslandStrip.h"

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
    item.skipped = NLLooseBool(entry[NL_HP_SKIPPED], NO);
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

// Every play of the day, read again only once its file has changed: the pages
// load every day whenever SpringBoard writes (each minute while a song
// plays), and it is mostly today's that did.
static NSArray<NLHistoryItem *> *NLHistoryAllOfDay(NSString *day) {
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

NSArray<NLHistoryItem *> *NLHistoryItemsOfDay(NSString *day, BOOL skipped) {
    NSArray<NLHistoryItem *> *items = NLHistoryAllOfDay(day);
    return skipped ? items : [items filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"skipped == NO"]];
}

NSArray<NLHistoryItem *> *NLHistoryLoadAll(BOOL skipped) {
    NSMutableArray<NLHistoryItem *> *all = [NSMutableArray array];
    for (NSString *day in NLHistoryDays()) {   // newest first
        [all addObjectsFromArray:NLHistoryItemsOfDay(day, skipped).reverseObjectEnumerator.allObjects];
    }
    return all;
}

BOOL NLHistoryShowsSkipped(PSViewController *page) {
    return [page nlBoolPref:NL_HISTORY_SKIPPED_PREF fallback:YES];
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

static NSString *NLHistoryDateString(NSString *template, NSDate *date) {
    NSDateFormatter *formatter = NLHistoryFormatter(template, ^id {
        NSDateFormatter *made = [NSDateFormatter new];
        [made setLocalizedDateFormatFromTemplate:template];
        return made;
    });
    return [formatter stringFromDate:date];
}

NSString *NLHistoryDayTitle(NSDate *date) {
    NSCalendar *calendar = NSCalendar.currentCalendar;
    BOOL thisYear = [calendar component:NSCalendarUnitYear fromDate:date] == [calendar component:NSCalendarUnitYear fromDate:[NSDate date]];
    NSString *day = [calendar isDateInToday:date] ? NLL(@"Today") : [calendar isDateInYesterday:date] ? NLL(@"Yesterday")
                                                                                                     : NLHistoryDateString(@"EEEE", date);
    return [NSString stringWithFormat:NLL(@"%@, %@"), day, NLHistoryDateString(thisYear ? @"MMMd" : @"yMMMd", date)];
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
        made.unitsStyle = NSDateComponentsFormatterUnitsStyleAbbreviated;   // 1時53分, 1h 53m, as Screen Time's
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

UIImage *NLHistoryAppIcon(NSString *bundleID, CGFloat side) {
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *cacheKey = [NSString stringWithFormat:@"%@@%.0f", bundleID ?: @"", side];
    UIImage *cached = [cache objectForKey:cacheKey];
    if (cached) return cached;
    UIImage *icon = bundleID.length ? NLAppIcon(bundleID) : nil;
    if (!icon) return NLHistoryCover(nil, side);
    CGRect tile = CGRectMake(0, 0, side, side);
    UIImage *image = [[[UIGraphicsImageRenderer alloc] initWithSize:tile.size] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithRoundedRect:tile cornerRadius:side * 0.225] addClip];
        [icon drawInRect:tile];
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

// The song's card, as a lyrics card: its cover's color behind the cover, the
// title and the artist, its first lines (the saved lyrics) and Edit.
@interface NLSongCardCell : UITableViewCell
- (void)showItem:(NLHistoryItem *)item lines:(NSArray<NSString *> *)lines editable:(BOOL)editable color:(UIColor *)color;
@end

static const CGFloat kNLSongCoverSide = 56;
static const NSUInteger kNLSongCardLines = 3;

// A deep shade of the cover's color, which white reads on; grey for a cover without one.
static UIColor *NLSongCardColor(UIColor *cover) {
    CGFloat h = 0, s = 0, b = 0, a = 1;
    if (!cover || ![cover getHue:&h saturation:&s brightness:&b alpha:&a] || s < 0.12) return [UIColor colorWithWhite:0.26 alpha:1];
    return [UIColor colorWithHue:h saturation:MIN(MAX(s, 0.35), 0.65) brightness:0.45 alpha:1];
}

static UILabel *NLSongCardLabel(UIFontTextStyle style, BOOL bold, CGFloat alpha, NSInteger lines) {
    UILabel *label = [UILabel new];
    UIFontDescriptor *descriptor = [UIFontDescriptor preferredFontDescriptorWithTextStyle:style];
    if (bold) descriptor = [descriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold];
    label.font = [UIFont fontWithDescriptor:descriptor size:0];
    label.adjustsFontForContentSizeCategory = YES;
    label.textColor = [UIColor colorWithWhite:1 alpha:alpha];
    label.numberOfLines = lines;
    return label;
}

@implementation NLSongCardCell {
    UIImageView *_cover;
    UILabel *_title, *_artist, *_note, *_edit;
    NSArray<UILabel *> *_lines;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _cover = [UIImageView new];
    _title = NLSongCardLabel(UIFontTextStyleHeadline, NO, 1, 2);
    _artist = NLSongCardLabel(UIFontTextStyleSubheadline, NO, 0.75, 2);
    UIStackView *names = [[UIStackView alloc] initWithArrangedSubviews:@[_title, _artist]];
    names.axis = UILayoutConstraintAxisVertical;
    names.spacing = 2;
    UIStackView *head = [[UIStackView alloc] initWithArrangedSubviews:@[_cover, names]];
    head.alignment = UIStackViewAlignmentCenter;
    head.spacing = 12;
    NSMutableArray<UILabel *> *lines = [NSMutableArray array];
    for (NSUInteger i = 0; i < kNLSongCardLines; i++) [lines addObject:NLSongCardLabel(UIFontTextStyleTitle3, YES, i + 1 < kNLSongCardLines ? 0.95 : 0.5, 2)];
    _lines = lines;
    UIStackView *lyrics = [[UIStackView alloc] initWithArrangedSubviews:lines];
    lyrics.axis = UILayoutConstraintAxisVertical;
    lyrics.spacing = 4;
    _note = NLSongCardLabel(UIFontTextStyleFootnote, NO, 0.75, 0);
    [_note setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    _edit = NLSongCardLabel(UIFontTextStyleFootnote, NO, 0.75, 1);
    [_edit setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [_edit setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *foot = [[UIStackView alloc] initWithArrangedSubviews:@[_note, _edit]];
    foot.alignment = UIStackViewAlignmentFirstBaseline;
    foot.spacing = 8;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[head, lyrics, foot]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 14;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];
    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_cover.widthAnchor constraintEqualToConstant:kNLSongCoverSide],
        [_cover.heightAnchor constraintEqualToConstant:kNLSongCoverSide],
        [stack.topAnchor constraintEqualToAnchor:margins.topAnchor constant:6],
        [stack.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor constant:-6],
        [stack.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
    ]];
    return self;
}

- (void)showItem:(NLHistoryItem *)item lines:(NSArray<NSString *> *)lines editable:(BOOL)editable color:(UIColor *)color {
    UIBackgroundConfiguration *background = [UIBackgroundConfiguration listGroupedCellConfiguration];
    background.backgroundColor = color;
    self.backgroundConfiguration = background;
    _cover.image = NLHistoryCover(item.art, kNLSongCoverSide);
    _title.text = item.title;
    _artist.text = NLJoinNonEmpty(item.artist, item.album, @" — ");
    _artist.hidden = !_artist.text.length;
    for (NSUInteger i = 0; i < _lines.count; i++) {
        _lines[i].text = i < lines.count ? lines[i] : nil;
        _lines[i].hidden = i >= lines.count;
    }
    _note.text = lines.count ? NLL(@"Lyrics") : NLL(@"No lyrics saved for this song yet.");
    NSMutableAttributedString *edit = [[NSMutableAttributedString alloc] initWithString:[NLL(@"Edit") stringByAppendingString:@" "]];
    UIImage *chevron = [UIImage systemImageNamed:@"chevron.right" withConfiguration:[UIImageSymbolConfiguration configurationWithFont:_edit.font scale:UIImageSymbolScaleSmall]];
    [edit appendAttributedString:[NSAttributedString attributedStringWithAttachment:[NSTextAttachment textAttachmentWithImage:
        [chevron imageWithTintColor:_edit.textColor renderingMode:UIImageRenderingModeAlwaysOriginal]]]];
    _edit.attributedText = edit;
    _edit.hidden = !editable;
}

@end

// Listen in the app it played in, and More Ways to Listen (the others, Share),
// side by side under the card.
@interface NLSongListenCell : UITableViewCell
@property (nonatomic, readonly) UIButton *listenButton, *moreButton;
@end

@implementation NLSongListenCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
    _listenButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _moreButton = [UIButton buttonWithType:UIButtonTypeSystem];
    _moreButton.showsMenuAsPrimaryAction = YES;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[_listenButton, _moreButton]];
    stack.distribution = UIStackViewDistributionFillEqually;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
        [stack.heightAnchor constraintGreaterThanOrEqualToConstant:50],
    ]];
    return self;
}

@end

static UIButtonConfiguration *NLSongButton(NSString *title, UIColor *fill, UIColor *text, UIImage *trailing) {
    UIButtonConfiguration *configuration = [UIButtonConfiguration filledButtonConfiguration];
    configuration.cornerStyle = UIButtonConfigurationCornerStyleLarge;
    configuration.baseBackgroundColor = fill;
    configuration.baseForegroundColor = text;
    configuration.title = title;
    configuration.titleLineBreakMode = NSLineBreakByTruncatingTail;
    configuration.titleTextAttributesTransformer = ^NSDictionary *(NSDictionary *attributes) {
        NSMutableDictionary *changed = [attributes mutableCopy];
        changed[NSFontAttributeName] = [UIFont fontWithDescriptor:[[UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleSubheadline]
                                                                   fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold] size:0];
        return changed;
    };
    configuration.image = trailing;
    configuration.imagePlacement = NSDirectionalRectEdgeTrailing;
    configuration.imagePadding = 4;
    configuration.preferredSymbolConfigurationForImage = [UIImageSymbolConfiguration configurationWithTextStyle:UIFontTextStyleFootnote scale:UIImageSymbolScaleSmall];
    return configuration;
}

// One of the song's numbers on a tile of its own, as Health's: a colored
// symbol and name, the number big with its units small, a note under it.
@interface NLSongTile : UIView
- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol color:(UIColor *)color;
- (void)showValue:(NSAttributedString *)value detail:(NSString *)detail;
@end

@implementation NLSongTile {
    UILabel *_value, *_detail;
}

- (instancetype)initWithTitle:(NSString *)title symbol:(NSString *)symbol color:(UIColor *)color {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
    self.layer.cornerRadius = 10;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    UILabel *name = [UILabel new];
    UIFont *font = [UIFont fontWithDescriptor:[[UIFontDescriptor preferredFontDescriptorWithTextStyle:UIFontTextStyleFootnote]
                                               fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold] size:0];
    NSMutableAttributedString *text = [NSMutableAttributedString new];
    UIImage *image = [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithFont:font]];
    [text appendAttributedString:[NSAttributedString attributedStringWithAttachment:[NSTextAttachment textAttachmentWithImage:
        [image imageWithTintColor:color renderingMode:UIImageRenderingModeAlwaysOriginal]]]];
    [text appendAttributedString:[[NSAttributedString alloc] initWithString:[@" " stringByAppendingString:title]
                                                                 attributes:@{NSFontAttributeName: font, NSForegroundColorAttributeName: color}]];
    name.attributedText = text;
    name.adjustsFontSizeToFitWidth = YES;
    name.minimumScaleFactor = 0.7;
    _value = [UILabel new];
    _value.numberOfLines = 2;
    _value.adjustsFontSizeToFitWidth = YES;
    _value.minimumScaleFactor = 0.7;
    _detail = [UILabel new];
    _detail.font = [UIFont preferredFontForTextStyle:UIFontTextStyleCaption1];
    _detail.textColor = UIColor.secondaryLabelColor;
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[name, _value, _detail]];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 4;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.topAnchor constant:10],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:self.bottomAnchor constant:-10],
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
    ]];
    return self;
}

- (void)showValue:(NSAttributedString *)value detail:(NSString *)detail {
    _value.attributedText = value;
    _detail.text = detail;
    _detail.hidden = !detail.length;
}

@end

// A count or a time: its digits big, the units between them small and grey.
static NSAttributedString *NLSongTileNumber(NSString *text) {
    UIFont *big = [UIFont preferredFontForTextStyle:UIFontTextStyleTitle2];
    NSDictionary *unit = @{NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline],
                           NSForegroundColorAttributeName: UIColor.secondaryLabelColor};
    NSMutableAttributedString *string = [[NSMutableAttributedString alloc] initWithString:text ?: @""
                                                                               attributes:@{NSFontAttributeName: big, NSForegroundColorAttributeName: UIColor.labelColor}];
    NSCharacterSet *digits = NSCharacterSet.decimalDigitCharacterSet;
    [text enumerateSubstringsInRange:NSMakeRange(0, text.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *character, NSRange range, NSRange enclosing, BOOL *stop) {
        if ([character rangeOfCharacterFromSet:digits].location == NSNotFound && ![character isEqualToString:@":"]) [string addAttributes:unit range:range];
    }];
    return string;
}

static NSAttributedString *NLSongTileText(NSString *text) {
    return [[NSAttributedString alloc] initWithString:text ?: @"" attributes:@{
        NSFontAttributeName: [UIFont preferredFontForTextStyle:UIFontTextStyleBody], NSForegroundColorAttributeName: UIColor.labelColor}];
}

// Plays, Listening Time, First Played, Last Played: two by two.
@interface NLSongTilesCell : UITableViewCell
@property (nonatomic, readonly) NLSongTile *plays, *listened, *first, *last;
@end

@implementation NLSongTilesCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if (!(self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) return nil;
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundConfiguration = [UIBackgroundConfiguration clearConfiguration];
    _plays = [[NLSongTile alloc] initWithTitle:NLL(@"Plays") symbol:@"play.fill" color:UIColor.systemPinkColor];
    _listened = [[NLSongTile alloc] initWithTitle:NLL(@"Listening Time") symbol:@"clock.fill" color:UIColor.systemGreenColor];
    _first = [[NLSongTile alloc] initWithTitle:NLL(@"First Played") symbol:@"calendar" color:UIColor.systemBlueColor];
    _last = [[NLSongTile alloc] initWithTitle:NLL(@"Last Played") symbol:@"clock.arrow.circlepath" color:UIColor.systemOrangeColor];
    NSMutableArray<UIStackView *> *rows = [NSMutableArray array];
    for (NSArray *pair in @[@[_plays, _listened], @[_first, _last]]) {
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:pair];
        row.distribution = UIStackViewDistributionFillEqually;
        row.spacing = 10;
        [rows addObject:row];
    }
    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:rows];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.contentView.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor],
        [stack.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor],
    ]];
    return self;
}

@end

// The song's page: its card (Edit opens the editor), how to listen to it
// again, its numbers, its week's chart (a tapped day opens that day) and its offset.
typedef NS_ENUM(NSInteger, NLSongSection) { NLSongSectionCard, NLSongSectionListen, NLSongSectionNumbers, NLSongSectionWeek, NLSongSectionOffset };

@implementation NLHistorySongController {
    NLHistoryItem *_item;
    UITableView *_table;
    NSArray<NSNumber *> *_sections;
    NLSongCardCell *_cardCell;
    NLSongListenCell *_listenCell;
    NLSongTilesCell *_tilesCell;
    NLActivityCardCell *_weekCell;
    NLActivityChartView *_chart;
    NLActivityPeriod *_week;       // the week of its latest play
    NSString *_folder;        // the app's Library/NowLyrics; nil when NowLyrics never ran there
    NSString *_lyricsPath;    // the song's lyrics there, added by hand or saved; nil without
    BOOL _loaded;
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
    _cardCell = [[NLSongCardCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    _listenCell = [[NLSongListenCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    [_listenCell.listenButton addTarget:self action:@selector(nlListen) forControlEvents:UIControlEventTouchUpInside];
    _tilesCell = [[NLSongTilesCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    // Ours, not Screen Time's: its week scale is in whole hours, and a song's
    // week is minutes. A tapped day opens its timeline.
    __weak typeof(self) weakSelf = self;
    _chart = [NLActivityChartView new];
    __weak NLActivityChartView *weakChart = _chart;
    _chart.didSelectBar = ^(NSInteger index) {
        if (index == NSNotFound) return;
        weakChart.selectedIndex = NSNotFound;
        [weakSelf nlOpenDay:weakChart.period.bars[index].start];
    };
    _weekCell = [[NLActivityCardCell alloc] initWithScreenTime:NO];
    _weekCell.selectionStyle = UITableViewCellSelectionStyleNone;
    _weekCell.chartView = _chart;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self nlLoad];   // again after the editor saved or deleted
}

- (void)nlOpenDay:(NSDate *)day {
    NLHistoryPush(self, [[NLHistoryDayController alloc] initWithDay:NLHistoryDayKey(day)]);
}

- (void)nlListen {
    NSArray<NSString *> *apps = NLListenApps(_item);
    if (apps.count) NLListen(_item, apps.firstObject);
}

- (NSString *)nlDateString:(NSDate *)date {
    NSDateFormatter *dates = NLHistoryFormatter(@"first played", ^id {
        NSDateFormatter *made = [NSDateFormatter new];
        made.dateStyle = NSDateFormatterMediumStyle;
        made.timeStyle = NSDateFormatterShortStyle;
        made.doesRelativeDateFormatting = YES;
        return made;
    });
    return date ? [dates stringFromDate:date] : @"";
}

- (void)nlLoad {
    NLHistoryItem *item = _item;
    BOOL skipped = NLHistoryShowsSkipped(self);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableArray<NLHistoryItem *> *mine = [NSMutableArray array];
        NSUInteger skips = 0;
        double listened = 0;
        for (NLHistoryItem *other in NLHistoryLoadAll(skipped)) {   // newest first
            if (![other isSameSongAs:item]) continue;
            [mine addObject:other];
            if (other.skipped) skips++;
            listened += other.listened;
        }
        NLHistoryApps *apps = [NLHistoryApps appsForItems:mine];
        NSDate *latest = mine.firstObject.start ?: item.start ?: [NSDate date];
        NLActivityPeriod *week = [NLActivityPeriod periodWithScale:NLActivityScaleWeek containingDate:latest items:mine apps:apps];
        NSString *artPath = NLHistoryArtworkPath(item.art);
        NSData *art = artPath ? [NSData dataWithContentsOfFile:artPath] : nil;
        UIColor *color = NLSongCardColor(art ? NLColorFromArtwork(art) : nil);
        NSArray<NSString *> *listenApps = NLListenApps(item);
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
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSString *text = lyrics ? [NSString stringWithContentsOfFile:lyrics encoding:NSUTF8StringEncoding error:nil] : nil;
        for (NLLyricLine *line in text ? NLParseLRC(text) : @[]) {
            NSString *words = [line.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            if (words.length) [lines addObject:words];
            if (lines.count == kNLSongCardLines) break;
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_week = week;
            self->_folder = folder;
            self->_lyricsPath = lyrics;
            self->_loaded = YES;
            [self->_cardCell showItem:item lines:lines editable:lyrics != nil color:color];
            [self nlShowListenApps:listenApps];
            NLSongTilesCell *tiles = self->_tilesCell;
            [tiles.plays showValue:NLSongTileNumber(NLHistoryCount(mine.count, @"1 time", @"%lu times"))
                            detail:skips ? [NSString stringWithFormat:NLL(@"Skipped %@"), NLHistoryCount(skips, @"1 time", @"%lu times")] : nil];
            [tiles.listened showValue:NLSongTileNumber(NLHistoryDuration(listened)) detail:nil];
            [tiles.first showValue:NLSongTileText([self nlDateString:mine.lastObject.start]) detail:nil];
            [tiles.last showValue:NLSongTileText([self nlDateString:mine.firstObject.start]) detail:nil];
            // The week's time, not its daily average: a song is played on a day or two.
            self->_chart.period = week;
            [self->_weekCell showTitle:NLL(@"Listening Time") value:NLHistoryDuration(week.total) trend:nil rising:NO
                             durations:week.durations apps:apps];
            NSMutableArray *sections = [NSMutableArray arrayWithObjects:@(NLSongSectionCard), @(NLSongSectionListen), @(NLSongSectionNumbers), nil];
            if (mine.count) [sections addObject:@(NLSongSectionWeek)];
            if (folder && item.key.length) [sections addObject:@(NLSongSectionOffset)];
            self->_sections = sections;
            [self->_table reloadData];
        });
    });
}

// The app it played in on the left; the other music apps and Share in More.
- (void)nlShowListenApps:(NSArray<NSString *> *)apps {
    UIButton *listen = _listenCell.listenButton, *more = _listenCell.moreButton;
    NSString *first = apps.firstObject;
    listen.hidden = !first;
    if (first) {
        UIColor *text = nil;
        UIColor *fill = NLListenColor(first, &text);
        listen.configuration = NLSongButton(NLListenTitle(first), fill, text, nil);
    }
    more.configuration = NLSongButton(NLL(@"More Ways to Listen"), UIColor.tertiarySystemFillColor, UIColor.labelColor,
                                      [UIImage systemImageNamed:@"chevron.down"]);
    NSArray<NSString *> *others = apps.count > 1 ? [apps subarrayWithRange:NSMakeRange(1, apps.count - 1)] : @[];
    more.menu = NLListenMenu(_item, others, self, more);
}

- (NLSongSection)nlSection:(NSInteger)section {
    return (NLSongSection)_sections[section].integerValue;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return _loaded ? (NSInteger)_sections.count : 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ([self nlSection:section]) {
        case NLSongSectionWeek: return _week.title;
        case NLSongSectionOffset: return NLL(@"Offset");
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return [self nlSection:section] == NLSongSectionOffset ? NLL(@"This song's own offset, on top of the default one.") : nil;
}

// The card, its buttons and its numbers close together.
- (CGFloat)tableView:(UITableView *)tableView heightForHeaderInSection:(NSInteger)section {
    switch ([self nlSection:section]) {
        case NLSongSectionCard: return 16;
        case NLSongSectionListen:
        case NLSongSectionNumbers: return 12;
        default: return UITableViewAutomaticDimension;
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    switch ([self nlSection:section]) {
        case NLSongSectionCard:
        case NLSongSectionListen: return CGFLOAT_MIN;
        case NLSongSectionOffset: return UITableViewAutomaticDimension;
        default: return 12;   // before a titled one
    }
}

// Without views of their own the table keeps its usual space for them.
- (UIView *)tableView:(UITableView *)tableView viewForHeaderInSection:(NSInteger)section {
    return [self tableView:tableView titleForHeaderInSection:section] ? nil : [UIView new];
}

- (UIView *)tableView:(UITableView *)tableView viewForFooterInSection:(NSInteger)section {
    return [self tableView:tableView titleForFooterInSection:section] ? nil : [UIView new];
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return [self nlSection:indexPath.section] == NLSongSectionOffset ? kNLStackedRowHeight : UITableViewAutomaticDimension;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    switch ([self nlSection:indexPath.section]) {
        case NLSongSectionCard: return _cardCell;
        case NLSongSectionListen: return _listenCell;
        case NLSongSectionNumbers: return _tilesCell;
        case NLSongSectionWeek: return _weekCell;
        case NLSongSectionOffset: {
            double offset = [self nlDefaultOffset] + NLTrackOffset(@{NL_TRACK_OFFSETS_KEY: [self nlOffsets]}, _item.key);
            return NLSongOffsetRow(offset, self, @selector(nlOffsetChanged:));
        }
    }
    return [UITableViewCell new];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self nlSection:indexPath.section] != NLSongSectionCard || !_lyricsPath) return;
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
    NLDateBar *_dateBar;
    NSString *_status;                       // its songs and their time, over them
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
    self.title = NLL(@"Timeline");
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    self.navigationItem.rightBarButtonItem = NLApplyButton(self);
    _table = NLMakeTable(self);
    _table.estimatedRowHeight = 60;

    // The day stays on top with buttons to the days around it, as All
    // Activity's once its chart has gone; the list starts under it.
    _dateBar = [NLDateBar barOnPage:self];
    [_dateBar.previousButton addTarget:self action:@selector(nlPreviousDay) forControlEvents:UIControlEventTouchUpInside];
    [_dateBar.nextButton addTarget:self action:@selector(nlNextDay) forControlEvents:UIControlEventTouchUpInside];
    _dateBar.previousButton.accessibilityLabel = NLL(@"Previous Day");
    _dateBar.nextButton.accessibilityLabel = NLL(@"Next Day");
    [_dateBar setShown:YES animated:NO];
    _table.contentInset = UIEdgeInsetsMake(NLDateBar.height, 0, 0, 0);
    _table.verticalScrollIndicatorInsets = _table.contentInset;

    NLHistoryObserve(self, @selector(nlLoad));
    [self nlShowDay:_day];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if (_loaded) [self nlLoad];   // back from a song: its plays may be gone
}

- (void)nlShowDay:(NSString *)day {
    _day = [day copy];
    NSDate *date = NLHistoryDayDate(day);
    _dateBar.titleLabel.text = date ? NLHistoryDayTitle(date) : day;
    _items = nil;
    _rows = nil;
    _loaded = NO;
    [_table reloadData];
    [_table setContentOffset:CGPointMake(0, -_table.adjustedContentInset.top) animated:NO];
    [self nlLoad];
}

- (void)nlLoad {
    NSString *day = _day;
    BOOL skipped = NLHistoryShowsSkipped(self);
    NSUInteger load = ++_loads;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NSString *> *days = NLHistoryDays();
        NSArray<NLHistoryItem *> *items = NLHistoryItemsOfDay(day, skipped);
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

    _dateBar.previousButton.enabled = [self nlNeighbour:+1] != nil;
    _dateBar.nextButton.enabled = [self nlNeighbour:-1] != nil;
    _status = _items.count ? [NSString stringWithFormat:@"%@ · %@", NLHistorySongCount(_items.count),
                              NLHistoryDuration(NLHistoryTotalListened(_items))] : nil;
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

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return _status;
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
        // A skipped one greyed, and said so after its time.
        if (item.skipped) content.textProperties.color = UIColor.secondaryLabelColor;
        NSString *when = item.skipped ? [NSString stringWithFormat:@"%@ · %@", NLHistoryTime(item.start), NLL(@"Skipped")] : NLHistoryTime(item.start);
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

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    return NLSongContextMenu(_rows[indexPath.row].item, self);
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
    NLHistorySectionBackup,    // export (with plays), import
    NLHistorySectionDelete,
    NLHistorySectionCount,
};

typedef NS_ENUM(NSInteger, NLHistorySetting) {
    NLHistorySettingRecord,
    NLHistorySettingKeep,
    NLHistorySettingSkipped,
    NLHistorySettingCount,
};

@interface NLHistoryController () <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@end

@implementation NLHistoryController {
    NSArray<NLHistoryItem *> *_items;      // every play, newest first
    NSArray<NLUsage *> *_topSongs;
    NLHistoryApps *_apps;                  // the bars' colors
    NLActivityCardCell *_cardCell;
    UIView *_chart;                        // Screen Time's own (NLScreenTimeChartView), else ours (NLActivityChartView)
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
    // A press shows a day; a tap still opens All Activity (the card's).
    _chart = NLScreenTimeChartsAvailable() ? [[NLScreenTimeChartView alloc] initTitled:YES] : [NLActivityChartView new];
    _cardCell = [[NLActivityCardCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    _cardCell.chartView = _chart;
    if ([_chart isKindOfClass:NLScreenTimeChartView.class]) _cardCell.chartHeight = [NLScreenTimeChartView heightTitled:YES];
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
    BOOL skipped = NLHistoryShowsSkipped(self);
    NSUInteger load = ++_loads;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSArray<NLHistoryItem *> *items = NLHistoryLoadAll(skipped);
        NLHistoryApps *apps = [NLHistoryApps appsForItems:items];
        NLActivityPeriod *week = [NLActivityPeriod periodWithScale:NLActivityScaleWeek containingDate:[NSDate date] items:items apps:apps];
        NLActivityPeriod *lastWeek = [NLActivityPeriod periodWithScale:NLActivityScaleWeek containingDate:[week.start dateByAddingTimeInterval:-1]
                                                                 items:items apps:apps];   // for the trend
        NSArray<NLUsage *> *top = NLUsages(week.items, week.start, week.end, NLUsageKindSongs);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (load != self->_loads) return;
            self->_items = items;
            self->_apps = apps;
            self->_topSongs = [top subarrayWithRange:NSMakeRange(0, MIN(top.count, kNLTopSongs))];
            self->_loaded = YES;
            BOOL rising = NO;
            NSString *trend = NLActivityTrend(week, lastWeek, &rising);
            if ([self->_chart isKindOfClass:NLScreenTimeChartView.class]) {
                [(NLScreenTimeChartView *)self->_chart showPeriod:week selectedDay:nil title:NLL(@"Daily Average")
                                                            value:NLHistoryDuration(week.dailyAverage) trend:trend rising:rising];
            } else {
                ((NLActivityChartView *)self->_chart).period = week;
            }
            [self->_cardCell showTitle:NLL(@"Daily Average") value:NLHistoryDuration(week.dailyAverage) trend:trend rising:rising
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
        case NLHistorySectionSettings: return NLHistorySettingCount;
        case NLHistorySectionBackup: return _items.count ? 2 : 1;
        default: return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return section == NLHistorySectionTopSongs ? NLL(@"Most Played This Week") : nil;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == NLHistorySectionSettings) return NLL(@"SpringBoard writes down every song you play, in any app. One played less than 30 seconds (or half of a shorter song) is marked as skipped. The history stays on this iPhone.");
    if (section == NLHistorySectionBackup) return NLL(@"Export saves the history and its covers as one file. Importing adds a file's plays to the history here, or replaces it.");
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
    if (row == NLHistorySettingKeep) {
        cell.textLabel.text = NLL(@"Keep History");
        cell.imageView.image = NLSettingsIcon(@"calendar", @"#FF3B30");
        NSArray *titles = @[NLL(@"30 Days"), NLL(@"90 Days"), NLL(@"1 Year"), NLL(@"Forever")];
        __weak typeof(self) weakSelf = self;
        cell.accessoryView = NLPopUpButton(titles, @[@30, @90, @365, @0], @([self nlKeepDays]), ^(id value) { [weakSelf nlKeepChanged:value]; });
        return cell;
    }
    BOOL record = row == NLHistorySettingRecord;
    cell.textLabel.text = record ? NLL(@"Record Listening History") : NLL(@"Show Skipped Songs");
    cell.imageView.image = record ? NLSettingsIcon(@"clock.arrow.circlepath", @"#FF9500") : NLSettingsIcon(@"forward.end.fill", @"#5856D6");
    UISwitch *toggle = [UISwitch new];
    toggle.on = record ? [self nlOn] : NLHistoryShowsSkipped(self);
    [toggle addTarget:self action:record ? @selector(nlSwitchChanged:) : @selector(nlSkippedChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    NLThemeCell(cell);
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
            NLUsage *usage = _topSongs[indexPath.row];
            NSTimeInterval longest = _topSongs.firstObject.duration;
            [cell showUsage:usage fraction:longest > 0 ? usage.duration / longest : 0
                      color:[_apps colorForCategory:[_apps categoryForApp:usage.item.app]]];
            return cell;
        }
        case NLHistorySectionSettings: return [self nlSettingsCell:indexPath.row];
        case NLHistorySectionBackup: {
            BOOL export = _items.count && indexPath.row == 0;
            return NLActionCell(export ? NLL(@"Export History…") : NLL(@"Import History…"),
                                export ? @"square.and.arrow.up" : @"square.and.arrow.down", UIColor.tintColor);
        }
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
        case NLHistorySectionBackup:
            if (_items.count && indexPath.row == 0) [self nlExportFrom:[tableView cellForRowAtIndexPath:indexPath]];
            else [self nlImport];
            break;
        case NLHistorySectionDelete:
            NLConfirm(self, NLL(@"Delete all listening history?"), NLL(@"This can't be undone."), NLL(@"Delete"), ^{
                NLHistoryDeleteAll(^{ [self nlLoad]; });
            });
            break;
    }
}

- (UIContextMenuConfiguration *)tableView:(UITableView *)tableView contextMenuConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath point:(CGPoint)point {
    if (indexPath.section != NLHistorySectionTopSongs || indexPath.row >= (NSInteger)_topSongs.count) return nil;
    return NLSongContextMenu(_topSongs[indexPath.row].item, self);
}

#pragma mark Export and import

// The history as one file (Listening History 2026-10-14.json), to the share sheet.
- (void)nlExportFrom:(UIView *)source {
    NLHistoryExport(^(NSData *data, NSUInteger plays) {
        NSString *name = [NSString stringWithFormat:@"%@ %@.json", NLL(@"Listening History"), NLHistoryDayKey([NSDate date])];
        NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:name]];
        if (!data || ![data writeToURL:url atomically:YES]) {
            NLAlert(self, NLL(@"Could not export"), nil);
            return;
        }
        UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[url] applicationActivities:nil];
        share.popoverPresentationController.sourceView = source;
        share.popoverPresentationController.sourceRect = source.bounds;
        [self presentViewController:share animated:YES completion:nil];
    });
}

- (void)nlImport {
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeJSON] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *export = NLHistoryReadExport([NSData dataWithContentsOfURL:url]);
        dispatch_async(dispatch_get_main_queue(), ^{ [self nlConfirmImport:export]; });
    });
}

// What the file holds is said first; then its plays are added to the history
// here, or put in its place.
- (void)nlConfirmImport:(NSDictionary *)export {
    NSDictionary<NSString *, NSArray *> *days = export[@"days"];
    NSUInteger plays = 0;
    for (NSArray *dayPlays in days.allValues) plays += dayPlays.count;
    if (!plays) {
        NLAlert(self, NLL(@"Could not import"), NLL(@"This file isn't a NowLyrics listening history."));
        return;
    }
    NSArray<NSString *> *sorted = [days.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSDateFormatter *dates = NLHistoryFormatter(@"import range", ^id {
        NSDateFormatter *made = [NSDateFormatter new];
        made.dateStyle = NSDateFormatterMediumStyle;
        return made;
    });
    NSString *message = [NSString stringWithFormat:NLL(@"%1$@, %2$@ – %3$@."), NLHistoryCount(plays, @"1 play", @"%lu plays"),
                         [dates stringFromDate:NLHistoryDayDate(sorted.firstObject)], [dates stringFromDate:NLHistoryDayDate(sorted.lastObject)]];
    void (^import)(BOOL) = ^(BOOL replace) {
        NLHistoryImport(export, replace, ^(NSUInteger added) {
            [self nlLoad];
            NLAlert(self, [NSString stringWithFormat:NLL(@"Added %@"), NLHistoryCount(added, @"1 play", @"%lu plays")], nil);
        });
    };
    NLPresentAlert(self, NLL(@"Import listening history?"), message, @[
        [UIAlertAction actionWithTitle:NLL(@"Add to History") style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) { import(NO); }],
        [UIAlertAction actionWithTitle:NLL(@"Replace History") style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { import(YES); }],
        [UIAlertAction actionWithTitle:NLL(@"Cancel") style:UIAlertActionStyleCancel handler:nil],
    ]);
}

#pragma mark Settings

- (void)nlSwitchChanged:(UISwitch *)toggle {
    [self nlSetPref:@(toggle.on) forKey:NL_HISTORY_PREF];
    if (!_topSongs.count) [_table reloadSections:[NSIndexSet indexSetWithIndex:NLHistorySectionTopSongs] withRowAnimation:UITableViewRowAnimationNone];
}

// The pages only show them or not; the files keep them either way.
- (void)nlSkippedChanged:(UISwitch *)toggle {
    [self nlSetPref:@(toggle.on) forKey:NL_HISTORY_SKIPPED_PREF];
    [self nlLoad];
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
