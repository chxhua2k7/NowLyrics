//
//  NLCrescendo.m
//  Crescendo (com.yves.crescendo, GPL-3.0) puts the volume slider back in the
//  lock screen's player and in the open island. It is injected into
//  SpringBoard and MediaRemoteUI only, so the copies on these pages (the
//  player at the top, the island preview) would lack it; with Crescendo
//  installed and its switches on, they get it the way Crescendo gives it:
//
//  - The lock screen's player has the volume row already, dormant. Its
//    -[MRUNowPlayingView setShowVolumeControlsView:] is forced on for the
//    player on these pages, and -updateVisibility (which can hide it by a
//    direct ivar write) is followed by the setter again.
//  - The island's open player has none: a MRUNowPlayingVolumeControlsView with
//    a MRUVolumeController on the system's volume, styled by the island's
//    view, under the transport controls; the island opens that much taller.
//
//  Crescendo's switches are read as it reads them: its live notify-state token
//  ("com.yves.crescendo.state") when Settings has published one, else its
//  preferences.
//
//  iOS 17 and later have this themselves (Accessibility > Audio & Visual >
//  Always Show Volume Control, -[MRUserSettings alwaysShowVolumeControls]),
//  and the island has none either way (26.1: only MRULockscreenViewController
//  and MRUNowPlayingViewController read it; 26.6.2's open island has no row
//  with it on). The lock screen's controller is what shows the row, so the
//  player copied onto these pages lacks it: the row is forced there by that
//  setting the same way as by Crescendo's.
//

#import "NLLyricsPages.h"
#import "../NLIslandStrip.h"
#import <notify.h>
#import <objc/runtime.h>

@interface NSObject (NLUserSettings)
+ (id)currentSettings;                  // MRUserSettings
- (BOOL)alwaysShowVolumeControls;       // iOS 17 and later
@end

@interface UIView (NLCrescendo)
- (BOOL)showVolumeControlsView;
- (void)setShowVolumeControlsView:(BOOL)show;
- (UIView *)volumeControlsView;
- (void)updateVisibility;
- (void)updateVolumeAnimated:(BOOL)animated;
- (void)setVolumeController:(id)controller;
- (id)stylingProvider;
- (void)setStylingProvider:(id)provider;
- (void)updateVisualStyling;
@end

@interface NSObject (NLCrescendo)
- (void)setDataSource:(id)dataSource;
- (void)updateVolumeValue;
- (void)updateVolumeControls;
- (void)updatePreferredContentSize;
@end

#define kNLCrescendoDylib NLJBPath(@"/Library/MobileSubstrate/DynamicLibraries/Crescendo.dylib")

BOOL NLTweakStatePref(const char *state, int *token, CFStringRef domain, NSString *key, uint64_t bit, BOOL fallback) {
    if (*token == -1 && notify_register_check(state, token) != NOTIFY_STATUS_OK) *token = -2;
    uint64_t value = 0;
    if (*token >= 0 && notify_get_state(*token, &value) == NOTIFY_STATUS_OK &&
        (value & (1ULL << 63)) && (value & (bit << 32))) {
        return (value & bit) != 0;
    }
    return NLLooseBool(CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, domain)), fallback);
}

static BOOL NLCrescendoPref(NSString *key, uint64_t bit, BOOL fallback) {
    static int token = -1;
    return NLTweakStatePref("com.yves.crescendo.state", &token, CFSTR("com.yves.crescendo"), key, bit, fallback);
}

BOOL NLCrescendoInstalled(void) { return NL_ONCE([[NSFileManager defaultManager] fileExistsAtPath:kNLCrescendoDylib]); }

// Advanced › Supported Tweaks › Crescendo (on unless switched off).
static BOOL NLCrescendoWanted(void) {
    return NLReadPrefBool(nil, @"tweakCrescendo", YES);
}

BOOL NLCrescendoShows(NLCrescendoPlace place) {
    if (!NLCrescendoUsed()) return NO;   // the system's own setting, see the top
    if (!NLCrescendoInstalled() || !NLCrescendoWanted() || !NLCrescendoPref(@"Enabled", 1ULL << 0, YES)) return NO;
    return place == NLCrescendoLockScreen ? NLCrescendoPref(@"showLockScreen", 1ULL << 2, YES)
                                          : NLCrescendoPref(@"showDynamicIsland", 1ULL << 3, YES);
}

#pragma mark - The lock screen's player

static char kNLForceVolumeKey;
static void (*gSetShowVolume)(UIView *, SEL, BOOL);
static void (*gUpdateVisibility)(UIView *, SEL);

static BOOL NLForced(UIView *view) {
    return [objc_getAssociatedObject(view, &kNLForceVolumeKey) boolValue];
}

static void NLSetShowVolume(UIView *self, SEL _cmd, BOOL show) {
    if (NLForced(self)) show = YES;
    gSetShowVolume(self, _cmd, show);
}

static void NLUpdateVisibility(UIView *self, SEL _cmd) {
    gUpdateVisibility(self, _cmd);
    if (NLForced(self) && !self.showVolumeControlsView) self.showVolumeControlsView = YES;
}

static void NLHookPlayerView(Class cls) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method set = class_getInstanceMethod(cls, @selector(setShowVolumeControlsView:));
        Method update = class_getInstanceMethod(cls, @selector(updateVisibility));
        if (!set || !update) return;
        gSetShowVolume = (void *)method_setImplementation(set, (IMP)NLSetShowVolume);
        gUpdateVisibility = (void *)method_setImplementation(update, (IMP)NLUpdateVisibility);
    });
}

