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
//  - The action behind the "Clear lyrics cache" button.
//  - "Apply" in the navigation bar: after a confirmation, restarts SpringBoard
//    through FrontBoardServices' SBSRelaunchAction (Cephei's way, nothing is
//    spawned). Needed after install or update so NowLyricsIsland is loaded.
//  - The version shown in the About group (NL_VERSION, PACKAGE_VERSION from
//    the Makefile).
//  - Rows that follow a switch: a plist entry with `showIf` = <key> is shown
//    only while that switch is on (NLUpdateShownSpecifiers).
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

extern NSString *const NLIslandPreviewChangedNotification;   // NLIslandPreviewCell.m

// Localized from this bundle's Island.strings, the copies of
// prefs/<lang>.lproj/Localizable.strings the Makefile puts there. Both pages
// can use it: the main page's own bundle is PreferenceLoader's folder.
static NSString *NLL(NSString *key) {
    static NSBundle *bundle;
    if (!bundle) bundle = [NSBundle bundleForClass:[NLRootListController class]];
    return [bundle localizedStringForKey:key value:key table:@"Island"];
}

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

static void NLApplyIcon(PSSpecifier *specifier) {
    if ([specifier propertyForKey:PSIconImageKey]) return;   // drawn already, or a real image from the plist
    // `iconApp`: the installed app's own icon (the 29 pt "small" format), so the
    // row matches what the user sees on the home screen. Falls back to the symbol.
    NSString *app = [specifier propertyForKey:@"iconApp"];
    if ([app isKindOfClass:[NSString class]]) {
        UIImage *icon = [UIImage _applicationIconImageForBundleIdentifier:app format:0 scale:UIScreen.mainScreen.scale];
        if (icon) { [specifier setProperty:icon forKey:PSIconImageKey]; return; }
    }
    NSString *symbol = [specifier propertyForKey:@"iconSymbol"];
    UIColor *color = NLColorFromHex([specifier propertyForKey:@"iconColor"]);
    if (![symbol isKindOfClass:[NSString class]] || !color) return;
    [specifier setProperty:NLTileIcon(symbol, color) forKey:PSIconImageKey];
}

#pragma mark - Rows that follow a switch

// A row whose plist entry names `showIf` = <key> is shown only while the switch
// with that key is on; flipping the switch inserts or removes those rows,
// animated. Both pages keep the full list and show the wanted subset.
static PSSpecifier *NLSwitchFor(NSArray<PSSpecifier *> *all, NSString *key) {
    for (PSSpecifier *s in all) {
        if ([[s propertyForKey:@"key"] isEqual:key]) return s;
    }
    return nil;
}

static BOOL NLSpecifierWanted(PSListController *controller, NSArray<PSSpecifier *> *all, PSSpecifier *specifier) {
    NSString *key = [specifier propertyForKey:@"showIf"];
    if (![key isKindOfClass:NSString.class]) return YES;
    PSSpecifier *control = NLSwitchFor(all, key);
    if (!control) return YES;
    id value = [controller readPreferenceValue:control];
    if (![value respondsToSelector:@selector(boolValue)]) value = [control propertyForKey:@"default"];
    return [value boolValue];
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

// After a switch changed: bring the shown rows in line with the full list.
static void NLUpdateShownSpecifiers(PSListController *controller, NSArray<PSSpecifier *> *all, PSSpecifier *changed) {
    NSString *key = [changed propertyForKey:@"key"];
    BOOL controlsRows = NO;
    for (PSSpecifier *s in all) {
        if ([[s propertyForKey:@"showIf"] isEqual:key]) { controlsRows = YES; break; }
    }
    if (!controlsRows) return;
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

#pragma mark - Controller

static void NLNoteNoIsland(NSArray<PSSpecifier *> *all, NSString *anchor);   // below, by the island page

@implementation NLRootListController {
    NSArray<PSSpecifier *> *_allSpecifiers;   // every row from the plist, shown or not
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:[self nlLocalized:@"Apply"]
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(nlApply:)];
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
    NLNoteNoIsland(all, @"NLIslandListController");
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

// "Clear lyrics cache" records the time of the tap in the preference file and
// posts the reload notification like any other setting. Every app then deletes
// the cached files older than that moment: at once if it is running, otherwise
// when it is next launched.
- (void)nlClearLyricsCache:(PSSpecifier *)specifier {
    [self setPreferenceValue:@([[NSDate date] timeIntervalSince1970]) specifier:specifier];
    NLShowAlert(self, [self nlLocalized:@"Lyrics cache cleared"],
                [self nlLocalized:@"Apps that are not running clear theirs when next opened."],
                @[[UIAlertAction actionWithTitle:[self nlLocalized:@"OK"] style:UIAlertActionStyleDefault handler:nil]]);
}

// The About group's Version row (`get = nlVersion:` in the plist).
- (NSString *)nlVersion:(PSSpecifier *)specifier {
    return @NL_VERSION;
}

@end

#pragma mark - Lyrics in the island

// Whether this iPhone has a Dynamic Island, as SpringBoard decides it:
// SpringBoardServices' SBSIsSystemApertureAvailable (iOS 16 and later), which
// goes by the artwork subtype MobileGestalt reports, so an iPhone made to show
// the island by changing that (iOS 16) counts too. Without that function, a
// status bar taller than a notch's (59 pt and up with the island, 44 to 50
// with a notch); not known yet (no window) counts as yes, so the note below
// never shows by mistake.
static BOOL NLDeviceHasDynamicIsland(void) {
    if (@available(iOS 16.0, *)) {} else return NO;
    if (UIDevice.currentDevice.userInterfaceIdiom != UIUserInterfaceIdiomPhone) return NO;
    static BOOL (*available)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dlopen("/System/Library/PrivateFrameworks/SpringBoardServices.framework/SpringBoardServices", RTLD_LAZY);
        available = (BOOL (*)(void))dlsym(RTLD_DEFAULT, "SBSIsSystemApertureAvailable");
    });
    if (available) return available();
    CGFloat top = 0;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        for (UIWindow *window in windowScene.windows) top = MAX(top, window.safeAreaInsets.top);
        top = MAX(top, CGRectGetHeight(windowScene.statusBarManager.statusBarFrame));
    }
    return top == 0 || top > 51;
}

static NSString *const kNLNoIslandNote = @"Lyrics in the island needs an iPhone with the Dynamic Island, on iOS 16 or later, so it does not show on this one. The lyrics on the lock screen, in Control Center and in CarPlay work as usual.";

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
    [group setProperty:had.length ? [NSString stringWithFormat:@"%@\n\n%@", note, had] : note forKey:@"footerText"];
}

@implementation NLIslandListController {
    NSArray<PSSpecifier *> *_allSpecifiers;
}

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSArray<PSSpecifier *> *all = nil;
        _specifiers = NLPrepareSpecifiers(self, [self loadSpecifiersFromPlistName:@"Island" target:self], &all);
        _allSpecifiers = all;
        NLNoteNoIsland(all, @"islandLyrics");
    }
    return _specifiers;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    NLUpdateShownSpecifiers(self, _allSpecifiers, specifier);
    [[NSNotificationCenter defaultCenter] postNotificationName:NLIslandPreviewChangedNotification object:self];
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
