//
//  NowLyricsIsland.x
//  SpringBoard half of the chorus cue: bounces the Dynamic Island when the
//  player half (NLEngine.m) posts app.nowlyrics/Chorus.
//
//  The bounce is SpringBoard's own, the one the island gives when an app is
//  flung up into it: -[SBSystemApertureViewController
//  animateTransitionAcceptanceBounceWithVelocityVector:triggeredBlock:].
//  On 16.5.1 the vector's dx picks the style (beyond
//  -acceptanceSideBounceXVelocityThreshold either way: a side bounce, else up),
//  and -_triggerBounceAcceptResponse:triggeredBlock: already does nothing when
//  the island is empty or a bounce is still running, calling the block (nil is
//  fine) instead. That method also takes a backlight assertion, so it is only
//  ever called with the screen on and the device unlocked: a phone in a pocket
//  must not light up at every chorus.
//
//  Kept apart from NowLyrics.dylib so that the only code running in SpringBoard
//  is this file.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

@interface SBSystemApertureViewController : UIViewController
- (void)animateTransitionAcceptanceBounceWithVelocityVector:(CGVector)velocity triggeredBlock:(id)block;
@end

@interface SBBacklightController : NSObject
+ (instancetype)sharedInstanceIfExists;
- (BOOL)screenIsOn;
@end

@interface SBLockScreenManager : NSObject
+ (instancetype)sharedInstanceIfExists;
- (BOOL)isUILocked;
@end

typedef NS_ENUM(NSInteger, NLBounceStyle) {
    NLBounceStyleUp = 0,
    NLBounceStyleSide,   // alternates left and right
};

static NSString *const kNLPrefsDomain = @"app.nowlyrics";
static NSString *const kNLReloadNotification = @"app.nowlyrics/ReloadPrefs";
static NSString *const kNLChorusNotification = @"app.nowlyrics/Chorus";
static const CGFloat kNLSideVelocity = 10000;   // far past any side threshold

static BOOL gBounce = NO;   // off until the user turns it on
static NLBounceStyle gStyle = NLBounceStyleUp;
static BOOL gNextLeft = YES;
static __weak SBSystemApertureViewController *gApertureVC = nil;

// Same file NLSettings.m reads, at the paths SpringBoard can see.
static void NLIslandLoadPrefs(void) {
    NSDictionary *prefs = nil;
    for (NSString *root in @[@"/var/jb/var/mobile", @"/var/mobile"]) {
        prefs = [NSDictionary dictionaryWithContentsOfFile:
                 [NSString stringWithFormat:@"%@/Library/Preferences/%@.plist", root, kNLPrefsDomain]];
        if (prefs.count) break;
    }
    id enabled = prefs[@"enabled"], bounce = prefs[@"chorusBounce"], style = prefs[@"chorusBounceStyle"];
    BOOL on = [enabled respondsToSelector:@selector(boolValue)] ? [enabled boolValue] : YES;
    gBounce = on && [bounce respondsToSelector:@selector(boolValue)] && [bounce boolValue];
    gStyle = [style isEqual:@"side"] ? NLBounceStyleSide : NLBounceStyleUp;
}

static void NLIslandBounce(void) {
    SBSystemApertureViewController *vc = gApertureVC;
    if (!gBounce || !vc) return;
    if (![[objc_getClass("SBBacklightController") sharedInstanceIfExists] screenIsOn]) return;
    if ([[objc_getClass("SBLockScreenManager") sharedInstanceIfExists] isUILocked]) return;
    if (![vc respondsToSelector:@selector(animateTransitionAcceptanceBounceWithVelocityVector:triggeredBlock:)]) return;

    CGVector velocity = CGVectorMake(0, 0);
    if (gStyle == NLBounceStyleSide) {
        velocity.dx = gNextLeft ? -kNLSideVelocity : kNLSideVelocity;
        gNextLeft = !gNextLeft;
    }
    [vc animateTransitionAcceptanceBounceWithVelocityVector:velocity triggeredBlock:nil];
}

%hook SBSystemApertureViewController

- (void)viewDidLoad {
    %orig;
    gApertureVC = self;
}

%end

static void NLIslandPrefsChanged(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NLIslandLoadPrefs();
}

static void NLIslandChorus(CFNotificationCenterRef center, void *observer,
                           CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ NLIslandBounce(); });
}

%ctor {
    @autoreleasepool {
        if (!objc_getClass("SBSystemApertureViewController")) return;   // no Dynamic Island support in this iOS
        NLIslandLoadPrefs();
        CFNotificationCenterRef darwin = CFNotificationCenterGetDarwinNotifyCenter();
        CFNotificationCenterAddObserver(darwin, NULL, NLIslandPrefsChanged, (__bridge CFStringRef)kNLReloadNotification,
                                        NULL, CFNotificationSuspensionBehaviorCoalesce);
        CFNotificationCenterAddObserver(darwin, NULL, NLIslandChorus, (__bridge CFStringRef)kNLChorusNotification,
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        %init;
    }
}
