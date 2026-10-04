//
//  NLRootListController.m
//  The settings page's controller. libprefs' PLLocalizedListController does the
//  work: it loads the items from the plist next to the PreferenceLoader entry
//  (prefs/NowLyrics.plist) and localizes them. This subclass adds what a plist
//  cannot express on its own:
//
//  - Row icons drawn from SF Symbols at runtime. A row names `iconSymbol` and
//    `iconColor` and gets the 29 pt white-glyph-on-coloured-tile that Settings
//    uses, so the page ships no PNGs and the glyphs come from the system.
//  - "Apply" in the navigation bar: after a confirmation, restarts SpringBoard
//    through FrontBoardServices' SBSRelaunchAction (Cephei's way, nothing is
//    spawned). Needed after install or update so NowLyricsIsland is loaded.
//  - The version shown in the About group (NL_VERSION, PACKAGE_VERSION from
//    the Makefile).
//  - Rows that follow a switch: a plist entry with `showIf` = <key> is shown
//    only while that switch is on (NLUpdateShownSpecifiers).
//  - The "Now Playing" and "Lyrics Library" pages are their own controllers
//    (NLLyricsPages.h); this one writes the per-song offsets for the first.
//  - The lock screen's player at the top (NLPlayerHeader), and the pages'
//    theme: the color the island preview shows (NLThemeRefresh).
//  - NLIslandListController, the "Lyrics in the island" page (with a live
//    preview at the top, NLIslandPreviewCell.m), loaded from
//    Island.plist inside this bundle (outside the folder PreferenceLoader scans
//    for entries) and localized by the Island.strings the Makefile copies from
//    prefs/<lang>.lproj/Localizable.strings at stage time.
//
//  Importing <libprefs/prefs.h> links libprefs through Theos' module map; the
//  rootless rpath Theos adds finds it in /var/jb/usr/lib, the same way
//  PreferenceLoader itself links it.
//

#import <UIKit/UIKit.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <libprefs/prefs.h>
#import <dlfcn.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import "NLLyricsPages.h"

@interface PSListController (NLPreferences)
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end


#ifndef NL_VERSION
#error NL_VERSION comes from PACKAGE_VERSION in the Makefile
#endif

@interface UIImage (NLPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(CGFloat)scale;
@end

@interface NLRootListController : PLLocalizedListController
@end

@interface NLIslandListController : PSListController
@end


extern NSString *const NLIslandPreviewChangedNotification;          // NLIslandPreviewCell.m

#pragma mark - Icons

static const CGFloat kNLIconSize = 29;            // what a Settings row shows
static const CGFloat kNLIconCornerRadius = 6.5;
static const CGFloat kNLIconGlyphPointSize = 15;

// "#RRGGBB" → UIColor, nil for anything else.
static UIColor *NLColorFromHex(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *digits = [value hasPrefix:@"#"] ? [value substringFromIndex:1] : value;
    unsigned rgb = 0;
    if (digits.length != 6 || ![[NSScanner scannerWithString:digits] scanHexInt:&rgb]) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1];
}

// A white SF Symbol centred on a rounded tile of the given colour.
static UIImage *NLTileIcon(NSString *symbolName, UIColor *color) {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:kNLIconGlyphPointSize
                                                                                                weight:UIImageSymbolWeightMedium];
    UIImage *glyph = [[UIImage systemImageNamed:symbolName withConfiguration:configuration]
                      imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];

    CGRect tile = CGRectMake(0, 0, kNLIconSize, kNLIconSize);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:tile.size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [color setFill];
        [[UIBezierPath bezierPathWithRoundedRect:tile cornerRadius:kNLIconCornerRadius] fill];
        if (!glyph) return;   // unknown symbol name: a plain tile rather than nothing
        CGSize size = glyph.size;
        [glyph drawInRect:CGRectMake((kNLIconSize - size.width) / 2, (kNLIconSize - size.height) / 2, size.width, size.height)];
    }];
}

