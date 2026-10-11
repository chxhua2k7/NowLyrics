//
//  NLLibraryController.m
//  Every lyrics file the apps hold. The first page lists the apps (icon, name,
//  how many songs); an app's page lists its songs, the ones added by hand
//  first, then the saved ones, newest first. Searching on the first page looks
//  through every app's songs. Swipe to delete, tap to open in the editor.
//  "Clear lyrics cache" at the bottom deletes the saved ones and keeps the
//  added ones.
//
//  Files written since 1.2.0 name their track and source in LRC tags at the
//  top; older ones only have their file name to go by.
//

#import "NLLyricsPages.h"

@interface NLLibraryEntry : NSObject
@property (nonatomic, copy) NSString *path, *title, *artist, *source, *bundleID;
@property (nonatomic, strong) NSDate *date;
@property (nonatomic, assign) BOOL manual, words;
@end

@implementation NLLibraryEntry
@end

// A name to show for a file without tags: the cache's "_<hash>" goes, and an
// added file's "Title - Artist" is split.
static void NLNameFromFile(NLLibraryEntry *entry) {
    NSString *name = entry.path.lastPathComponent.stringByDeletingPathExtension;
    if (entry.manual) {
        NSRange dash = [name rangeOfString:@" - " options:NSBackwardsSearch];
        if (dash.location != NSNotFound && !entry.title) {
            entry.title = [name substringToIndex:dash.location];
            entry.artist = entry.artist ?: [name substringFromIndex:NSMaxRange(dash)];
        }
    } else {
        NSRange hash = [name rangeOfString:@"_[0-9a-f]+$" options:NSRegularExpressionSearch];
        if (hash.location != NSNotFound) name = [name substringToIndex:hash.location];
    }
    if (!entry.title) entry.title = name;
}

static NSArray<NLLibraryEntry *> *NLEntriesIn(NSString *folder, NSString *bundleID, BOOL manual) {
    NSMutableArray<NLLibraryEntry *> *out = [NSMutableArray array];
    NSArray<NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:folder isDirectory:YES]
                                                            includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                 error:nil];
    // Lyrics cached before 1.2.0 (no source named) stay out until the app has
    // deleted them, which it does the next time it runs (NLClearOldCache).
    BOOL oldGone = manual || [[NSFileManager defaultManager] fileExistsAtPath:[folder stringByAppendingPathComponent:NL_OLD_CACHE_CLEARED]];
    for (NSURL *url in files) {
        if (![url.pathExtension.lowercaseString isEqualToString:@"lrc"]) continue;
        NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
        if (!text) continue;
        NSDictionary *tags = NLParseLRCHeader(text);
        if (!oldGone && !tags[NL_LRC_SOURCE]) continue;
        NLLibraryEntry *entry = [NLLibraryEntry new];
        entry.path = url.path;
        entry.bundleID = bundleID;
        entry.manual = manual;
        entry.title = tags[NL_LRC_TITLE];
        entry.artist = tags[NL_LRC_ARTIST];
        entry.source = manual ? NLL(@"Added by you") : tags[NL_LRC_SOURCE];
        entry.words = [text rangeOfString:@"]<"].location != NSNotFound;
        NSDate *date = nil;
        [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
        entry.date = date ?: [NSDate distantPast];
        NLNameFromFile(entry);
        [out addObject:entry];
    }
    return out;
}

@interface NLLibraryController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, copy) NSString *onlyApp;   // an app's page; nil for the first one
@end

@implementation NLLibraryController {
    UITableView *_table;
    UISearchController *_search;
    NSArray<NSString *> *_apps;                                       // bundle IDs, by name
    NSDictionary<NSString *, NSString *> *_names;                     // bundle ID → name, as of the load
    NSDictionary<NSString *, NSMutableArray<NLLibraryEntry *> *> *_entries;
    NSArray<NSString *> *_shownApps;                                  // after the search
    NSDictionary<NSString *, NSArray<NLLibraryEntry *> *> *_shown;
    NSDateFormatter *_dates;
    BOOL _loaded;
    BOOL _appList;   // showing the apps rather than songs
    NLPageTop *_pageTop;   // the top as the main page's (Advanced › Other pages too)
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.onlyApp ? NLAppName(self.onlyApp) : NLL(@"Lyrics Library");
    _dates = [NSDateFormatter new];
    _dates.dateStyle = NSDateFormatterShortStyle;
    _dates.timeStyle = NSDateFormatterNoStyle;
    _dates.doesRelativeDateFormatting = YES;

    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    _table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:_table];

    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = NLL(@"Search");
    self.navigationItem.searchController = _search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
    _pageTop = [[NLPageTop alloc] initWithOwner:self table:_table];
    [_pageTop update];
}