static UIView *NLFindView(UIView *root, Class cls) {
    if ([root isKindOfClass:cls]) return root;
    for (UIView *sub in root.subviews) {
        UIView *found = NLFindView(sub, cls);
        if (found) return found;
    }
    return nil;
}

// The platter's MRUNowPlayingView, nil before its view loads.
static UIView *NLPlatterPlayer(UIViewController *platter) {
    Class playerClass = objc_getClass("MRUNowPlayingView");
    return playerClass && platter.isViewLoaded ? NLFindView(platter.view, playerClass) : nil;
}

// iOS 17 and later: Always Show Volume Control, as the lock screen reads it.
static BOOL NLSystemShowsVolume(void) {
    Class settingsClass = objc_getClass("MRUserSettings");
    id settings = [settingsClass respondsToSelector:@selector(currentSettings)] ? [settingsClass currentSettings] : nil;
    return [settings respondsToSelector:@selector(alwaysShowVolumeControls)] && [settings alwaysShowVolumeControls];
}

static BOOL gForcedOnce;   // a player was forced here once: from then on there may be something to undo

BOOL NLCrescendoSyncPlayer(UIViewController *platter) {
    if (!platter.isViewLoaded) return NO;
    BOOL want = NO;
    if (@available(iOS 17.0, *)) want = NLSystemShowsVolume();
    else want = NLCrescendoShows(NLCrescendoLockScreen);
    if (!want && !gForcedOnce) return NO;   // nothing forced yet: the player's own say, no walk
    UIView *player = NLPlatterPlayer(platter);
    if (!player || ![player respondsToSelector:@selector(setShowVolumeControlsView:)]) return NO;
    NLHookPlayerView(objc_getClass("MRUNowPlayingView"));
    if (!want && !NLForced(player)) return NO;   // not ours: the player's own say
    if (want && NLForced(player) && player.showVolumeControlsView) return NO;

    objc_setAssociatedObject(player, &kNLForceVolumeKey, @(want), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (want) gForcedOnce = YES;
    player.showVolumeControlsView = want;
    UIViewController *owner = NLViewControllerOf(player);
    if (want) {
        // Apple's wiring pass, then the row seeded so it shows the volume at once.
        if ([owner respondsToSelector:@selector(updateVolumeControls)]) [owner updateVolumeControls];
        UIView *volume = [player respondsToSelector:@selector(volumeControlsView)] ? player.volumeControlsView : nil;
        if ([volume respondsToSelector:@selector(updateVisibility)]) [volume updateVisibility];
        if ([volume respondsToSelector:@selector(updateVolumeAnimated:)]) [volume updateVolumeAnimated:NO];
    }
    // The player's size with or without the row, up to the platter.
    [player invalidateIntrinsicContentSize];
    for (UIView *v = player; v; v = v.superview) [v setNeedsLayout];
    [player layoutIfNeeded];
    CGFloat width = player.bounds.size.width;
    if (width > 0 && owner) {
        CGSize fit = [player sizeThatFits:CGSizeMake(width, CGFLOAT_MAX)];
        if (fit.height > 0) owner.preferredContentSize = fit;
    }
    for (UIViewController *vc = owner; vc; vc = vc.parentViewController) {
        if ([vc respondsToSelector:@selector(updatePreferredContentSize)]) [vc updatePreferredContentSize];
        if (vc == platter) break;
    }
    return YES;
}

CGFloat NLPlayerFittingHeight(UIViewController *platter, CGFloat width) {
    UIView *player = NLPlatterPlayer(platter);
    if (!player) return 0;
    CGFloat around = MAX(platter.view.bounds.size.height - player.bounds.size.height, 0);
    CGFloat inner = player.bounds.size.width > 0 ? player.bounds.size.width : width;
    return [player sizeThatFits:CGSizeMake(inner, CGFLOAT_MAX)].height + around;
}

#pragma mark - The island

UIView *NLCrescendoMakeVolumeRow(UIView *host) {
    Class rowClass = objc_getClass("MRUNowPlayingVolumeControlsView");
    Class controllerClass = objc_getClass("MRUVolumeController");
    Class sourceClass = objc_getClass("MPVolumeControllerSystemDataSource");
    if (!rowClass || !controllerClass || !sourceClass || !host) return nil;
    UIView *row = [[rowClass alloc] initWithFrame:CGRectZero];
    NSObject *controller = [controllerClass new];
    if (![controller respondsToSelector:@selector(setDataSource:)] || ![row respondsToSelector:@selector(setVolumeController:)]) return nil;
    controller.dataSource = [sourceClass new];
    row.volumeController = controller;   // makes the row the controller's delegate
    // The island's styling: its monochrome look rather than a blue slider.
    if ([host respondsToSelector:@selector(stylingProvider)] && host.stylingProvider &&
        [row respondsToSelector:@selector(setStylingProvider:)]) {
        row.stylingProvider = host.stylingProvider;
        if ([row respondsToSelector:@selector(updateVisualStyling)]) [row updateVisualStyling];
    }
    if ([controller respondsToSelector:@selector(updateVolumeValue)]) [controller updateVolumeValue];
    if ([row respondsToSelector:@selector(updateVolumeAnimated:)]) [row updateVolumeAnimated:NO];
    return row;
}
