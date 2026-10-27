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
//  - The "Now Playing" page is its own controller (NLLyricsPages.h), linked
//    from here; this one writes the per-song offsets for it.
//  - The lock screen's player at the top (NLPlayerHeader), or the island
//    preview, or nothing (Advanced › Top of main page), and the pages' theme,
//    which goes with Player over its cover (NLThemeRefresh).
//  - NLIslandListController, the "Lyrics Island" page (with a live
//    preview at the top, NLIslandPreviewCell.m), loaded from
//    Island.plist inside this bundle (outside the folder PreferenceLoader scans
//    for entries) and localized by the Island.strings the Makefile copies from
//    prefs/<lang>.lproj/Localizable.strings at stage time.
//
//  Importing <libprefs/prefs.h> links libprefs through Theos' module map; the
//  rootless rpath Theos adds finds it in /var/jb/usr/lib, the same way
//  PreferenceLoader itself links it.
//

#import <libprefs/prefs.h>
#import <dlfcn.h>
#import <notify.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <sys/stat.h>
#import "NLLyricsPages.h"
#import "../NLPlayerTint.h"

@interface PSListController (NLPreferences)
// Moves a shown row and its table row, the table animating it (iOS 15 to 26).
- (void)_moveSpecifierAtIndex:(NSUInteger)from toIndex:(NSUInteger)to animated:(BOOL)animated;
@end


#ifndef NL_VERSION
#error NL_VERSION comes from PACKAGE_VERSION in the Makefile
#endif

@interface NLRootListController : PLLocalizedListController
@end

@interface NLIslandListController : NLListController
@end

#pragma mark - Icons

static const CGFloat kNLIconGlyphPointSize = 15;

// "#RRGGBB" → UIColor, nil for anything else.
UIColor *NLColorFromHex(id value) {
    if (![value isKindOfClass:[NSString class]]) return nil;
    NSString *digits = [value hasPrefix:@"#"] ? [value substringFromIndex:1] : value;
    unsigned rgb = 0;
    if (digits.length != 6 || ![[NSScanner scannerWithString:digits] scanHexInt:&rgb]) return nil;
    return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                           green:((rgb >> 8) & 0xFF) / 255.0
                            blue:(rgb & 0xFF) / 255.0
                           alpha:1];
}

// A white SF Symbol centred on a rounded tile of the given colour. The name
// can list fallbacks, "newer|older", for symbols an older iOS lacks.
static UIImage *NLTileIcon(NSString *symbolName, UIColor *color) {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:kNLIconGlyphPointSize
                                                                                                weight:UIImageSymbolWeightMedium];
    UIImage *symbol = nil;
    for (NSString *name in [symbolName componentsSeparatedByString:@"|"]) {
        symbol = [UIImage systemImageNamed:name withConfiguration:configuration];
        if (symbol) break;
    }
    UIImage *glyph = [symbol imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];

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

// Drawn once per symbol, color and text weight: Now Playing and Source order
// ask for one on every cell. Main queue.
UIImage *NLSettingsIcon(NSString *symbol, NSString *hex) {
    static NSMutableDictionary<NSString *, UIImage *> *drawn;
    NSString *key = [NSString stringWithFormat:@"%@\n%@\n%d", symbol, hex, UIAccessibilityIsBoldTextEnabled()];
    UIImage *icon = drawn[key];
    if (icon) return icon;
    UIColor *color = NLColorFromHex(hex);
    icon = color ? NLTileIcon(symbol, color) : nil;
    if (icon) {
        if (!drawn) drawn = [NSMutableDictionary dictionary];
        drawn[key] = icon;
    }
    return icon;
}

@interface NSObject (NLWorkspace)
+ (instancetype)defaultWorkspace;
- (BOOL)applicationIsInstalled:(NSString *)bundleID;
@end

BOOL NLAppInstalled(NSString *bundleID) {
    id workspace = [objc_getClass("LSApplicationWorkspace") defaultWorkspace];
    return [workspace respondsToSelector:@selector(applicationIsInstalled:)] ? [workspace applicationIsInstalled:bundleID] : YES;
}

UIImage *NLRowIcon(NSString *app, NSString *symbol, NSString *hex) {
    // An app that is not installed would get the system's blank placeholder.
    if ([app isKindOfClass:[NSString class]] && NLAppInstalled(app)) {
        UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:app format:0 scale:UIScreen.mainScreen.scale];
        if (icon) return icon;
    }
    return NLSettingsIcon(symbol, hex);
}