// The cover the island preview used to show: a warm gradient with a note, on
// a Settings-sized tile (the main switch's icon, `iconDrawn` = sampleCover;
// not `iconImage`, which is PSIconImageKey itself).
UIImage *NLSampleCoverIcon(void) {
    CGRect tile = CGRectMake(0, 0, kNLIconSize, kNLIconSize);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:tile.size];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        [[UIBezierPath bezierPathWithRoundedRect:tile cornerRadius:kNLIconCornerRadius] addClip];
        CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
        NSArray *colors = @[(id)[UIColor colorWithRed:1.00 green:0.48 blue:0.36 alpha:1].CGColor,
                            (id)[UIColor colorWithRed:0.86 green:0.25 blue:0.55 alpha:1].CGColor];
        CGGradientRef gradient = CGGradientCreateWithColors(space, (__bridge CFArrayRef)colors, NULL);
        CGContextDrawLinearGradient(context.CGContext, gradient, CGPointZero, CGPointMake(kNLIconSize, kNLIconSize), 0);
        CGGradientRelease(gradient);
        CGColorSpaceRelease(space);
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:kNLIconSize * 0.45
                                                                                             weight:UIImageSymbolWeightSemibold];
        UIImage *note = [[UIImage systemImageNamed:@"music.note" withConfiguration:config]
                         imageWithTintColor:[UIColor colorWithWhite:1 alpha:0.9] renderingMode:UIImageRenderingModeAlwaysOriginal];
        [note drawInRect:CGRectMake((kNLIconSize - note.size.width) / 2, (kNLIconSize - note.size.height) / 2,
                                    note.size.width, note.size.height)];
    }];
}

UIImage *NLSettingsIcon(NSString *symbol, NSString *hex) {
    UIColor *color = NLColorFromHex(hex);
    return color ? NLTileIcon(symbol, color) : nil;
}

@interface NSObject (NLWorkspace)
+ (instancetype)defaultWorkspace;
- (BOOL)applicationIsInstalled:(NSString *)bundleID;
@end

static BOOL NLAppInstalled(NSString *bundleID) {
    id workspace = [objc_getClass("LSApplicationWorkspace") defaultWorkspace];
    return [workspace respondsToSelector:@selector(applicationIsInstalled:)] ? [workspace applicationIsInstalled:bundleID] : YES;
}

UIImage *NLRowIcon(NSString *app, NSString *symbol, NSString *hex) {
    if ([app isKindOfClass:[NSString class]] && NLAppInstalled(app)) {
        UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:app format:0 scale:UIScreen.mainScreen.scale];
        if (icon) return icon;
    }
    return NLSettingsIcon(symbol, hex);
}

static void NLApplyIcon(PSSpecifier *specifier) {
    if ([specifier propertyForKey:PSIconImageKey]) return;   // drawn already, or a real image from the plist
    // `iconApp`: the installed app's own icon (the 29 pt "small" format), so the
    // row matches what the user sees on the home screen. Falls back to the symbol.
    if ([[specifier propertyForKey:@"iconDrawn"] isEqual:@"sampleCover"]) {
        [specifier setProperty:NLSampleCoverIcon() forKey:PSIconImageKey];
        return;
    }
    NSString *app = [specifier propertyForKey:@"iconApp"];
    // An app that is not installed would get the system's blank placeholder.
    if ([app isKindOfClass:[NSString class]] && NLAppInstalled(app)) {
        UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:app format:0 scale:UIScreen.mainScreen.scale];
        if (icon) { [specifier setProperty:icon forKey:PSIconImageKey]; return; }
    }
    NSString *symbol = [specifier propertyForKey:@"iconSymbol"];
    UIColor *color = NLColorFromHex([specifier propertyForKey:@"iconColor"]);
    if (![symbol isKindOfClass:[NSString class]] || !color) return;
    [specifier setProperty:NLTileIcon(symbol, color) forKey:PSIconImageKey];
}

#pragma mark - Rows that follow a switch

// A row whose plist entry names `showIf` = <key> (or an array of keys) is
// shown only while the switch with that key (every one of them) is on;
// flipping a switch inserts or removes those rows, animated. A key with no
// switch on the page is read from the preferences (off when unset), and
// "!<key>" wants it off. Both pages keep the full list and show the wanted
// subset.
static PSSpecifier *NLSwitchFor(NSArray<PSSpecifier *> *all, NSString *key) {
    for (PSSpecifier *s in all) {
        if ([[s propertyForKey:@"key"] isEqual:key]) return s;
    }
    return nil;
}

static NSArray<NSString *> *NLShowIfKeys(PSSpecifier *specifier) {
    id showIf = [specifier propertyForKey:@"showIf"];
    if ([showIf isKindOfClass:NSString.class]) return @[showIf];
    if ([showIf isKindOfClass:NSArray.class]) return showIf;
    return @[];
}

static NSString *NLShowIfKey(NSString *rule) {
    return [rule hasPrefix:@"!"] ? [rule substringFromIndex:1] : rule;
}