- (void)viewWillAppear:(BOOL)animated {
    [_pageTop update];
    [super viewWillAppear:animated];
    [self nlLoad];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [_pageTop appear];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_pageTop disappear];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [_pageTop layout];
}

- (void)preferredContentSizeDidChangeForChildContentContainer:(id<UIContentContainer>)container {
    [super preferredContentSizeDidChangeForChildContentContainer:container];
    [_pageTop layout];
}

- (void)nlLoad {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary<NSString *, NSMutableArray<NLLibraryEntry *> *> *entries = [NSMutableDictionary dictionary];
        // An app's page needs its own folder only, not a scan of every app's container.
        NSString *container = self.onlyApp ? NLDataContainerForBundle(self.onlyApp) : nil;
        NSDictionary<NSString *, NSString *> *folders = !self.onlyApp ? NLLyricsFolders()
            : container ? @{self.onlyApp: [container stringByAppendingPathComponent:@"Library/NowLyrics"]} : @{};
        for (NSString *bundleID in folders) {
            NSMutableArray<NLLibraryEntry *> *list = [NSMutableArray array];
            NSArray *manual = NLEntriesIn([folders[bundleID] stringByAppendingPathComponent:@"manual"], bundleID, YES);
            NSArray *saved = NLEntriesIn(folders[bundleID], bundleID, NO);
            NSSortDescriptor *newest = [NSSortDescriptor sortDescriptorWithKey:@"date" ascending:NO];
            [list addObjectsFromArray:[manual sortedArrayUsingDescriptors:@[newest]]];
            [list addObjectsFromArray:[saved sortedArrayUsingDescriptors:@[newest]]];
            if (list.count) entries[bundleID] = list;
        }
        NSMutableDictionary<NSString *, NSString *> *names = [NSMutableDictionary dictionary];
        for (NSString *bundleID in entries) names[bundleID] = NLAppName(bundleID);
        NSArray *apps = [entries.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
            return [names[a] localizedStandardCompare:names[b]];
        }];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_entries = entries;
            self->_apps = apps;
            self->_names = names;
            self->_loaded = YES;
            [self nlFilter];
        });
    });
}

- (void)nlFilter {
    NSString *query = [_search.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    _appList = !self.onlyApp && query.length == 0;
    NSMutableArray<NSString *> *apps = [NSMutableArray array];
    NSMutableDictionary<NSString *, NSArray<NLLibraryEntry *> *> *shown = [NSMutableDictionary dictionary];
    for (NSString *bundleID in _apps) {
        NSArray<NLLibraryEntry *> *list = _entries[bundleID];
        if (query.length) {
            BOOL appMatches = [_names[bundleID] localizedCaseInsensitiveContainsString:query];
            list = [list filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NLLibraryEntry *e, NSDictionary *b) {
                return appMatches || [e.title localizedCaseInsensitiveContainsString:query] ||
                       [e.artist localizedCaseInsensitiveContainsString:query];
            }]];
        }
        if (list.count == 0) continue;
        [apps addObject:bundleID];
        shown[bundleID] = list;
    }
    _shownApps = apps;
    _shown = shown;
    [_table reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController *)searchController {
    [self nlFilter];
}

#pragma mark Table

// The first page: one section of apps. Songs: one section per app (an app's
// page has just its own). Either way the clear button follows, on the first
// page only.
- (NSInteger)nlListSections {
    return _appList ? 1 : (NSInteger)MAX(_shownApps.count, 1);
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    if (!_loaded) return 0;
    return [self nlListSections] + (self.onlyApp ? 0 : 1);
}

- (BOOL)nlIsButtonSection:(NSInteger)section {
    return !self.onlyApp && section == [self nlListSections];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if ([self nlIsButtonSection:section]) return 1;
    if (_appList) return (NSInteger)MAX(_shownApps.count, 1);
    return _shownApps.count ? (NSInteger)_shown[_shownApps[section]].count : 1;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if ([self nlIsButtonSection:section] || _appList || self.onlyApp || _shownApps.count == 0) return nil;
    return _names[_shownApps[section]];
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return [self nlIsButtonSection:section] ? NLL(@"Lyrics you added are kept.") : nil;
}