static void NLApplyIcon(PSSpecifier *specifier) {
    if ([specifier propertyForKey:PSIconImageKey]) return;   // drawn already, or a real image from the plist
    if ([[specifier propertyForKey:@"iconDrawn"] isEqual:@"sampleCover"]) {
        [specifier setProperty:NLSampleCoverIcon() forKey:PSIconImageKey];
        return;
    }
    // `iconBundle`: a tweak's own icon, the "icon" of its preference bundle (a
    // jailbreak path), as its own Settings row has it. Not installed: the symbol.
    NSString *tweakBundle = [specifier propertyForKey:@"iconBundle"];
    if ([tweakBundle isKindOfClass:NSString.class]) {
        NSBundle *bundle = [NSBundle bundleWithPath:NLJBPath(tweakBundle)];
        UIImage *image = bundle ? [UIImage imageNamed:@"icon" inBundle:bundle compatibleWithTraitCollection:nil] : nil;
        if (image) {
            [specifier setProperty:NLRowSizedImage(image, NO) forKey:PSIconImageKey];
            return;
        }
    }
    // `iconApp`: the installed app's own icon (the 29 pt "small" format), so the
    // row matches what the user sees on the home screen. Falls back to the symbol.
    NSString *symbol = [specifier propertyForKey:@"iconSymbol"];
    // No symbol name, no tile (NLRowIcon would draw a plain one).
    UIImage *icon = NLRowIcon([specifier propertyForKey:@"iconApp"], symbol,
                              [symbol isKindOfClass:NSString.class] ? [specifier propertyForKey:@"iconColor"] : nil);
    if (icon) [specifier setProperty:icon forKey:PSIconImageKey];
}

#pragma mark - Rows that follow a switch

// A row whose plist entry names `showIf` = <key> (or an array of keys) is
// shown only while the switch with that key (every one of them) is on;
// flipping a switch inserts or removes those rows, animated. A key with no
// switch on the page is read from the preferences (off when unset), and
// "!<key>" wants it off. A group's rule covers its rows. Every page keeps the
// full list and shows the wanted subset.
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

// What the top of the main page shows (Advanced › Top of main page): the
// lock screen's player, the island preview or nothing.
NSString *NLMainPageTop(PSListController *controller) {
    id value = NLReadPref(controller, @"pageHeader");
    return [value isEqual:@"island"] || [value isEqual:@"none"] ? value : @"player";
}

static BOOL NLSpecifierWanted(PSListController *controller, NSArray<PSSpecifier *> *all, PSSpecifier *specifier) {
    for (NSString *rule in NLShowIfKeys(specifier)) {
        NSString *key = NLShowIfKey(rule);
        PSSpecifier *control = NLSwitchFor(all, key);
        // What this iOS can do, or what the main page's top shows, rather than a switch.
        id value = [key isEqualToString:@"nlAppleMusicAvailable"] ? @(NLAppleMusicAvailable())
                 : [key isEqualToString:@"nlPlayerTintAvailable"] ? @(NLPlayerTintAvailable())
                 : [key isEqualToString:@"nlCrescendoUsed"] ? @(NLCrescendoUsed())
                 : [key isEqualToString:@"nlNextUpUsed"] ? @(NLNextUpUsed())
                 : [key isEqualToString:@"nlSystemPlayer"] ? @(NLSystemPlayerAvailable())
                 : [key isEqualToString:@"nlSystemPlayerSizes"] ? @(NLSystemPlayerSizesAvailable())
                 : [key isEqualToString:@"nlCCSupport"] ? @(NLCCModulesAvailable())
                 : [key isEqualToString:@"nlHeaderIsland"] ? @([NLMainPageTop(controller) isEqualToString:@"island"])
                 : control ? [controller readPreferenceValue:control]
                           : NLReadPref(nil, key);
        if (![value respondsToSelector:@selector(boolValue)]) value = [control propertyForKey:@"default"];
        if ([value boolValue] == [rule hasPrefix:@"!"]) return NO;
    }
    return YES;
}

// A row is also hidden while its group is: a group's showIf covers its rows.
static BOOL NLRowWanted(PSListController *controller, NSArray<PSSpecifier *> *all, PSSpecifier *s, BOOL *groupWanted) {
    BOOL want = NLSpecifierWanted(controller, all, s);
    if (s.cellType == PSGroupCell) return *groupWanted = want;
    return *groupWanted && want;
}

