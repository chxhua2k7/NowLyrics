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
#import <objc/message.h>
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
static CGFloat gTintClearness = 0.5;   // playerTintClear, a percentage in the prefs
static char kNLTintKey;

static void NLReadTintPrefs(void) {
    NSDictionary *prefs = NLReadPrefsFile();
    gTintOn = NLPrefBool(prefs, NL_PLAYER_TINT_KEY, YES) && NLPrefBool(prefs, @"enabled", YES);
    gTintClearness = MIN(MAX(NLPrefNum(prefs, @"playerTintClear", 50), 0), 100) / 100;
}

// What is playing, into every tint (each skips work when its cover is the same).
static void NLRefreshTints(BOOL animated) {
    if (!gTintOn || gTints.count == 0) return;
    NLNowPlayingInfo(^(NSDictionary *info) {
        for (NLPlayerTintView *tint in gTints) [tint showNowPlaying:info animated:animated];
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
    if (tint.superview != material.superview) [material.superview insertSubview:tint aboveSubview:material];
    else if ([material.superview.subviews indexOfObject:tint] != [material.superview.subviews indexOfObject:material] + 1) {
        [material.superview insertSubview:tint aboveSubview:material];
    }
    tint.hidden = NO;
    tint.material = material;
    tint.clearness = gTintClearness;
    tint.frame = material.frame;
    tint.transform = material.transform;
    tint.alpha = material.alpha;
    tint.layer.cornerRadius = radius > 0 ? radius : material.layer.cornerRadius;
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

static UIView *NLFindClass(UIView *view, const char *name, int depth) {
    if (strcmp(class_getName(view.class), name) == 0) return view;
    if (depth <= 0) return nil;
    for (UIView *sub in view.subviews) {
        UIView *found = NLFindClass(sub, name, depth - 1);
        if (found) return found;
    }
    return nil;
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
    NSNumber *memo = objc_getAssociatedObject(platter, &kNLMediaPlatterKey);
    UIView *content = [platter respondsToSelector:@selector(customContentView)] ? platter.customContentView : nil;
    // iOS 15: the player is a platter of the lock screen's adjunct list
    // (CSAdjunctItemView) with CoverSheet's own player view as its content.
    if (content && NLFindClass(content, "CSMediaControlsView", 1)) {
        objc_setAssociatedObject(platter, &kNLMediaPlatterKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return YES;
    }
    if (content && content.subviews.count && !NLFindClass(content, "CSActivityItemContentView", 1) &&
        !NLFindClass(content, "CSActivityContentView", 1)) {
        objc_setAssociatedObject(platter, &kNLMediaPlatterKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return NO;   // a notification or something else now
    }
    for (UIResponder *r = platter.nextResponder; r; r = r.nextResponder) {
        if (strcmp(class_getName(r.class), "NCNotificationListSupplementaryHostingViewController") != 0) continue;
        id configuration = [r respondsToSelector:@selector(configuration)] ? [(id)r configuration] : nil;
        NSString *group = [configuration respondsToSelector:@selector(groupingIdentifier)] ? [configuration groupingIdentifier] : nil;
        if (![group isKindOfClass:NSString.class]) break;   // no answer: as it was
        BOOL media = [group isEqualToString:@"com.apple.MediaRemoteUI"];
        objc_setAssociatedObject(platter, &kNLMediaPlatterKey, @(media), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return media;
    }
    return memo.boolValue;
}

#ifdef NLI_FILELOG
// VM builds: the player's view order once, to see what the tint sits under.
static void NLTintDumpOrder(UIView *platter, UIView *material) {
    static NSMutableSet *seen;
    if (!seen) seen = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%p %.0f", platter, platter.bounds.size.width];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    NSMutableString *out = [NSMutableString stringWithFormat:@"%@ platter %@ material %@ in %@\n", [NSDate date],
                            NSStringFromCGRect(platter.frame), NSStringFromClass(material.class), NSStringFromClass(material.superview.class)];
    __block void (^walk)(UIView *, int);
    __block __weak void (^weakWalk)(UIView *, int);
    weakWalk = walk = ^(UIView *view, int depth) {
        [out appendFormat:@"%*s%@ %@%@%@%@\n", depth * 2, "", NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
         view.hidden ? @" hidden" : @"", view.alpha < 1 ? [NSString stringWithFormat:@" a%.2f", view.alpha] : @"",
         view.layer.hidden ? @" layerHidden" : @""];
        if (depth < 4) for (UIView *sub in view.subviews) weakWalk(sub, depth + 1);
    };
    walk(platter, 0);
    NSString *path = @"/var/mobile/Library/Logs/NowLyricsTint.log";
    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!h) { [[NSFileManager defaultManager] createFileAtPath:path contents:nil attributes:nil]; h = [NSFileHandle fileHandleForWritingAtPath:path]; }
    [h seekToEndOfFile];
    [h writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
}
#endif

%hook PLPlatterView
- (void)layoutSubviews {
    %orig;
    UIView *material = [self respondsToSelector:@selector(backgroundView)] ? self.backgroundView : nil;
    BOOL media = material && NLIsMediaPlatter(self);
    NLPlayerTintView *tint = objc_getAssociatedObject(self, &kNLTintKey);
    // iOS 15 rounds the platter itself (-_setContinuousCornerRadius:), not its material.
    CGFloat radius = material.layer.cornerRadius;
    if (radius <= 0 && [self respondsToSelector:@selector(_continuousCornerRadius)]) {
        radius = ((CGFloat (*)(id, SEL))objc_msgSend)(self, @selector(_continuousCornerRadius));
    }
    if (media) NLPlaceTint(self, material, radius);
    else tint.hidden = YES;   // a reused platter showing something else now
#ifdef NLI_FILELOG
    if (media) NLTintDumpOrder(self, material);
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
    UIView *material = [self respondsToSelector:@selector(materialView)] ? self.materialView : nil;
    if (material) NLPlaceTint(self, material, [self respondsToSelector:@selector(cornerRadius)] ? self.cornerRadius : 0);
}
%end
%end

// iOS 18: the redesigned Control Center's media module.
%group NLTintCC18
%hook MRUMediaControlsModuleBackgroundView
- (void)layoutSubviews {
    %orig;
    UIView *material = [self respondsToSelector:@selector(materialView)] ? self.materialView : nil;
    if (material) NLPlaceTint(self, material, [self respondsToSelector:@selector(cornerRadius)] ? self.cornerRadius : 0);
#ifdef NLI_FILELOG
    NLTintDumpOrder(self, material);
#endif
}
%end
%end

// iOS 26 draws the media module's background from the cover itself
// (MRUCrossfadeImageView) and the lock screen's player in glass, which shows
// what is behind the platter over anything inside it: no tint there.

%hook SBMediaController
- (void)_mediaRemoteNowPlayingInfoDidChange:(id)notification {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ NLRefreshTints(YES); });
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
        if (switched) NLRefreshTints(YES);   // returns at once when it went off
    });
}

%ctor {
    @autoreleasepool {
        NLReadTintPrefs();
        dlopen("/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls", RTLD_NOW);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, NLTintPrefsChanged,
                                        (__bridge CFStringRef)NL_RELOAD_NOTIFICATION, NULL,
                                        CFNotificationSuspensionBehaviorCoalesce);
        %init;
        if (objc_getClass("MRUControlCenterView")) %init(NLTintCC16);
        if (objc_getClass("MRUMediaControlsModuleBackgroundView")) %init(NLTintCC18);
    }
}
