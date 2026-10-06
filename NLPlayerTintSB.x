//
//  NLPlayerTintSB.x
//  SpringBoard: the now-playing player's background from its cover
//  (NLPlayerTint.h) in Control Center and on the lock screen, while the
//  "playerTint" switch is on. Part of NowLyricsIsland.
//
//  Control Center: MRUControlCenterView (16) or the media module's
//  MRUMediaControlsModuleBackgroundView (18) keeps its material in
//  -materialView; the tint goes right above it, in its frame and corners. Lock screen: the
//  player's PLPlatterView in the notification list, above its material and
//  under MediaRemoteUI's scene (a tweak coloring inside that scene, such as
//  MediaColor, covers it).
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import "NLShared.h"
#import "NLLocate.h"
#import "NLPlayerTint.h"

@interface MRUControlCenterView : UIView
@property (nonatomic, strong) UIView *materialView;
@property (nonatomic, assign) CGFloat cornerRadius;
@end

@interface MRUMediaControlsModuleBackgroundView : UIView
@property (nonatomic, strong) UIView *materialView;
@property (nonatomic, assign) CGFloat cornerRadius;
@end


static NSHashTable<NLPlayerTintView *> *gTints;   // every tint shown, to update together
static BOOL gTintOn = YES;
static CGFloat gTintClearness = 0.5;   // playerTintClear, a percentage in the prefs (the tint clamps it)
static char kNLTintKey;

static void NLReadTintPrefs(void) {
    NSDictionary *prefs = NLReadPrefsFile();
    gTintOn = NLPrefBool(prefs, NL_PLAYER_TINT_KEY, YES) && NLPrefBool(prefs, @"enabled", YES);
    gTintClearness = NLPrefNum(prefs, NL_PLAYER_TINT_CLEAR_KEY, 50) / 100;   // the tint clamps it to 0…1
}

// What is playing, into every tint (each skips work when its cover is the same).
static void NLRefreshTints(void) {
    if (!gTintOn || gTints.count == 0) return;
    NLNowPlayingInfo(^(NSDictionary *info) {
        for (NLPlayerTintView *tint in gTints) [tint showNowPlaying:info animated:YES];
    });
}