static NSMutableArray *NLWantedSpecifiers(PSListController *controller, NSArray<PSSpecifier *> *all) {
    NSMutableArray *wanted = [NSMutableArray array];
    BOOL group = YES;
    for (PSSpecifier *s in all) {
        if (NLRowWanted(controller, all, s, &group)) [wanted addObject:s];
    }
    return wanted;
}

// The island preview's row (`islandPreview`, on the island page and at the
// top of the main page): room for the open island, taller by the rows tweaks
// add to it (Crescendo's volume row, NextUp 3's Up Next row), at the most it
// can be.
static void NLMakeRoomForIslandPreview(PSSpecifier *s) {
    if (![s.identifier isEqualToString:@"islandPreview"]) return;   // shown or not
    // iOS 26's grouped tables leave less between the row's group and the next
    // card than 16's: the open island touched that card.
    CGFloat slack = 0;
    if (@available(iOS 26.0, *)) slack = 12;
    id base = [s propertyForKey:@"nlBaseHeight"] ?: [s propertyForKey:@"height"];
    if (![base respondsToSelector:@selector(doubleValue)]) return;
    [s setProperty:base forKey:@"nlBaseHeight"];
    [s setProperty:@([base doubleValue] + NLIslandPreviewMostExtraHeight() + slack) forKey:@"height"];
}

// Every page: icons, the link fix, the domain, the island preview's room.
static NSArray<PSSpecifier *> *NLPrepareSpecifiers(NSArray<PSSpecifier *> *specifiers) {
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
        // Every setting lives in NowLyrics' domain; the plists leave `defaults` out.
        if ([specifier propertyForKey:@"key"] && ![specifier propertyForKey:@"defaults"]) {
            [specifier setProperty:NL_PREFS_DOMAIN forKey:@"defaults"];
        }
        NLMakeRoomForIslandPreview(specifier);
    }
    return [specifiers copy];
}

// Bring the shown rows in line with the full list.
static void NLRefreshShownSpecifiers(PSListController *controller, NSArray<PSSpecifier *> *all) {
    PSSpecifier *previous = nil;
    BOOL group = YES;
    for (PSSpecifier *s in all) {
        BOOL want = NLRowWanted(controller, all, s, &group);
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

// Whether a row that follows one of `keys` is shown, or hidden, against what
// the preferences say now: another process (SpringBoard) may have written
// them since the rows were laid out.
static BOOL NLRowsFollowingOutOfStep(PSListController *controller, NSArray<PSSpecifier *> *all, NSArray<NSString *> *keys) {
    NLSyncPrefs();
    BOOL group = YES;
    for (PSSpecifier *s in all) {
        BOOL want = NLRowWanted(controller, all, s, &group);   // every row, in order: a group's rule covers its rows
        BOOL follows = NO;
        for (NSString *rule in NLShowIfKeys(s)) follows = follows || [keys containsObject:NLShowIfKey(rule)];
        if (follows && want != ([controller indexOfSpecifier:s] != NSNotFound)) return YES;
    }
    return NO;
}

#pragma mark - Lyrics Island

// Whether this device shows the Dynamic Island: what SpringBoard found once it
// had finished launching (NL_ISLAND_STATE_NAME), which counts an island given
// by other means (a MobileGestalt edit, a tweak in SpringBoard), on an iPad
// too. Until SpringBoard has said (installed, not yet resprung), as
// SpringBoard decides it in this process: SpringBoardServices'
// SBSIsSystemApertureAvailable (iOS 16 and later), which goes by what
// MobileGestalt reports, so a device made to show the island by changing that
// counts too. Without that function, a status bar taller than a notch's (59 pt
// and up with the island, 44 to 50 with a notch); not known yet (no window)
// counts as yes, so the note below never shows by mistake.
static BOOL NLDeviceHasDynamicIsland(void) {
    if (@available(iOS 16.0, *)) {} else return NO;
    static int token = -1;
    if (token == -1 && notify_register_check(NL_ISLAND_STATE_NAME, &token) != NOTIFY_STATUS_OK) token = -2;
    uint64_t state = 0;
    if (token >= 0) notify_get_state(token, &state);
    if (state == kNLIslandPresent || state == kNLIslandAbsent) return state == kNLIslandPresent;
    static BOOL (*available)(void);
    static BOOL has;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        available = (BOOL (*)(void))dlsym(RTLD_DEFAULT, "SBSIsSystemApertureAvailable");
        if (available) has = available();
    });
    if (available) return has;
    CGFloat top = 0;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) top = MAX(top, window.safeAreaInsets.top);
        top = MAX(top, CGRectGetHeight(windowScene.statusBarManager.statusBarFrame));
    }
    return top == 0 || top > 51;
}

