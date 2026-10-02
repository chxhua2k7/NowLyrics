//
//  NowLyricsIsland.x
//  PROTOTYPE: the current lyric line in a strip under the compact Dynamic
//  Island. SpringBoard only.
//
//  - Height: -[SBSystemApertureSceneElement preferredEdgeOutsetsForLayoutMode:
//    suggestedOutsets:maximumOutsets:] is asked for the now-playing element's
//    frame; in compact layout (SpringBoard's mode 2; MediaRemoteUI numbers it 3)
//    its bottom outset is pushed down. Outsets are negative outwards.
//  - Label: hung in the element's container view, which SpringBoard hands to
//    -_layoutSceneViewInContainerView: on every layout. Inside MediaRemoteUI only
//    the leading and trailing views reach the screen in compact layout, and
//    those get transformed by other tweaks (artwork spinners), so the label
//    lives here instead.
//  - Text: the now-playing title, which NowLyrics already sets to the current
//    line, from SBMediaController.
//
//  Control plist, re-read every 2 s:
//    /var/jb/var/mobile/Library/Preferences/app.nowlyrics.probe.plist
//      bottom  extra height in pt, as a negative outset (e.g. -12); 0 = off
//      label   0 hides the label (default 1)
//      red     1 gives the label a red background
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <dlfcn.h>

@interface SBSystemApertureSceneElement : NSObject
- (NSString *)clientIdentifier;
- (NSString *)elementIdentifier;
- (NSInteger)layoutMode;
@end

@interface SBSystemApertureViewController : UIViewController
- (void)preferredEdgeOutsetsDidInvalidateForLayoutSpecifier:(id)specifier;
@end

@interface SBMediaController : NSObject
+ (instancetype)sharedInstanceIfExists;
- (NSDictionary *)_nowPlayingInfo;
@end

static NSString *const kProbePath = @"/var/jb/var/mobile/Library/Preferences/app.nowlyrics.probe.plist";
static NSDictionary *gProbe = nil;
static dispatch_source_t gTimer = nil;
static NSInteger gLastBottom = 0;

static __weak SBSystemApertureViewController *gApertureVC = nil;
static __weak SBSystemApertureSceneElement *gElement = nil;
static __weak UIView *gContainer = nil;
static UILabel *gLabel = nil;

static NSInteger ProbeInt(NSString *key, NSInteger fallback) {
    id v = gProbe[key];
    return [v respondsToSelector:@selector(integerValue)] ? [v integerValue] : fallback;
}

static BOOL IsNowPlaying(id element) {
    NSString *client = [element respondsToSelector:@selector(clientIdentifier)] ? [element clientIdentifier] : nil;
    return [client isEqualToString:@"com.apple.MediaRemoteUI"];
}

// SBMediaController keeps no info dictionary on 16.5.1, so ask MediaRemote and
// keep the answer; it arrives asynchronously on the main queue.
static NSString *gTitle = nil;
static void UpdateLabelText(void);

static NSString *CurrentTitle(void) {
    return gTitle;
}

static void RefreshTitle(void) {
    static void (*getInfo)(dispatch_queue_t, void (^)(CFDictionaryRef)) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (mr) getInfo = (void (*)(dispatch_queue_t, void (^)(CFDictionaryRef)))dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    });
    if (!getInfo) return;
    getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        id title = info ? ((__bridge NSDictionary *)info)[@"kMRMediaRemoteNowPlayingInfoTitle"] : nil;
        NSString *now = [title isKindOfClass:NSString.class] ? title : nil;
        if ((now || gTitle) && ![now isEqual:gTitle]) {
            gTitle = now;
            UpdateLabelText();
        }
    });
}

// The black pill on screen. The view handed to -_layoutSceneViewInContainerView:
// only carries MediaRemoteUI's scene, which is not what gets drawn.
static UIView *PillFor(UIView *view) {
    Class pill = objc_getClass("SBSystemApertureContainerView");
    for (UIView *v = view; v; v = v.superview) {
        if (pill && [v isKindOfClass:pill]) return v;
    }
    return nil;
}

