//
//  NowLyricsIsland.x
//  The current lyric line in a strip under the compact Dynamic Island.
//  SpringBoard only.
//
//  - Height: -[SBSystemApertureSceneElement preferredEdgeOutsetsForLayoutMode:
//    suggestedOutsets:maximumOutsets:] is asked for the now-playing element's
//    frame; in compact layout (SpringBoard's mode 2; MediaRemoteUI numbers it 3)
//    its bottom outset is pushed down until the island ends exactly on the
//    status bar's line (the top safe-area inset), never past it. Outsets are
//    negative outwards, and SpringBoard validates and animates the result like
//    any element's own.
//  - Width: the line is centred under the camera at the camera's width, so it
//    stays put while the artwork and waveform change size, and clear of
//    artwork-spinning tweaks.
//  - Strip: hung in the island's black pill (SBSystemApertureContainerView),
//    found from the view SpringBoard hands to -_layoutSceneViewInContainerView:.
//    That view only carries MediaRemoteUI's scene, and inside MediaRemoteUI only
//    the leading and trailing views reach the screen in compact layout (and get
//    transformed by artwork-spinning tweaks), so the strip lives here.
//  - Text: the now-playing title, which NowLyrics sets to the current line when
//    its main switch is on (otherwise it is the track title, so the strip can
//    show just that), from MRMediaRemoteGetNowPlayingInfo; SBMediaController
//    keeps no info dictionary on 16.5.1. The artwork in the same answer gives
//    the album color.
//
//  - Word by word: when the playing app's lyrics have word times (its
//    nowplaying.plist names the file, NLLocate.h), the line shown is found in
//    that file by the position MediaRemote reports, the same way the app picks
//    it, and the strip lights it up as it is sung.
//
//  Settings are the NowLyrics preference file, re-read on its reload
//  notification, so every change on the settings page applies at once.
//

#import <UIKit/UIKit.h>
#import <notify.h>
#import <objc/runtime.h>
#import "NLShared.h"
#import "NLIslandStrip.h"
#import "NLLocate.h"

// Built with -DNLI_FILELOG (for devices without a log reader, such as the
// vphone VMs), notable events go to /var/mobile/Library/Logs/NowLyricsIsland.log.
#ifdef NLI_FILELOG
static void NLIFileLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void NLIFileLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *line = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NLIAppendLog(@"/var/mobile/Library/Logs/NowLyricsIsland.log", [NSString stringWithFormat:@"%@ %@\n", [NSDate date], line]);
}
#define NLI_LOG(...) NLIFileLog(__VA_ARGS__)
// Logs a state description only when it differs from the last one logged here.
#define NLI_LOG_CHANGED(expr) do { \
    static NSString *last_ = nil; \
    NSString *state_ = (expr); \
    if (![state_ isEqualToString:last_]) { last_ = state_; NLI_LOG(@"%@", state_); } \
} while (0)
// Logs each distinct state description once (at most `limit` of them).
#define NLI_LOG_ONCE(limit, expr) do { \
    static NSMutableSet *seen_ = nil; \
    if (!seen_) seen_ = [NSMutableSet set]; \
    NSString *state_ = (expr); \
    if (seen_.count < (limit) && ![seen_ containsObject:state_]) { [seen_ addObject:state_]; NLI_LOG(@"%@", state_); } \
} while (0)
#define NLI_DEBUG_HOOKS 1
#else
#define NLI_LOG(...) do {} while (0)
#define NLI_LOG_CHANGED(expr) do {} while (0)
#define NLI_LOG_ONCE(limit, expr) do {} while (0)
#define NLI_DEBUG_HOOKS 0
#endif

// The pill. Its content view is what SpringBoard scales (a transform against a
// reference size), fades (contentAlpha) and clips while the island resizes,
// with the artwork and waveform in it; addContentSubview: puts a view there.
@interface SBSystemApertureContainerView : UIView
- (void)addContentSubview:(UIView *)view;
- (UIViewController *)elementViewController;   // the element the pill shows now
@end

@interface SBSystemApertureSceneElement : NSObject
- (NSString *)clientIdentifier;
- (NSInteger)layoutMode;
@end

@interface SBSystemApertureViewController : UIViewController
@property (readonly, nonatomic) CGRect minimumSensorRegionFrame;
- (void)preferredEdgeOutsetsDidInvalidateForLayoutSpecifier:(id)specifier;
- (void)_reevaluateElementSuppression;   // asks each element again whether the app or scene shown hides it
@end

static const NSInteger kNLCompactLayoutMode = 2;   // SpringBoard's numbering

#pragma mark - Settings