static NSString *const kNLNoIslandNote = @"Lyrics Island needs an iPhone with the Dynamic Island, on iOS 16 or later, so it does not show on this one. The lyrics on the lock screen, in Control Center and in CarPlay work as usual.";

// Without a Dynamic Island, a note on the group that holds `anchor`: the
// island row's (its detail class) on the main page, the switch's on the
// island page. Ahead of whatever the group already says.
static void NLNoteNoIsland(NSArray<PSSpecifier *> *all, NSString *anchor) {
    if (NLDeviceHasDynamicIsland()) return;
    PSSpecifier *group = nil;
    for (PSSpecifier *s in all) {
        if (s.cellType == PSGroupCell) group = s;
        BOOL hit = [NSStringFromClass(s.detailControllerClass) isEqualToString:anchor] ||
                   [[s propertyForKey:@"key"] isEqual:anchor];
        if (hit) break;
    }
    if (!group) return;
    NSString *note = NLL(kNLNoIslandNote);
    NSString *had = [group propertyForKey:@"footerText"];
    [group setProperty:NLJoinNonEmpty(note, had, @"\n\n") forKey:@"footerText"];
}

#pragma mark - Controller

// Every island preview's values (the Lyrics Island page's own, the main
// page's, the other pages'): each island setting's current value, read through
// `controller` (or from the domain without one), else its default. Read from
// the Lyrics Island page's plist rather than loaded as its specifiers, which
// would give the page asking that page's title.
NSDictionary *NLIslandPreviewValuesFromPlist(PSListController *controller) {
    static NSArray<NSDictionary *> *items;
    if (!items) {
        // This bundle's: the main page's own bundle is PreferenceLoader's folder.
        NSString *path = [NLPrefsBundle() pathForResource:@"Island" ofType:@"plist"];
        items = NLArray(path ? [NSDictionary dictionaryWithContentsOfFile:path] : nil, @"items") ?: @[];
    }
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    for (NSDictionary *item in items) {
        NSString *key = NLString(item, @"key");
        if (!key) continue;
        id value = NLReadPref(controller, key) ?: item[@"default"];
        if (value) values[key] = value;
    }
    return values;
}

// SpringBoard restarted, as the Apply button does it: what runs there (Lyrics
// Island, Player over its cover, Apple Music lyrics in other apps) loads anew.
static void NLRespring(void) {
    Class serviceClass = NLLoadedClass("FBSSystemService", "/System/Library/PrivateFrameworks/FrontBoardServices.framework/FrontBoardServices");
    Class actionClass = NLLoadedClass("SBSRelaunchAction", "/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices");
    if (!actionClass || !serviceClass) return;
    // SBSRelaunchActionOptionsRestartRenderServer = 1 << 0
    id action = ((id (*)(id, SEL, id, NSUInteger, id))objc_msgSend)(actionClass, @selector(actionWithReason:options:targetURL:), @"NowLyrics", 1, nil);
    id service = ((id (*)(id, SEL))objc_msgSend)(serviceClass, @selector(sharedService));
    ((void (*)(id, SEL, id, id))objc_msgSend)(service, @selector(sendActions:withResult:), [NSSet setWithObject:action], nil);
}

UIBarButtonItem *NLApplyButton(UIViewController *controller) {
    __weak UIViewController *weakController = controller;
    UIAction *apply = [UIAction actionWithTitle:NLL(@"Apply") image:nil identifier:nil handler:^(UIAction *action) {
        UIViewController *presenter = weakController;
        if (presenter) NLConfirm(presenter, NLL(@"Apply"), NLL(@"Restart SpringBoard to apply?"), NLL(@"Respring"), ^{ NLRespring(); });
    }];
    UIBarButtonItem *item = [[UIBarButtonItem alloc] initWithPrimaryAction:apply];
    item.style = UIBarButtonItemStyleDone;
    return item;
}

@implementation NLRootListController {
    NSArray<PSSpecifier *> *_allSpecifiers;   // every row from the plist, shown or not
    NSString *_size;
    NLPlayerHeader *_player;
    NSTimer *_refresh;
    NSUInteger _ticks;
    id _nowPlayingObserver;   // the theme follows what plays on every page above this one
}