// The tint for `owner`, made once, laid over `material` (its sibling, just
// above it) with its frame and corners.
static void NLPlaceTint(UIView *owner, UIView *material, CGFloat radius) {
    NLPlayerTintView *tint = objc_getAssociatedObject(owner, &kNLTintKey);
    if (!gTintOn || !material.superview) {
        tint.hidden = YES;
        return;
    }
    if (!tint) {
        tint = [NLPlayerTintView new];
        tint.clearsWhenNothingPlays = YES;   // nothing playing: the system's own look
        objc_setAssociatedObject(owner, &kNLTintKey, tint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (!gTints) gTints = [NSHashTable weakObjectsHashTable];
        [gTints addObject:tint];
        NLNowPlayingInfo(^(NSDictionary *info) {
            [tint showNowPlaying:info animated:NO];
        });
    }
    NLPlaceTintAbove(tint, material);
    tint.hidden = NO;
    tint.material = material;
    tint.clearness = gTintClearness;
    tint.alpha = material.alpha;
    tint.layer.cornerRadius = radius > 0 ? radius : material.layer.cornerRadius;
}

// Control Center's player: the tint over its -materialView, in its -cornerRadius.
static void NLPlaceModuleTint(UIView *module) {
    UIView *material = [module respondsToSelector:@selector(materialView)] ? [(MRUControlCenterView *)module materialView] : nil;
    if (material) NLPlaceTint(module, material, [module respondsToSelector:@selector(cornerRadius)] ? [(MRUControlCenterView *)module cornerRadius] : 0);
}

#pragma mark - Lock screen

// The lock screen's player is a PLPlatterView in the notification list: its
// material (-backgroundView), and as its content a CSActivityItemContentView
// (CSActivityContentView on 26) showing a scene of MediaRemoteUI. Live Activities come in the same platter,
// so it is told apart by whose scene it shows.
@interface UIView (NLCorners)
- (CGFloat)_continuousCornerRadius;
@end

@interface PLPlatterView : UIView
@property (nonatomic, readonly) UIView *backgroundView;
@property (nonatomic, readonly) UIView *customContentView;
@end

// Whether `view` or one of its subviews is exactly of class `cls` (Nil: never).
static BOOL NLHoldsClass(UIView *view, Class cls) {
    if (!cls) return NO;
    if (view.class == cls) return YES;
    for (UIView *sub in view.subviews) {
        if (sub.class == cls) return YES;
    }
    return NO;
}

@interface NSObject (NLSupplementary)
- (id)configuration;
- (NSString *)groupingIdentifier;
@end

static char kNLMediaPlatterKey;

// Whether the platter is the player: the notification list hosts it through a
// supplementary view controller whose configuration is MediaRemoteUI's group
// (Live Activities have their own). Remembered per platter, and kept while the
// answer cannot be had: laid out in the middle of a change (a song change
// re-lays the list out), the platter can be off its controller for a moment,
// and hiding the tint then flashed the material through.
static BOOL NLIsMediaPlatter(PLPlatterView *platter) {
    // Looked up again while missing: a class this iOS has not loaded never matches.
    static Class mediaControls, itemContent, activityContent, hostClass;
    if (!mediaControls) mediaControls = objc_getClass("CSMediaControlsView");
    if (!itemContent) itemContent = objc_getClass("CSActivityItemContentView");
    if (!activityContent) activityContent = objc_getClass("CSActivityContentView");
    if (!hostClass) hostClass = objc_getClass("NCNotificationListSupplementaryHostingViewController");
    UIView *content = [platter respondsToSelector:@selector(customContentView)] ? platter.customContentView : nil;
    NSNumber *answer = nil;
    // iOS 15: the player is a platter of the lock screen's adjunct list
    // (CSAdjunctItemView) with CoverSheet's own player view as its content.
    if (content && NLHoldsClass(content, mediaControls)) {
        answer = @YES;
    } else if (content && content.subviews.count && !NLHoldsClass(content, itemContent) &&
               !NLHoldsClass(content, activityContent)) {
        answer = @NO;   // a notification or something else now
    } else {
        for (UIResponder *r = platter.nextResponder; r; r = r.nextResponder) {
            if (r.class != hostClass) continue;
            id configuration = [r respondsToSelector:@selector(configuration)] ? [(id)r configuration] : nil;
            NSString *group = [configuration respondsToSelector:@selector(groupingIdentifier)] ? [configuration groupingIdentifier] : nil;
            // A group that is not a string is no answer: as it was.
            if ([group isKindOfClass:NSString.class]) answer = @([group isEqualToString:NL_MEDIAREMOTEUI_ID]);
            break;
        }
    }
    NSNumber *memo = objc_getAssociatedObject(platter, &kNLMediaPlatterKey);
    if (!answer) return memo.boolValue;
    if (![answer isEqual:memo]) objc_setAssociatedObject(platter, &kNLMediaPlatterKey, answer, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return answer.boolValue;
}

#ifdef NLI_FILELOG
// One line for `view` (class, frame, and how it is hidden or faded), then its
// subviews', four levels deep.
static void NLTintDumpView(NSMutableString *out, UIView *view, int depth) {
    [out appendFormat:@"%*s%@ %@%@%@%@\n", depth * 2, "", NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
     view.hidden ? @" hidden" : @"", view.alpha < 1 ? [NSString stringWithFormat:@" a%.2f", view.alpha] : @"",
     view.layer.hidden ? @" layerHidden" : @""];
    if (depth < 4) for (UIView *sub in view.subviews) NLTintDumpView(out, sub, depth + 1);
}

// VM builds: the player's view order once, to see what the tint sits under.
static void NLTintDumpOrder(UIView *platter, UIView *material) {
    static NSMutableSet *seen;
    if (!seen) seen = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%p %.0f", platter, platter.bounds.size.width];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    NSMutableString *out = [NSMutableString stringWithFormat:@"%@ platter %@ material %@ in %@\n", [NSDate date],
                            NSStringFromCGRect(platter.frame), NSStringFromClass(material.class), NSStringFromClass(material.superview.class)];
    NLTintDumpView(out, platter, 0);
    NLIAppendLog(@"/var/mobile/Library/Logs/NowLyricsTint.log", out);
}
#endif

%hook PLPlatterView
- (void)layoutSubviews {
    %orig;
    UIView *material = [self respondsToSelector:@selector(backgroundView)] ? self.backgroundView : nil;
    if (!material || !NLIsMediaPlatter(self)) {
        ((NLPlayerTintView *)objc_getAssociatedObject(self, &kNLTintKey)).hidden = YES;   // a reused platter showing something else now
        return;
    }
    // iOS 15 rounds the platter itself (-_setContinuousCornerRadius:), not its material.
    CGFloat radius = material.layer.cornerRadius;
    if (radius <= 0 && [self respondsToSelector:@selector(_continuousCornerRadius)]) radius = [self _continuousCornerRadius];
    NLPlaceTint(self, material, radius);
#ifdef NLI_FILELOG
    NLTintDumpOrder(self, material);
#endif
}
%end

#pragma mark - Control Center

// Each Control Center class only where this iOS has it (Logos hands
// MSHookMessageEx a nil class otherwise).
%group NLTintCC16
%hook MRUControlCenterView
- (void)layoutSubviews {
    %orig;
    NLPlaceModuleTint(self);
}
%end
%end

// iOS 18: the redesigned Control Center's media module.
%group NLTintCC18
%hook MRUMediaControlsModuleBackgroundView
- (void)layoutSubviews {
    %orig;
    NLPlaceModuleTint(self);
#ifdef NLI_FILELOG
    NLTintDumpOrder(self, [self respondsToSelector:@selector(materialView)] ? self.materialView : nil);
#endif
}
%end
%end

// iOS 26 draws the media module's background from the cover itself
// (MRUCrossfadeImageView) and the lock screen's player in glass, which shows
// what is behind the platter over anything inside it: no tint there, none of
// these hooks (NLPlayerTintAvailable, %ctor).

%hook SBMediaController
- (void)_mediaRemoteNowPlayingInfoDidChange:(id)notification {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ NLRefreshTints(); });
}
%end

static void NLTintPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                               const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        BOOL wasOn = gTintOn;
        NLReadTintPrefs();
        // While on, every now-playing change reaches the tints already, and the
        // layout hooks keep them shown or hidden: only the switch itself needs them
        // shown again, placed and given what is playing now.
        BOOL switched = gTintOn != wasOn;
        for (NLPlayerTintView *tint in gTints) {
            if (switched) {
                tint.hidden = !gTintOn;
                [tint.superview setNeedsLayout];
            }
            tint.clearness = gTintClearness;
        }
        if (switched) NLRefreshTints();   // returns at once when it went off
    });
}

%ctor {
    @autoreleasepool {
        if (!NLPlayerTintAvailable()) return;
        NLReadTintPrefs();
        dlopen("/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls", RTLD_NOW);
        NLObserveDarwin(NL_RELOAD_NOTIFICATION, NLTintPrefsChanged, CFNotificationSuspensionBehaviorCoalesce);
        %init;
        if (objc_getClass("MRUControlCenterView")) %init(NLTintCC16);
        if (objc_getClass("MRUMediaControlsModuleBackgroundView")) %init(NLTintCC18);
    }
}
