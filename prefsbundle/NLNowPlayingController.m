//
//  NLNowPlayingController.m
//  "Now Playing": the lock screen's own player at the top (MediaControls'
//  cover sheet platter: artwork, the line being sung as its title, scrubber,
//  transport), then the song as the app really reports it and where its lyrics
//  came from, how lines are shown (the artist field, the E badge: changed
//  here, seen in the player above) and its offset, and
//  its lyrics: the sources to look it up again with (a tap does it), pasting
//  or importing lyrics of its own, looking at and editing the file.
//
//  The real title and the lyrics file come from the app's nowplaying.plist
//  (the now-playing title MediaRemote has is a lyric line). After a change the
//  page re-reads that file for a while until the app has answered.
//

#import "NLLyricsPages.h"
#import "NLOffsetControl.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>


typedef NS_ENUM(NSInteger, NLSection) {
    NLSectionSong = 0,
    NLSectionDisplay,      // how lines are shown, and this song's offset
    NLSectionLyrics,       // the sources to look it up with, then pasting, importing, editing
    NLSectionCount,
    NLSectionNothing,   // with nothing playing: the note, then Display
};

typedef NS_ENUM(NSInteger, NLDisplayRow) {
    NLDisplayRowArtist = 0,
    NLDisplayRowExplicit,
    NLDisplayRowOffset,     // only while a song plays: its own
    NLDisplayRowCount,
};


// The artist field's choices, by their preference values; their titles are in -nlArtistFieldButton.
static NSArray<NSString *> *NLArtistFieldValues(void) { return NL_ONCE((@[@"title", @"next", @"none"])); }

// What each source answered when none had the song: the apps join the answers
// with NL_STATUS_NOTES_SEPARATOR (NLResolveLyrics, NLSources.m); here each goes
// on a line of its own, so a long list reads whole. Only for that list: a found
// status such as "cache · LRCLIB" uses the same separator and stays as it is.
// The whole lookup is tried again when the apps add NL_STATUS_RETRY_SUFFIX
// (NLEngine.m), so that goes on a line of its own too rather than after the
// last source, as if only that one were asked again.
static NSString *NLMissLines(NSString *status) {
    NSString *retry = NL_STATUS_RETRY_SUFFIX;
    BOOL retrying = [status hasSuffix:retry];
    if (retrying) status = [status substringToIndex:status.length - retry.length];
    NSString *lines = [status stringByReplacingOccurrencesOfString:NL_STATUS_NOTES_SEPARATOR withString:@"\n"];
    if (!retrying) return lines;
    NSString *alone = [retry stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    return lines.length ? [NSString stringWithFormat:@"%@\n%@", lines, alone] : alone;
}

#pragma mark - Cells

// Icon, title, artist and where the lyrics are from, each in full: the card
// grows with them (the row sizes itself), the icon staying by the title.
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
        _titleLabel.numberOfLines = 0;
        _artistLabel = [UILabel new];
        _artistLabel.font = [UIFont systemFontOfSize:15];
        _artistLabel.textColor = UIColor.secondaryLabelColor;
        _artistLabel.numberOfLines = 0;
        _statusLabel = [UILabel new];
        _statusLabel.font = [UIFont systemFontOfSize:13];
        _statusLabel.textColor = UIColor.secondaryLabelColor;
        _statusLabel.numberOfLines = 0;

        UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[_titleLabel, _artistLabel, _statusLabel]];
        text.axis = UILayoutConstraintAxisVertical;
        text.spacing = 2;
        [text setCustomSpacing:6 afterView:_artistLabel];
        UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[_icon, text]];
        row.spacing = 14;
        row.alignment = UIStackViewAlignmentTop;
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
        [self.contentView addSubview:_control];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    NLLayoutStackedOffsetRow(self, _control, self.contentView.layoutMargins.left);
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
    CFAbsoluteTime _askedAt;         // looked up again from here (0: not): "Searching…" until the app has answered
    NSString *_askedSource;          // with which source ("" automatic), for the result row
    BOOL _showResult;                // the result row: since a lookup from here, until another song
    NSArray<NSString *> *_sources;   // the source rows offered for this app
    NSString *_picked;               // this song's picked source ("" automatic), as trackSources has it
    NSTimer *_refresh;
    NSUInteger _ticks;
    BOOL _loaded;
    NLPlayerHeader *_player;         // the lock screen's player, as the table's header
    NSMutableDictionary<NSIndexPath *, NSNumber *> *_heights;   // each row's height as last shown, its estimate off screen
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NLL(@"Now Playing");
    self.navigationItem.rightBarButtonItem = NLApplyButton(self);
    _table = NLMakeTable(self);
    _heights = [NSMutableDictionary dictionary];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nlReload)
                                                 name:UIApplicationWillEnterForegroundNotification object:nil];
    _player = [[NLPlayerHeader alloc] initWithOwner:self table:_table];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nlThemeChanged)
                                                 name:NLThemeChangedNotification object:nil];
}