// Settings still in the old domain, should this page open before SpringBoard moved them.
+ (void)initialize {
    if (self == [NLRootListController class]) NLMoveOldPrefs();
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = NLApplyButton(self);
    [self nlApplyHeader];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nlApplyTheme)
                                                 name:NLThemeChangedNotification object:nil];
    _nowPlayingObserver = NLThemeFollowNowPlaying();
}

- (void)dealloc {
    [_refresh invalidate];
    if (_nowPlayingObserver) [[NSNotificationCenter defaultCenter] removeObserver:_nowPlayingObserver];
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
    // Changed under Advanced. Before super, which deselects the row tapped to
    // leave the page by its index path: the island row shifts the rows below.
    [self nlApplyHeader];
    [super viewWillAppear:animated];
    [self nlApplyTheme];
    NLThemeRefresh();
    [_refresh invalidate];
    __weak typeof(self) weakSelf = self;
    _refresh = [NSTimer scheduledTimerWithTimeInterval:kNLPageRefreshInterval repeats:YES block:^(NSTimer *timer) { [weakSelf nlTick]; }];
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
    NLPageTick(_player, &_ticks);
}

// The top of the page as Advanced › Top of main page sets it: the lock
// screen's player as the table's header, the island preview as the first row
// (shown by its group's showIf), or neither.
- (void)nlApplyHeader {
    BOOL player = [NLMainPageTop(self) isEqualToString:@"player"];
    if (player && !_player) {
        _player = [[NLPlayerHeader alloc] initWithOwner:self table:self.table];
        [_player layout];
    } else if (!player && _player) {
        [_player remove];
        _player = nil;
    }
    if (_allSpecifiers) NLRefreshShownSpecifiers(self, _allSpecifiers);
}