static BOOL NLSpecifierWanted(PSListController *controller, NSArray<PSSpecifier *> *all, PSSpecifier *specifier) {
    for (NSString *rule in NLShowIfKeys(specifier)) {
        NSString *key = NLShowIfKey(rule);
        PSSpecifier *control = NLSwitchFor(all, key);
        id value = control ? [controller readPreferenceValue:control]
                           : CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("app.nowlyrics")));
        if (![value respondsToSelector:@selector(boolValue)]) value = [control propertyForKey:@"default"];
        if ([value boolValue] == [rule hasPrefix:@"!"]) return NO;
    }
    return YES;
}

static NSMutableArray *NLWantedSpecifiers(PSListController *controller, NSArray<PSSpecifier *> *all) {
    NSMutableArray *wanted = [NSMutableArray array];
    for (PSSpecifier *s in all) {
        if (NLSpecifierWanted(controller, all, s)) [wanted addObject:s];
    }
    return wanted;
}

// Both pages: icons, the link fix below, then the rows to show of `specifiers`,
// which is kept whole in *all.
static NSMutableArray *NLPrepareSpecifiers(PSListController *controller, NSArray<PSSpecifier *> *specifiers,
                                           NSArray<PSSpecifier *> **all) {
    for (PSSpecifier *specifier in specifiers) {
        NLApplyIcon(specifier);
        // libprefs' PLCustomListController turns every PSLinkCell without a bundle
        // path into another page of the host class; a link that names its
        // `detail` gets that class back.
        NSString *detail = [specifier propertyForKey:@"detail"];
        Class detailClass = [detail isKindOfClass:NSString.class] ? NSClassFromString(detail) : Nil;
        if (detailClass && specifier.detailControllerClass != detailClass) {
            [specifier setValue:detailClass forKey:@"detailControllerClass"];
        }
    }
    *all = [specifiers copy];
    return NLWantedSpecifiers(controller, *all);
}

static void NLShowAlert(UIViewController *controller, NSString *title, NSString *message, NSArray<UIAlertAction *> *actions) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    for (UIAlertAction *action in actions) [alert addAction:action];
    [controller presentViewController:alert animated:YES completion:nil];
}

// Bring the shown rows in line with the full list.
static void NLRefreshShownSpecifiers(PSListController *controller, NSArray<PSSpecifier *> *all) {
    PSSpecifier *previous = nil;
    for (PSSpecifier *s in all) {
        BOOL want = NLSpecifierWanted(controller, all, s);
        BOOL shown = [controller indexOfSpecifier:s] != NSNotFound;
        if (want && !shown) {
            if (previous) [controller insertSpecifier:s afterSpecifier:previous animated:YES];
            else [controller insertSpecifier:s atIndex:0 animated:YES];
        } else if (!want && shown) {
            [controller removeSpecifier:s animated:YES];
        }
        if (want) previous = s;
    }
}

// After a switch changed: the rows that follow it.
static void NLUpdateShownSpecifiers(PSListController *controller, NSArray<PSSpecifier *> *all, PSSpecifier *changed) {
    NSString *key = [changed propertyForKey:@"key"];
    for (PSSpecifier *s in all) {
        for (NSString *rule in NLShowIfKeys(s)) {
            if ([NLShowIfKey(rule) isEqual:key]) {
                NLRefreshShownSpecifiers(controller, all);
                return;
            }
        }
    }
}

#pragma mark - Controller

@implementation NLRootListController {
    NSArray<PSSpecifier *> *_allSpecifiers;   // every row from the plist, shown or not
    NSString *_size;
    NLPlayerHeader *_player;
    NSTimer *_refresh;
    NSUInteger _ticks;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:[self nlLocalized:@"Apply"]
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(nlApply:)];
    _player = [[NLPlayerHeader alloc] initWithOwner:self table:self.table];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nlApplyTheme)
                                                 name:NLThemeChangedNotification object:nil];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_refresh invalidate];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [_player layout];
}

- (void)preferredContentSizeDidChangeForChildContentContainer:(id<UIContentContainer>)container {
    [super preferredContentSizeDidChangeForChildContentContainer:container];
    [_player layout];
}

// While the page is up the player follows what is playing, and the theme
// follows what the island preview shows.
- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self nlApplyTheme];
    NLThemeRefresh();
    NLRecheckAppleMusicIfDue(nil);   // a lapsed subscription locks Apple Music again
    [_refresh invalidate];
    __weak typeof(self) weakSelf = self;
    _refresh = [NSTimer scheduledTimerWithTimeInterval:0.75 repeats:YES block:^(NSTimer *timer) { [weakSelf nlTick]; }];
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
    // Back to Settings: its own colors again.
    if (self.isMovingFromParentViewController) self.navigationController.view.tintColor = nil;
}