- (void)nlThemeChanged {
    NLThemeTable(_table);
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
    _refresh = [NSTimer scheduledTimerWithTimeInterval:kNLPageRefreshInterval repeats:YES block:^(NSTimer *timer) {
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
    NLPageTick(_player, &_ticks);
    if (_ticks % 4 == 0) {
        [self nlReload];   // another app may have started playing
        return;
    }
    [self nlAdopt:_bundleID np:NLReadNowPlaying(_bundleID)];
}

#pragma mark Data

// The app MediaRemote says is playing; failing that (it may not know, or the
// app has NowLyrics switched off), whichever app wrote its nowplaying.plist last.
- (void)nlReload {
    NLPlayingSong(^(NSString *bundleID, NSDictionary *np) { [self nlAdopt:bundleID np:np]; });
}

// Redraws only what changed: a new song rebuilds the page, new lyrics for the
// same one leave the offset row alone (it may be under a finger).
- (void)nlAdopt:(NSString *)bundleID np:(NSDictionary *)np {
    BOOL first = !_loaded;
    _loaded = YES;
    // nil and nil (nothing playing) are the same app too.
    if (!first && NLSame(bundleID, _bundleID) && NLSame(np, _np)) return;
    BOOL sameSong = !first && _np && np && [bundleID isEqual:_bundleID] && [np[NL_NP_KEY] isEqual:_np[NL_NP_KEY]];
    _bundleID = bundleID;
    _np = np;
    if (!sameSong) {
        _askedAt = 0;
        _showResult = NO;   // the result was another song's
        [self nlRebuild:YES];
        return;
    }
    if (_askedAt && [self nlWrittenAfter:_askedAt]) _askedAt = 0;   // the app has answered
    NSUInteger oldRows = [self nlLyricsRowCount];
    [self nlRebuild:NO];
    if ([self nlLyricsRowCount] != oldRows) {
        [_table reloadData];
        return;
    }
    [self nlReloadSongAndLyrics];
}

// The song's row and the lyrics group; the offset row is left alone (it may be under a finger).
- (void)nlReloadSongAndLyrics {
    NSMutableIndexSet *sections = [NSMutableIndexSet indexSetWithIndex:NLSectionSong];
    [sections addIndex:NLSectionLyrics];
    [_table reloadSections:sections withRowAnimation:UITableViewRowAnimationNone];
}

// Whether the app wrote its nowplaying.plist after `time`: by its stamp, or by
// its date (whole seconds only) for an app not restarted since NowLyrics was.
- (BOOL)nlWrittenAfter:(CFAbsoluteTime)time {
    BOOL wholeSeconds;
    CFAbsoluteTime written = NLNowPlayingWritten(_np, &wholeSeconds);
    return wholeSeconds ? written > floor(time) - 0.001 : written > time;
}

- (NSString *)nlString:(NSString *)key {
    return NLString(_np, key);
}

- (NSString *)nlPath { return [self nlString:NL_NP_PATH]; }

- (BOOL)nlIsManual { return [[self nlPath] containsString:@"/" NL_MANUAL_FOLDER @"/"]; }

// The sources switched on under Lyrics Sources (Apple Music in other apps only
// while it may be used there), and the actions that fit the lyrics in use.
- (void)nlRebuild:(BOOL)reload {
    NSMutableArray<NSString *> *sources = [NSMutableArray array];
    for (NSString *name in [@[@""] arrayByAddingObjectsFromArray:NLSourceNamesInOrder()]) {   // "" is automatic
        if (name.length && ![self nlSourceEnabled:name]) continue;
        [sources addObject:name];
    }
    _sources = sources;
    NSMutableArray<NSString *> *actions = [NSMutableArray array];
    if (_np) {
        if ([self nlIsManual]) [actions addObject:@"removeManual"];
        [actions addObject:@"paste"];
        [actions addObject:@"import"];
        if ([self nlPath]) [actions addObject:@"edit"];
    }
    _actions = actions;
    _picked = [self nlPickedSource];
    if (reload) [_table reloadData];
}

// The lyrics group: the result of a lookup from here (while there is one),
// the sources, then the actions.
- (NSUInteger)nlResultRows { return (_showResult && _np) ? 1 : 0; }
- (NSUInteger)nlLyricsRowCount { return [self nlResultRows] + _sources.count + _actions.count; }

- (BOOL)nlSourceEnabled:(NSString *)name {
    PSListController *root = [self nlParentList];
    if ([name isEqualToString:@"applemusic"]) {
        // Music asks by its own item; other apps through SpringBoard, when allowed.
        return NLAppleMusicVerified() && NLSourceSwitchOn(root, name) &&
               ([_bundleID isEqualToString:@"com.apple.Music"] || [self nlBoolPref:@"appleMusicOtherApps" fallback:YES]);
    }
    if ([name isEqualToString:@"musixmatch"]) return [self nlHasMusixmatch];
    return NLSourceSwitchOn(root, name);
}

// After a change the app answers in its own time; the refresh picks it up.
// This just looks once more right away.
- (void)nlStartPolling {
    NLAfter(0.3, ^{ [self nlAdopt:self->_bundleID np:NLReadNowPlaying(self->_bundleID)]; });
}

#pragma mark Offset

- (NSDictionary *)nlDictionaryPref:(NSString *)key {
    id value = [self nlPref:key];
    return [value isKindOfClass:NSDictionary.class] ? value : @{};
}

// As the apps decide it (NLSettings): switched on, with usable credentials.
- (BOOL)nlHasMusixmatch {
    return [self nlBoolPref:@"useMusixmatch" fallback:NO] &&
           NLMusixmatchHasCredentials([self nlPref:@"musixmatchToken"], [self nlPref:@"musixmatchKey"]);
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
    return NLString([self nlDictionaryPref:NL_TRACK_SOURCES_KEY], [self nlString:NL_NP_KEY] ?: @"") ?: @"";
}

// Pinned (or back to automatic): the saved copy goes, and once the apps have
// re-read the settings, they are told to look the song up again.
// A tap on a source looks the song up again with it at once; on the one ticked
// already, the same again (what "Search again" was). The song's row says
// "Searching…" right away.
- (void)nlPickSource:(NSString *)name {
    BOOL same = [name isEqualToString:_picked];
    if (!same) [self nlSetTrackValue:(name.length ? name : nil) inPref:NL_TRACK_SOURCES_KEY];
    _picked = [self nlPickedSource];   // re-read: nothing is written without a track key
    NSString *path = [self nlPath];
    if (path && ![self nlIsManual]) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    CFAbsoluteTime asked = CFAbsoluteTimeGetCurrent();
    _askedAt = asked;
    _askedSource = name;
    _showResult = YES;
    NLAfter(20, ^{
        if (self->_askedAt != asked) return;
        self->_askedAt = 0;   // no answer: say what the file says again
        [self->_table reloadData];
    });
    [self nlReloadSongAndLyrics];
    // The pick also goes beside the app's nowplaying.plist (NL_LOOKUP_FILE),
    // which it reads when told: the preference just written may not be in the
    // file it reads yet, and the song was looked up with the old source.
    NSString *dir = NLLyricsFolderForBundle(_bundleID);
    NSString *key = [self nlString:NL_NP_KEY];
    if (dir && key.length) {
        [@{NL_LOOKUP_KEY: key, NL_LOOKUP_SOURCE: name, NL_LOOKUP_STAMP: @(asked)}
            writeToFile:[dir stringByAppendingPathComponent:NL_LOOKUP_FILE] atomically:YES];
    }
    NLSyncPrefs();
    NLPostLyricsChanged();
    [self nlStartPolling];
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
    NSArray<NSString *> *titles = @[NLL(@"Track and artist"), NLL(@"Next line"), NLL(@"Leave alone")];   // NLArtistFieldValues()' order
    __weak typeof(self) weakSelf = self;
    return NLPopUpButton(titles, NLArtistFieldValues(), [self nlArtistField], ^(id value) { [weakSelf nlSetArtistField:value]; });
}

- (void)nlSetArtistField:(NSString *)value {
    if ([value isEqualToString:[self nlArtistField]]) return;
    [self nlSetPref:value forKey:@"artistField"];
    [self nlReloadDisplayRow:NLDisplayRowArtist];
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
        case NLSectionLyrics: return (NSInteger)[self nlLyricsRowCount];
        case NLSectionDisplay: return _np ? NLDisplayRowCount : NLDisplayRowOffset;
        default: return 1;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    switch ([self nlSectionKind:section]) {
        case NLSectionLyrics: return NLL(@"Lyrics");
        case NLSectionDisplay: return NLL(@"Display");
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    NLSection kind = [self nlSectionKind:section];
    if (kind == NLSectionNothing) return NLL(@"Play a song in an app NowLyrics is on for, then come back.");
    if (kind == NLSectionDisplay && _np) return NLL(@"This song’s timing only; a positive offset shows its lyrics earlier. Every other song uses the default offset under Advanced.");
    if (kind == NLSectionLyrics) {
        return [NSString stringWithFormat:NLL(@"Tap a source to look this song up again with it; the ticked one looks it up again as before. Automatic follows the source order. Added lyrics are used in %@ before any online source; LRC, word-by-word LRC and TTML work."),
                NLAppName(_bundleID)];
    }
    return nil;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NLSection kind = [self nlSectionKind:indexPath.section];
    if (kind == NLSectionDisplay && indexPath.row == NLDisplayRowOffset) return kNLStackedRowHeight;
    return UITableViewAutomaticDimension;
}

// The song's card and the result row size themselves to their text, which a
// refresh changes (one line while searching, a line per source for a miss).
// Reloaded off screen, a row is laid out at its estimate until it shows again;
// the height it was last shown at keeps the rows in view where they are when
// the card above them was scrolled away.
- (CGFloat)tableView:(UITableView *)tableView estimatedHeightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSNumber *height = _heights[indexPath];
    return height ? height.doubleValue : 44;
}

// Searching, or asked from here and not answered yet.
- (BOOL)nlSearching { return _askedAt || ![self nlString:NL_NP_STATUS]; }

// What the readout says about the lyrics: manual, cached or fetched (and from
// where), still searching, or not found (with what each source answered).
- (NSString *)nlStatusText {
    NSString *status = [self nlString:NL_NP_STATUS];
    NSString *path = [self nlPath];
    NSString *text;
    if ([self nlIsManual]) {
        text = NLL(@"Added by you");
    } else if ([self nlSearching]) {
        text = NLL(@"Searching…");
    } else if (path) {
        NSString *from = NLStatusSource(status);
        text = [status hasPrefix:NL_STATUS_CACHE]
            ? ([from isEqualToString:NL_STATUS_CACHE] ? NLL(@"Saved") : [NSString stringWithFormat:@"%@ · %@", NLL(@"Saved"), from])
            : from;
    } else {
        text = [NSString stringWithFormat:@"%@\n%@", NLL(@"No lyrics found"), NLMissLines(status)];
    }
    if (NLPrefBool(_np, NL_NP_WORDS, NO)) text = [text stringByAppendingFormat:@" · %@", NLL(@"Word by word")];
    return text;
}

// The offset this song plays with: the default one (Advanced) and its own
// together, so there is one number to look at. A change is kept as this
// song's own, the difference from the default.
- (double)nlDefaultOffset {
    return NLLooseNum([self nlPref:@"offset"], 0);
}

- (UITableViewCell *)nlOffsetCell {
    NLSongOffsetCell *cell = [[NLSongOffsetCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = NLL(@"Offset");
    cell.imageView.image = NLSettingsIcon(@"clock", @"#33C759");
    double offset = [self nlDefaultOffset] + NLTrackOffset(@{NL_TRACK_OFFSETS_KEY: [self nlDictionaryPref:NL_TRACK_OFFSETS_KEY]}, [self nlString:NL_NP_KEY]);
    // Past the slider's ±3 s (the default raised after this song got its own),
    // the range takes it in: clamped, the row would show another offset and a
    // touch would write that one back.
    [cell.control extendRangeToInclude:offset];
    cell.control.value = offset;
    [cell.control addTarget:self action:@selector(nlOffsetChanged:) forControlEvents:UIControlEventValueChanged];
    return cell;
}

- (UITableViewCell *)nlDisplayCellForRow:(NSInteger)row {
    if (row == NLDisplayRowOffset) return [self nlOffsetCell];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    if (row == NLDisplayRowArtist) {
        cell.textLabel.text = NLL(@"Artist field");
        cell.imageView.image = NLSettingsIcon(@"text.alignleft", @"#FC9429");
        cell.accessoryView = [self nlArtistFieldButton];
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

// What the lookup from here came to: still searching (with which source),
// found (where, how many lines, word or line timing, the first lines), or not
// (with what each source answered).
- (UITableViewCell *)nlResultCell {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.textLabel.numberOfLines = 0;
    cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.imageView.image = NLSettingsIcon(@"magnifyingglass", @"#5C5CDE");
    NSString *status = [self nlString:NL_NP_STATUS];
    NSString *path = [self nlPath];
    if ([self nlIsManual]) {
        cell.textLabel.text = NLL(@"This song uses lyrics you added");
        return cell;
    }
    if ([self nlSearching]) {
        cell.textLabel.text = [NSString stringWithFormat:NLL(@"Searching with %@…"), NLSourceTitle(_askedSource)];
        UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        [spinner startAnimating];
        cell.accessoryView = spinner;
        return cell;
    }
    NSArray<NLLyricLine *> *lines = path ? NLParseLRCFile(path) : nil;   // parsed again only when the file changed
    NSArray<NSString *> *sung = NLSungTexts(lines, NSUIntegerMax);
    if (!sung.count) {
        cell.textLabel.text = NLL(@"No lyrics found");
        // What each source answered; with a file that no longer reads (deleted
        // for a lookup from here that went unanswered) the status names where
        // it came from instead.
        cell.detailTextLabel.text = path ? status : NLMissLines(status);
        return cell;
    }
    NSString *from = NLStatusSource(status);
    if ([from hasPrefix:@"Musixmatch"]) from = @"Musixmatch";
    cell.imageView.image = NLSourceIcon([self nlSourceNameForLabel:from]);
    cell.textLabel.text = [NSString stringWithFormat:NLL(@"%@ · %lu lines · %@"), from, (unsigned long)sung.count,
                           NLHasWords(lines) ? NLL(@"word-timed") : NLL(@"line-timed")];
    cell.detailTextLabel.text = [[sung subarrayWithRange:NSMakeRange(0, MIN(sung.count, (NSUInteger)2))] componentsJoinedByString:@"\n"];
    return cell;
}

// The source's preference name from the label the engine writes.
- (NSString *)nlSourceNameForLabel:(NSString *)label {
    NSDictionary *names = NL_ONCE((@{@"Apple Music": @"applemusic", @"Musixmatch": @"musixmatch", @"LRCLIB": @"lrclib", @"NetEase": @"netease"}));
    return names[label] ?: @"";
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self nlSectionKind:indexPath.section] == NLSectionDisplay) return [self nlDisplayCellForRow:indexPath.row];
    if (!_np) {
        UITableViewCell *cell = NLNoteCell(NLL(@"Nothing is playing"));
        cell.textLabel.textAlignment = NSTextAlignmentCenter;
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
    NSInteger lyricsRow = indexPath.row - (NSInteger)[self nlResultRows];
    if (indexPath.section == NLSectionLyrics && lyricsRow < 0) return [self nlResultCell];
    if (indexPath.section == NLSectionLyrics && lyricsRow < (NSInteger)_sources.count) {
        NSString *name = _sources[lyricsRow];
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = NLSourceTitle(name);
        cell.imageView.image = NLSourceIcon(name);
        cell.accessoryType = [name isEqualToString:_picked] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        return cell;
    }

    NSString *action = _actions[lyricsRow - _sources.count];
    NSDictionary *rows = NL_ONCE((@{
        @"removeManual": @[@"Remove added lyrics", @"trash"],
        @"paste":        @[@"Paste lyrics", @"doc.on.clipboard"],
        @"import":       @[@"Import from Files", @"folder"],
        @"edit":         @[@"View and edit", @"doc.text"],
    }));
    UITableViewCell *cell = NLActionCell(NLL(rows[action][0]), rows[action][1],
                                         [action isEqualToString:@"removeManual"] ? UIColor.systemRedColor : self.view.tintColor);
    if ([action isEqualToString:@"edit"]) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (!_np || indexPath.section != NLSectionLyrics) return;
    NSInteger lyricsRow = indexPath.row - (NSInteger)[self nlResultRows];
    if (lyricsRow < 0) return;   // the result
    if (lyricsRow < (NSInteger)_sources.count) {
        [self nlPickSource:_sources[lyricsRow]];
        return;
    }
    NSString *action = _actions[lyricsRow - _sources.count];
    if ([action isEqualToString:@"removeManual"]) [self nlRemoveManual];
    else if ([action isEqualToString:@"paste"]) [self nlPaste];
    else if ([action isEqualToString:@"import"]) [self nlImport];
    else if ([action isEqualToString:@"edit"]) [self nlEdit];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    NLThemeCell(cell);
    _heights[indexPath] = @(cell.bounds.size.height);
}

#pragma mark Actions

- (void)nlRemoveManual {
    NSString *path = [self nlPath];   // the song asked about, should the next one start while the alert is up
    NLConfirm(self, NLL(@"Remove added lyrics?"), NLL(@"The app looks the song up again."), NLL(@"Remove"), ^{
        NLDeleteLyricsFile(path);
        [self nlStartPolling];
    });
}

// Pasted or imported text as this song's own lyrics; `title` and `message` say
// why not when it holds no timed lyrics.
- (void)nlAddLyrics:(NSString *)text unusable:(NSString *)title message:(NSString *)message {
    NSString *stored = NLLyricsFileText(text, [self nlString:NL_NP_TITLE], [self nlString:NL_NP_ARTIST]);
    if (!stored) {
        NLAlert(self, title, message);
        return;
    }
    [self nlSaveManual:stored];
}

- (void)nlPaste {
    [self nlAddLyrics:UIPasteboard.generalPasteboard.string
             unusable:NLL(@"No timed lyrics on the clipboard") message:NLL(@"Copy LRC or TTML lyrics first.")];
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
    [self nlAddLyrics:text unusable:NLL(@"Not timed lyrics") message:NLL(@"The file is not LRC or TTML with times.")];
}

// Into the app's manual folder, under the name NLManualLyrics looks for, which
// takes it before the cache and the sources.
- (void)nlSaveManual:(NSString *)text {
    NSString *folder = NLLyricsFolderForBundle(_bundleID);
    if (!folder) {
        NLAlert(self, NLL(@"Could not save"), NLAppName(_bundleID));
        return;
    }
    NSString *dir = [folder stringByAppendingPathComponent:NL_MANUAL_FOLDER];
    NSString *path = [dir stringByAppendingPathComponent:NLManualFileName([self nlString:NL_NP_TITLE], [self nlString:NL_NP_ARTIST])];

    void (^write)(void) = ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
        if (NLSaveLyricsFile(self, text, path)) [self nlStartPolling];
    };
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        write();
        return;
    }
    NLConfirm(self, NLL(@"Replace the added lyrics?"), nil, NLL(@"Replace"), write);
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
