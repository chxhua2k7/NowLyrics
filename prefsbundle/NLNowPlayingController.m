//
//  NLNowPlayingController.m
//  "Now Playing": the lock screen's own player at the top (MediaControls'
//  cover sheet platter: artwork, the line being sung as its title, scrubber,
//  transport), then the song as the app really reports it and where its lyrics
//  came from, a source picked for this song, how lines are shown (the artist
//  field, the overall offset, the E badge: changed here, seen in the player
//  above), its own offset, and search again, paste or import lyrics of its
//  own, look at and edit the file.
//
//  The real title and the lyrics file come from the app's nowplaying.plist
//  (the now-playing title MediaRemote has is a lyric line). After a change the
//  page re-reads that file for a while until the app has answered.
//

#import "NLLyricsPages.h"
#import "NLOffsetControl.h"
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "../NLIslandStrip.h"
#import "../NLPlayerTint.h"
#import <dlfcn.h>
#import <objc/runtime.h>

static const NSTimeInterval kNLRefreshInterval = 0.75;   // how often the page looks at what is playing


typedef NS_ENUM(NSInteger, NLSection) {
    NLSectionSong = 0,
    NLSectionSource,
    NLSectionDisplay,
    NLSectionOffset,
    NLSectionLyrics,
    NLSectionCount,
    NLSectionNothing,   // with nothing playing: the note, then Display
};

typedef NS_ENUM(NSInteger, NLDisplayRow) {
    NLDisplayRowArtist = 0,
    NLDisplayRowExplicit,
    NLDisplayRowTint,       // the player's background in the lyrics' color, here and on the lock screen / in Control Center
    NLDisplayRowCount,
};


// The artist field's choices, by their preference values.
static NSArray<NSString *> *NLArtistFieldValues(void) { return @[@"title", @"next", @"none"]; }

static NSString *NLArtistFieldTitle(NSString *value) {
    NSDictionary *titles = @{@"title": @"Track and artist", @"next": @"Next line", @"none": @"Leave alone"};
    return NLL(titles[value] ?: titles[@"title"]);
}

// The sources a song can be pinned to, by their preference names.
static NSArray<NSString *> *const NLSourceNames(void) {
    return @[@"", @"applemusic", @"musixmatch", @"lrclib", @"netease"];   // "" is automatic
}

static NSString *NLSourceTitle(NSString *name) {
    NSDictionary *titles = @{@"": @"Automatic", @"applemusic": @"Apple Music", @"musixmatch": @"Musixmatch",
                             @"lrclib": @"LRCLIB", @"netease": @"NetEase Music"};
    return NLL(titles[name] ?: name);
}

#pragma mark - Cells

// Icon, title, artist and where the lyrics are from.
@interface NLSongCell : UITableViewCell
@property (nonatomic, readonly) UIImageView *icon;
@property (nonatomic, readonly) UILabel *titleLabel, *artistLabel, *statusLabel;
@end

@implementation NLSongCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _icon = [UIImageView new];
        _icon.contentMode = UIViewContentModeScaleAspectFit;
        _icon.layer.cornerRadius = 12;
        _icon.layer.cornerCurve = kCACornerCurveContinuous;
        _icon.clipsToBounds = YES;
        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        _titleLabel.numberOfLines = 2;
        _artistLabel = [UILabel new];
        _artistLabel.font = [UIFont systemFontOfSize:15];
        _artistLabel.textColor = UIColor.secondaryLabelColor;
        _statusLabel = [UILabel new];
        _statusLabel.font = [UIFont systemFontOfSize:13];
        _statusLabel.textColor = UIColor.secondaryLabelColor;
        _statusLabel.numberOfLines = 3;

        UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _artistLabel, _statusLabel]];
        text.axis = UILayoutConstraintAxisVertical;
        text.spacing = 2;
        [text setCustomSpacing:6 afterView:_artistLabel];
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_icon, text]];
        row.spacing = 14;
        row.alignment = UIStackViewAlignmentCenter;
        row.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:row];
        UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
        [NSLayoutConstraint activateConstraints:@[
            [_icon.widthAnchor constraintEqualToConstant:54],
            [_icon.heightAnchor constraintEqualToConstant:54],
            [row.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
            [row.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
            [row.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12],
            [row.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12],
        ]];
    }
    return self;
}