static void LayoutLabel(void) {
    UIView *container = PillFor(gContainer);
    SBSystemApertureSceneElement *element = gElement;
    CGFloat extra = -(CGFloat)ProbeInt(@"bottom", 0);
    BOOL compact = [element respondsToSelector:@selector(layoutMode)] && element.layoutMode == 2;
    BOOL show = container && extra > 0 && compact && ProbeInt(@"label", 1) != 0;
    static NSString *lastState = nil;
    NSString *state = [NSString stringWithFormat:@"container=%@ %@ clips=%d mode=%ld show=%d title=%@",
                       NSStringFromClass(container.class), container ? NSStringFromCGRect(container.bounds) : @"-",
                       container.clipsToBounds, [element respondsToSelector:@selector(layoutMode)] ? (long)element.layoutMode : -1L,
                       show, CurrentTitle()];
    if (![state isEqualToString:lastState]) {
        lastState = state;
        NSMutableArray *chain = [NSMutableArray array];
        for (UIView *v = gContainer; v && chain.count < 8; v = v.superview) {
            [chain addObject:[NSString stringWithFormat:@"%@%@", NSStringFromClass(v.class), NSStringFromCGRect(v.frame)]];
        }
        NSLog(@"[NowLyricsIsland] layout %@ chain=%@", state, [chain componentsJoinedByString:@" < "]);
    }
    if (!show) {
        gLabel.hidden = YES;
        return;
    }
    if (!gLabel) {
        gLabel = [UILabel new];
        gLabel.font = [UIFont systemFontOfSize:11 weight:UIFontWeightSemibold];
        gLabel.textColor = [UIColor colorWithWhite:1 alpha:0.92];
        gLabel.textAlignment = NSTextAlignmentCenter;
        gLabel.adjustsFontSizeToFitWidth = YES;
        gLabel.minimumScaleFactor = 0.75;
        gLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        gLabel.userInteractionEnabled = NO;
    }
    if (gLabel.superview != container) [container addSubview:gLabel];
    else [container bringSubviewToFront:gLabel];
    CGRect b = container.bounds;
    gLabel.frame = CGRectMake(14, CGRectGetHeight(b) - extra - 3, MAX(CGRectGetWidth(b) - 28, 0), extra);
    gLabel.backgroundColor = ProbeInt(@"red", 0) ? [UIColor colorWithRed:1 green:0 blue:0 alpha:0.6] : nil;
    gLabel.hidden = NO;
}

static void UpdateLabelText(void) {
    LayoutLabel();
    if (!gLabel) return;
    NSString *text = CurrentTitle() ?: @"";
    if ([text isEqualToString:gLabel.text ?: @""]) return;
    CATransition *fade = [CATransition animation];
    fade.type = kCATransitionFade;
    fade.duration = 0.25;
    [gLabel.layer addAnimation:fade forKey:@"text"];
    gLabel.text = text;
}

%hook SBSystemApertureViewController
- (void)viewDidLoad {
    %orig;
    gApertureVC = self;
}
%end

%hook SBSystemApertureSceneElement

- (NSDirectionalEdgeInsets)preferredEdgeOutsetsForLayoutMode:(NSInteger)mode suggestedOutsets:(NSDirectionalEdgeInsets)suggested maximumOutsets:(NSDirectionalEdgeInsets)maximum {
    NSDirectionalEdgeInsets outsets = %orig;
    if (!IsNowPlaying(self)) return outsets;
    gElement = self;
    NSInteger extra = ProbeInt(@"bottom", 0);
    if (mode == 2 && extra < 0) outsets.bottom = MAX(outsets.bottom + extra, maximum.bottom);
    return outsets;
}

- (void)_layoutSceneViewInContainerView:(UIView *)container {
    %orig;
    if (!IsNowPlaying(self)) return;
    gElement = self;
    gContainer = container;
    if (!gTitle) RefreshTitle();
    UpdateLabelText();
}

%end

%hook SBMediaController
- (void)_mediaRemoteNowPlayingInfoDidChange:(id)notification {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{ RefreshTitle(); });
}
%end

static void ProbeReload(void) {
    NSDictionary *now = [NSDictionary dictionaryWithContentsOfFile:kProbePath] ?: @{};
    if ([now isEqual:gProbe]) return;
    gProbe = now;
    NSLog(@"[NowLyricsIsland] control %@", now);
    NSInteger bottom = ProbeInt(@"bottom", 0);
    if (bottom != gLastBottom) {
        gLastBottom = bottom;
        SBSystemApertureViewController *vc = gApertureVC;
        SBSystemApertureSceneElement *element = gElement;
        if (element && [vc respondsToSelector:@selector(preferredEdgeOutsetsDidInvalidateForLayoutSpecifier:)]) {
            [vc preferredEdgeOutsetsDidInvalidateForLayoutSpecifier:element];
        }
        [vc.view setNeedsLayout];
    }
    UpdateLabelText();
}

%ctor {
    @autoreleasepool {
        if (!objc_getClass("SBSystemApertureSceneElement")) return;
        gProbe = [NSDictionary dictionaryWithContentsOfFile:kProbePath] ?: @{};
        gLastBottom = ProbeInt(@"bottom", 0);
        NSLog(@"[NowLyricsIsland] prototype loaded, control %@", gProbe);
        %init;
        gTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(gTimer, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), 2 * NSEC_PER_SEC, NSEC_PER_SEC / 2);
        dispatch_source_set_event_handler(gTimer, ^{ ProbeReload(); });
        dispatch_resume(gTimer);
    }
}