- (NSString *)nlAppAt:(NSIndexPath *)indexPath {
    if (!_appList || [self nlIsButtonSection:indexPath.section] || indexPath.row >= (NSInteger)_shownApps.count) return nil;
    return _shownApps[indexPath.row];
}

- (NLLibraryEntry *)nlEntryAt:(NSIndexPath *)indexPath {
    if (_appList || [self nlIsButtonSection:indexPath.section] || _shownApps.count == 0) return nil;
    return _shown[_shownApps[indexPath.section]][indexPath.row];
}

// An app row: its icon at the size Settings uses, its name, how many songs.
- (UITableViewCell *)nlAppCell:(NSString *)bundleID {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
    cell.textLabel.text = _names[bundleID];
    cell.detailTextLabel.text = [NSString stringWithFormat:@"%lu", (unsigned long)_shown[bundleID].count];
    UIImage *icon = NLAppIcon(bundleID);
    if (icon) {
        CGSize size = CGSizeMake(29, 29);
        cell.imageView.image = [[[UIGraphicsImageRenderer alloc] initWithSize:size] imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:6.5] addClip];
            [icon drawInRect:CGRectMake(0, 0, size.width, size.height)];
        }];
    }
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self nlIsButtonSection:indexPath.section]) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = NLL(@"Clear lyrics cache");
        cell.textLabel.textColor = UIColor.systemRedColor;
        cell.imageView.image = [UIImage systemImageNamed:@"trash"];
        cell.imageView.tintColor = UIColor.systemRedColor;
        return cell;
    }
    NSString *app = [self nlAppAt:indexPath];
    if (app) return [self nlAppCell:app];
    NLLibraryEntry *entry = [self nlEntryAt:indexPath];
    if (!entry) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = _search.searchBar.text.length ? NLL(@"No results") : NLL(@"No lyrics stored yet");
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        return cell;
    }
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"entry"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"entry"];
    cell.textLabel.text = entry.title;
    NSMutableArray<NSString *> *detail = [NSMutableArray array];
    if (entry.artist.length) [detail addObject:entry.artist];
    if (entry.source.length) [detail addObject:entry.source];
    [detail addObject:[_dates stringFromDate:entry.date]];
    if (entry.words) [detail addObject:NLL(@"Word by word")];
    cell.detailTextLabel.text = [detail componentsJoinedByString:@" · "];
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self nlIsButtonSection:indexPath.section]) {
        [self nlConfirmClear];
        return;
    }
    NSString *app = [self nlAppAt:indexPath];
    if (app) {
        NLLibraryController *page = [NLLibraryController new];
        page.onlyApp = app;
        [self.navigationController pushViewController:page animated:YES];
        return;
    }
    NLLibraryEntry *entry = [self nlEntryAt:indexPath];
    if (!entry) return;
    NLLyricsEditorController *editor = [[NLLyricsEditorController alloc] initWithPath:entry.path title:entry.title];
    // Saved or deleted, it pops: -viewWillAppear: loads the list again.
    [self.navigationController pushViewController:editor animated:YES];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NLLibraryEntry *entry = [self nlEntryAt:indexPath];
    if (!entry) return nil;
    UIContextualAction *delete = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
                                                                         title:NLL(@"Delete")
                                                                       handler:^(UIContextualAction *a, UIView *v, void (^done)(BOOL)) {
        [[NSFileManager defaultManager] removeItemAtPath:entry.path error:nil];
        [self->_entries[entry.bundleID] removeObject:entry];
        NLPostLyricsChanged();
        [self nlFilter];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

#pragma mark Clearing

- (void)nlConfirmClear {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NLL(@"Clear lyrics cache?")
                                                                   message:NLL(@"Lyrics you added are kept.")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NLL(@"Cancel") style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:NLL(@"Clear") style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *a) { [self nlClear]; }]];
    [self presentViewController:alert animated:YES completion:nil];
}

// The saved files of every app, deleted here and now (Preferences can reach
// them); running apps are told to forget theirs. Added lyrics stay.
- (void)nlClear {
    for (NSString *bundleID in _entries) {
        for (NLLibraryEntry *entry in _entries[bundleID]) {
            if (!entry.manual) [[NSFileManager defaultManager] removeItemAtPath:entry.path error:nil];
        }
    }
    NLPostLyricsChanged();
    [self nlLoad];
}

@end
