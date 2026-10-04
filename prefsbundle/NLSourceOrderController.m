//
//  NLSourceOrderController.m
//  "Source order" on the Lyrics Sources page: the sources switched on, in the
//  order they are tried, dragged into another. Saved as `sourceOrder`, every
//  source named once (those switched off keep their place among themselves,
//  after the others), which NLSettings reads.
//

#import "NLLyricsPages.h"
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>

@interface PSListController (NLPreferences)
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
@end

// Each source: its preference name, title, switch and default, and the icon
// the Lyrics Sources page gives it.
static NSArray<NSDictionary *> *NLSources(void) {
    return @[
        @{@"name": @"applemusic", @"title": @"Apple Music", @"switch": @"useAppleMusic", @"on": @NO,
          @"app": @"com.apple.Music", @"symbol": @"music.note", @"color": @"#FA2D48"},
        @{@"name": @"musixmatch", @"title": @"Musixmatch", @"switch": @"useMusixmatch", @"on": @NO,
          @"app": @"com.musixmatch.lyrics", @"symbol": @"sparkles", @"color": @"#B052DE"},
        @{@"name": @"lrclib", @"title": @"LRCLIB", @"switch": @"useLRCLIB", @"on": @YES,
          @"symbol": @"globe", @"color": @"#30B0C7"},
        @{@"name": @"netease", @"title": @"NetEase Music", @"switch": @"useNetease", @"on": @YES,
          @"app": @"com.netease.cloudmusic", @"symbol": @"cloud", @"color": @"#E33D3D"},
    ];
}

static NSDictionary *NLSourceInfo(NSString *name) {
    for (NSDictionary *info in NLSources()) if ([info[@"name"] isEqualToString:name]) return info;
    return nil;
}

UIImage *NLSourceIcon(NSString *name) {
    NSDictionary *info = NLSourceInfo(name);
    if (!info) return NLSettingsIcon(@"list.number", @"#5C5CDE");   // automatic: the source order's
    return NLRowIcon(info[@"app"], info[@"symbol"], info[@"color"]);
}

@interface NLSourceOrderController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation NLSourceOrderController {
    UITableView *_table;
    NSMutableArray<NSString *> *_order;   // every source, in order
    NSMutableArray<NSString *> *_shown;   // those switched on, in order
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NLL(@"Source order");
    _table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _table.dataSource = self;
    _table.delegate = self;
    _table.editing = YES;
    _table.allowsSelectionDuringEditing = NO;
    [self.view addSubview:_table];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self nlLoad];
    [_table reloadData];
}

#pragma mark Preferences

// Through the page that pushed this one, the way its own rows read and write.
- (PSListController *)nlParent {
    PSViewController *parent = self.parentController;
    return [parent isKindOfClass:PSListController.class] ? (PSListController *)parent : nil;
}

- (PSSpecifier *)nlSpecifierForKey:(NSString *)key {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:key target:[self nlParent]
                                                          set:@selector(setPreferenceValue:specifier:)
                                                          get:@selector(readPreferenceValue:)
                                                       detail:Nil cell:PSStaticTextCell edit:Nil];
    [spec setProperty:NL_PREFS_DOMAIN forKey:@"defaults"];
    [spec setProperty:key forKey:@"key"];
    [spec setProperty:NL_RELOAD_NOTIFICATION forKey:@"PostNotification"];
    return spec;
}

- (id)nlPref:(NSString *)key {
    PSListController *parent = [self nlParent];
    return parent ? [parent readPreferenceValue:[self nlSpecifierForKey:key]]
                  : CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)NL_PREFS_DOMAIN));
}

- (void)nlSetPref:(id)value forKey:(NSString *)key {
    PSListController *parent = [self nlParent];
    if (parent) {
        [parent setPreferenceValue:value specifier:[self nlSpecifierForKey:key]];
        return;
    }
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)NL_PREFS_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)NL_PREFS_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)NL_RELOAD_NOTIFICATION, NULL, NULL, YES);
}

- (BOOL)nlIsOn:(NSDictionary *)info {
    id value = [self nlPref:info[@"switch"]];
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : [info[@"on"] boolValue];
}

// The saved order, completed as NLSettings completes it (an old preferred
// source goes right after Apple Music).
- (void)nlLoad {
    id saved = [self nlPref:@"sourceOrder"];
    id preferred = [self nlPref:@"preferredSource"];
    NSArray *names = [saved isKindOfClass:NSArray.class] ? saved : @[@"applemusic", preferred ?: @""];
    _order = [NSMutableArray array];
    for (id name in [names arrayByAddingObjectsFromArray:[NLSources() valueForKey:@"name"]]) {
        if ([name isKindOfClass:NSString.class] && NLSourceInfo(name) && ![_order containsObject:name]) [_order addObject:name];
    }
    _shown = [NSMutableArray array];
    for (NSString *name in _order) {
        if ([name isEqualToString:@"applemusic"] && !NLAppleMusicVerified()) continue;   // no subscription confirmed
        if ([self nlIsOn:NLSourceInfo(name)]) [_shown addObject:name];
    }
}

// The shown ones in their new order, the others after them as they were.
- (void)nlSave {
    NSMutableArray *order = [_shown mutableCopy];
    for (NSString *name in _order) if (![order containsObject:name]) [order addObject:name];
    _order = order;
    [self nlSetPref:[order copy] forKey:@"sourceOrder"];
}

#pragma mark Table

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_shown.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    return NLL(@"Drag to change the order; the one on top is tried first. Only sources switched on are listed.");
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *info = NLSourceInfo(_shown[indexPath.row]);
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = NLL(info[@"title"]);
    cell.imageView.image = NLSourceIcon(info[@"name"]);
    cell.showsReorderControl = YES;
    return cell;
}

- (BOOL)tableView:(UITableView *)tableView canMoveRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSString *name = _shown[from.row];
    [_shown removeObjectAtIndex:from.row];
    [_shown insertObject:name atIndex:to.row];
    [self nlSave];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    NLThemeCell(cell);
}

@end