// The tint reaches every NowLyrics page through the navigation controller's
// view; the switches are set one by one.
- (void)nlApplyTheme {
    UINavigationController *navigation = self.navigationController;
    if (![navigation.viewControllers containsObject:self]) return;
    // Set plainly: a transition on the navigation controller's view would
    // replace the push and pop animations running under it.
    UIView *view = navigation.view;
    UIColor *color = NLThemeColor();
    if (![view.tintColor isEqual:color]) view.tintColor = color;
    for (UIViewController *controller in navigation.viewControllers) {
        if ([controller isKindOfClass:PSListController.class]) NLThemeTable([(PSListController *)controller table]);
    }
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([PSListController instancesRespondToSelector:_cmd]) [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    NLThemeCell(cell);
}

- (NSMutableArray *)specifiers {
    if (_specifiers && _allSpecifiers) return _specifiers;
    _allSpecifiers = NLPrepareSpecifiers([super specifiers]);
    _specifiers = NLWantedSpecifiers(self, _allSpecifiers);
    NLNoteNoIsland(_allSpecifiers, @"NLIslandListController");
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

// The About group's Version row (`get = nlVersion:` in the plist).
- (NSString *)nlVersion:(PSSpecifier *)specifier {
    return @NL_VERSION;
}

// The About group's Size row: what the package installed, by dpkg's list of
// its files. A rootless list has the files as they are (/var/jb/...), a
// roothide one has them under the jailbreak root (/Library/...).
- (NSString *)nlSize:(PSSpecifier *)specifier {
    if (_size) return _size;
    NSString *list = [NSString stringWithContentsOfFile:NLJBPath(@"/var/lib/dpkg/info/com.c3x14n.nowlyrics.list")
                                               encoding:NSUTF8StringEncoding error:nil];
    if (!list) return @"–";
    unsigned long long total = 0;
    for (NSString *listed in [list componentsSeparatedByString:@"\n"]) {
        if (!listed.length) continue;
#if __has_include(<roothide.h>)
        NSString *path = jbroot(listed);
#else
        NSString *path = listed;
#endif
        struct stat st;
        if (lstat(path.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode)) total += (unsigned long long)st.st_size;
    }
    _size = [NSByteCountFormatter stringFromByteCount:(long long)total countStyle:NSByteCountFormatterCountStyleFile];
    return _size;
}

@end

#pragma mark - The pages from this bundle's plists

@interface NLListController ()
@property (nonatomic, copy) NSArray<PSSpecifier *> *nlAllSpecifiers;   // every row from the plist, shown or not
- (NSArray<PSSpecifier *> *)nlLoadSpecifiers;                // the page's rows
- (void)nlDidLoadSpecifiers:(NSArray<PSSpecifier *> *)all;   // notes on groups
@end

@implementation NLListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = NLApplyButton(self);
}

- (NSArray<PSSpecifier *> *)nlLoadSpecifiers {
    return @[];
}

- (void)nlDidLoadSpecifiers:(NSArray<PSSpecifier *> *)all {
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        self.nlAllSpecifiers = NLPrepareSpecifiers([self nlLoadSpecifiers]);
        _specifiers = NLWantedSpecifiers(self, self.nlAllSpecifiers);
        [self nlDidLoadSpecifiers:self.nlAllSpecifiers];
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    NLUpdateShownSpecifiers(self, self.nlAllSpecifiers, specifier);
}

- (void)tableView:(UITableView *)tableView willDisplayCell:(UITableViewCell *)cell forRowAtIndexPath:(NSIndexPath *)indexPath {
    if ([PSListController instancesRespondToSelector:_cmd]) [super tableView:tableView willDisplayCell:cell forRowAtIndexPath:indexPath];
    NLThemeCell(cell);
}

@end

@implementation NLIslandListController

- (NSArray<PSSpecifier *> *)nlLoadSpecifiers {
    return [self loadSpecifiersFromPlistName:@"Island" target:self];
}

- (void)nlDidLoadSpecifiers:(NSArray<PSSpecifier *> *)all {
    NLNoteNoIsland(all, @"islandLyrics");
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    [[NSNotificationCenter defaultCenter] postNotificationName:NLIslandPreviewChangedNotification object:self];
}

@end

#pragma mark - Detail pages

// Lyrics Sources: the rows of the sources (`source` in the plist) in the order
// they are tried, as Source order sets it, in the places those rows take.
static NSArray<PSSpecifier *> *NLInSourceOrder(PSListController *controller, NSArray<PSSpecifier *> *specifiers) {
    NSIndexSet *places = [specifiers indexesOfObjectsPassingTest:^BOOL(PSSpecifier *s, NSUInteger i, BOOL *stop) {
        return [[s propertyForKey:@"source"] isKindOfClass:NSString.class];
    }];
    if (places.count < 2) return specifiers;
    NSArray<NSString *> *order = NLSourceOrder(controller);
    // Stable: Apple Music's two rows (only one is ever shown) keep theirs.
    NSArray<PSSpecifier *> *rows = [[specifiers objectsAtIndexes:places] sortedArrayWithOptions:NSSortStable
                                                                                usingComparator:^NSComparisonResult(PSSpecifier *a, PSSpecifier *b) {
        NSUInteger x = [order indexOfObject:[a propertyForKey:@"source"]];
        NSUInteger y = [order indexOfObject:[b propertyForKey:@"source"]];
        return x < y ? NSOrderedAscending : x > y ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray<PSSpecifier *> *sorted = [specifiers mutableCopy];
    [sorted replaceObjectsAtIndexes:places withObjects:rows];
    return sorted;
}

static BOOL NLSameRows(NSArray<PSSpecifier *> *a, NSArray<PSSpecifier *> *b) {
    if (a.count != b.count) return NO;
    for (NSUInteger i = 0; i < a.count; i++) if (a[i] != b[i]) return NO;
    return YES;
}

// Supported Tweaks: a tweak that is not installed has its switch dimmed, and
// its group says so.
static void NLMarkMissingTweaks(NSArray<PSSpecifier *> *all) {
    PSSpecifier *group = nil;
    for (PSSpecifier *s in all) {
        if (s.cellType == PSGroupCell) group = s;
        NSString *tweak = [s propertyForKey:@"nlTweak"];
        if (![tweak isKindOfClass:NSString.class]) continue;
        BOOL installed = [tweak isEqualToString:@"crescendo"] ? NLCrescendoInstalled()
                       : [tweak isEqualToString:@"nextup"] ? NLNextUpInstalled() : YES;
        if (installed || [[s propertyForKey:@"nlMarkedMissing"] boolValue]) continue;
        [s setProperty:@YES forKey:@"nlMarkedMissing"];
        [s setProperty:@NO forKey:@"enabled"];
        NSString *had = [group propertyForKey:@"footerText"];
        NSString *note = NLL(@"Not installed.");
        if (group) [group setProperty:NLJoinNonEmpty(had, note, @" ") forKey:@"footerText"];
    }
}

@implementation NLSubListController {
    NLPageTop *_pageTop;   // the top as the main page's (Advanced › Other pages too)
}

- (void)viewDidLoad {
    [super viewDidLoad];
    _pageTop = [[NLPageTop alloc] initWithOwner:self table:self.table];
}

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    [_pageTop layout];
}

- (void)preferredContentSizeDidChangeForChildContentContainer:(id<UIContentContainer>)container {
    [super preferredContentSizeDidChangeForChildContentContainer:container];
    [_pageTop layout];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [_pageTop disappear];
}

- (NSArray<PSSpecifier *> *)nlLoadSpecifiers {
    NSString *name = [self.specifier propertyForKey:@"subPlist"];
    NSArray<PSSpecifier *> *loaded = [name isKindOfClass:NSString.class] ? [self loadSpecifiersFromPlistName:name target:self] : @[];
    return NLInSourceOrder(self, loaded);
}

- (void)nlDidLoadSpecifiers:(NSArray<PSSpecifier *> *)all {
    NLMarkMissingTweaks(all);
}

// Back from Source order: the sources' rows move to their new places.
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self nlFollowSourceOrder];
    [_pageTop appear];
}