typedef struct {
    BOOL on;
    CGFloat fontSize;
    BOOL artworkColor;
    BOOL scrollUp;       // line change pushes up instead of fading
    CGFloat speed;       // marquee, pt/s
    BOOL wordByWord;     // light lines up as they are sung, when the lyrics have word times
    BOOL alwaysShow;     // the island stays up in the app that is playing, too
    BOOL debugNoGrow;    // NLI_FILELOG builds only: skip the outsets change
    BOOL debugNoStrip;   // NLI_FILELOG builds only: never attach the strip
} NLIslandSettings;

static NLIslandSettings gSettings;   // read in %ctor
static NSDictionary *gPrefs = nil;   // the file itself, for the lyrics offsets

// Ranges and defaults match bundle/Island.plist.
static CGFloat NLIslandNum(NSDictionary *prefs, NSString *key, CGFloat fallback, CGFloat lo, CGFloat hi) {
    CGFloat n = NLPrefNum(prefs, key, fallback);
    return isnan(n) ? fallback : MIN(MAX(n, lo), hi);
}

// The file NowLyrics reads in the apps (NLShared.h), as the caller read it.
static NLIslandSettings NLIslandReadSettings(NSDictionary *prefs) {
    NLIslandSettings s = {0};
    // Independent of the main switch: with lyrics off, the now-playing title is
    // the real track title, and the strip shows that instead of a line.
    s.on = NLPrefBool(prefs, @"islandLyrics", NO);
    s.fontSize = NLIslandNum(prefs, @"islandFontSize", kNLDefaultFontSize, 9, 15);
    s.artworkColor = [prefs[@"islandColor"] isEqual:@"artwork"];
    s.scrollUp = [prefs[@"islandTransition"] isEqual:@"up"];
    s.speed = NLIslandNum(prefs, @"islandMarqueeSpeed", kNLDefaultSpeed, 9, 81);   // shown as 0.3×–2.7×
    s.wordByWord = NLPrefBool(prefs, @"islandWordByWord", YES);
    s.alwaysShow = NLPrefBool(prefs, @"islandAlwaysShow", NO);
#ifdef NLI_FILELOG
    s.debugNoGrow = NLPrefBool(prefs, @"islandDebugNoGrow", NO);
    s.debugNoStrip = NLPrefBool(prefs, @"islandDebugNoStrip", NO);
#endif
    return s;
}

#pragma mark - State

static __weak SBSystemApertureViewController *gApertureVC = nil;
static __weak SBSystemApertureSceneElement *gElement = nil;
static __weak UIView *gSceneContainer = nil;   // as handed to -_layoutSceneViewInContainerView:
static __weak UIView *gAttachedPill = nil;     // the pill the strip is attached to
static void *gAttachedPillPtr = NULL;          // the same, for the per-frame layout check

// Geometry. gExtra is what the island is grown by: the distance from the
// compact island's bottom to the status bar's line. gSensorWidth is the
// camera's width; the line is centred under it at that width. Both come from
// the fixed sensor region (14 Pro values until measured). The artwork and
// waveform widths SpringBoard reports change across expand and collapse, and
// a line placed between them moved sideways with every change.
static const CGFloat kNLDefaultExtra = 11;     // 14 Pro: compact bottom 48 pt, status bar line 59 pt
static CGFloat gExtra = kNLDefaultExtra;
static CGFloat gSensorWidth = kNLDefaultSensorWidth;
static __weak UIWindow *gMeasuredWindow = nil;  // the window gExtra was measured in

static NSString *gTitle = nil;
static BOOL gExplicit = NO;   // the track is flagged explicit (and NowLyrics was not told to hide that)
static UIColor *gArtworkColor = nil;
static NSUInteger gArtworkPrint = 0;           // the artwork gArtworkColor is (being) taken from
static NSUInteger gArtworkMissing = 0;         // the wait for a missing cover that is on (0: none)

// Word by word: the shown line's pieces and the playback clock they run on
// (the app's lookup position, offsets included), as of gWordsAt.
static NLShownWords *gWords = nil;
static CFTimeInterval gWordsAt = 0;

static BOOL NLIsNowPlaying(id element) {
    NSString *client = [element respondsToSelector:@selector(clientIdentifier)] ? [element clientIdentifier] : nil;
    return [client isEqualToString:NL_MEDIAREMOTEUI_ID];
}

static Class NLRotatingContentClass(void) { return NL_ONCE(objc_getClass("_SBSystemApertureContainerViewRotatingContentView")); }   // iOS 17 and later; Nil on 16