@end

// The offset row, laid out like the main page's (NLOffsetCell): title and the
// value on the first line, the slider underneath.
@interface NLSongOffsetCell : UITableViewCell
@property (nonatomic, readonly) NLOffsetControl *control;
@end

@implementation NLSongOffsetCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        _control = [[NLOffsetControl alloc] initWithFrame:CGRectZero];
        _control.stacked = YES;
        [self.contentView addSubview:_control];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect content = self.contentView.bounds;
    CGFloat inset = self.contentView.layoutMargins.left;
    CGRect icon = self.imageView.frame;
    icon.origin.y = round((44 - icon.size.height) / 2);
    self.imageView.frame = icon;
    CGRect title = self.textLabel.frame;
    title.origin.y = round((44 - title.size.height) / 2);
    title.size.width = MIN(title.size.width, content.size.width - inset - 84 - 12 - title.origin.x);
    self.textLabel.frame = title;
    _control.frame = CGRectMake(inset, 0, content.size.width - inset * 2, content.size.height - 6);
}

@end

#pragma mark - Controller

@interface NLNowPlayingController () <UITableViewDataSource, UITableViewDelegate, UIDocumentPickerDelegate>
@end

@implementation NLNowPlayingController {
    UITableView *_table;
    NSString *_bundleID;
    NSDictionary *_np;            // the app's nowplaying.plist
    NSArray<NSString *> *_actions;
    NSArray<NSString *> *_sources;   // the source rows offered for this app
    NSTimer *_refresh;
    NSUInteger _ticks;
    BOOL _loaded;
    NLPlayerHeader *_player;         // the lock screen's player, as the table's header
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NLL(@"Now Playing");
    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    _table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:_table];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nlReload)
                                                 name:UIApplicationWillEnterForegroundNotification object:nil];
    _player = [[NLPlayerHeader alloc] initWithOwner:self table:_table];
    __weak UITableView *table = _table;
    [[NSNotificationCenter defaultCenter] addObserverForName:NLThemeChangedNotification object:nil queue:nil
                                                  usingBlock:^(NSNotification *n) { NLThemeTable(table); }];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [_player layout];
}

- (void)preferredContentSizeDidChangeForChildContentContainer:(id<UIContentContainer>)container {
    [super preferredContentSizeDidChangeForChildContentContainer:container];
    [_player layout];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_refresh invalidate];
}

// While the page is up it follows what is playing: the app's nowplaying.plist
// every tick (cheap), which app is playing every few.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self nlReload];
    [_refresh invalidate];
    __weak typeof(self) weakSelf = self;
    _refresh = [NSTimer scheduledTimerWithTimeInterval:kNLRefreshInterval repeats:YES block:^(NSTimer *timer) {
        [weakSelf nlTick];
    }];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_player appear];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_refresh invalidate];
    _refresh = nil;
    [_player disappear];
}

- (void)nlTick {
    [_player tick];
    if (_ticks % 4 == 0) NLThemeRefresh();
    if (++_ticks % 4 == 0) {
        [self nlReload];   // another app may have started playing
        return;
    }
    [self nlAdopt:_bundleID np:NLReadNowPlaying(_bundleID)];
}

#pragma mark Data

// The app MediaRemote says is playing; failing that (it may not know, or the
// app has NowLyrics switched off), whichever app wrote its nowplaying.plist last.
- (void)nlReload {
    NLNowPlayingBundleID(^(NSString *playing) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *bundleID = playing;
            NSDictionary *np = NLReadNowPlaying(bundleID);
            if (!np) {
                NSDate *latest = nil;
                bundleID = nil;
                for (NSString *candidate in NLLyricsFolders()) {
                    NSDictionary *info = NLReadNowPlaying(candidate);
                    NSDate *updated = info[NL_NP_UPDATED];
                    if ([updated isKindOfClass:NSDate.class] && (!latest || [updated compare:latest] == NSOrderedDescending)) {
                        latest = updated;
                        bundleID = candidate;
                        np = info;
                    }
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ [self nlAdopt:bundleID np:np]; });
        });
    });
}