- (void)nlFollowSourceOrder {
    if (!self.nlAllSpecifiers) return;
    NSArray<PSSpecifier *> *sorted = NLInSourceOrder(self, self.nlAllSpecifiers);
    if (NLSameRows(sorted, self.nlAllSpecifiers)) return;
    self.nlAllSpecifiers = sorted;
    NSMutableArray<PSSpecifier *> *wanted = NLWantedSpecifiers(self, sorted);
    BOOL sameRows = wanted.count == _specifiers.count;
    for (PSSpecifier *s in wanted) if ([_specifiers indexOfObjectIdenticalTo:s] == NSNotFound) { sameRows = NO; break; }
    if (!sameRows || ![self respondsToSelector:@selector(_moveSpecifierAtIndex:toIndex:animated:)]) {
        [self setSpecifiers:wanted];
        return;
    }
    // One move per row out of place, the rows between shifting along.
    for (NSUInteger i = 0; i < wanted.count; i++) {
        NSUInteger from = [_specifiers indexOfObjectIdenticalTo:wanted[i]];
        if (from != i) [self _moveSpecifierAtIndex:from toIndex:i animated:YES];
    }
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    // Advanced › Top of main page or Other pages too: this page's top at once.
    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqual:@"topOnEveryPage"] || [key isEqual:@"pageHeader"]) [_pageTop update];
    // Player over its cover: the theme goes with it, at once.
    if ([key isEqual:NL_PLAYER_TINT_KEY]) NLThemeRefresh();
    // Supported Tweaks: the players and island previews take their rows in or
    // out now (NextUp's own views and our players redo theirs on its notice).
    if ([key isEqual:@"tweakCrescendo"] || [key isEqual:@"tweakNextUp"]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:NL_NEXTUP_CHANGED_NOTIFICATION object:nil];
        [[NSNotificationCenter defaultCenter] postNotificationName:NLIslandPreviewChangedNotification object:self];
        [_pageTop layout];
    }
}

// Control Center: Settings' own page of it, where NowLyrics' modules are added.
- (void)nlOpenControlCenterSettings {
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"prefs:root=ControlCenter"] options:@{} completionHandler:nil];
}

// After Apple Music or Musixmatch was unlocked or locked: their rows, and
// their links' states.
- (void)nlRefreshLockedRows {
    NLRefreshShownSpecifiers(self, self.nlAllSpecifiers);
    [self nlReloadLinkStates];
}

// The link rows that show a switch's state (`stateKey` in Sources.plist),
// shown ones only.
- (void)nlReloadLinkStates {
    for (PSSpecifier *s in [_specifiers copy]) {
        if ([s propertyForKey:@"stateKey"]) [self reloadSpecifier:s animated:NO];
    }
}

