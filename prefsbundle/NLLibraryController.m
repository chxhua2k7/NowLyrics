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
    if (entry.title) return;   // named by its tags
    NSString *name = entry.path.lastPathComponent.stringByDeletingPathExtension;
    if (entry.manual) {
        NSRange dash = [name rangeOfString:@" - " options:NSBackwardsSearch];
        if (dash.location != NSNotFound) {
            entry.title = [name substringToIndex:dash.location];
            entry.artist = entry.artist ?: [name substringFromIndex:NSMaxRange(dash)];
            return;
        }
    } else {
        NSRange hash = [name rangeOfString:@"_[0-9a-f]+$" options:NSRegularExpressionSearch];
        if (hash.location != NSNotFound) name = [name substringToIndex:hash.location];
    }
    entry.title = name;
}

// Hidden files too: a file is named after its title, which may start with a
// "." ("...Ready For It?"), and the apps use it all the same. The extension
// keeps everything else out, and so does a missing source while lyrics cached
// before 1.2.0 are still to be deleted, which the app does the next time it
// runs (NLClearOldCache).
static NSArray<NLLibraryEntry *> *NLEntriesIn(NSString *folder, NSString *bundleID, BOOL manual) {
    NSMutableArray<NLLibraryEntry *> *out = [NSMutableArray array];
    NSArray<NSURL *> *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:folder isDirectory:YES]
                                                            includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                               options:0
                                                                                 error:nil];
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
        entry.words = NLLRCHasWordTimes(text);
        entry.date = NLModificationDate(url);
        NLNameFromFile(entry);
        [out addObject:entry];
    }
    return out;
}

@interface NLLibraryController () <UITableViewDataSource, UITableViewDelegate, UISearchResultsUpdating>
@property (nonatomic, copy) NSString *onlyApp;   // an app's page; nil for the first one
@end

@implementation NLLibraryController {
    UISearchController *_search;
    NSArray<NSString *> *_apps;                                       // bundle IDs, by name
    NSDictionary<NSString *, NSString *> *_names;                     // bundle ID → name, as of the load
    NSDictionary<NSString *, NSMutableArray<NLLibraryEntry *> *> *_entries;
    NSArray<NSString *> *_shownApps;                                  // after the search
    NSDictionary<NSString *, NSArray<NLLibraryEntry *> *> *_shown;
    NSDateFormatter *_dates;
    BOOL _loaded;
    BOOL _appList;   // showing the apps rather than songs
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.onlyApp ? NLAppName(self.onlyApp) : NLL(@"Lyrics Library");
    _dates = [NSDateFormatter new];
    _dates.dateStyle = NSDateFormatterShortStyle;
    _dates.timeStyle = NSDateFormatterNoStyle;
    _dates.doesRelativeDateFormatting = YES;

    _search = [[UISearchController alloc] initWithSearchResultsController:nil];
    _search.searchResultsUpdater = self;
    _search.obscuresBackgroundDuringPresentation = NO;
    _search.searchBar.placeholder = NLL(@"Search");
    self.navigationItem.searchController = _search;
    self.navigationItem.hidesSearchBarWhenScrolling = NO;
    self.definesPresentationContext = YES;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self nlLoad];
}

- (void)nlLoad {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableDictionary<NSString *, NSMutableArray<NLLibraryEntry *> *> *entries = [NSMutableDictionary dictionary];
        // An app's page needs its own folder only, not a scan of every app's container.
        NSString *own = self.onlyApp ? NLLyricsFolderForBundle(self.onlyApp) : nil;
        NSDictionary<NSString *, NSString *> *folders = !self.onlyApp ? NLLyricsFolders() : own ? @{self.onlyApp: own} : @{};
        NSSortDescriptor *newest = [NSSortDescriptor sortDescriptorWithKey:@"date" ascending:NO];
        for (NSString *bundleID in folders) {
            NSMutableArray<NLLibraryEntry *> *list = [NSMutableArray array];
            NSArray *manual = NLEntriesIn([folders[bundleID] stringByAppendingPathComponent:NL_MANUAL_FOLDER], bundleID, YES);
            NSArray *saved = NLEntriesIn(folders[bundleID], bundleID, NO);
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

// What is searched for: the search bar's text without its outer spaces, so
// spaces alone search for nothing.
- (NSString *)nlQuery {
    return [_search.searchBar.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

- (void)nlFilter {
    NSString *query = [self nlQuery];
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
    if (icon) cell.imageView.image = NLRowSizedImage(icon, YES);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([self nlIsButtonSection:indexPath.section]) {
        return NLActionCell(NLL(@"Clear lyrics cache"), @"trash", UIColor.systemRedColor);
    }
    NSString *app = [self nlAppAt:indexPath];
    if (app) return [self nlAppCell:app];
    NLLibraryEntry *entry = [self nlEntryAt:indexPath];
    if (!entry) return NLNoteCell([self nlQuery].length ? NLL(@"No results") : NLL(@"No lyrics stored yet"));
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"entry"]
        ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"entry"];
    cell.textLabel.text = entry.title;
    NSMutableArray<NSString *> *detail = [NSMutableArray array];
    if (entry.artist.length) [detail addObject:entry.artist];
    if (entry.source.length) [detail addObject:entry.source];
    [detail addObject:[_dates stringFromDate:entry.date]];
    if (entry.words) [detail addObject:NLL(@"Word by word")];
    // Wrapped rather than cut: after a long artist the source, the date and
    // whether it is word by word would go first. The title stays on one line.
    cell.detailTextLabel.text = [detail componentsJoinedByString:@" · "];
    cell.detailTextLabel.numberOfLines = 0;
    cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if ([self nlIsButtonSection:indexPath.section]) {
        NLConfirm(self, NLL(@"Clear lyrics cache?"), NLL(@"Lyrics you added are kept."), NLL(@"Clear"), ^{ [self nlClear]; });
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
        NLDeleteLyricsFile(entry.path);
        [self->_entries[entry.bundleID] removeObject:entry];
        [self nlFilter];
        done(YES);
    }];
    return [UISwipeActionsConfiguration configurationWithActions:@[delete]];
}

#pragma mark Clearing

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