// Where SpringBoard has _SBSystemApertureContainerViewRotatingContentView
// (iOS 17 and later; 16.5.1 has no such class): the element's own view, the one
// wrapper inside it (itself inside the view that scales). Those container
// content views must hold exactly one subview: -contentView asserts it
// (sbsa_onlyObjectOrNilAssert), so -addContentSubview: swaps the element out
// and a sibling there crashes SpringBoard. The wrapper takes extra subviews and
// still scales with the island. Without that class, -addContentSubview: adds
// to the content view instead of replacing.
static UIView *NLElementWrapperView(UIView *sceneContainer, UIView *pill) {
    Class rotating = NLRotatingContentClass();
    if (!rotating) return nil;
    for (UIView *v = sceneContainer.superview; v && v != pill; v = v.superview) {
        if ([v.superview isKindOfClass:rotating]) return v;
    }
    return nil;
}

// The black pill on screen.
static UIView *NLPillFor(UIView *view) {
    return NLAncestorOfClass(view, NL_ONCE(objc_getClass("SBSystemApertureContainerView")));   // no such class: nil
}


// Content-view-sized and clipped to the capsule, so nothing escapes the black.
// It lives in the pill's content view (iOS 16) or the element's own view inside
// it (iOS 17+, see NLElementWrapperView), which SpringBoard scales, fades and
// clips together with the artwork and waveform while the island resizes, so
// the line needs no resize handling of its own.
@interface NLIslandClipView : UIView
@end

@implementation NLIslandClipView
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.layer.cornerCurve = kCACornerCurveCircular;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = MIN(self.bounds.size.width, self.bounds.size.height) / 2;
}
@end

static NLIslandStripView *gStrip = nil;
static NLIslandClipView *gClip = nil;
// iOS 17 and later: the strip is in the element's wrapper view. The island
// changes its size there by laying the wrapper out at each step (16.5 scales
// a content view of fixed size instead), with no animation on the layers the
// stillness check looks at.
static BOOL gInWrapper = NO;

#pragma mark - Updating

// The height lives in the element's outsets, so SpringBoard has to ask again.
static void NLIslandInvalidateHeight(void) {
    SBSystemApertureViewController *vc = gApertureVC;
    SBSystemApertureSceneElement *element = gElement;
    if (element && [vc respondsToSelector:@selector(preferredEdgeOutsetsDidInvalidateForLayoutSpecifier:)]) {
        [vc preferredEdgeOutsetsDidInvalidateForLayoutSpecifier:element];
    }
    [vc.view setNeedsLayout];
}

// Where the island should end: the top safe-area inset, the line apps start
// their content under. SpringBoard's own windows may report none, so the
// pill's window, the key window and a 14 Pro default are tried in turn.
//
// The compact island ends where the camera's sensor region ends, a fixed
// rectangle; measuring the pill instead fed back into itself (the pill had not
// taken the last height yet) and the island kept resizing by half points.
//
// Measured once per window: the sensor region and the line only change with
// the screen. A measurement that had to fall back to the default is retried.
static void NLIslandMeasureExtra(UIView *pill) {
    if (pill.window == gMeasuredWindow) return;
    SBSystemApertureViewController *vc = gApertureVC;
    if (!pill.window || !vc.isViewLoaded || ![vc respondsToSelector:@selector(minimumSensorRegionFrame)]) return;
    CGRect sensor = vc.minimumSensorRegionFrame;
    if (CGRectIsEmpty(sensor)) return;
    gSensorWidth = CGRectGetWidth(sensor);
    CGFloat compactBottom = CGRectGetMaxY([vc.view convertRect:sensor toCoordinateSpace:vc.view.window.screen.coordinateSpace]);

    CGFloat line = pill.window.safeAreaInsets.top;
    if (line < 30) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        line = UIApplication.sharedApplication.keyWindow.safeAreaInsets.top;
#pragma clang diagnostic pop
    }
    if (line < 30) {
        line = compactBottom + kNLDefaultExtra;
    } else {
        gMeasuredWindow = pill.window;
        // An island given by other means (an iPad, an iPhone with a notch):
        // the status bar ends above the island's bottom (32 pt against 48 on
        // an iPad), so there is no line to grow to; it grows as a 14 Pro's.
        if (line - compactBottom < 1) line = compactBottom + kNLDefaultExtra;
    }
    CGFloat extra = MIN(MAX(round((line - compactBottom) * 2) / 2, 0), 30);
    if (fabs(extra - gExtra) < 0.5) return;
    NLI_LOG(@"island grows %.1f -> %.1f pt (line %.1f, compact bottom %.1f)", gExtra, extra, line, compactBottom);
    gExtra = extra;
    dispatch_async(dispatch_get_main_queue(), ^{ NLIslandInvalidateHeight(); });
}

