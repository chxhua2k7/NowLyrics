//
//  NLSourceOrderController.m
//  "Source order" on the Lyrics Sources page: the sources switched on, in the
//  order they are tried, dragged into another. Saved as `sourceOrder`, every
//  source named once (those switched off keep their place among themselves,
//  after the others), which NLSettings reads.
//
//  Also what the pages share about the sources and the preferences (read and
//  written through the page that pushed them), and NLTablePage, the base of
//  the pages that are a table of their own.
//

#import "NLLyricsPages.h"

// Each source: its preference name, title, switch and default, and the icon
// the Lyrics Sources page gives it.
static NSArray<NSDictionary *> *NLSources(void) {
    return NL_ONCE((@[
        @{@"name": @"applemusic", @"title": @"Apple Music", @"switch": @"useAppleMusic", @"on": @NO,
          @"app": @"com.apple.Music", @"symbol": @"music.note", @"color": @"#FA2D48"},
        @{@"name": @"musixmatch", @"title": @"Musixmatch", @"switch": @"useMusixmatch", @"on": @NO,
          @"app": NLMusixmatchBundleID, @"symbol": @"sparkles", @"color": @"#B052DE"},
        @{@"name": @"lrclib", @"title": @"LRCLIB", @"switch": @"useLRCLIB", @"on": @YES,
          @"symbol": @"globe", @"color": @"#30B0C7"},
        @{@"name": @"netease", @"title": @"NetEase Music", @"switch": @"useNetease", @"on": @YES,
          @"app": @"com.netease.cloudmusic", @"symbol": @"cloud", @"color": @"#E33D3D"},
    ]));
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

NSString *NLSourceTitle(NSString *name) {
    NSDictionary *info = NLSourceInfo(name);
    return NLL(info ? info[@"title"] : name.length ? name : @"Automatic");
}

#pragma mark Preferences

// A preference through `controller`, the way its own rows read and write it;
// without one, straight from the domain.
static PSSpecifier *NLPrefSpecifier(PSListController *controller, NSString *key) {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:key target:controller
                                                          set:@selector(setPreferenceValue:specifier:)
                                                          get:@selector(readPreferenceValue:)
                                                       detail:Nil cell:PSStaticTextCell edit:Nil];
    [spec setProperty:NL_PREFS_DOMAIN forKey:@"defaults"];
    [spec setProperty:key forKey:@"key"];
    [spec setProperty:NL_RELOAD_NOTIFICATION forKey:@"PostNotification"];
    return spec;
}

id NLReadPref(PSListController *controller, NSString *key) {
    return controller ? [controller readPreferenceValue:NLPrefSpecifier(controller, key)]
                      : CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)NL_PREFS_DOMAIN));
}

void NLWritePref(PSListController *controller, NSString *key, id value) {
    if (controller) [controller setPreferenceValue:value specifier:NLPrefSpecifier(controller, key)];
    else NLWritePrefs(@{key: value ?: NSNull.null});
}

// The saved order, completed as NLSettings completes it (NLCompletedSourceOrder).
NSArray<NSString *> *NLSourceOrder(PSListController *controller) {
    return NLCompletedSourceOrder(NLReadPref(controller, @"sourceOrder"), NLReadPref(controller, @"preferredSource"));
}

BOOL NLSourceSwitchOn(PSListController *controller, NSString *name) {
    NSDictionary *info = NLSourceInfo(name);
    return info && NLReadPrefBool(controller, info[@"switch"], [info[@"on"] boolValue]);
}

@implementation PSViewController (NLPrefs)

// Through the page that pushed this one, the way its own rows read and write.
- (PSListController *)nlParentList {
    PSViewController *parent = self.parentController;
    return [parent isKindOfClass:PSListController.class] ? (PSListController *)parent : nil;
}

- (id)nlPref:(NSString *)key { return NLReadPref([self nlParentList], key); }

- (void)nlSetPref:(id)value forKey:(NSString *)key { NLWritePref([self nlParentList], key, value); }

- (BOOL)nlBoolPref:(NSString *)key fallback:(BOOL)fallback { return NLReadPrefBool([self nlParentList], key, fallback); }

@end

#pragma mark - Table page

@implementation NLTablePage {
    NLPageTop *_pageTop;   // the top as the main page's (Advanced › Other pages too)
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _table = NLMakeTable(self);
    _pageTop = [[NLPageTop alloc] initWithOwner:self table:_table];   // built by -viewWillAppear:'s update
    self.navigationItem.rightBarButtonItem = NLApplyButton(self);
}

// Before super, as on the main page: the header is in place before the row
// tapped to leave the page is deselected.
- (void)viewWillAppear:(BOOL)animated {
    [_pageTop update];
    [super viewWillAppear:animated];
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

@end

#pragma mark - Source order

@interface NLSourceOrderController () <UITableViewDataSource, UITableViewDelegate>
@end

@implementation NLSourceOrderController {
    NSMutableArray<NSString *> *_order;   // every source, in order
    NSMutableArray<NSString *> *_shown;   // those switched on, in order
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NLL(@"Source order");
    _table.editing = YES;
    _table.allowsSelectionDuringEditing = NO;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self nlLoad];
    [_table reloadData];
}

#pragma mark Preferences

- (void)nlLoad {
    _order = [NLSourceOrder([self nlParentList]) mutableCopy];
    _shown = [NSMutableArray array];
    for (NSString *name in _order) {
        if ([name isEqualToString:@"applemusic"] && !NLAppleMusicVerified()) continue;   // no subscription confirmed
        if ([name isEqualToString:@"musixmatch"] && !NLMusixmatchVerified()) continue;   // not unlocked
        if (NLSourceSwitchOn([self nlParentList], name)) [_shown addObject:name];
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
    NSString *name = _shown[indexPath.row];
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = NLSourceTitle(name);
    cell.imageView.image = NLSourceIcon(name);
    cell.showsReorderControl = YES;
    return cell;
}

- (UITableViewCellEditingStyle)tableView:(UITableView *)tableView editingStyleForRowAtIndexPath:(NSIndexPath *)indexPath {
    return UITableViewCellEditingStyleNone;
}

- (BOOL)tableView:(UITableView *)tableView shouldIndentWhileEditingRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

// Every row can move: this method alone makes them movable.
- (void)tableView:(UITableView *)tableView moveRowAtIndexPath:(NSIndexPath *)from toIndexPath:(NSIndexPath *)to {
    NSString *name = _shown[from.row];
    [_shown removeObjectAtIndex:from.row];
    [_shown insertObject:name atIndex:to.row];
    [self nlSave];
}

@end