// Redraws only what changed: a new song rebuilds the page, new lyrics for the
// same one leave the offset row alone (it may be under a finger).
- (void)nlAdopt:(NSString *)bundleID np:(NSDictionary *)np {
    BOOL first = !_loaded;
    _loaded = YES;
    if (!first && [bundleID isEqual:_bundleID] && (np == _np || [np isEqualToDictionary:_np])) return;
    BOOL sameSong = !first && _np && np && [bundleID isEqual:_bundleID] && [np[NL_NP_KEY] isEqual:_np[NL_NP_KEY]];
    _bundleID = bundleID;
    _np = np;
    if (!sameSong) {
        [self nlRebuild];
        return;
    }
    NSUInteger oldActions = _actions.count;
    [self nlRebuild:NO];
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSetWithIndex:NLSectionSong];
    [sections addIndex:NLSectionSource];
    if (_actions.count == oldActions) [sections addIndex:NLSectionLyrics];
    if (_actions.count != oldActions) [_table reloadData];
    else [_table reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
}

- (NSString *)nlString:(NSString *)key {
    id value = _np[key];
    return [value isKindOfClass:NSString.class] ? value : nil;
}

- (NSString *)nlPath { return [self nlString:NL_NP_PATH]; }

- (BOOL)nlIsManual { return [[self nlPath] containsString:@"/manual/"]; }

- (void)nlRebuild {
    [self nlRebuild:YES];
}

// The sources switched on under Lyrics Sources (Apple Music in other apps only
// while it may be used there), and the actions that fit the lyrics in use.
- (void)nlRebuild:(BOOL)reload {
    NSMutableArray<NSString *> *sources = [NSMutableArray array];
    for (NSString *name in NLSourceNames()) {
        if (name.length && ![self nlSourceEnabled:name]) continue;
        [sources addObject:name];
    }
    _sources = sources;
    NSMutableArray<NSString *> *actions = [NSMutableArray array];
    if (_np) {
        [actions addObject:[self nlIsManual] ? @"removeManual" : @"search"];
        [actions addObject:@"paste"];
        [actions addObject:@"import"];
        if ([self nlPath]) [actions addObject:@"edit"];
    }
    _actions = actions;
    if (reload) [_table reloadData];
}

- (BOOL)nlBoolPref:(NSString *)key fallback:(BOOL)fallback {
    id value = [self nlPref:key];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

- (BOOL)nlSourceEnabled:(NSString *)name {
    if ([name isEqualToString:@"applemusic"]) {
        // Music asks by its own item; other apps through SpringBoard, when allowed.
        return NLAppleMusicVerified() && [self nlBoolPref:@"useAppleMusic" fallback:NO] &&
               ([_bundleID isEqualToString:@"com.apple.Music"] || [self nlBoolPref:@"appleMusicOtherApps" fallback:YES]);
    }
    if ([name isEqualToString:@"musixmatch"]) return [self nlHasMusixmatch];
    if ([name isEqualToString:@"lrclib"]) return [self nlBoolPref:@"useLRCLIB" fallback:YES];
    if ([name isEqualToString:@"netease"]) return [self nlBoolPref:@"useNetease" fallback:YES];
    return YES;
}

// After a change the app answers in its own time; the refresh picks it up.
// This just looks once more right away.
- (void)nlStartPolling {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self nlAdopt:self->_bundleID np:NLReadNowPlaying(self->_bundleID)];
    });
}

#pragma mark Offset

// The main page's controller writes it, the same way as every other setting,
// and posts the reload notification.
- (PSListController *)nlRoot {
    PSViewController *parent = self.parentController;
    return [parent isKindOfClass:[PSListController class]] ? (PSListController *)parent : nil;
}