- (void)nlTick {
    [_player tick];
    if (_ticks++ % 4 == 0) NLThemeRefresh();
}

// The tint reaches every NowLyrics page through the navigation controller's
// view; the switches are set one by one.
- (void)nlApplyTheme {
    if (self.navigationController.topViewController != self && ![self.navigationController.viewControllers containsObject:self]) return;
    // Set plainly: a transition on the navigation controller's view would
    // replace the push and pop animations running under it.
    UIView *view = self.navigationController.view ?: self.view;
    UIColor *color = NLThemeColor();
    if (view.tintColor != color && ![view.tintColor isEqual:color]) view.tintColor = color;
    for (UIViewController *controller in self.navigationController.viewControllers) {
        if ([controller isKindOfClass:PSListController.class]) NLThemeTable([(PSListController *)controller table]);
    }
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([PSListController instancesRespondToSelector:_cmd]) [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    NLThemeCell(cell);
}

- (void)nlApply:(id)sender {
    NLShowAlert(self, [self nlLocalized:@"Apply"], [self nlLocalized:@"Restart SpringBoard to apply?"], @[
        [UIAlertAction actionWithTitle:[self nlLocalized:@"Cancel"] style:UIAlertActionStyleCancel handler:nil],
        [UIAlertAction actionWithTitle:[self nlLocalized:@"Respring"] style:UIAlertActionStyleDestructive
                               handler:^(UIAlertAction *action) { [self nlRespring]; }],
    ]);
}

- (void)nlRespring {
    dlopen("/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices", RTLD_NOW);
    dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_NOW);
    Class actionClass = objc_getClass("SBSRelaunchAction");
    Class serviceClass = objc_getClass("FBSSystemService");
    if (!actionClass || !serviceClass) return;
    // SBSRelaunchActionOptionsRestartRenderServer = 1 << 0
    id action = ((id (*)(id, SEL, id, NSUInteger, id))objc_msgSend)(actionClass, @selector(actionWithReason:options:targetURL:), @"NowLyrics", 1, nil);
    id service = ((id (*)(id, SEL))objc_msgSend)(serviceClass, @selector(sharedService));
    ((void (*)(id, SEL, id, id))objc_msgSend)(service, @selector(sendActions:withResult:), [NSSet setWithObject:action], nil);
}

- (NSMutableArray *)specifiers {
    if (_specifiers && _allSpecifiers) return _specifiers;
    NSArray<PSSpecifier *> *all = nil;
    _specifiers = NLPrepareSpecifiers(self, [super specifiers], &all);
    _allSpecifiers = all;
    return _specifiers;
}

- (void)reloadSpecifiers {
    _allSpecifiers = nil;
    [super reloadSpecifiers];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    NLUpdateShownSpecifiers(self, _allSpecifiers, specifier);
}

- (NSString *)nlLocalized:(NSString *)key {
    return [self.bundle localizedStringForKey:key value:key table:nil] ?: key;
}

// The About group's Version row (`get = nlVersion:` in the plist).
- (NSString *)nlVersion:(PSSpecifier *)specifier {
    return @NL_VERSION;
}

// The About group's Size row: what the package installed, by dpkg's list of
// its files.
- (NSString *)nlSize:(PSSpecifier *)specifier {
    if (_size) return _size;
    NSString *list = [NSString stringWithContentsOfFile:@"/var/jb/var/lib/dpkg/info/com.c3x14n.nowlyrics.list"
                                               encoding:NSUTF8StringEncoding error:nil];
    if (!list) return @"–";
    unsigned long long total = 0;
    for (NSString *path in [list componentsSeparatedByString:@"\n"]) {
        struct stat st;
        if (path.length && lstat(path.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode)) total += (unsigned long long)st.st_size;
    }
    _size = [NSByteCountFormatter stringFromByteCount:(long long)total countStyle:NSByteCountFormatterCountStyleFile];
    return _size;
}

@end

#pragma mark - Lyrics in the island