#ifdef NLI_FILELOG
static void NLIDumpLayout(UIView *host, UIView *pill) {
    NSMutableArray *chain = [NSMutableArray array];
    for (UIView *v = host; v && chain.count < 6; v = v.superview) {
        [chain addObject:[NSString stringWithFormat:@"%@%@ a%.2f%@", NSStringFromClass(v.class),
                          NSStringFromCGRect(v.frame), v.alpha, v.hidden ? @" H" : @""]];
    }
    NSMutableArray *subList = [NSMutableArray array];
    for (UIView *sv in host.subviews) {
        [subList addObject:[NSString stringWithFormat:@"%@%@ a%.2f%@ layerHidden%d", NSStringFromClass(sv.class),
                            NSStringFromCGRect(sv.frame), sv.alpha, sv.hidden ? @" H" : @"", sv.layer.hidden]];
        for (UIView *inner in sv.subviews) {
            [subList addObject:[NSString stringWithFormat:@"  >%@%@ a%.2f%@", NSStringFromClass(inner.class),
                                NSStringFromCGRect(inner.frame), inner.alpha, inner.hidden ? @" H" : @""]];
        }
    }
    NLI_LOG_CHANGED(([NSString stringWithFormat:@"layout chain=%@ subviews=[%@] contentAlpha=%@",
                      [chain componentsJoinedByString:@" < "], [subList componentsJoinedByString:@" | "],
                      [pill respondsToSelector:@selector(contentAlpha)] ? [pill valueForKey:@"contentAlpha"] : @"?"]));
}
#endif

static void NLIslandRevealWhenStill(UIView *pill, int attempt);

// Frames, set only from the pill's layoutSubviews (hooked below) or right
// after attaching. That pass runs inside SpringBoard's resize animations, so
// the line moves in the same animation as the artwork and waveform even when
// resizes come quickly one after another; frames set from anywhere else jumped
// to the end of whatever animation was running.
static CGFloat gLaidOutFontSize = 0;   // font size of the last layout, to know when one is due

static void NLIslandLayout(UIView *pill) {
    UIView *host = gClip.superview;
    if (!host || pill != gAttachedPill) return;
#ifdef NLI_FILELOG
    NLIDumpLayout(host, pill);
#endif
    // The line's box sits on the island's bottom edge, under the camera. It is
    // exactly the font's line height, so the text's bottom is the island's and
    // a bigger font only grows upwards. Measured in the content view, which is
    // the pill's size or, while scaling, its reference size.
    CGRect b = host.bounds;
    // iOS 26 shows the island at its plain compact size first and widens it
    // for its artwork and waveform a moment later: a line already shown
    // there moved sideways with it. Out, and back once the island is still.
    static CGSize laidOutSize;
    if (gInWrapper && gClip.alpha > 0 && !CGSizeEqualToSize(laidOutSize, CGSizeZero) &&
        (fabs(b.size.width - laidOutSize.width) > 0.5 || fabs(b.size.height - laidOutSize.height) > 0.5)) {
        gClip.alpha = 0;
        dispatch_async(dispatch_get_main_queue(), ^{
            UIView *p = gAttachedPill;
            if (p && gClip.superview) NLIslandRevealWhenStill(p, 0);
        });
    }
    laidOutSize = b.size;
    CGFloat h = MIN(NLIslandLineHeight(gSettings.fontSize), CGRectGetHeight(b));
    CGFloat width = MAX(MIN(gSensorWidth, CGRectGetWidth(b)) - kNLContentGap * 2, 0);
    CGRect strip = NLIslandStripFrame(b.size, width, h);
    if (!CGRectEqualToRect(gClip.frame, b)) gClip.frame = b;
    if (!CGRectEqualToRect(gStrip.frame, strip)) gStrip.frame = strip;
    gLaidOutFontSize = gSettings.fontSize;
    NLIslandMeasureExtra(pill);
#ifdef NLI_FILELOG
    CGRect inPill = [host convertRect:host.bounds toView:pill];
    NLIFileLog(@"%.3f geo host %@ inPill %@ strip %@ sensor %.2f alpha %.2f pillAnim %lu hostAnim %lu", CACurrentMediaTime(),
               NSStringFromCGRect(b), NSStringFromCGRect(inPill), NSStringFromCGRect(strip), gSensorWidth, gClip.alpha,
               (unsigned long)pill.layer.animationKeys.count, (unsigned long)host.layer.animationKeys.count);
#endif
}

static BOOL NLLayerAnimating(CALayer *layer) {
    return layer.animationKeys.count > 0;
}