- (PSSpecifier *)nlSpecifierForKey:(NSString *)key {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:key target:[self nlRoot]
                                                          set:@selector(setPreferenceValue:specifier:)
                                                          get:@selector(readPreferenceValue:)
                                                       detail:Nil cell:PSStaticTextCell edit:Nil];
    [spec setProperty:NL_PREFS_DOMAIN forKey:@"defaults"];
    [spec setProperty:key forKey:@"key"];
    [spec setProperty:NL_RELOAD_NOTIFICATION forKey:@"PostNotification"];
    return spec;
}

- (id)nlPref:(NSString *)key {
    PSListController *root = [self nlRoot];
    return root ? [root readPreferenceValue:[self nlSpecifierForKey:key]]
                : CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)NL_PREFS_DOMAIN));
}

- (void)nlSetPref:(id)value forKey:(NSString *)key {
    PSListController *root = [self nlRoot];
    if (root) {
        [root setPreferenceValue:value specifier:[self nlSpecifierForKey:key]];
        return;
    }
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)NL_PREFS_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)NL_PREFS_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)NL_RELOAD_NOTIFICATION, NULL, NULL, YES);
}

- (NSDictionary *)nlDictionaryPref:(NSString *)key {
    id value = [self nlPref:key];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

- (NSDictionary *)nlOffsets { return [self nlDictionaryPref:NL_TRACK_OFFSETS_KEY]; }

- (BOOL)nlHasMusixmatch {
    NSString *token = [self nlPref:@"musixmatchToken"], *key = [self nlPref:@"musixmatchKey"];
    return [[self nlPref:@"useMusixmatch"] boolValue] &&
           (([token isKindOfClass:NSString.class] && token.length) || ([key isKindOfClass:NSString.class] && key.length));
}

// One song's entry in a per-song dictionary; nil removes it. Bounded: the
// others go, at random, once there are too many.
- (void)nlSetTrackValue:(id)value inPref:(NSString *)prefKey {
    NSString *key = [self nlString:NL_NP_KEY];
    if (key.length == 0) return;
    NSMutableDictionary *all = [[self nlDictionaryPref:prefKey] mutableCopy];
    if (value) all[key] = value;
    else [all removeObjectForKey:key];
    while (all.count > kNLTrackOffsetsLimit) {
        for (NSString *other in all.allKeys) {
            if (![other isEqualToString:key]) { [all removeObjectForKey:other]; break; }
        }
    }
    [self nlSetPref:[all copy] forKey:prefKey];
}

- (NSString *)nlPickedSource {
    id name = [self nlDictionaryPref:NL_TRACK_SOURCES_KEY][[self nlString:NL_NP_KEY] ?: @""];
    return [name isKindOfClass:NSString.class] ? name : @"";
}

// Pinned (or back to automatic): the saved copy goes, and once the apps have
// re-read the settings, they are told to look the song up again.
- (void)nlPickSource:(NSString *)name {
    if ([name isEqualToString:[self nlPickedSource]]) return;
    [self nlSetTrackValue:(name.length ? name : nil) inPref:NL_TRACK_SOURCES_KEY];
    NSString *path = [self nlPath];
    if (path && ![self nlIsManual]) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    [_table reloadSections:[NSIndexSet indexSetWithIndex:NLSectionSource] withRowAnimation:UITableViewRowAnimationNone];
    CFPreferencesAppSynchronize(CFSTR("app.nowlyrics"));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NLPostLyricsChanged();
        [self nlStartPolling];
    });
}

- (void)nlOffsetChanged:(NLOffsetControl *)control {
    double value = round((control.value - [self nlDefaultOffset]) * 100) / 100;
    [self nlSetTrackValue:(value == 0 ? nil : @(value)) inPref:NL_TRACK_OFFSETS_KEY];
}

#pragma mark Display

- (NSString *)nlArtistField {
    id value = [self nlPref:@"artistField"];
    return [NLArtistFieldValues() containsObject:value] ? value : @"title";
}

