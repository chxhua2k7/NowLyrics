//
//  NLPlayerTintSB.x
//  SpringBoard: the now-playing player's background in the lyrics' color
//  (NLPlayerTint.h) in Control Center and on the lock screen, while the
//  "playerTint" switch is on. Part of NowLyricsIsland.
//
//  Control Center: MRUControlCenterView keeps its material in -materialView;
//  the tint goes right above it, in its frame and corners. Lock screen: the
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


static NSHashTable<NLPlayerTintView *> *gTints;   // every tint shown, to update together
static BOOL gTintOn = YES;
static BOOL gAlbumLyrics = NO;
static char kNLTintKey;

static void NLReadTintPrefs(void) {
    NSDictionary *prefs = NLReadPrefsFile();
    gTintOn = NLPrefBool(prefs, NL_PLAYER_TINT_KEY, YES) && NLPrefBool(prefs, @"enabled", YES);
    gAlbumLyrics = [prefs[@"islandColor"] isEqual:@"artwork"];
}

// What is playing, into every tint (each skips work when its cover is the same).
static void NLRefreshTints(BOOL animated) {
    if (!gTintOn || gTints.count == 0) return;
    NLNowPlayingInfo(^(NSDictionary *info) {
        for (NLPlayerTintView *tint in gTints) [tint showNowPlaying:info albumLyrics:gAlbumLyrics animated:animated];
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
            [tint showNowPlaying:info albumLyrics:gAlbumLyrics animated:NO];
        });
    }
    if (tint.superview != material.superview) [material.superview insertSubview:tint aboveSubview:material];
    else if ([material.superview.subviews indexOfObject:tint] != [material.superview.subviews indexOfObject:material] + 1) {
        [material.superview insertSubview:tint aboveSubview:material];
    }
    tint.hidden = NO;
    tint.frame = material.frame;
    tint.transform = material.transform;
    tint.alpha = material.alpha;
    tint.layer.cornerRadius = radius > 0 ? radius : material.layer.cornerRadius;
}

#pragma mark - Lock screen

// The lock screen's player is a PLPlatterView in the notification list: its
// material (-backgroundView), and as its content a CSActivityItemContentView
// showing a scene of MediaRemoteUI. Live Activities come in the same platter,
// so it is told apart by whose scene it shows.
@interface PLPlatterView : UIView
@property (nonatomic, readonly) UIView *backgroundView;
@property (nonatomic, readonly) UIView *customContentView;
@end

static UIView *NLFindClass(UIView *view, NSString *name, int depth) {
    if ([NSStringFromClass(view.class) isEqualToString:name]) return view;
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
    if (content && content.subviews.count && !NLFindClass(content, @"CSActivityItemContentView", 1)) {
        objc_setAssociatedObject(platter, &kNLMediaPlatterKey, @NO, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return NO;   // a notification or something else now
    }
    for (UIResponder *r = platter.nextResponder; r; r = r.nextResponder) {
        if (![NSStringFromClass(r.class) isEqualToString:@"NCNotificationListSupplementaryHostingViewController"]) continue;
        id configuration = [r respondsToSelector:@selector(configuration)] ? [(id)r configuration] : nil;
        NSString *group = [configuration respondsToSelector:@selector(groupingIdentifier)] ? [configuration groupingIdentifier] : nil;
        if (![group isKindOfClass:NSString.class]) break;   // no answer: as it was
        BOOL media = [group isEqualToString:@"com.apple.MediaRemoteUI"];
        objc_setAssociatedObject(platter, &kNLMediaPlatterKey, @(media), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return media;
    }
    return memo.boolValue;
}

%hook PLPlatterView
- (void)layoutSubviews {
    %orig;
    UIView *material = [self respondsToSelector:@selector(backgroundView)] ? self.backgroundView : nil;
    BOOL media = material && NLIsMediaPlatter(self);
    NLPlayerTintView *tint = objc_getAssociatedObject(self, &kNLTintKey);
    if (media) NLPlaceTint(self, material, material.layer.cornerRadius);
    else tint.hidden = YES;   // a reused platter showing something else now
}
%end

#pragma mark - Control Center

%hook MRUControlCenterView
- (void)layoutSubviews {
    %orig;
    UIView *material = [self respondsToSelector:@selector(materialView)] ? self.materialView : nil;
    if (material) NLPlaceTint(self, material, [self respondsToSelector:@selector(cornerRadius)] ? self.cornerRadius : 0);
}
%end

%hook SBMediaController
- (void)_mediaRemoteNowPlayingInfoDidChange:(id)notification {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ NLRefreshTints(YES); });
}
%end

static void NLTintPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name,
                               const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NLReadTintPrefs();
        for (NLPlayerTintView *tint in gTints) {
            tint.hidden = !gTintOn;
            [tint.superview setNeedsLayout];
        }
        NLRefreshTints(YES);
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
    }
}
