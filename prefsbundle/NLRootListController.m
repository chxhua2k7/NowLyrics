//
//  NLRootListController.m
//  The settings page's controller. libprefs' PLLocalizedListController does the
//  work: it loads the items from the plist next to the PreferenceLoader entry
//  (prefs/NowLyrics.plist) and localizes them. This subclass adds the two
//  things a plist cannot express on its own:
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
//  - NLIslandListController, the "Lyrics in the island" page, loaded from
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

#pragma mark - Controller

@implementation NLRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:[self nlLocalized:@"Apply"]
                                                                              style:UIBarButtonItemStyleDone
                                                                             target:self
                                                                             action:@selector(nlApply:)];
}

- (void)nlApply:(id)sender {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[self nlLocalized:@"Apply"]
                                                                   message:[self nlLocalized:@"Restart SpringBoard to apply?"]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[self nlLocalized:@"Cancel"] style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:[self nlLocalized:@"Respring"] style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *action) { [self nlRespring]; }]];
    [self presentViewController:alert animated:YES completion:nil];
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
    NSMutableArray *specifiers = [super specifiers];
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
    return specifiers;
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

    UIAlertController *alert = [UIAlertController alertControllerWithTitle:[self nlLocalized:@"Lyrics cache cleared"]
                                                                   message:[self nlLocalized:@"Apps that are not running clear theirs when next opened."]
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:[self nlLocalized:@"OK"] style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// The About group's Version row (`get = nlVersion:` in the plist).
- (NSString *)nlVersion:(PSSpecifier *)specifier {
    return @NL_VERSION;
}

@end

#pragma mark - Lyrics in the island

@implementation NLIslandListController

- (NSMutableArray *)specifiers {
    if (!_specifiers) {
        NSMutableArray *specifiers = [[self loadSpecifiersFromPlistName:@"Island" target:self] mutableCopy];
        for (PSSpecifier *specifier in specifiers) NLApplyIcon(specifier);
        _specifiers = specifiers;
    }
    return _specifiers;
}

@end