// "Unlock Apple Music lyrics": SpringBoard checks for a subscription; with
// one, Apple Music shows and is switched on, without one it stays hidden.
// Before Apple Music's privacy notice is agreed to there is nothing to ask:
// Music, where it is agreed to, is one tap away. Without an Apple ID signed in
// for Media & Purchases it stays locked, and the alert says where to sign in.
- (void)nlUnlockAppleMusic:(PSSpecifier *)specifier {
    UIAlertController *alert = NLPresentAlert(self, NLL(@"Apple Music subscription"), NLL(@"Checking your Apple Music subscription…"),
                                              @[[UIAlertAction actionWithTitle:NLL(@"OK") style:UIAlertActionStyleCancel handler:nil]]);
    __weak typeof(self) weakSelf = self;
    NLCheckAppleMusicSubscription(^(NLSubscription result, NSString *detail) {
        NLApplyAppleMusicSubscription(result, YES);   // active: Apple Music on too, in one write
        [weakSelf nlRefreshLockedRows];
        if (result == NLSubscriptionPrivacy) {
            void (^ask)(void) = ^{
                if (weakSelf) NLPresentAlert(weakSelf, NLL(@"Apple Music subscription"),
                                             NLL(@"Apple Music’s privacy notice is not agreed to on this iPhone yet. Agree to it in Music, then unlock again."),
                                             @[[UIAlertAction actionWithTitle:NLL(@"Open Music") style:UIAlertActionStyleDefault
                                                                      handler:^(UIAlertAction *action) { NLOpenURL(@"music://"); }],
                                               [UIAlertAction actionWithTitle:NLL(@"OK") style:UIAlertActionStyleCancel handler:nil]]);
            };
            if (alert.presentingViewController) [alert dismissViewControllerAnimated:YES completion:ask];
            else ask();
            return;
        }
        alert.message = result == NLSubscriptionActive
            ? NLL(@"Subscription confirmed. Apple Music lyrics are unlocked and on, in Music and in other apps such as Spotify.")
            : result == NLSubscriptionNone
            ? NLL(@"There is no Apple Music subscription on this Apple ID, so Apple Music lyrics stay hidden.")
            : result == NLSubscriptionSignedOut
            ? NLL(@"No Apple ID is signed in for Media & Purchases. Sign in under Settings › your name › Media & Purchases, then unlock again.")
            : [NSString stringWithFormat:NLL(@"Could not check the subscription (%@). Try again later."), detail];
    });
}

// "Unlock Musixmatch lyrics": with the Musixmatch app installed, Musixmatch
// shows and is switched on; without it, the App Store is one tap away.
- (void)nlUnlockMusixmatch:(PSSpecifier *)specifier {
    BOOL unlocked = NLUnlockMusixmatch();
    if (unlocked) [self nlRefreshLockedRows];
    NSMutableArray<UIAlertAction *> *actions = [NSMutableArray array];
    if (!unlocked) [actions addObject:[UIAlertAction actionWithTitle:@"App Store" style:UIAlertActionStyleDefault
                                                             handler:^(UIAlertAction *action) { NLOpenURL(NLMusixmatchStoreURL); }]];
    [actions addObject:[UIAlertAction actionWithTitle:NLL(@"OK") style:UIAlertActionStyleCancel handler:nil]];
    NLPresentAlert(self, @"Musixmatch", unlocked
        ? NLL(@"The Musixmatch app is installed. Musixmatch lyrics are unlocked and on; paste your User Token on the Musixmatch page.")
        : NLL(@"Musixmatch lyrics need the Musixmatch app, where the User Token comes from. Install it, then unlock again."), actions);
}

// The Apple Music and Musixmatch rows on Lyrics Sources: on or off, as Settings
// shows a page's state beside its link; read again on coming back from it.
static NSString *NLSwitchState(NSString *key) {
    NLSyncPrefs();
    return NLReadPrefBool(nil, key, NO) ? NLL(@"On") : NLL(@"Off");
}

- (NSString *)nlLinkState:(PSSpecifier *)specifier {
    return NLSwitchState([specifier propertyForKey:@"stateKey"]);
}

- (void)viewWillAppear:(BOOL)animated {
    // Before super, as on the main page: the header is in place before the row
    // tapped to leave the page is deselected.
    [_pageTop update];
    [super viewWillAppear:animated];
    // Musixmatch's app removed with nothing saved to work without it: locked again.
    if (NLRecheckMusixmatch()) NLRefreshShownSpecifiers(self, self.nlAllSpecifiers);
    [self nlReloadLinkStates];
    // Apple Music locked, unlocked or switched off since the rows were laid
    // out: SpringBoard keeps it in step with the subscription (NLAppleMusicSB.x).
    if (NLRowsFollowingOutOfStep(self, self.nlAllSpecifiers, @[@"appleMusicVerified", @"useAppleMusic"])) [self nlRefreshLockedRows];
}

@end