@implementation NLIslandListController {
    NSArray<PSSpecifier *> *_allSpecifiers;
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSArray<PSSpecifier *> *all = nil;
        _specifiers = NLPrepareSpecifiers(self, [self loadSpecifiersFromPlistName:@"Island" target:self], &all);
        _allSpecifiers = all;
        // Room for the open island, taller by the rows tweaks add to it (Crescendo's
        // volume row, NextUp 3's Up Next row), at the most it can be.
        PSSpecifier *preview = nil;
        for (PSSpecifier *s in all) if ([s.identifier isEqualToString:@"islandPreview"]) preview = s;   // shown or not
        id height = [preview propertyForKey:@"height"];
        CGFloat extra = NLIslandPreviewMostExtraHeight();
        if (preview && extra > 0 && [height respondsToSelector:@selector(doubleValue)]) {
            [preview setProperty:@([height doubleValue] + extra) forKey:@"height"];
        }
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    NLUpdateShownSpecifiers(self, _allSpecifiers, specifier);
    [[NSNotificationCenter defaultCenter] postNotificationName:NLIslandPreviewChangedNotification object:self];
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([PSListController instancesRespondToSelector:_cmd]) [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    NLThemeCell(cell);
}

// For the preview row (NLIslandPreviewCell): each setting's current value, or
// its plist default when it was never changed.
- (NSDictionary *)nlIslandPreviewValues {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (PSSpecifier *specifier in _allSpecifiers) {
        NSString *key = [specifier propertyForKey:@"key"];
        if (![key isKindOfClass:NSString.class]) continue;
        id value = [self readPreferenceValue:specifier] ?: [specifier propertyForKey:@"default"];
        if (value) values[key] = value;
    }
    return values;
}

@end

#pragma mark - Detail pages

@implementation NLSubListController {
    NSArray<PSSpecifier *> *_allSpecifiers;
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSString *name = [self.specifier propertyForKey:@"subPlist"];
        NSArray<PSSpecifier *> *all = nil;
        _specifiers = NLPrepareSpecifiers(self, [name isKindOfClass:NSString.class]
                                                    ? [self loadSpecifiersFromPlistName:name target:self] : @[], &all);
        _allSpecifiers = all;
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    NLUpdateShownSpecifiers(self, _allSpecifiers, specifier);
}

// After Apple Music was unlocked or locked: its rows, and its link's state.
- (void)nlRefreshAppleMusicRows {
    NLRefreshShownSpecifiers(self, _allSpecifiers);
    if ([self specifierForID:@"appleMusicLink"]) [self reloadSpecifierID:@"appleMusicLink" animated:NO];
}

// "Unlock Apple Music lyrics": SpringBoard checks for a subscription; with
// one, Apple Music shows and is switched on, without one it stays hidden.
- (void)nlUnlockAppleMusic:(PSSpecifier *)specifier {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:NLL(@"Apple Music subscription")
                                                                   message:NLL(@"Checking your Apple Music subscription…")
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NLL(@"OK") style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    __weak typeof(self) weakSelf = self;
    NLCheckAppleMusicSubscription(^(NLSubscription result, NSString *detail) {
        NLApplyAppleMusicSubscription(result);
        if (result == NLSubscriptionActive) {
            CFPreferencesSetAppValue(CFSTR("useAppleMusic"), kCFBooleanTrue, CFSTR("app.nowlyrics"));
            CFPreferencesAppSynchronize(CFSTR("app.nowlyrics"));
            CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                                 CFSTR("app.nowlyrics/ReloadPrefs"), NULL, NULL, YES);
        }
        [weakSelf nlRefreshAppleMusicRows];
        alert.message = result == NLSubscriptionActive
            ? NLL(@"Subscription confirmed. Apple Music lyrics are unlocked and on, in Music and in other apps such as Spotify.")
            : result == NLSubscriptionNone
            ? NLL(@"There is no Apple Music subscription on this Apple ID, so Apple Music lyrics stay hidden.")
            : [NSString stringWithFormat:NLL(@"Could not check the subscription (%@). Try again later."), detail];
    });
}

// The Apple Music row on Lyrics Sources: on or off, as Settings shows a page's
// state beside its link; read again on coming back from that page.
- (NSString *)nlAppleMusicState:(PSSpecifier *)specifier {
    CFPreferencesAppSynchronize(CFSTR("app.nowlyrics"));
    id on = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("useAppleMusic"), CFSTR("app.nowlyrics")));
    return [on boolValue] ? NLL(@"On") : NLL(@"Off");
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    if ([self specifierForID:@"appleMusicLink"]) [self reloadSpecifierID:@"appleMusicLink" animated:NO];
    __weak typeof(self) weakSelf = self;
    NLRecheckAppleMusicIfDue(^{ [weakSelf nlRefreshAppleMusicRows]; });
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([PSListController instancesRespondToSelector:_cmd]) [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    NLThemeCell(cell);
}

@end