// Where the view is on screen right now, mid-animation included.
static CGRect NLPresentedFrame(UIView *view) {
    CALayer *layer = view.layer.presentationLayer ?: view.layer;
    CALayer *top = view.window.layer.presentationLayer ?: view.window.layer;
    return top ? [layer convertRect:layer.bounds toLayer:top] : CGRectZero;
}

static BOOL NLRectsClose(CGRect a, CGRect b) {
    return fabs(a.origin.x - b.origin.x) < 0.5 && fabs(a.origin.y - b.origin.y) < 0.5 &&
           fabs(a.size.width - b.size.width) < 0.5 && fabs(a.size.height - b.size.height) < 0.5;
}

// Fades the line in once the pill has finished moving. Attached while the
// island is still growing (playback just started, a collapse), its frames are
// the final ones inside a pill that is not there yet, which read as the line
// drifting into place. Polls the pill's layers rather than guessing a delay.
// One poll at a time: a hide calls it off (gRevealPending), and a poll that
// starts after that is a new one (gRevealPoll), so a look the old one had
// already scheduled stops instead of polling, and counting still looks,
// alongside it.
static BOOL gRevealPending = NO;
static NSUInteger gRevealPoll = 0;   // the poll that is on; each new one counts up
static void NLIslandRevealWhenStill(UIView *pill, int attempt) {
    if (gRevealPending && attempt == 0) return;
    if (attempt == 0) gRevealPoll++;
    gRevealPending = YES;
    NSUInteger poll = gRevealPoll;
    UIView *host = gClip.superview;
    BOOL moving = NLLayerAnimating(pill.layer) || NLLayerAnimating(host.layer) || NLLayerAnimating(pill.superview.layer);
    if (gInWrapper) {
        // No layer animation to go by there: still is where the island's
        // content is on screen not changing for a few looks in a row (it
        // springs past its size and back on iOS 26).
        static CGRect lastSeen;
        static int stillLooks;
        CGRect seen = NLPresentedFrame(host);
        if (attempt == 0 || !NLRectsClose(seen, lastSeen)) stillLooks = 0;
        else stillLooks++;
        lastSeen = seen;
        moving = moving || stillLooks < 4;
    }
    if (moving && attempt < 30) {
        __weak UIView *weakPill = pill;
        NLAfter(0.07, ^{
            // Hidden again meanwhile (expanded, app opened), or shown again
            // since, with a poll of its own.
            if (!gRevealPending || poll != gRevealPoll) return;
            UIView *p = weakPill;
            if (p && gClip.superview && p == gAttachedPill) NLIslandRevealWhenStill(p, attempt + 1);
            else gRevealPending = NO;
        });
        return;
    }
    gRevealPending = NO;
    [UIView performWithoutAnimation:^{ NLIslandLayout(pill); }];
    [UIView animateWithDuration:0.2 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ gClip.alpha = 1; } completion:nil];
}

// Whether the pill shows the now-playing element. Another element can take
// the pill over while the player stays compact (Face ID's check grows it into
// a square), and the line, which is the pill's content rather than the
// element's, stayed at its bottom.
static BOOL NLPillShowsNowPlaying(UIView *pill) {
    if (!pill || ![pill respondsToSelector:@selector(elementViewController)]) return YES;
    UIViewController *shown = [(SBSystemApertureContainerView *)pill elementViewController];
    UIView *scene = gSceneContainer;
    if (!shown || !scene) return YES;
    if (![scene isDescendantOfView:pill]) return NO;
    UIViewController *ours = NLViewControllerOf(scene);
    if (!ours) return YES;
    for (UIViewController *vc = ours; vc; vc = vc.parentViewController) {
        if (vc == shown) return YES;
    }
    return NO;
}

static BOOL gShowsNowPlaying = YES;   // as last seen by the pill's layout