// A pop-up of the three choices, its title the one in use.
- (UIButton *)nlArtistFieldButton {
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSString *value in NLArtistFieldValues()) [titles addObject:NLArtistFieldTitle(value)];
    __weak typeof(self) weakSelf = self;
    return NLPopUpButton(titles, NLArtistFieldValues(), [self nlArtistField], ^(id value) { [weakSelf nlSetArtistField:value]; });
}

- (void)nlSetArtistField:(NSString *)value {
    if ([value isEqualToString:[self nlArtistField]]) return;
    [self nlSetPref:value forKey:@"artistField"];
    [self nlReloadDisplayRow:NLDisplayRowArtist];
}

- (void)nlTintChanged:(UISwitch *)toggle {
    [self nlSetPref:@(toggle.on) forKey:NL_PLAYER_TINT_KEY];
    [_player layout];
}

- (void)nlExplicitChanged:(UISwitch *)toggle {
    [self nlSetPref:@(toggle.on) forKey:@"hideExplicit"];
}

- (void)nlReloadDisplayRow:(NSInteger)row {
    NSInteger section = [self nlSectionIndex:NLSectionDisplay];
    if (section >= [_table numberOfSections] || row >= [_table numberOfRowsInSection:section]) return;
    [_table reloadRowsAtIndexPaths:@[[NSIndexPath indexPathForRow:row inSection:section]]
                  withRowAnimation:UITableViewRowAnimationNone];
}

#pragma mark Table

// With nothing playing the page is the note and the Display settings.
- (NLSection)nlSectionKind:(NSInteger)section {
    if (_np) return (NLSection)section;
    return section == 0 ? NLSectionNothing : NLSectionDisplay;
}