static void NLIslandUpdateIn(UIView *pill) {
    SBSystemApertureSceneElement *element = gElement;
    BOOL compact = [element respondsToSelector:@selector(layoutMode)] && element.layoutMode == kNLCompactLayoutMode;
    gShowsNowPlaying = NLPillShowsNowPlaying(pill);
    BOOL show = gSettings.on && pill && compact && gShowsNowPlaying && gTitle.length > 0 && !gSettings.debugNoStrip;
    NLI_LOG_CHANGED(([NSString stringWithFormat:@"update on=%d pill=%@ mode=%ld title=%@ show=%d",
                      gSettings.on, pill ? NSStringFromClass(pill.class) : @"nil",
                      [element respondsToSelector:@selector(layoutMode)] ? (long)element.layoutMode : -1L, gTitle, show]));
    if (!show) {
        // Faded rather than hidden (expanding, the app taking over): a strip
        // vanishing in one frame reads as a flash.
        gRevealPending = NO;
        if (gClip.superview && gClip.alpha > 0) {
            [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                             animations:^{ gClip.alpha = 0; } completion:nil];
        }
        return;
    }
    if (!gClip) {
        gClip = [[NLIslandClipView alloc] initWithFrame:CGRectZero];
        gStrip = [[NLIslandStripView alloc] initWithFrame:CGRectZero];
        gStrip.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleTopMargin;   // stays on the bottom edge
        [gClip addSubview:gStrip];
    }
    // In the pill's content view, next to the artwork and waveform, so the line
    // gets exactly their scaling, fading and clipping during a resize instead
    // of chasing the pill's frame from outside.
    // The full walk, not just gAttachedPill: SpringBoard can replace the
    // element's view and leave the strip in one that is no longer in the pill.
    BOOL fresh = NLPillFor(gClip.superview) != pill;
    if (fresh) {
        UIView *wrapper = NLElementWrapperView(gSceneContainer, pill);
        // -addContentSubview: adds on 16.5 but replaces on 17 and later (it
        // would swap the player out of the island): only where no wrapper
        // can exist.
        BOOL canAdd = !NLRotatingContentClass() && [pill respondsToSelector:@selector(addContentSubview:)];
        if (!wrapper && !canAdd) return;   // neither layout known: stay off rather than guess
        gClip.alpha = 0;
        gAttachedPill = pill;
        gAttachedPillPtr = (__bridge void *)pill;
        gInWrapper = wrapper != nil;
        if (wrapper) [wrapper addSubview:gClip];
        else [(SBSystemApertureContainerView *)pill addContentSubview:gClip];
        [UIView performWithoutAnimation:^{ NLIslandLayout(pill); }];
    } else {
        UIView *host = gClip.superview;
        if (host.subviews.lastObject != gClip) [host bringSubviewToFront:gClip];
        // Frames are only ever set in the pill's own layout pass; only a new font
        // size changes them outside one.
        if (gSettings.fontSize != gLaidOutFontSize) [pill setNeedsLayout];
    }
    [gStrip applyFontSize:gSettings.fontSize color:NLIslandTextColor(gSettings.artworkColor, gArtworkColor) speed:gSettings.speed];
    [gStrip setText:gTitle explicit:gExplicit scrollUp:gSettings.scrollUp];
    [gStrip setWordTexts:gWords.texts starts:gWords.starts ends:gWords.ends
                position:NLClockAt(gWords.position, gWordsAt, gWords.rate) rate:gWords.rate];
    if (gClip.alpha < 1) NLIslandRevealWhenStill(pill, 0);
}

static void NLIslandUpdate(void) { NLIslandUpdateIn(NLPillFor(gSceneContainer)); }

#pragma mark - Word by word

// The pieces of the line on screen, when it has word times (NLLocate.m).
static void NLIslandUpdateWords(NSDictionary *info) {
    gWords = nil;
    if (!gSettings.wordByWord) return;
    NSString *bundleID = NLSpringBoardPlayingBundleID();
    gWords = NLWordsForShownLine(bundleID, gTitle, info, gPrefs);
#ifdef NLI_FILELOG
    NSDictionary *np = NLReadNowPlaying(bundleID);
    NLI_LOG(@"words app=%@ title=%@ np.words=%@ np.file=%@ elapsed=%@ got=%lu", bundleID, gTitle, np[NL_NP_WORDS],
            [np[NL_NP_PATH] lastPathComponent], info[NL_MR_ELAPSED], (unsigned long)gWords.texts.count);
#endif
    gWordsAt = CACurrentMediaTime();
}

static void NLIslandRefreshInfo(void) {
    if (!gSettings.on) return;
    // One request at a time (each answer carries the artwork across XPC); a
    // change that arrives meanwhile asks once more when the answer is in.
    static BOOL inFlight = NO, again = NO;
    if (inFlight) { again = YES; return; }
    inFlight = YES;
    NLNowPlayingInfo(^(NSDictionary *info) {
        gTitle = NLString(info, NL_MR_TITLE);
        // Cleared by the players already when "Hide explicit badge" is on.
        gExplicit = NLPrefBool(info, NL_MR_EXPLICIT, NO);
        NLIslandUpdateWords(info);

        NSData *artwork = gSettings.artworkColor ? NLInfoArtwork(info) : nil;   // empty data is no cover, as for the player tint
        NSUInteger print = artwork ? NLArtworkPrint(artwork) : 0;
        if (print) {
            gArtworkMissing = 0;   // a cover is here: a wait for one is called off
        } else if (gSettings.artworkColor && (gArtworkColor || gArtworkPrint) && !gArtworkMissing) {
            // No cover. Between songs that lasts a moment, and the album color
            // stays through it; still none after kNLMissingGrace (NLLocate.h,
            // as the player tint waits), the song has none: the island's white.
            static NSUInteger waits = 0;
            NSUInteger wait = gArtworkMissing = ++waits;
            NLAfter(kNLMissingGrace, ^{
                if (gArtworkMissing != wait) return;   // a cover came meanwhile
                gArtworkMissing = 0;
                gArtworkPrint = 0;
                gArtworkColor = nil;
                NLIslandUpdate();
            });
        }
        if (print && print != gArtworkPrint) {
            gArtworkPrint = print;   // claimed now, so the burst at a track change decodes it once
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
                UIColor *color = NLColorFromArtwork(artwork);
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (gArtworkPrint != print) return;   // the track changed meanwhile
                    gArtworkColor = color;
                    NLIslandUpdate();
                });
            });
        }
        NLIslandUpdate();
        inFlight = NO;
        if (again) {
            again = NO;
            NLIslandRefreshInfo();
        }
    });
}

#pragma mark - Hooks

%hook SBSystemApertureViewController
- (void)viewDidLoad {
    %orig;
    gApertureVC = self;
}
%end

%hook SBSystemApertureSceneElement

- (NSDirectionalEdgeInsets)preferredEdgeOutsetsForLayoutMode:(NSInteger)mode suggestedOutsets:(NSDirectionalEdgeInsets)suggested maximumOutsets:(NSDirectionalEdgeInsets)maximum {
    NSDirectionalEdgeInsets outsets = %orig;
    NLI_LOG_ONCE(NSUIntegerMax, ([NSString stringWithFormat:@"outsets element %@|%@|%ld", NSStringFromClass([self class]),
                                  [self respondsToSelector:@selector(clientIdentifier)] ? [self clientIdentifier] : @"?", (long)mode]));
    if (!NLIsNowPlaying(self)) return outsets;
    gElement = self;
    if (mode == kNLCompactLayoutMode && gSettings.on && !gSettings.debugNoGrow) {
        outsets.bottom = MAX(outsets.bottom - gExtra, maximum.bottom);
    }
    return outsets;
}

- (void)_layoutSceneViewInContainerView:(UIView *)container {
    %orig;
    if (!NLIsNowPlaying(self)) return;
    // iOS 18 also lays the scene out in containers outside the pill (mirrors,
    // snapshots); adopting those hid the line every other layout.
    UIView *pill = NLPillFor(container);
    if (!pill) return;
#ifdef NLI_FILELOG
    {
        NSMutableArray *chain = [NSMutableArray array];
        for (UIView *v = container; v && chain.count < 6; v = v.superview) {
            [chain addObject:[NSString stringWithFormat:@"%@%@[%lu]", NSStringFromClass(v.class), NSStringFromCGRect(v.frame), (unsigned long)v.subviews.count]];
        }
        NLI_LOG_CHANGED([@"scene container chain=" stringByAppendingString:[chain componentsJoinedByString:@" < "]]);
    }
#endif
    gElement = self;
    gSceneContainer = container;
    if (!gSettings.on && !gClip.superview) return;   // off and nothing up: nothing to show or fade
    if (!gTitle) NLIslandRefreshInfo();
    NLIslandUpdateIn(pill);
}

// Always show: SpringBoard puts an element away while the app it belongs to
// (the player's, for this one) or one of its scenes is on screen; the
// now-playing island stays instead.
- (BOOL)shouldSuppressElementWhilePresentingAppWithBundleId:(NSString *)bundleID {
    if (gSettings.on && gSettings.alwaysShow && NLIsNowPlaying(self)) return NO;
    return %orig;
}

- (BOOL)shouldSuppressElementWhilePresentingSceneWithIdentifier:(NSString *)identifier {
    if (gSettings.on && gSettings.alwaysShow && NLIsNowPlaying(self)) return NO;
    return %orig;
}

%end

%hook SBSystemApertureContainerView
- (void)layoutSubviews {
    %orig;
    if ((__bridge void *)self != gAttachedPillPtr) return;
    NLIslandLayout(self);
    // Another element took the pill over, or gave it back: the line goes or comes.
    if (NLPillShowsNowPlaying(self) != gShowsNowPlaying) {
        dispatch_async(dispatch_get_main_queue(), ^{ NLIslandUpdate(); });
    }
}
%end

// Probes for the NLI_FILELOG builds. Logos ignores #ifdef, so the group is
// always compiled and only installed (%init) when NLI_DEBUG_HOOKS is 1.
@interface SBSAElementContextMutator : NSObject
@end