- (NSInteger)nlSectionIndex:(NLSection)kind {
    if (_np) return kind;
    return kind == NLSectionDisplay ? 1 : 0;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (_np) return NLSectionCount;
    return _loaded ? 2 : 0;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    switch ([self nlSectionKind:section]) {
        case NLSectionLyrics: return (NSInteger)_actions.count;
        case NLSectionSource: return (NSInteger)_sources.count;
        case NLSectionDisplay: return NLDisplayRowCount;
        default: return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ([self nlSectionKind:section]) {
        case NLSectionSource: return NLL(@"Lyrics source");
        case NLSectionDisplay: return NLL(@"Display");
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NLSection kind = [self nlSectionKind:section];
    if (kind == NLSectionNothing) return NLL(@"Play a song in an app NowLyrics is on for, then come back.");
    if (kind == NLSectionDisplay) return NLL(@"Player in lyrics color colors the player here, on the lock screen and in Control Center: the album color the lyrics use, or the cover blurred and darkened.");
    if (kind == NLSectionOffset) return NLL(@"This song’s timing only; a positive offset shows its lyrics earlier. Every other song uses the default offset under Advanced.");
    if (kind == NLSectionSource) return NLL(@"Picks the source for this song and searches it again. Automatic follows the order on the main page.");
    if (section == NLSectionLyrics) {
        return [NSString stringWithFormat:NLL(@"Added lyrics are used in %@ before any online source. LRC, word-by-word LRC and TTML work."),
                NLAppName(_bundleID)];
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NLSection kind = [self nlSectionKind:indexPath.section];
    if (kind == NLSectionOffset) return 92;
    return UITableViewAutomaticDimension;
}

// What the readout says about the lyrics: manual, cached or fetched (and from
// where), still searching, or not found (with what each source answered).
- (NSString *)nlStatusText {
    NSString *status = [self nlString:NL_NP_STATUS];
    NSString *path = [self nlPath];
    NSString *text;
    if ([self nlIsManual]) {
        text = NLL(@"Added by you");
    } else if (!status) {
        text = NLL(@"Searching…");
    } else if (path) {
        NSString *from = [status hasPrefix:@"cache · "] ? [status substringFromIndex:8] : status;
        text = [status hasPrefix:@"cache"]
            ? ([from isEqualToString:@"cache"] ? NLL(@"Saved") : [NSString stringWithFormat:@"%@ · %@", NLL(@"Saved"), from])
            : from;
    } else {
        text = [NSString stringWithFormat:@"%@\n%@", NLL(@"No lyrics found"), status];
    }
    if (NLPrefBool(_np, NL_NP_WORDS, NO)) text = [text stringByAppendingFormat:@" · %@", NLL(@"Word by word")];
    return text;
}

// The offset this song plays with: the default one (Advanced) and its own
// together, so there is one number to look at. A change is kept as this
// song's own, the difference from the default.
- (double)nlDefaultOffset {
    id value = [self nlPref:@"offset"];
    return [value respondsToSelector:@selector(doubleValue)] ? [value doubleValue] : 0;
}

- (UITableViewCell *)nlOffsetCell {
    NLSongOffsetCell *cell = [[NLSongOffsetCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = NLL(@"Offset");
    cell.imageView.image = NLSettingsIcon(@"clock", @"#33C759");
    cell.control.value = [self nlDefaultOffset] + NLTrackOffset(@{NL_TRACK_OFFSETS_KEY: [self nlOffsets]}, [self nlString:NL_NP_KEY]);
    [cell.control addTarget:self action:@selector(nlOffsetChanged:) forControlEvents:UIControlEventValueChanged];
    return cell;
}

- (UITableViewCell *)nlDisplayCellForRow:(NSInteger)row {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (row == NLDisplayRowArtist) {
        cell.textLabel.text = NLL(@"Artist field");
        cell.imageView.image = NLSettingsIcon(@"text.alignleft", @"#FC9429");
        cell.accessoryView = [self nlArtistFieldButton];
    } else if (row == NLDisplayRowTint) {
        cell.textLabel.text = NLL(@"Player in lyrics color");
        cell.imageView.image = NLSettingsIcon(@"paintbrush.fill", @"#FF6482");
        UISwitch *toggle = [UISwitch new];
        toggle.on = [self nlBoolPref:NL_PLAYER_TINT_KEY fallback:YES];
        [toggle addTarget:self action:@selector(nlTintChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    } else {
        cell.textLabel.text = NLL(@"Hide explicit badge");
        cell.imageView.image = NLSettingsIcon(@"e.square", @"#8E8E93");
        UISwitch *toggle = [UISwitch new];
        toggle.on = [self nlBoolPref:@"hideExplicit" fallback:NO];
        [toggle addTarget:self action:@selector(nlExplicitChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
    }
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self nlSectionKind:indexPath.section] == NLSectionDisplay) return [self nlDisplayCellForRow:indexPath.row];
    if ([self nlSectionKind:indexPath.section] == NLSectionOffset) return [self nlOffsetCell];
    if (!_np) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = NLL(@"Nothing is playing");
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    if (indexPath.section == NLSectionSong) {
        NLSongCell *cell = [[NLSongCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.icon.image = NLAppIcon(_bundleID);
        cell.titleLabel.text = [self nlString:NL_NP_TITLE];
        cell.artistLabel.text = [self nlString:NL_NP_ARTIST];
        cell.statusLabel.text = [self nlStatusText];
        return cell;
    }
    if (indexPath.section == NLSectionSource) {
        NSString *name = _sources[indexPath.row];
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = NLSourceTitle(name);
        cell.imageView.image = NLSourceIcon(name);
        cell.accessoryType = [name isEqualToString:[self nlPickedSource]] ? UITableViewCellAccessoryCheckmark
                                                                           : UITableViewCellAccessoryNone;
        return cell;
    }

    NSString *action = _actions[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    NSDictionary *rows = @{
        @"search":       @[@"Search again", @"arrow.clockwise"],
        @"removeManual": @[@"Remove added lyrics", @"trash"],
        @"paste":        @[@"Paste lyrics", @"doc.on.clipboard"],
        @"import":       @[@"Import from Files", @"folder"],
        @"edit":         @[@"View and edit", @"doc.text"],
    };
    cell.textLabel.text = NLL(rows[action][0]);
    cell.imageView.image = [UIImage systemImageNamed:rows[action][1]];
    BOOL destructive = [action isEqualToString:@"removeManual"];
    UIColor *tint = destructive ? UIColor.systemRedColor : self.view.tintColor;
    cell.textLabel.textColor = tint;
    cell.imageView.tintColor = tint;
    if ([action isEqualToString:@"edit"]) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (_np && indexPath.section == NLSectionSource) {
        [self nlPickSource:_sources[indexPath.row]];
        return;
    }
    if (!_np || indexPath.section != NLSectionLyrics) return;
    NSString *action = _actions[indexPath.row];
    if ([action isEqualToString:@"search"]) [self nlSearchAgain];
    else if ([action isEqualToString:@"removeManual"]) [self nlRemoveManual];
    else if ([action isEqualToString:@"paste"]) [self nlPaste];
    else if ([action isEqualToString:@"import"]) [self nlImport];
    else if ([action isEqualToString:@"edit"]) [self nlEdit];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    NLThemeCell(cell);
}

#pragma mark Actions

// The saved copy goes, so the app has nothing on disk and asks the sources
// again; a song nothing was found for is simply asked about again.
- (void)nlSearchAgain {
    NSString *path = [self nlPath];
    if (path && ![self nlIsManual]) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NLPostLyricsChanged();
    [self nlStartPolling];
}

- (void)nlRemoveManual {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NLL(@"Remove added lyrics?")
                                                                   message:NLL(@"The app looks the song up again.")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NLL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:NLL(@"Remove") style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) {
        [[NSFileManager defaultManager] removeItemAtPath:[self nlPath] error:nil];
        NLPostLyricsChanged();
        [self nlStartPolling];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)nlPaste {
    NSString *text = UIPasteboard.generalPasteboard.string;
    NSString *stored = NLLyricsFileText(text, [self nlString:NL_NP_TITLE], [self nlString:NL_NP_ARTIST]);
    if (!stored) {
        NLAlert(self, NLL(@"No timed lyrics on the clipboard"), NLL(@"Copy LRC or TTML lyrics first."));
        return;
    }
    [self nlSaveManual:stored];
}

- (void)nlImport {
    NSArray<UTType *> *types = @[UTTypeItem];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:types asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    NSStringEncoding used = NSUTF8StringEncoding;
    NSString *text = [NSString stringWithContentsOfURL:url usedEncoding:&used error:nil];
    if (!text) text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
    NSString *stored = NLLyricsFileText(text, [self nlString:NL_NP_TITLE], [self nlString:NL_NP_ARTIST]);
    if (!stored) {
        NLAlert(self, NLL(@"Not timed lyrics"), NLL(@"The file is not LRC or TTML with times."));
        return;
    }
    [self nlSaveManual:stored];
}

// Into the app's manual folder, under the name NLManualLyrics looks for, which
// takes it before the cache and the sources.
- (void)nlSaveManual:(NSString *)text {
    NSString *container = NLDataContainerForBundle(_bundleID);
    if (!container) {
        NLAlert(self, NLL(@"Could not save"), NLAppName(_bundleID));
        return;
    }
    NSString *dir = [container stringByAppendingPathComponent:@"Library/NowLyrics/manual"];
    NSString *path = [dir stringByAppendingPathComponent:NLManualFileName([self nlString:NL_NP_TITLE], [self nlString:NL_NP_ARTIST])];

    void (^write)(void) = ^{
        NSError *error = nil;
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
            NLAlert(self, NLL(@"Could not save"), error.localizedDescription);
            return;
        }
        NLPostLyricsChanged();
        [self nlStartPolling];
    };
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        write();
        return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NLL(@"Replace the added lyrics?")
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NLL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:NLL(@"Replace") style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) { write(); }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)nlEdit {
    NSString *path = [self nlPath];
    if (!path) return;
    NLLyricsEditorController *editor = [[NLLyricsEditorController alloc] initWithPath:path title:[self nlString:NL_NP_TITLE]];
    __weak typeof(self) weakSelf = self;
    editor.onChange = ^{ [weakSelf nlStartPolling]; };
    [self.navigationController pushViewController:editor animated:YES];
}

@end