#ifdef NLI_FILELOG
static NSString *NLIInsets(NSDirectionalEdgeInsets i) {
    return [NSString stringWithFormat:@"{t %.1f l %.1f b %.1f r %.1f}", i.top, i.leading, i.bottom, i.trailing];
}
#endif

%group NLIDebug

%hook SBSystemApertureViewController
- (NSDirectionalEdgeInsets)preferredEdgeOutsetsForLayoutMode:(NSInteger)mode suggestedOutsets:(NSDirectionalEdgeInsets)suggested maximumOutsets:(NSDirectionalEdgeInsets)maximum forTargetWithOverrider:(id)overrider isDefaultValue:(BOOL *)isDefault {
    NSDirectionalEdgeInsets r = %orig;
    NLI_LOG_ONCE(NSUIntegerMax, ([NSString stringWithFormat:@"VC outsets mode=%ld|%@|%@ -> %@", (long)mode,
                                  NSStringFromClass([overrider class]),
                                  [overrider respondsToSelector:@selector(layoutSpecifyingOverridingTarget)]
                                      ? NSStringFromClass([[overrider performSelector:@selector(layoutSpecifyingOverridingTarget)] class]) : @"-",
                                  NLIInsets(r)]));
    return r;
}
%end

%hook SBSAElementContextMutator
- (void)setPreferredEdgeOutsets:(NSDirectionalEdgeInsets)outsets {
    %orig;
    NLI_LOG_ONCE(40, ([NSString stringWithFormat:@"SBSA setPreferredEdgeOutsets %@ on %@", NLIInsets(outsets), NSStringFromClass([self class])]));
}
%end

%end

%hook SBMediaController
- (void)_mediaRemoteNowPlayingInfoDidChange:(id)notification {
    %orig;
    if (!gSettings.on) return;
    dispatch_async(dispatch_get_main_queue(), ^{ NLIslandRefreshInfo(); });
}
%end

// The settings page asks SpringBoard rather than its own process whether
// there is an island (NL_ISLAND_STATE_NAME), so one given by other means (a
// MobileGestalt edit, a tweak in SpringBoard) counts, on any device. Asked
// only once SpringBoard has finished launching: SpringBoardServices keeps the
// answer for the process the first time it is asked, and a tweak giving the
// island has hooked what it needs by then. The token stays registered, so the
// state lasts while SpringBoard runs.
static void NLIslandPublishAvailability(void) {
    static int token = -1;
    if (token == -1 && notify_register_check(NL_ISLAND_STATE_NAME, &token) != NOTIFY_STATUS_OK) return;
    BOOL (*available)(void) = (BOOL (*)(void))dlsym(RTLD_DEFAULT, "SBSIsSystemApertureAvailable");
    notify_set_state(token, available && available() ? kNLIslandPresent : kNLIslandAbsent);
}

%hook SpringBoard
- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    NLIslandPublishAvailability();
}
%end

static void NLIslandPrefsChanged(CFNotificationCenterRef center, void *observer,
                                 CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    NSDictionary *prefs = NLReadPrefsFile();
    NLIslandSettings now = NLIslandReadSettings(prefs);
    dispatch_async(dispatch_get_main_queue(), ^{
        gPrefs = prefs;
        BOOL heightChanged = now.on != gSettings.on;
        BOOL colorChanged = now.artworkColor != gSettings.artworkColor;
        BOOL keptChanged = (now.on && now.alwaysShow) != (gSettings.on && gSettings.alwaysShow);
        gSettings = now;
        // Always show switched: the island comes back over the player's app,
        // or goes away from it, at once rather than at the next app switch.
        SBSystemApertureViewController *vc = gApertureVC;
        if (keptChanged && [vc respondsToSelector:@selector(_reevaluateElementSuppression)]) [vc _reevaluateElementSuppression];
        if (colorChanged) gArtworkPrint = 0;   // fetch the artwork again
        if (heightChanged) NLIslandInvalidateHeight();
        NLIslandRefreshInfo();   // an offset or the word-by-word switch may have changed too
        NLIslandUpdate();
    });
}

%ctor {
    @autoreleasepool {
        if (!objc_getClass("SBSystemApertureSceneElement")) return;   // no Dynamic Island support in this iOS
        gPrefs = NLReadPrefsFile();
        gSettings = NLIslandReadSettings(gPrefs);
        NLI_LOG(@"loaded on=%d fontSize=%.1f", gSettings.on, gSettings.fontSize);
        if (NLI_DEBUG_HOOKS) {
            %init(NLIDebug);
        }
        NLObserveDarwin(NL_RELOAD_NOTIFICATION, NLIslandPrefsChanged, CFNotificationSuspensionBehaviorCoalesce);
        %init;
    }
}
