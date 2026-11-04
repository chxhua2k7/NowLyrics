//
//  NLSystemPlayerSB.x
//  SpringBoard: NowLyrics in Control Center's own media player (MediaControls).
//  iOS 16: under the outputs in their list (MRURoutingView) the sources the
//  Now Playing page offers (NLLyricsSources), the player's size in Control
//  Center and NowLyrics' settings, the card kept at the outputs' size; the
//  open player with the lyrics as Apple Music shows them (on its side between
//  the time bar and the buttons, upright under the song) and the song's own
//  title over them; closed, laid out for the size picked, 2×4 and 3×4 with
//  the lyrics too. iOS 26 (MediaControls' Swift module): the sources under
//  its outputs the same way, and its sizes, open on its side and beside the
//  outputs with the lyrics as iOS 16's. Part of NowLyricsIsland.
//

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import "NLShared.h"
#import "NowLyrics.h"
#import "NLLocate.h"
#import "NLIslandStrip.h"
#import "NLLyricsSources.h"
#import "NLSystemPlayer.h"

// MediaControls' buttons (MRUTransportButton) and their glyphs.
@interface MRUAsset : NSObject
+ (instancetype)symbolNamed:(NSString *)name;
+ (instancetype)image:(UIImage *)image;
@end
@interface UIButton (NLSPTransportButton)
- (void)setAsset:(MRUAsset *)asset animated:(BOOL)animated;
@end

@interface MRUNowPlayingTransportControlsView : UIView
@property (nonatomic, readonly) UIView *leftButton, *centerButton, *rightButton, *routingButton, *leadingButton;
@property (nonatomic, assign) long long layout;   // 0 the closed player's (20 pt glyphs), else the open one's (32 pt, press circles)
- (void)updateVisibility;   // the output button selected in the outputs layout, among others
@end

// The card's views: its title and the rows under it.
@interface MRUNowPlayingLabelView : UIView
@property (nonatomic, copy) NSString *title, *subtitle;
@property (nonatomic, assign) BOOL showRoute;   // the output's name over the song
- (void)updateVisibility;   // the output's name over it shown or not (showRoute)
@property (nonatomic, readonly) BOOL showPlaceholder;
@property (nonatomic, readonly) UIView *routeLabel, *placeholderMarqueeView, *titleMarqueeView, *subtitleMarqueeView;
- (void)setMarqueeEnabled:(BOOL)enabled;
- (void)updateMarquee;   // its title's and subtitle's marquees on or off
@end
@interface MRUNowPlayingHeaderView : UIView
@property (nonatomic, readonly) MRUNowPlayingLabelView *labelView;
@property (nonatomic, readonly) UIView *routingButton;
- (void)setTextAlignment:(NSTextAlignment)alignment;
@end
@interface MRUNowPlayingView : UIView
@property (nonatomic, readonly) MRUNowPlayingHeaderView *headerView;
@property (nonatomic, readonly) UIView *artworkView, *timeControlsView, *transportControlsView, *volumeControlsView;
- (void)updateTextAlignment;   // its label's alignment for its layout
- (void)updateVisibility;      // which of its rows show for its layout
@end

@interface MRUControlCenterView : UIView
@property (nonatomic, assign) long long state;
@property (nonatomic, readonly, getter=isTransitioning) BOOL transitioning;   // opening or closing
@property (nonatomic, readonly) CGRect transitionFrame;
@property (nonatomic, readonly) UIView *routingButton;   // the closed player's corner output button
- (void)updateVisibility;
@end

// The card's controller. Its layouts: the player open, and open with the
// outputs (the output button toggles between them through its delegate,
// Control Center's MRUControlCenterViewController).
@interface MRUNowPlayingViewController : UIViewController
@property (nonatomic, assign) long long layout;
@property (nonatomic, weak) id delegate;
@end
@interface NSObject (NLSPNowPlayingDelegate)
- (void)nowPlayingViewController:(MRUNowPlayingViewController *)controller applyLayout:(long long)layout;
@end

// The outputs in the card, under its header (beside it on its side).
@interface MRURoutingView : UIView
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, assign) UIEdgeInsets contentEdgeInsets;
@end

// Control Center's grid: a module's size there (columns, rows), a place in
// it (column, row), a module's rect, and them as NSValues.
typedef struct NLSPLayoutSize {
    unsigned long long width, height;
} NLSPLayoutSize;
typedef struct NLSPLayoutPoint {
    unsigned long long x, y;
} NLSPLayoutPoint;
typedef struct NLSPLayoutRect {
    NLSPLayoutPoint origin;
    NLSPLayoutSize size;
} NLSPLayoutRect;
@interface NSValue (NLSPLayout)
+ (NSValue *)ccui_valueWithLayoutSize:(NLSPLayoutSize)size;
+ (NSValue *)ccui_valueWithLayoutRect:(NLSPLayoutRect)rect;
- (NLSPLayoutSize)ccui_sizeValue;
@end
@interface UIViewController (NLSPModuleGrid)
- (void)_updatePositionProviders;    // CCUIModuleCollectionViewController: the modules measured and placed again, while it shows
- (void)_refreshPositionProviders;   // the same whatever it shows
@end

// MRUControlCenterView's state with the player open, and the card's layouts in it.
static const long long kNLSPPlayerState = 1;
static const long long kNLSPOutputsLayout = 1, kNLSPPlayerLayout = 2;
static const NSTimeInterval kNLSPReadInterval = 0.5, kNLSPAnswerWait = 20;
// The card's content inset (its header's artwork's), the rows' margins.
static const CGFloat kNLSPInset = 24;

#ifdef NLI_FILELOG
#define NLSP_LOG(...) NLIAppendLog(@"/var/mobile/Library/Logs/NowLyricsPlayer.log", \
    [NSString stringWithFormat:@"%@ %@\n", [NSDate date], [NSString stringWithFormat:__VA_ARGS__]])
#else
#define NLSP_LOG(...) do {} while (0)
#endif

// The settings' strings, from the settings bundle's copies of them.
static NSString *NLSPL(NSString *key) {
    NSBundle *bundle = NL_ONCE([NSBundle bundleWithPath:NLJBPath(@"/Library/PreferenceBundles/NowLyricsPrefs.bundle")]);
    return bundle ? [bundle localizedStringForKey:key value:key table:@"Island"] : key;
}

static UIColor *NLSPSecondary(void) { return NL_ONCE([UIColor colorWithWhite:1 alpha:0.6]); }

// The outputs' fonts (MediaControls' UIFont additions), for rows and
// headers the same size as theirs; the system's at about their sizes otherwise.
@interface UIFont (NLSPRouting)
+ (UIFont *)mru_routingTitleFont;
+ (UIFont *)mru_routingSubtitleFont;
+ (UIFont *)mru_routingHeaderFont;
@end
static UIFont *NLSPRoutingFont(SEL selector, CGFloat size) {
    UIFont *font = [UIFont respondsToSelector:selector] ? ((UIFont *(*)(id, SEL))objc_msgSend)(UIFont.class, selector) : nil;
    return [font isKindOfClass:UIFont.class] ? font : [UIFont systemFontOfSize:size];
}

// The media module in Control Center's grid, and its size there as picked
// in the list: "rows x columns" (systemPlayerSize; none, the system's).
static NSString *const kNLSPMediaModule = @"com.apple.mediaremote.controlcenter.nowplaying";
static NSString *const kNLSPPlayerSizeKey = @"systemPlayerSize";
static NSString *gNLSPPlayerSize;
static NSArray<NSString *> *NLSPSizeNames(void) { return NL_ONCE((@[@"1x4", @"2x2", @"2x4", @"3x4"])); }
static NSString *NLSPPlayerSizeName(void) { return [NLSPSizeNames() containsObject:gNLSPPlayerSize] ? gNLSPPlayerSize : @"2x2"; }

// NowLyrics switched on (`enabled`), the player's size (anything but a size,
// "default" from the settings page among them: MediaControls' own) and the
// settings page's Control Center switches: lyrics in the closed player (2×4
// and up), in the open one (upright, on its side, beside the outputs), the
// sources under the media module's outputs. Read again on every settings change.
static BOOL gNLSPEnabled = YES, gNLSPClosedLyrics = YES, gNLSPOpenLyrics = YES, gNLSPSourcesInOutputs = YES;
static void NLSPReadPrefs(void) {
    NSDictionary *prefs = NLReadPrefsFile();
    gNLSPEnabled = NLPrefBool(prefs, @"enabled", YES);
    NSString *size = NLString(prefs, kNLSPPlayerSizeKey);
    gNLSPPlayerSize = [NLSPSizeNames() containsObject:size] ? size : nil;
    gNLSPClosedLyrics = NLPrefBool(prefs, @"ccClosedLyrics", YES);
    gNLSPOpenLyrics = NLPrefBool(prefs, @"ccOpenLyrics", YES);
    gNLSPSourcesInOutputs = NLPrefBool(prefs, @"ccSourcesInOutputs", YES);
}

// Control Center's module grid as it last measured its modules (CCUIModuleCollectionViewController).
static __weak UIViewController *gNLSPModuleGrid;

// A content module context for the media module, as Control Center hands its
// modules one (CCUIContentModuleContext, its delegate the module manager):
// what opens a URL from Control Center (asking for the passcode first when
// locked, Control Center going away for the app) and asks the module's size
// again. nil without them. Its init declared so ARC sees it as one (it takes
// alloc's object and hands back its own).
@interface CCUIContentModuleContext : NSObject
- (instancetype)initWithModuleIdentifier:(NSString *)identifier;
@end
static id NLSPMediaContext(void) {
    static id context;
    if (!context) {
        Class contextClass = NSClassFromString(@"CCUIContentModuleContext"), managerClass = NSClassFromString(@"CCUIModuleInstanceManager");
        if (![contextClass instancesRespondToSelector:@selector(initWithModuleIdentifier:)] || ![managerClass respondsToSelector:@selector(sharedInstance)] ||
            ![contextClass instancesRespondToSelector:@selector(setDelegate:)]) return nil;
        context = [[contextClass alloc] initWithModuleIdentifier:kNLSPMediaModule];
        id manager = ((id (*)(id, SEL))objc_msgSend)(managerClass, @selector(sharedInstance));
        ((void (*)(id, SEL, id))objc_msgSend)(context, @selector(setDelegate:), manager);
    }
    return context;
}

// The context Control Center gave the module `view` is in: its container's
// (CCUIContentModuleContainerViewController) module's. What opens a URL on
// iOS 26, where NLSPMediaContext can't make one (its initializer changed).
static id NLSPModuleContextNear(UIView *view) {
    for (UIResponder *next = view; next; next = next.nextResponder) {
        if (![next respondsToSelector:@selector(contentModule)]) continue;
        id module = ((id (*)(id, SEL))objc_msgSend)(next, @selector(contentModule));
        if ([module respondsToSelector:@selector(contentModuleContext)]) return ((id (*)(id, SEL))objc_msgSend)(module, @selector(contentModuleContext));
    }
    return nil;
}

// Control Center's grid laid out again at once, the module `context` is
// for moving to its new size (the grid's own update waits while a module is
// open; CCSupport's notice to ask every module's size again too, should that
// not do).
static void NLSPRefreshGrid(id context) {
    if ([context respondsToSelector:@selector(requestLayoutSizeUpdate)]) ((void (*)(id, SEL))objc_msgSend)(context, @selector(requestLayoutSizeUpdate));
    UIViewController *grid = gNLSPModuleGrid;
    if ([grid respondsToSelector:@selector(_refreshPositionProviders)]) [grid _refreshPositionProviders];
    else if ([grid respondsToSelector:@selector(_updatePositionProviders)]) [grid _updatePositionProviders];
    NLPostDarwin(@"com.opa334.ccsupport/ReloadSizes");
    [grid.view setNeedsLayout];
    [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0
                        options:UIViewAnimationOptionAllowUserInteraction | UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ [grid.view layoutIfNeeded]; } completion:nil];
}

// The media module's size picked: kept (quietly, nothing else reloads for it), the grid laid out with it.
static void NLSPSetPlayerSize(NSString *name) {
    if ([name isEqualToString:NLSPPlayerSizeName()] && gNLSPPlayerSize) return;
    gNLSPPlayerSize = name;
    NLWritePrefQuietly(kNLSPPlayerSizeKey, name);
    NLSPRefreshGrid(NLSPMediaContext());
}
static void NLSPPrefsChanged(CFNotificationCenterRef center, void *observer, CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString *was = gNLSPPlayerSize;
        NLSPReadPrefs();
        if (!NLSame(was, gNLSPPlayerSize)) NLSPRefreshGrid(NLSPMediaContext());   // picked on the settings page
    });
}

#pragma mark - Views

// Whether `view` is in a window that shows. Closed, Control Center keeps its
// views in its window and hides the window (-[SBControlCenterController
// _updateWindowVisibility]), where MediaControls goes on laying its players
// out at every change: NowLyrics' own frames and readings (NLSPFollower, the
// lines' display links, the sources' timer) stop there, and start again as the
// window shows (UIWindowDidBecomeVisibleNotification).
static BOOL NLSPWindowShows(UIView *view) {
    UIWindow *window = view.window;
    return window && !window.hidden;
}

// The player's view `view` is in (it too).
static MRUControlCenterView *NLSPOwnerView(UIView *view) {
    return (MRUControlCenterView *)NLAncestorOfClass(view, objc_getClass("MRUControlCenterView"));
}

static UIView *NLSPDescendant(UIView *view, Class cls) {
    if ([view isKindOfClass:cls]) return view;
    for (UIView *sub in view.subviews) {
        UIView *found = NLSPDescendant(sub, cls);
        if (found) return found;
    }
    return nil;
}
// The same by class name (MediaControls' Swift classes have none to import).
static UIView *NLSPDescendantNamed(UIView *view, const char *className) {
    Class cls = objc_getClass(className);
    return cls ? NLSPDescendant(view, cls) : nil;
}
// Every one under `view` (it too), not looking inside one found.
static NSArray<UIView *> *NLSPDescendantsNamed(UIView *view, const char *className) {
    Class cls = objc_getClass(className);
    NSMutableArray<UIView *> *found = [NSMutableArray array], *pending = view && cls ? [NSMutableArray arrayWithObject:view] : nil;
    while (pending.count) {
        UIView *next = pending.firstObject;
        [pending removeObjectAtIndex:0];
        if ([next isKindOfClass:cls]) [found addObject:next];
        else [pending addObjectsFromArray:next.subviews];
    }
    return found;
}

// A row's height (MediaControls' time bar, buttons, volume): its own, or
// MediaControls' usual one before it has been laid out.
static const CGFloat kNLSPRowHeight = 44;
static CGFloat NLSPHeight(UIView *view) {
    return view.bounds.size.height > 0 ? view.bounds.size.height : kNLSPRowHeight;
}

// A Swift object's stored field by name (MediaControls' iOS 26 views: their
// classes' ivars): a one-byte enum's value (-1 without it), an object.
static const uint8_t *NLSPSwiftFieldAt(id object, const char *name) {
    Ivar ivar = object ? class_getInstanceVariable(object_getClass(object), name) : NULL;
    return ivar ? (const uint8_t *)(__bridge void *)object + ivar_getOffset(ivar) : NULL;
}
static int NLSPSwiftByte(id object, const char *name) {
    const uint8_t *at = NLSPSwiftFieldAt(object, name);
    return at ? *at : -1;
}
static id NLSPSwiftObject(id object, const char *name) {
    const uint8_t *at = NLSPSwiftFieldAt(object, name);
    return at ? (__bridge id)*(void *const *)at : nil;
}

#pragma mark - NowLyrics' own module

// NowLyrics' own Control Center modules (cc/NLCCModule.m, one per size) each
// hold a copy of this player, made as the media module makes its own: at the
// module's size, its outputs' list the lyrics sources alone, its output
// buttons the sources' (a lyrics glyph), 1×1 and 1×2 the module's own tile
// over it. What the module hands over (NLSystemPlayer.h), kept on the
// player's view controller.
static BOOL gNLSPCanAdopt, gNLSPAdopted;   // iOS 16's player hooked (%ctor); a module has one

@implementation NLSPOwnModule
+ (BOOL)canAdopt {
    return gNLSPCanAdopt;
}

+ (void)adopt:(UIViewController *)player size:(NSString *)size tile:(UIView *)tile {
    gNLSPAdopted = YES;
    NLSPOwnModule *own = [self new];
    own.size = size;
    own.tile = tile;
    objc_setAssociatedObject(player, @selector(adopt:size:tile:), own, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
@end

// The module whose copy `view` is in; nil in the media module's (or the lock screen's).
static NLSPOwnModule *NLSPOwnModuleOf(UIView *view) {
    UIResponder *controller = gNLSPAdopted ? NLSPOwnerView(view).nextResponder : nil;
    return controller ? objc_getAssociatedObject(controller, @selector(adopt:size:tile:)) : nil;
}

// The size of the player `view` is in, rows × columns: its module's own, or
// the media module's as picked; nil while none is (MediaControls' own layouts).
static NSString *NLSPPickedSize(UIView *view) {
    NLSPOwnModule *own = NLSPOwnModuleOf(view);
    if (own) return own.size;
    return gNLSPEnabled && gNLSPPlayerSize ? NLSPPlayerSizeName() : nil;
}

// The module's output buttons (MediaControls' routing buttons: the closed
// player's corner one, the header's, the transport row's) the lyrics
// sources' there, with a lyrics glyph in place of the output's.
static BOOL NLSPIsOwnRoutingButton(UIView *button) {
    if (!gNLSPAdopted) return NO;
    Class owner = objc_getClass("MRUControlCenterView");
    for (UIView *up = button.superview; up; up = up.superview) {
        if ([up respondsToSelector:@selector(routingButton)] && ((UIView *(*)(id, SEL))objc_msgSend)(up, @selector(routingButton)) == button) {
            return NLSPOwnModuleOf(up) != nil;
        }
        if ([up isKindOfClass:owner]) break;
    }
    return NO;
}
static char kNLSPLyricsGlyphKey;   // on a button: it has the lyrics glyph
static MRUAsset *NLSPLyricsGlyph(void) {
    return NL_ONCE(({
        Class asset = objc_getClass("MRUAsset");
        [asset respondsToSelector:@selector(symbolNamed:)] ? [asset symbolNamed:@"quote.bubble"] :
        [asset respondsToSelector:@selector(image:)] ? [asset image:[UIImage systemImageNamed:@"quote.bubble"]] : nil;
    }));
}
// What MediaControls gives `button`: the lyrics glyph for the module's output buttons.
static MRUAsset *NLSPAssetFor(UIView *button, MRUAsset *asset) {
    BOOL own = NLSPIsOwnRoutingButton(button);
    objc_setAssociatedObject(button, &kNLSPLyricsGlyphKey, own ? @YES : nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return own ? NLSPLyricsGlyph() ?: asset : asset;
}
// The glyph given to any that has none yet (set before it was in the module):
// the corner one of `view`, its player's header's and transport row's.
static void NLSPShowLyricsGlyphs(MRUControlCenterView *view, MRUNowPlayingView *player) {
    MRUAsset *glyph = NLSPLyricsGlyph();
    if (!glyph || !NLSPOwnModuleOf(view)) return;
    NSMutableArray<UIView *> *holders = [NSMutableArray arrayWithObject:view];
    if ([player respondsToSelector:@selector(headerView)] && player.headerView) [holders addObject:player.headerView];
    if ([player respondsToSelector:@selector(transportControlsView)] && player.transportControlsView) [holders addObject:player.transportControlsView];
    for (UIView *holder in holders) {
        UIButton *button = [holder respondsToSelector:@selector(routingButton)] ? ((UIButton *(*)(id, SEL))objc_msgSend)(holder, @selector(routingButton)) : nil;
        if (!button || [objc_getAssociatedObject(button, &kNLSPLyricsGlyphKey) boolValue] || ![button respondsToSelector:@selector(setAsset:animated:)]) continue;
        [button setAsset:glyph animated:NO];   // marked as it goes in (its hook)
    }
}

#pragma mark - List

// iOS 26's outputs' rows as they are, measured off them (+lookOfOutputsIn:):
// their inset from the list's sides and their height, where in a row the
// glyph's box and the text start, the check's box and its room from the end,
// their fonts and check, and the lit one's filters (Apple's vibrancy, its
// background's and its text's). MediaControls' numbers where there is no row
// to measure yet.
@interface NLSPOutputLook : NSObject
@property (nonatomic, assign) CGFloat inset, height, glyphX, glyphSide, textX, checkSide, checkEnd;
@property (nonatomic, strong) UIFont *titleFont, *subtitleFont;
@property (nonatomic, strong) UIImage *check;
@property (nonatomic, copy) NSArray *litFilters, *litContentFilters;
+ (instancetype)lookOfOutputsIn:(UIView *)outputs;
- (BOOL)isEqualToLook:(NLSPOutputLook *)look;
@end

@implementation NLSPOutputLook

+ (instancetype)lookOfOutputsIn:(UIView *)outputs {
    NLSPOutputLook *look = [NLSPOutputLook new];
    look.inset = 16;
    look.height = 48;
    look.glyphX = 12;
    look.glyphSide = look.checkSide = 32;
    look.textX = 48;
    look.checkEnd = 10;
    look.titleFont = [UIFont systemFontOfSize:17];
    look.subtitleFont = [UIFont systemFontOfSize:11];
    look.check = NL_ONCE([UIImage systemImageNamed:@"checkmark" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:17 weight:UIImageSymbolWeightSemibold]]);
    UIView *cell = NLSPDescendantNamed(outputs, "_TtC13MediaControls19RoutePickerItemCell");
    UIView *content = NLSPDescendantNamed(cell, "_TtC13MediaControls26RoutePickerItemContentView");
    if (!cell || !content) return look;
    look.inset = CGRectGetMinX(cell.frame);
    look.height = cell.bounds.size.height;
    Class accessory = objc_getClass("_TtC13MediaControls28RoutePickerItemAccessoryView");
    for (UIView *sub in content.subviews) {
        if ([sub isKindOfClass:UIImageView.class]) {
            look.glyphX = CGRectGetMinX(sub.frame);
            look.glyphSide = sub.bounds.size.width;
        } else if ([sub isKindOfClass:UIStackView.class]) {
            look.textX = CGRectGetMinX(sub.frame);
            NSArray<UIView *> *labels = ((UIStackView *)sub).arrangedSubviews;
            if (labels.count > 0 && [labels[0] isKindOfClass:UILabel.class]) look.titleFont = ((UILabel *)labels[0]).font;
            if (labels.count > 1 && [labels[1] isKindOfClass:UILabel.class]) look.subtitleFont = ((UILabel *)labels[1]).font;
        } else if (accessory && [sub isKindOfClass:accessory]) {
            look.checkSide = sub.bounds.size.width;
            look.checkEnd = content.bounds.size.width - CGRectGetMaxX(sub.frame);
            UIImageView *mark = (UIImageView *)NLSPDescendant(sub, UIImageView.class);
            if (mark.image && !mark.hidden) look.check = mark.image;
        }
    }
    // The lit one's: the first row whose background has its filters.
    for (UIView *row in NLSPDescendantsNamed(outputs, "_TtC13MediaControls19RoutePickerItemView")) {
        NSArray *filters = [NLSPDescendantNamed(row, "_TtC13MediaControls29RoutePickerItemBackgroundView").layer valueForKey:@"filters"];
        if (!filters.count) continue;
        look.litFilters = filters;
        look.litContentFilters = [NLSPDescendantNamed(row, "_TtC13MediaControls26RoutePickerItemContentView").layer valueForKey:@"filters"];
        break;
    }
    return look;
}

- (BOOL)isEqualToLook:(NLSPOutputLook *)look {
    return look && _inset == look.inset && _height == look.height && _glyphX == look.glyphX && _glyphSide == look.glyphSide &&
           _textX == look.textX && _checkSide == look.checkSide && _checkEnd == look.checkEnd &&
           NLSame(_titleFont, look.titleFont) && NLSame(_subtitleFont, look.subtitleFont) && NLSame(_check, look.check) &&
           (_litFilters.count > 0) == (look.litFilters.count > 0);
}

@end

// One row as the output list has them: a glyph, the title (and under it the
// lyrics' status for the pick), a white check, or a spinner while asked.
// Pressed it darkens; a tap sends its action. A plain view, not a control, so
// a drag that starts on it scrolls the list it is in (a scroll view keeps a
// control's touches).
@interface NLSPRow : UIView
@property (nonatomic, copy) NSString *source;   // nil: not a source (the settings, a note)
@property (nonatomic, assign, getter=isHighlighted) BOOL highlighted;
// iOS 26: as its outputs' rows (`outputLook`): inset and rounded, the pick
// lit as the output in use is; nil, iOS 16's (lines between them).
@property (nonatomic, strong) NLSPOutputLook *outputLook;
- (void)showTitle:(NSString *)title subtitle:(NSString *)subtitle symbol:(NSString *)symbol picked:(BOOL)picked busy:(BOOL)busy;
- (void)setTarget:(id)target action:(SEL)action;   // -action:(NLSPRow *)row
@end

@implementation NLSPRow {
    __weak id _target;
    SEL _action;
    UIImageView *_glyph, *_check;
    UILabel *_title, *_subtitle;
    UIActivityIndicatorView *_spinner;
    UIView *_line;
    UIView *_pillView;
    BOOL _picked;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _glyph = [UIImageView new];
        _glyph.tintColor = UIColor.whiteColor;
        _glyph.contentMode = UIViewContentModeCenter;
        _title = [UILabel new];
        _title.font = NLSPRoutingFont(@selector(mru_routingTitleFont), 15);
        _title.textColor = UIColor.whiteColor;
        _subtitle = [UILabel new];
        _subtitle.font = NLSPRoutingFont(@selector(mru_routingSubtitleFont), 12);
        _subtitle.textColor = NLSPSecondary();
        UIImageSymbolConfiguration *check = [UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightRegular];
        _check = [[UIImageView alloc] initWithImage:[[UIImage systemImageNamed:@"checkmark.circle.fill" withConfiguration:check]
                                                     imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal]];
        _spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
        _spinner.color = UIColor.whiteColor;
        _spinner.hidesWhenStopped = YES;
        _line = [UIView new];
        _line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
        _pillView = [UIView new];
        _pillView.hidden = YES;
        for (UIView *view in @[_pillView, _glyph, _title, _subtitle, _check, _spinner, _line]) {
            view.userInteractionEnabled = NO;
            [self addSubview:view];
        }
    }
    return self;
}

- (void)showTitle:(NSString *)title subtitle:(NSString *)subtitle symbol:(NSString *)symbol picked:(BOOL)picked busy:(BOOL)busy {
    _title.text = title;
    _title.textColor = symbol ? UIColor.whiteColor : NLSPSecondary();   // a note has no glyph
    _subtitle.text = subtitle;
    _glyph.image = symbol ? [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular]] : nil;
    _check.hidden = !picked || busy;
    if (busy) [_spinner startAnimating];
    else [_spinner stopAnimating];
    _picked = picked;
    if (_outputLook) [self nlStylePill];
    [self setNeedsLayout];
}

- (void)setOutputLook:(NLSPOutputLook *)outputLook {
    if (outputLook == _outputLook) return;
    _outputLook = outputLook;
    if (!outputLook) return;
    _title.font = outputLook.titleFont;
    _subtitle.font = outputLook.subtitleFont;
    _check.image = [outputLook.check imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];   // tinted as the text
    _check.contentMode = UIViewContentModeCenter;
    [self nlStylePill];
    [self setNeedsLayout];
}

// The pick lit as the output in use is (dark on light, their filters on
// them), the others light on the card; the settings and a note too.
- (void)nlStylePill {
    BOOL lit = _picked;
    UIColor *ink = lit ? UIColor.blackColor : UIColor.whiteColor;
    _pillView.hidden = NO;
    _pillView.backgroundColor = [self nlPillColor:NO];
    [_pillView.layer setValue:lit ? _outputLook.litFilters : nil forKey:@"filters"];
    _title.textColor = _glyph.image ? ink : NLSPSecondary();   // a note has no glyph
    _subtitle.textColor = lit ? [UIColor colorWithWhite:0 alpha:0.6] : NLSPSecondary();
    _glyph.tintColor = _check.tintColor = ink;
    for (UIView *view in @[_title, _subtitle, _glyph, _check]) [view.layer setValue:lit ? _outputLook.litContentFilters : nil forKey:@"filters"];
    _spinner.color = ink;
    _line.hidden = YES;
}

- (UIColor *)nlPillColor:(BOOL)pressed {
    if (_picked) return [UIColor colorWithWhite:1 alpha:pressed ? 0.55 : 0.4];
    return pressed ? [UIColor colorWithWhite:1 alpha:0.18] : UIColor.clearColor;
}

- (void)setTarget:(id)target action:(SEL)action {
    _target = target;
    _action = action;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.highlighted = YES;
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.highlighted = [self pointInside:[touches.anyObject locationInView:self] withEvent:event];
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    BOOL tapped = self.highlighted;
    self.highlighted = NO;
    id target = _target;
    if (tapped && target && _action) ((void (*)(id, SEL, id))objc_msgSend)(target, _action, self);
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    self.highlighted = NO;   // the list scrolling
}

// Darker while pressed, as an output is, fading back after.
- (void)setHighlighted:(BOOL)highlighted {
    if (highlighted == _highlighted) return;
    _highlighted = highlighted;
    UIView *view = _outputLook ? _pillView : self;
    UIColor *color = _outputLook ? [self nlPillColor:highlighted] : highlighted ? [UIColor colorWithWhite:0 alpha:0.45] : UIColor.clearColor;
    if (highlighted) {
        view.backgroundColor = color;
        return;
    }
    // From the dark just set (a quick tap sets it and clears it at once), not from what showed.
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionAllowUserInteraction
                     animations:^{ view.backgroundColor = color; } completion:nil];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    if (_outputLook) {
        [self nlLayOutPill];
        return;
    }
    _glyph.frame = CGRectMake(kNLSPInset - 2, 0, 30, size.height);
    CGFloat x = kNLSPInset + 43, trailing = size.width - kNLSPInset - 26;
    _check.frame = _spinner.frame = CGRectMake(trailing, round((size.height - 26) / 2), 26, 26);
    CGFloat width = trailing - 8 - x;
    BOOL two = _subtitle.text.length > 0;
    CGFloat titleHeight = ceil(_title.font.lineHeight), subtitleHeight = two ? ceil(_subtitle.font.lineHeight) : 0;
    CGFloat top = round((size.height - titleHeight - subtitleHeight - (two ? 1 : 0)) / 2);
    _title.frame = CGRectMake(x, top, width, titleHeight);
    _subtitle.frame = CGRectMake(x, top + titleHeight + 1, width, subtitleHeight);
    _subtitle.hidden = !two;
    _line.frame = CGRectMake(x, size.height - 0.5, size.width - x - kNLSPInset, 0.5);   // as the outputs' lines end
}

// As iOS 26's outputs (outputLook): the row inset and rounded, the glyph in
// its box, the text after it, the check at the end.
- (void)nlLayOutPill {
    NLSPOutputLook *look = _outputLook;
    CGSize size = self.bounds.size;
    CGRect pill = CGRectMake(look.inset, 0, size.width - 2 * look.inset, size.height);
    _pillView.frame = pill;
    _pillView.layer.cornerRadius = size.height / 2;
    _pillView.layer.cornerCurve = kCACornerCurveContinuous;
    _glyph.frame = CGRectMake(CGRectGetMinX(pill) + look.glyphX, round((size.height - look.glyphSide) / 2), look.glyphSide, look.glyphSide);
    CGFloat x = CGRectGetMinX(pill) + look.textX, trailing = CGRectGetMaxX(pill) - look.checkEnd - look.checkSide;
    _check.frame = _spinner.frame = CGRectMake(trailing, round((size.height - look.checkSide) / 2), look.checkSide, look.checkSide);
    CGFloat width = trailing - 4 - x;
    BOOL two = _subtitle.text.length > 0;
    CGFloat titleHeight = ceil(_title.font.lineHeight), subtitleHeight = two ? ceil(_subtitle.font.lineHeight) : 0;
    CGFloat top = round((size.height - titleHeight - subtitleHeight) / 2);
    _title.frame = CGRectMake(_glyph.image ? x : CGRectGetMinX(pill) + look.glyphX, top, width, titleHeight);
    _subtitle.frame = CGRectMake(x, top + titleHeight, width, subtitleHeight);
    _subtitle.hidden = !two;
}

@end

// The sources under the outputs, in their list (its table's footer): a
// header, the sources (the pick ticked, its status under it, a spinner while
// asked), the player's size, NowLyrics' settings. It follows the playing
// app's nowplaying.plist while it shows.
@interface NLSPSourceList : UIView
- (void)reload;
- (CGFloat)heightForWidth:(CGFloat)width;
- (void)fit;   // as tall as it needs: its table told, or under the outputs (inOutputs26)
// iOS 26: in the outputs' collection view, under its rows (the room to
// scroll to it added under them), its rows as theirs (NLSPOutputLook, measured
// again as it fits) and no player size (Control Center's own).
@property (nonatomic, assign) BOOL inOutputs26;
// NowLyrics' own module's: in its outputs' place (a scroll view of its own),
// no size row (each module has its own size).
@property (nonatomic, strong) NLSPOwnModule *ownModule;
@end

// Whether `view` is to be seen: in a window, it and every view above it not
// hidden, clear or flat (the outputs' list is there, 0 high, with the player alone).
static BOOL NLSPShowsOnScreen(UIView *view) {
    if (!NLSPWindowShows(view)) return NO;
    for (UIView *v = view; v; v = v.superview) {
        if (v.hidden || v.alpha < 0.01 || v.bounds.size.height < 1) return NO;
    }
    return YES;
}

@implementation NLSPSourceList {
    UILabel *_header, *_sizeHeader;
    UISegmentedControl *_sizes;
    NSMutableArray<NLSPRow *> *_rows;
    NLSPRow *_settings;
    NSTimer *_timer;
    NSString *_bundleID;
    NSDictionary *_np, *_prefs;
    CFAbsoluteTime _askedAt;
    NSString *_askedSource;
    NSString *_shown;   // what the rows were last built from
    NLSPOutputLook *_outputLook;   // iOS 26: its outputs' rows' (inOutputs26)
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _header = [UILabel new];
        _header.font = NLSPRoutingFont(@selector(mru_routingHeaderFont), 13);
        _header.textColor = NLSPSecondary();
        _header.text = NLSPL(@"Lyrics Sources");
        [self addSubview:_header];
        _rows = [NSMutableArray array];
        _sizeHeader = [UILabel new];
        _sizeHeader.font = _header.font;
        _sizeHeader.textColor = NLSPSecondary();
        _sizeHeader.text = NLSPL(@"Player Size");
        [self addSubview:_sizeHeader];
        NSMutableArray<NSString *> *titles = [NSMutableArray array];
        for (NSString *name in NLSPSizeNames()) [titles addObject:[name stringByReplacingOccurrencesOfString:@"x" withString:@"×"]];
        _sizes = [[UISegmentedControl alloc] initWithItems:titles];
        _sizes.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
        _sizes.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
        _sizes.selectedSegmentTintColor = [UIColor colorWithWhite:1 alpha:0.32];
        [_sizes setTitleTextAttributes:@{NSForegroundColorAttributeName: UIColor.whiteColor,
                                         NSFontAttributeName: [UIFont systemFontOfSize:13 weight:UIFontWeightMedium]} forState:UIControlStateNormal];
        [_sizes addTarget:self action:@selector(nlSizePicked) forControlEvents:UIControlEventValueChanged];
        [self addSubview:_sizes];
        _settings = [NLSPRow new];
        [_settings showTitle:NLSPL(@"NowLyrics Settings…") subtitle:nil symbol:@"gearshape" picked:NO busy:NO];
        [_settings setTarget:self action:@selector(nlOpenSettings)];
        [self addSubview:_settings];
    }
    return self;
}

- (void)setOwnModule:(NLSPOwnModule *)ownModule {
    _ownModule = ownModule;
    _sizeHeader.hidden = _sizes.hidden = ownModule || _inOutputs26;
    [self setNeedsLayout];
}

// The media module's size picked selected; none while MediaControls' own (the settings page's default).
- (void)nlShowSizes {
    NSUInteger at = gNLSPPlayerSize ? [NLSPSizeNames() indexOfObject:gNLSPPlayerSize] : NSNotFound;
    _sizes.selectedSegmentIndex = at == NSNotFound ? UISegmentedControlNoSegment : (NSInteger)at;
}

- (void)setInOutputs26:(BOOL)inOutputs26 {
    _inOutputs26 = inOutputs26;
    _sizeHeader.hidden = _sizes.hidden = inOutputs26 || _ownModule;
    _outputLook = inOutputs26 ? [NLSPOutputLook lookOfOutputsIn:nil] : nil;   // measured once in the outputs (nlFitOutputs26)
    _settings.outputLook = _outputLook;
    _shown = nil;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_timer invalidate];
    _timer = nil;
    if (!self.window) return;
    _prefs = NLReadPrefsNow();
    _shown = nil;
    [self nlShowSizes];
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:kNLSPReadInterval repeats:YES block:^(NSTimer *timer) {
        NLSPSourceList *list = weakSelf;
        if (!NLSPShowsOnScreen(list)) return;
        [list reload];
        if (list.inOutputs26) [list fit];
    }];
    [self reload];
}

- (void)reload {
    if (!_prefs) _prefs = NLReadPrefsNow();   // asked before it first showed
    _bundleID = NLSpringBoardPlayingBundleID();
    NSDictionary *np = NLReadNowPlaying(_bundleID);
    if (!NLSame(np[NL_NP_KEY], _np[NL_NP_KEY])) _askedAt = 0;   // another song
    _np = np;
    if (_askedAt && NLNowPlayingWrittenAfter(np, _askedAt)) _askedAt = 0;   // the app has answered
    NSArray<NSString *> *sources = NLOfferedSources(_prefs, _bundleID, _np);
    NSString *picked = NLPickedSource(_prefs, _np);
    NSString *busy = _askedAt ? _askedSource : nil;
    NSString *status = NLLyricsStatusText(_np, _askedAt != 0, ^NSString *(NSString *key) { return NLSPL(key); });
    NSString *shown = [NSString stringWithFormat:@"%@|%@|%@|%@", [sources componentsJoinedByString:@","], picked, busy, status];
    if ([shown isEqualToString:_shown]) return;
    _shown = shown;

    for (NLSPRow *row in _rows) [row removeFromSuperview];
    [_rows removeAllObjects];
    for (NSString *name in sources) {
        NLSPRow *row = [NLSPRow new];
        row.source = name;
        row.outputLook = _outputLook;
        BOOL isPicked = [name isEqualToString:picked];
        BOOL off = [name isEqualToString:NL_TRACK_SOURCE_OFF];   // its title says it all
        [row showTitle:NLSPL(NLSourceTitleKey(name)) subtitle:isPicked && !off ? status : nil symbol:NLSourceSymbolName(name)
                picked:isPicked busy:[name isEqualToString:busy]];
        [row setTarget:self action:@selector(nlPicked:)];
        [_rows addObject:row];
        [self addSubview:row];
    }
    if (!sources.count) {
        NLSPRow *note = [NLSPRow new];
        note.userInteractionEnabled = NO;
        note.outputLook = _outputLook;
        BOOL off = !_np && _bundleID;
        [note showTitle:off ? NLSPL(@"Off in this app") : NLSPL(@"Nothing is playing") subtitle:nil symbol:nil picked:NO busy:NO];
        [_rows addObject:note];
        [self addSubview:note];
    }
    [self setNeedsLayout];
    [self fit];
}

// As on the Now Playing page: the song looked up again with the source, the
// tick moving at once, its row spinning until the app has answered.
- (void)nlPicked:(NLSPRow *)row {
    NSDictionary *prefs = _prefs;
    CFAbsoluteTime asked = NLPickSourceForSong(&prefs, _bundleID, _np, row.source);
    if (!asked) return;
    _prefs = prefs;
    _askedAt = asked;
    _askedSource = row.source;
    NLSP_LOG(@"pick %@ for %@", row.source.length ? row.source : @"automatic", _np[NL_NP_KEY]);
    __weak typeof(self) weakSelf = self;
    NLAfter(kNLSPAnswerWait, ^{
        NLSPSourceList *list = weakSelf;
        if (!list || list->_askedAt != asked) return;
        list->_askedAt = 0;   // no answer: what the file says again
        [list reload];
    });
    [self reload];
}

// The player's size in Control Center (NLSPSetPlayerSize).
- (void)nlSizePicked {
    NSInteger index = _sizes.selectedSegmentIndex;
    if (index >= 0 && index < (NSInteger)NLSPSizeNames().count) NLSPSetPlayerSize(NLSPSizeNames()[index]);
}

// The Now Playing page, opened as a module opens one (NLSPMediaContext).
- (void)nlOpenSettings {
    NSURL *url = [NSURL URLWithString:@"prefs:root=NowLyrics&path=nowPlaying"];
    id context = NLSPModuleContextNear(self) ?: NLSPMediaContext();
    if ([context respondsToSelector:@selector(openURL:completionHandler:)]) {
        ((void (*)(id, SEL, NSURL *, id))objc_msgSend)(context, @selector(openURL:completionHandler:), url, nil);
    } else {
        [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
    }
}

// The header, the rows, the settings, from the top: placed when `apply`; the height they take.
- (CGFloat)nlLayoutWidth:(CGFloat)width apply:(BOOL)apply {
    if (_inOutputs26) return [self nlLayout26Width:width apply:apply];
    CGFloat y = 14, headerHeight = ceil(_header.font.lineHeight);
    if (apply) _header.frame = CGRectMake(kNLSPInset, y, width - 2 * kNLSPInset, headerHeight);
    y += headerHeight + 6;
    NSString *picked = NLPickedSource(_prefs, _np);
    for (NLSPRow *row in _rows) {
        CGFloat height = row.source && [row.source isEqualToString:picked] ? 60 : 52;
        if (apply) row.frame = CGRectMake(0, y, width, height);
        y += height;
    }
    y += 14;
    if (!_sizes.hidden) {
        CGFloat sizeHeaderHeight = ceil(_sizeHeader.font.lineHeight);
        if (apply) _sizeHeader.frame = CGRectMake(kNLSPInset, y, width - 2 * kNLSPInset, sizeHeaderHeight);
        y += sizeHeaderHeight + 8;
        if (apply) _sizes.frame = CGRectMake(kNLSPInset, y, width - 2 * kNLSPInset, 30);
        y += 30 + 10;
    }
    if (apply) _settings.frame = CGRectMake(0, y, width, 52);
    return y + 52 + 12;
}

// iOS 26: the header over the rows' glyphs, the rows as the outputs' (the
// pick a little taller for its status), the settings after a gap.
- (CGFloat)nlLayout26Width:(CGFloat)width apply:(BOOL)apply {
    NLSPOutputLook *look = _outputLook;
    CGFloat y = 18, headerHeight = ceil(_header.font.lineHeight), inset = look.inset + look.glyphX;
    if (apply) _header.frame = CGRectMake(inset, y, width - 2 * inset, headerHeight);
    y += headerHeight + 8;
    NSString *picked = NLPickedSource(_prefs, _np);
    for (NLSPRow *row in _rows) {
        CGFloat height = row.source && [row.source isEqualToString:picked] ? look.height + 8 : look.height;
        if (apply) row.frame = CGRectMake(0, y, width, height);
        y += height + 2;
    }
    y += 10;
    if (apply) _settings.frame = CGRectMake(0, y, width, look.height);
    return y + look.height + 16;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    return [self nlLayoutWidth:width apply:NO];
}

- (void)fit {
    if (_inOutputs26) {
        [self nlFitOutputs26];
        return;
    }
    UIScrollView *scroll = [self.superview isKindOfClass:UIScrollView.class] ? (UIScrollView *)self.superview : nil;
    UITableView *table = [scroll isKindOfClass:UITableView.class] ? (UITableView *)scroll : nil;
    CGFloat width = scroll ? scroll.bounds.size.width : self.bounds.size.width, height = [self heightForWidth:width];
    if (scroll && !table && !CGSizeEqualToSize(scroll.contentSize, CGSizeMake(width, height))) scroll.contentSize = CGSizeMake(width, height);   // the own module's
    if (fabs(self.bounds.size.width - width) < 0.5 && fabs(self.bounds.size.height - height) < 0.5) return;
    self.frame = CGRectMake(0, self.frame.origin.y, width, height);
    if (table.tableFooterView == self) table.tableFooterView = self;   // measured again
}

// Under the outputs' rows wherever they end (their count can change while
// it shows: read again on its timer), the room under them as tall as it.
- (void)nlFitOutputs26 {
    UICollectionView *collection = [self.superview isKindOfClass:UICollectionView.class] ? (UICollectionView *)self.superview : nil;
    if (!collection) return;
    NLSPOutputLook *look = [NLSPOutputLook lookOfOutputsIn:collection];   // upright and on its side differ
    if (![look isEqualToLook:_outputLook]) {
        _outputLook = look;
        for (NLSPRow *row in [_rows arrayByAddingObject:_settings]) row.outputLook = look;
        [self setNeedsLayout];
    }
    CGFloat width = collection.bounds.size.width, height = [self heightForWidth:width];
    CGFloat top = collection.collectionViewLayout.collectionViewContentSize.height;
    CGRect frame = CGRectMake(0, top, width, height);
    if (!CGRectEqualToRect(self.frame, frame)) self.frame = frame;
    UIEdgeInsets insets = collection.contentInset;
    if (fabs(insets.bottom - height) > 0.5) {
        insets.bottom = height;
        collection.contentInset = insets;
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self nlLayoutWidth:self.bounds.size.width apply:YES];
}

@end

#pragma mark - The sources in the card

static char kNLSPListKey, kNLSPOwnFooterKey, kNLSPOwnScrollKey;

// NowLyrics' own module: the sources in the outputs' place, the outputs'
// table hidden (its rows left as MediaControls keeps them), the list in a
// scroll view of its own where the table is, with its insets.
static void NLSPPlaceOwnSources(MRURoutingView *routing, UITableView *table, NLSPSourceList *list) {
    UIScrollView *scroll = objc_getAssociatedObject(routing, &kNLSPOwnScrollKey);
    if (!scroll) {
        scroll = [UIScrollView new];
        scroll.alwaysBounceVertical = YES;
        scroll.showsHorizontalScrollIndicator = NO;
        objc_setAssociatedObject(routing, &kNLSPOwnScrollKey, scroll, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (scroll.superview != routing) [routing insertSubview:scroll aboveSubview:table];
    if (list.superview != scroll) {
        if (table.tableFooterView == list) table.tableFooterView = objc_getAssociatedObject(routing, &kNLSPOwnFooterKey) ?: [UIView new];
        [scroll addSubview:list];
    }
    table.hidden = YES;
    scroll.frame = table.frame;
    if (!UIEdgeInsetsEqualToEdgeInsets(scroll.contentInset, table.contentInset)) scroll.contentInset = table.contentInset;
    scroll.verticalScrollIndicatorInsets = table.verticalScrollIndicatorInsets;
    [list fit];
}

// The sources under the outputs in the card's outputs' list: its table's
// footer (MediaControls' own an empty view, back while NowLyrics is off).
static void NLSPPlaceSources(MRURoutingView *routing) {
    UITableView *table = [routing respondsToSelector:@selector(tableView)] ? routing.tableView : nil;
    if (!table) return;
    NLSPSourceList *list = objc_getAssociatedObject(routing, &kNLSPListKey);
    NLSPOwnModule *own = NLSPOwnModuleOf(routing);   // its outputs' list is the sources, whatever the switches
    if ((!own && (!gNLSPEnabled || !gNLSPSourcesInOutputs)) || !NLSPOwnerView(routing)) {
        if (list && table.tableFooterView == list) table.tableFooterView = objc_getAssociatedObject(routing, &kNLSPOwnFooterKey) ?: [UIView new];
        return;
    }
    if (!list) {
        list = [NLSPSourceList new];
        objc_setAssociatedObject(routing, &kNLSPListKey, list, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (list.ownModule != own) list.ownModule = own;
    if (own) {
        NLSPPlaceOwnSources(routing, table, list);
        return;
    }
    if (table.tableFooterView == list) {
        [list fit];   // another width
        return;
    }
    objc_setAssociatedObject(routing, &kNLSPOwnFooterKey, table.tableFooterView, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat width = table.bounds.size.width;
    list.frame = CGRectMake(0, 0, width, [list heightForWidth:width]);
    table.tableFooterView = list;
}

#pragma mark - The closed player at its size

// The closed player at a size picked in its list, its own views laid out as
// NowLyrics' module lays out its tile there (NLCCViews.m): the cover, the
// title and the artist (MediaControls' label: the line being sung over the
// song while NowLyrics puts it there) and the buttons; 1×4 a row (the cover,
// the song beside it, play or pause, next and the output button at the end;
// a shorter one play or pause alone), 2×2 the cover over the song, 2×4 a big
// cover with the song beside it, under it the lyrics or, without them, the
// buttons over the time bar; 3×4 the cover with the song beside it, the
// lyrics under them, the time bar and the buttons along the bottom (without
// lyrics as the open player: the time bar, the buttons and the volume spread
// under the cover). NowLyrics' own module at its size the same, 1×1 and 1×2
// its own tile over the player (NLSPPlaceOwnTile). Opening and closing,
// MediaControls' own animation moves them between this and the open player.
typedef NS_ENUM(NSInteger, NLSPClosedLayout) {
    NLSPClosedNone,       // not closed, or no size picked: MediaControls' own
    NLSPClosedRow,        // a short row (play or pause alone)
    NLSPClosedLongRow,    // 1×4
    NLSPClosedSquare,     // 2×2
    NLSPClosedWide,       // 2×4
    NLSPClosedTall,       // 3×4
    NLSPClosedTile,       // the own module's 1×1 and 1×2: its tile, the player hidden under it
};
static char kNLSPClosedKey, kNLSPClosedButtonsKey;
// The time bar (3×4, 2×4 without lyrics): MediaControls' time controls (the
// elapsed time, the bar, the time left), which centre their one row in their
// height; that row's height, and the room between it and the buttons' glyphs.
static const CGFloat kNLSPTimeRow = 13, kNLSPByGlyphs = 12;
// 3×4's margins (as 2×4's) and the room between the cover and the lyrics under
// it; its time bar, buttons and volume as the open player's (kNLSPInset in,
// the buttons and the volume this far apart, the time bar a little nearer the
// buttons, their glyphs this big).
static const CGFloat kNLSPTallInset = 14, kNLSPUnderCover = 8, kNLSPOpenRows = 51, kNLSPTimeOverButtons = 40, kNLSPOpenGlyphs = 32;
static const long long kNLSPOpenTransportLayout = 2;

static char kNLSPOpenKey;   // on the player's MRUControlCenterView: Control Center opening it or closing it

// Closed, as Control Center has the module: from the moment it starts closing
// it, until it starts opening it (its transitions, CCUIContentModuleContainer-
// ViewController), so the frames in between, any size, stay one layout. Before
// any, by its size (a module in the grid; MediaControls keeps its open state
// for some closed sizes, so not by that).
static BOOL NLSPIsClosed(UIView *view) {
    NSNumber *open = objc_getAssociatedObject(view, &kNLSPOpenKey);
    if (open) return !open.boolValue;
    CGSize size = view.bounds.size;
    return size.width > 0 && MAX(size.width, size.height) < 400;
}

// The layout for the size picked (its frames from the player view's size as
// it is, so the frames of a transition move it along without another layout).
static NLSPClosedLayout NLSPClosedLayoutFor(UIView *inPlayer, CGSize size) {
    MRUControlCenterView *view = NLSPOwnerView(inPlayer);
    NSString *name = view && size.width >= 1 && size.height >= 1 && NLSPIsClosed(view) ? NLSPPickedSize(view) : nil;
    if (!name) return NLSPClosedNone;
    if ([name isEqualToString:@"1x1"] || [name isEqualToString:@"1x2"]) return NLSPClosedTile;
    if ([name isEqualToString:@"1x4"]) return NLSPClosedLongRow;
    if ([name isEqualToString:@"2x4"]) return NLSPClosedWide;
    if ([name isEqualToString:@"3x4"]) return NLSPClosedTall;
    return NLSPClosedSquare;
}

// Closed at a size picked (`inPlayer` in the player), laid out by NowLyrics (not under a tile).
static BOOL NLSPClosedAtSize(UIView *inPlayer) {
    UIView *player = NLAncestorOfClass(inPlayer, objc_getClass("MRUNowPlayingView"));
    NLSPClosedLayout layout = player ? NLSPClosedLayoutFor(player, player.bounds.size) : NLSPClosedNone;
    return layout != NLSPClosedNone && layout != NLSPClosedTile;
}

// Closed at a size picked: the title scrolled through when it is long, as
// the open player's is. MediaControls' closed layout (0) keeps the marquee
// off and measures the title only as wide as its room (-updateMarquee,
// -sizeForText:font:layout:availableSize:); the open player's (2) does neither.
static const long long kNLSPMarqueeLayout = 2;
static BOOL NLSPClosedMarquee(MRUNowPlayingLabelView *label) {
    return NLSPClosedAtSize(label);
}

static char kNLSPAskedOnScreenKey;   // on the time bar: what MediaControls last told it

static BOOL NLSPClosedHasLyrics(UIView *player);

// Closed at 3×4, or at 2×4 without lyrics, in a window: the time bar shows there, its clock running
// (MediaControls runs it only while the player counts as on screen,
// -setOnScreen:, which its closed one does not).
static BOOL NLSPTimeRuns(UIView *time) {
    UIView *player = NLAncestorOfClass(time, objc_getClass("MRUNowPlayingView"));
    NLSPClosedLayout layout = player && time.window ? NLSPClosedLayoutFor(player, player.bounds.size) : NLSPClosedNone;
    return layout == NLSPClosedTall || (layout == NLSPClosedWide && !NLSPClosedHasLyrics(player));
}

// The time bar told again what MediaControls last told it (NLSPTimeRuns decides on top of it).
static void NLSPRecheckTime(UIView *time) {
    if (![time respondsToSelector:@selector(setOnScreen:)]) return;
    ((void (*)(id, SEL, BOOL))objc_msgSend)(time, @selector(setOnScreen:), [objc_getAssociatedObject(time, &kNLSPAskedOnScreenKey) boolValue]);
}

// 1×4: the output button (MediaControls' corner one, as it looks there) at
// the row's end, after the buttons; again whenever MediaControls puts it back
// in its corner (-[MRUControlCenterView layoutSubviews]). NO elsewhere.
static BOOL NLSPPlaceRowCorner(UIView *player) {
    MRUControlCenterView *view = NLSPOwnerView(player);
    UIView *corner = [view respondsToSelector:@selector(routingButton)] ? view.routingButton : nil;
    CGSize size = player.bounds.size;
    if (!corner.superview || NLSPClosedLayoutFor(player, size) != NLSPClosedLongRow) return NO;
    CGFloat inset = round(size.height * 0.15), side = corner.bounds.size.width;
    corner.center = [player convertPoint:CGPointMake(size.width - inset - side / 2 + 4, size.height / 2) toView:corner.superview];
    return YES;
}

// 3×4: the transport row in the open player's layout (MediaControls' bigger
// glyphs, their press circles, its own spacing), asked for whatever
// MediaControls asks (it asks 0 closed); the others as asked.
static long long NLSPTallTransport(UIView *transport, long long asked) {
    UIView *player = NLAncestorOfClass(transport, objc_getClass("MRUNowPlayingView"));
    return player && NLSPClosedLayoutFor(player, player.bounds.size) == NLSPClosedTall ? kNLSPOpenTransportLayout : asked;
}

// The closed player's time bar (NLSPTimeRuns), its row centred at `y`.
static void NLSPPlaceTimeRow(UIView *time, CGFloat x, CGFloat y, CGFloat width) {
    CGFloat height = NLSPHeight(time);
    time.frame = CGRectMake(x, round(y - height / 2), width, height);
    time.alpha = 1;
}

// The time bar and the buttons along the foot of a player `height` high, as
// 3×4 has them with lyrics (and the open player upright, after it): the
// middle of the buttons' glyphs, of the time row over them, and the foot of
// the room above it.
typedef struct {
    CGFloat glyphsY, timeY, roomFoot;
} NLSPFootRows;
static NLSPFootRows NLSPFootRowsIn(CGFloat height) {
    NLSPFootRows rows;
    rows.glyphsY = height - kNLSPTallInset - 4 - kNLSPOpenGlyphs / 2;
    rows.timeY = rows.glyphsY - kNLSPTimeOverButtons;
    rows.roomFoot = rows.timeY - kNLSPTimeRow / 2 - 4;
    return rows;
}

// The label's width from `x`, at most `width`, `gap` short of the corner
// output button where it shows.
static CGFloat NLSPWidthBeforeCorner(UIView *corner, UIView *player, CGFloat x, CGFloat width, CGFloat gap) {
    if (!corner.superview || corner.hidden) return width;
    return MIN(width, [corner.superview convertRect:corner.frame toView:player].origin.x - x - gap);
}

// The label's text's height in it: one line (its placeholder's) when nothing plays.
static CGFloat NLSPTextHeight(UIView *placeholder, CGFloat labelHeight) {
    return placeholder ? MIN(placeholder.bounds.size.height, labelHeight) : labelHeight;
}

#ifdef NLI_FILELOG
// Debug builds: the closed title's marquee as it is, on every change.
static void NLSPLogMarquee(MRUNowPlayingLabelView *label, NSString *when) {
    UIView *player = NLAncestorOfClass(label, objc_getClass("MRUNowPlayingView"));
    if (!player) return;
    id title = [label respondsToSelector:@selector(titleMarqueeView)] ? [label valueForKey:@"titleMarqueeView"] : nil;
    UIView *marquee = [title respondsToSelector:@selector(marqueeView)] ? [title valueForKey:@"marqueeView"] : nil;
    long long layout = -1;
    Ivar ivar = class_getInstanceVariable(object_getClass(label), "_layout");
    if (ivar) layout = *(long long *)((char *)(__bridge void *)label + ivar_getOffset(ivar));
    NSString *tell = [NSString stringWithFormat:@"marquee (%@): closed %ld wanted %d layout %lld window %d label on %@ title on %@ view on %@ content %@ bounds %@ animations %@ text %@",
                      when, (long)NLSPClosedLayoutFor(player, player.bounds.size), NLSPClosedMarquee(label), layout, label.window != nil,
                      [label valueForKey:@"marqueeEnabled"], [title valueForKey:@"marqueeEnabled"],
                      [marquee respondsToSelector:@selector(isMarqueeEnabled)] ? [marquee valueForKey:@"marqueeEnabled"] : @"-",
                      [marquee respondsToSelector:@selector(contentSize)] ? NSStringFromCGSize([[marquee valueForKey:@"contentSize"] CGSizeValue]) : @"-",
                      NSStringFromCGRect(marquee.bounds), [marquee.layer.animationKeys componentsJoinedByString:@","],
                      [title respondsToSelector:@selector(text)] ? [title valueForKey:@"text"] : @"-"];
    static NSString *told;
    if (!NLSame(tell, told)) NLSP_LOG(@"%@", tell);
    told = tell;
}
#endif

// The closed label's marquees started again once Control Center has closed
// the card (-didTransitionToExpandedContentMode:): closing, Control Center
// takes the card out of its window and puts it back, and MediaControls turns
// the marquees off as it leaves (-[MRUNowPlayingLabelView didMoveToWindow])
// but not on as it comes back; and a marquee turned on while the card still
// moves stays still until it is turned on again.
static void NLSPRestartClosedMarquee(MRUNowPlayingLabelView *label) {
    if (!label.window || !NLSPClosedMarquee(label) || ![label respondsToSelector:@selector(updateMarquee)]) return;
    for (NSString *key in @[@"titleMarqueeView", @"subtitleMarqueeView"]) {
        id marquee = [label respondsToSelector:NSSelectorFromString(key)] ? [label valueForKey:key] : nil;
        if ([marquee respondsToSelector:@selector(setMarqueeEnabled:)]) ((void (*)(id, SEL, BOOL))objc_msgSend)(marquee, @selector(setMarqueeEnabled:), NO);
    }
    [label setMarqueeEnabled:YES];   // the label's own on again (its hook keeps it so closed)
    [label updateMarquee];           // and its title's and subtitle's, for where it is now
#ifdef NLI_FILELOG
    NLSPLogMarquee(label, @"restarted");
#endif
}

// The cover, the label, the time bar and the buttons' row in the closed
// player, after MediaControls has laid it out (the volume hidden, as the tile
// has none); MediaControls' alignment, corner button, cover and rows back
// once it is not. The label as MediaControls has it: the line being sung
// over the song while NowLyrics puts it there; with the time bar under it
// placed as one (not playing, the one line saying so), and MediaControls'
// corner button where there is room for it.
static void NLSPLayOutClosed(MRUNowPlayingView *player) {
    CGSize size = player.bounds.size;
    NLSPClosedLayout layout = NLSPClosedLayoutFor(player, size);
    MRUControlCenterView *view = NLSPOwnerView(player);
    if (![player respondsToSelector:@selector(artworkView)] || ![player respondsToSelector:@selector(headerView)]) return;
    UIView *artwork = player.artworkView, *transport = player.transportControlsView;
    MRUNowPlayingHeaderView *header = player.headerView;
    MRUNowPlayingLabelView *label = [header respondsToSelector:@selector(labelView)] ? header.labelView : nil;
    UIView *corner = [view respondsToSelector:@selector(routingButton)] ? view.routingButton : nil;
    corner.alpha = layout == NLSPClosedRow || layout == NLSPClosedTile ? 0 : 1;   // MediaControls shows and hides it by `hidden`
    if (layout == NLSPClosedTile) return;   // under the own module's tile (NLSPPlaceOwnTile)
    if (layout == NLSPClosedNone) {
        if (![objc_getAssociatedObject(player, &kNLSPClosedKey) boolValue]) return;
        objc_setAssociatedObject(player, &kNLSPClosedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if ([player respondsToSelector:@selector(updateTextAlignment)]) [player updateTextAlignment];
        if ([player respondsToSelector:@selector(updateVisibility)]) [player updateVisibility];
        if ([label respondsToSelector:@selector(updateVisibility)]) [label updateVisibility];   // the output's name as MediaControls has it
        if ([view respondsToSelector:@selector(updateVisibility)]) [view updateVisibility];
        if (NLSPIsClosed(view)) artwork.alpha = 0;   // closed as MediaControls has it, without the cover
        return;
    }
    objc_setAssociatedObject(player, &kNLSPClosedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIView *time = player.timeControlsView;
    artwork.alpha = 1;
    time.alpha = player.volumeControlsView.alpha = 0;   // the time bar where it shows (NLSPTimeRuns)
    if ([header respondsToSelector:@selector(setTextAlignment:)]) [header setTextAlignment:NSTextAlignmentLeft];
    CGFloat width = size.width, height = size.height, row = NLSPHeight(transport);
    // No output's name over the song (MediaControls hides it for its closed
    // player, but only once the card has closed: it would move the song then).
    if ([label respondsToSelector:@selector(routeLabel)]) label.routeLabel.alpha = 0;
    UIView *placeholder = [label respondsToSelector:@selector(showPlaceholder)] && label.showPlaceholder &&
                          [label respondsToSelector:@selector(placeholderMarqueeView)] ? label.placeholderMarqueeView : nil;
    switch (layout) {
        case NLSPClosedRow:
        case NLSPClosedLongRow: {
            CGFloat inset = round(height * 0.15), side = height - inset * 2;
            artwork.frame = CGRectMake(inset, inset, side, side);
            CGFloat buttons = layout == NLSPClosedRow ? 40 : 84, end = width - inset;
            if (NLSPPlaceRowCorner(player)) end -= corner.bounds.size.width;   // the output button after them
            transport.frame = CGRectMake(end - buttons + 8, round((height - row) / 2), buttons, row);
            CGFloat x = inset + side + 9, labelWidth = CGRectGetMinX(transport.frame) - x;
            CGFloat labelHeight = MIN([header sizeThatFits:CGSizeMake(labelWidth, height)].height, height);
            header.frame = CGRectMake(x, round((height - NLSPTextHeight(placeholder, labelHeight)) / 2), labelWidth, labelHeight);
            break;
        }
        case NLSPClosedSquare: {
            CGFloat side = MIN(width, height), inset = round(side * 0.09), cover = round(side * 0.32);
            artwork.frame = CGRectMake(inset, inset, cover, cover);
            transport.frame = CGRectMake(round(inset / 2), height - round(inset * 0.6) - row + 5, width - inset, row);
            // The title and the artist down on the buttons; "Not Playing" (one line, at the
            // label's top) where the title goes, not lower in the artist's place.
            CGFloat labelWidth = width - inset * 2, top = CGRectGetMaxY(artwork.frame) + 6, bottom = CGRectGetMinY(transport.frame) + 3;
            CGFloat labelHeight = MIN([header sizeThatFits:CGSizeMake(labelWidth, bottom - top)].height, bottom - top);
            header.frame = CGRectMake(inset, round(MAX(top, bottom - labelHeight)), labelWidth, labelHeight);
            break;
        }
        case NLSPClosedWide: {
            CGFloat inset = round(height * 0.09), side = height - inset * 2;
            artwork.frame = CGRectMake(inset, inset, side, side);
            CGFloat x = inset + side + inset, columnWidth = width - x - inset;
            if (NLSPClosedHasLyrics(player)) {
                transport.frame = CGRectMake(x - 8, height - round(inset * 0.6) - row + 5, columnWidth + 16, row);   // as low as 2×2's
            } else {
                // The time bar along the bottom, its foot level with the cover's; the buttons
                // over it (their glyphs 20 pt closed).
                CGFloat timeY = inset + side - kNLSPTimeRow / 2, glyphsY = timeY - kNLSPTimeRow / 2 - kNLSPByGlyphs - 10;
                transport.frame = CGRectMake(x - 8, round(glyphsY - row / 2), columnWidth + 16, row);
                NLSPPlaceTimeRow(time, x, timeY, columnWidth);
            }
            // The label short of the corner button; the lyrics under it (NLSPPlaceClosedLyrics).
            CGFloat labelWidth = NLSPWidthBeforeCorner(corner, player, x, columnWidth, 4);
            CGFloat labelHeight = MIN([header sizeThatFits:CGSizeMake(labelWidth, height)].height, CGRectGetMinY(transport.frame) - inset);
            header.frame = CGRectMake(x, inset, labelWidth, labelHeight);
            break;
        }
        case NLSPClosedTall: {
            // The time bar, the buttons and (without lyrics) the volume as the open player
            // has them: its widths, its spacing, its buttons (MediaControls' open row,
            // NLSPTallTransport), with the lyrics over them or else the rows centred under the cover.
            CGFloat inset = kNLSPTallInset, cover = round(height * 0.24), content = width - kNLSPInset * 2;
            artwork.frame = CGRectMake(inset, inset, cover, cover);
            CGFloat timeY, glyphsY;
            UIView *volume = player.volumeControlsView;
            if (NLSPClosedHasLyrics(player)) {
                NLSPFootRows rows = NLSPFootRowsIn(height);
                glyphsY = rows.glyphsY;
                timeY = rows.timeY;
            } else {
                CGFloat start = inset + cover + kNLSPUnderCover, end = height - inset;
                CGFloat block = kNLSPTimeRow / 2 + kNLSPTimeOverButtons + kNLSPOpenRows + 10;   // the time row's top to the volume's foot (its row 20 pt)
                timeY = round(start + (end - start - block) / 2 + kNLSPTimeRow / 2);
                glyphsY = timeY + kNLSPTimeOverButtons;
                CGFloat volumeHeight = NLSPHeight(volume);
                volume.frame = CGRectMake(kNLSPInset, round(glyphsY + kNLSPOpenRows - volumeHeight / 2), content, volumeHeight);
                volume.alpha = 1;
            }
            NLSPPlaceTimeRow(time, kNLSPInset, timeY, content);
            transport.frame = CGRectMake(kNLSPInset, round(glyphsY - row / 2), content, row);
            // The song beside the cover, short of the corner button; the lyrics under them (NLSPPlaceClosedLyrics).
            CGFloat x = inset + cover + 12, labelWidth = NLSPWidthBeforeCorner(corner, player, x, width - inset - x, 4);
            CGFloat labelHeight = MIN([header sizeThatFits:CGSizeMake(labelWidth, cover)].height, cover);
            header.frame = CGRectMake(x, round(inset + (cover - NLSPTextHeight(placeholder, labelHeight)) / 2), labelWidth, labelHeight);
            break;
        }
        case NLSPClosedNone:
        case NLSPClosedTile:
            break;
    }
    NLSPRecheckTime(time);   // its clock running where it shows, stopped where it went away (lyrics came)
    // 3×4's buttons as the open player's, the others' as MediaControls closes them (NLSPTallTransport).
    if ([transport respondsToSelector:@selector(setLayout:)]) ((MRUNowPlayingTransportControlsView *)transport).layout = 0;
}

// Closed at a size picked, the card fills the module. MediaControls keeps
// its open state while it closes to some sizes (and sometimes after), and
// then makes the card as tall as the open player's header, a thin strip in
// the middle (2×4: 31 of 159 pt) that the layout above then took for a row.
static void NLSPFillClosedCard(MRUControlCenterView *view) {
    if (!NLSPIsClosed(view) || !NLSPPickedSize(view)) return;
    UIView *player = NLSPDescendant(view, objc_getClass("MRUNowPlayingView"));
    UIView *card = player.superview;
    if (!card || card == view || CGRectEqualToRect(card.frame, view.bounds)) return;
    CGSize was = card.bounds.size;
    card.frame = view.bounds;
    for (UIView *sub in card.subviews) {
        // Its backdrop, tint and the player, as big as it (not the corner button).
        if (sub == player || CGSizeEqualToSize(sub.bounds.size, was)) sub.frame = card.bounds;
    }
}

// The player under the own module's tile hidden, once the fade out that
// takes it away while Control Center closes the module is over (unless it
// was shown again meanwhile).
static char kNLSPFadeKey;   // on the player: its fade out under way
@interface NLSPHideAfterFade : NSObject <CAAnimationDelegate>
@property (nonatomic, weak) UIView *view;
@end

@implementation NLSPHideAfterFade
- (void)animationDidStop:(CAAnimation *)animation finished:(BOOL)finished {
    UIView *view = self.view;
    if (!view || objc_getAssociatedObject(view, &kNLSPFadeKey) != self) return;
    objc_setAssociatedObject(view, &kNLSPFadeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.hidden = YES;
    [view.layer removeAnimationForKey:@"nlTile"];
}
@end

// The player shown, or hidden under the tile: at once, or during Control
// Center's animation faded in, or out and then hidden (a fade cut short goes
// on from where it got).
static void NLSPShowUnderTile(UIView *player, BOOL show) {
    NSTimeInterval duration = UIView.inheritedAnimationDuration;
    BOOL fadingOut = objc_getAssociatedObject(player, &kNLSPFadeKey) != nil;
    if (show ? (!player.hidden && !fadingOut) : (player.hidden || fadingOut)) return;   // already so
    float from = player.hidden ? 0 : (player.layer.presentationLayer ?: player.layer).opacity;
    objc_setAssociatedObject(player, &kNLSPFadeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [player.layer removeAnimationForKey:@"nlTile"];
    if (duration <= 0) {
        player.hidden = !show;
        return;
    }
    player.hidden = NO;
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @(from);
    fade.duration = duration;
    if (!show) {
        NLSPHideAfterFade *hide = [NLSPHideAfterFade new];
        hide.view = player;
        objc_setAssociatedObject(player, &kNLSPFadeKey, hide, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        fade.toValue = @0;
        fade.fillMode = kCAFillModeForwards;
        fade.removedOnCompletion = NO;
        fade.delegate = hide;
    }
    [player.layer addAnimation:fade forKey:@"nlTile"];
}

// NowLyrics' own module closed at 1×1 or 1×2: its own tile (NLSPOwnModule's)
// over MediaControls' card, the player under it and its corner button hidden.
// In the card, not the player's whole view (which Control Center makes the
// screen's height open, the card in its middle), so it moves and clips with
// it: as the module opens the tile fades out at the card's corner, the
// closed size kept, the player fading in under it; closing, the reverse.
static void NLSPPlaceOwnTile(MRUControlCenterView *view, UIView *player) {
    UIView *tile = NLSPOwnModuleOf(view).tile, *card = player.superview;
    if (!tile || !card) return;
    BOOL shown = NLSPClosedLayoutFor(player, card.bounds.size) == NLSPClosedTile;
    if (!shown && tile.superview != card) return;
    if (tile.superview != card) {
        tile.alpha = 0;
        [card addSubview:tile];
    }
    [card bringSubviewToFront:tile];
    if (shown) tile.frame = card.bounds;
    tile.alpha = shown ? 1 : 0;
    tile.userInteractionEnabled = shown;
    if (shown && [view respondsToSelector:@selector(routingButton)]) view.routingButton.alpha = 0;
    NLSPShowUnderTile(player, !shown);
}

// The closed player's buttons for its layout, across its row: play or pause
// alone in a short row, with next in 1×4, previous, play or pause and next otherwise;
// the others hidden, and back as MediaControls has them once it is not.
static BOOL NLSPLayOutClosedButtons(MRUNowPlayingTransportControlsView *transport) {
    NLSPClosedLayout layout = NLSPClosedLayoutFor(transport, transport.superview.bounds.size);
    UIView *leading = [transport respondsToSelector:@selector(leadingButton)] ? transport.leadingButton : nil;
    UIView *left = [transport respondsToSelector:@selector(leftButton)] ? transport.leftButton : nil;
    UIView *center = [transport respondsToSelector:@selector(centerButton)] ? transport.centerButton : nil;
    UIView *right = [transport respondsToSelector:@selector(rightButton)] ? transport.rightButton : nil;
    UIView *routing = [transport respondsToSelector:@selector(routingButton)] ? transport.routingButton : nil;
    if (layout == NLSPClosedNone || layout == NLSPClosedTile || !center) {
        if ([objc_getAssociatedObject(transport, &kNLSPClosedButtonsKey) boolValue]) {
            objc_setAssociatedObject(transport, &kNLSPClosedButtonsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            left.alpha = right.alpha = 1;
            if ([transport respondsToSelector:@selector(updateVisibility)]) [transport updateVisibility];   // the leading and output buttons
        }
        return NO;
    }
    objc_setAssociatedObject(transport, &kNLSPClosedButtonsKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSMutableArray<UIView *> *shown = [NSMutableArray array];
    if (layout != NLSPClosedRow && layout != NLSPClosedLongRow && left) [shown addObject:left];
    [shown addObject:center];
    if (layout != NLSPClosedRow && right) [shown addObject:right];
    for (UIView *button in @[leading ?: NSNull.null, left ?: NSNull.null, right ?: NSNull.null, routing ?: NSNull.null]) {
        if ([button isKindOfClass:UIView.class]) button.alpha = [shown containsObject:button] ? 1 : 0;
    }
    CGSize size = transport.bounds.size;
    if (layout == NLSPClosedTall && shown.count == 3) {
        // 3×4: as the open row spaces them (MediaControls' open layout, NLSPTallTransport), centred without its output button.
        CGFloat apart = round(fabs(right.center.x - center.center.x)) ?: round(size.width / 4);
        for (NSUInteger i = 0; i < shown.count; i++) shown[i].center = CGPointMake(round(size.width / 2 + apart * ((CGFloat)i - 1)), round(size.height / 2));
        return YES;
    }
    for (NSUInteger i = 0; i < shown.count; i++) {
        shown[i].center = CGPointMake(round(size.width * (i + 0.5) / shown.count), round(size.height / 2));
    }
    return YES;
}

#pragma mark - Lyrics

// The lines, as Apple Music's: bold, wrapped, some room between them; the
// sung one bright (its unsung part dim), the others dim and blurred.
static const CGFloat kNLSPOtherAlpha = 0.3, kNLSPUnsungAlpha = 0.35;
// A pause in the singing this long or longer shows Apple Music's dots (gone
// a moment before the next line); how much they breathe and how slowly.
static const NSTimeInterval kNLSPPauseLeast = 3.5, kNLSPPauseEndsEarly = 0.25;
static const CGFloat kNLSPDotBreath = 0.08;
static const NSTimeInterval kNLSPDotBreathPeriod = 1.8;
// Room kept left and right of every line's text, for glyphs that reach out
// of it (the rounded side of a first letter) not to be cut there.
static const CGFloat kNLSPEdge = 6;
static const CGFloat kNLSPWordGrow = 0.06;       // a word as it lights grows by this much at its end, as Apple Music's
static const NSInteger kNLSPShownAround = 5;      // lines laid out either side of the sung one
// A new line: the column up on a soft spring, each line a beat after the one above it.
static const NSTimeInterval kNLSPScrollDuration = 0.7, kNLSPScrollStagger = 0.035;
static const CGFloat kNLSPScrollDamping = 0.82;

// A column's sizes: its font, the room between lines, the others' blur, how
// far a word lifts as it lights, the sung line's top and where the edges'
// fades end (shares of the room from its top), and the dots' size, the room
// between them and their row's height.
typedef struct {
    CGFloat size, gap, blur, lift, anchor, fadeTop, fadeBottom, dotSize, dotGap, dotRow;
} NLSPLyricsLook;
// The open player on its side: in the room between the time and the buttons.
static const NLSPLyricsLook kNLSPSidewaysLook = {20, 10, 1.5, 2, 0.22, 0.14, 0.78, 10, 7, 26};
// Closed at 2×4: three lines under the song.
static const NLSPLyricsLook kNLSPClosedLook = {15, 4, 1, 1.5, 0.04, 0.04, 0.88, 7, 5, 18};
static const NSInteger kNLSPClosedRows = 3;
// A column's rows, besides a count: all of its room (the fades taking the
// edges, on its side) or as many whole rows as fit (none cut by a fade).
static const NSInteger kNLSPAllTheRoom = 0, kNLSPWholeRows = -1;
// Closed at 3×4: from the top of their room, the sizes halfway between 2×4's
// and its side's, as the card's height is (159, 246 and 333 pt on a 6.1″ phone).
static const NLSPLyricsLook kNLSPTallLook = {17.5, 7, 1.25, 1.75, 0.06, 0.06, 0.88, 8.5, 6, 22};
// A look with `sizes`' font, room, blur, lift and dots, placed as `place`
// (its anchor and fades): a big card's lyrics as big as on its side, from
// the top of their room as the closed sizes'.
static NLSPLyricsLook NLSPLookPlaced(NLSPLyricsLook sizes, NLSPLyricsLook place) {
    NLSPLyricsLook look = sizes;
    look.anchor = place.anchor;
    look.fadeTop = place.fadeTop;
    look.fadeBottom = place.fadeBottom;
    return look;
}
// The rows under them on its side: the volume this far over the card's
// bottom, the transport row over it (their frames overlapping by their padding).
static const CGFloat kNLSPBottomInset = 8, kNLSPRowsOverlap = 6;
// The least room between the song and lyrics under it (the most: kNLSPUnderCover).
static const CGFloat kNLSPLeastGap = 2;

static dispatch_queue_t NLSPQueue(void) {
    return NL_ONCE(dispatch_queue_create("com.c3x14n.nowlyrics.player", DISPATCH_QUEUE_SERIAL));
}

@implementation NLSPFollower {
    NSMapTable<id, void (^)(void)> *_watchers;
    NSTimer *_timer;
    id _infoObserver;
    NSUInteger _readGeneration;
}

+ (instancetype)shared {
    return NL_ONCE([NLSPFollower new]);
}

- (instancetype)init {
    if ((self = [super init])) {
        _watchers = [NSMapTable weakToStrongObjectsMapTable];
        __weak typeof(self) weakSelf = self;
        [NSNotificationCenter.defaultCenter addObserverForName:UIWindowDidBecomeVisibleNotification object:nil queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(NSNotification *note) {
            NLSPFollower *follower = weakSelf;
            if ([follower nlWatched]) [follower wake];   // Control Center shown again: read at once, every watcher told
        }];
    }
    return self;
}

- (void)watch:(id)watcher changed:(void (^)(void))changed {
    [_watchers setObject:[changed copy] forKey:watcher];
    [self wake];
}

- (void)unwatch:(id)watcher {
    [_watchers removeObjectForKey:watcher];
    if (![self nlWatched]) [self nlStop];
}

// Anything watching that shows: a view out of a window, or in a hidden one
// (Control Center closed), does not keep it reading.
- (BOOL)nlWatched {
    for (id watcher in _watchers.keyEnumerator.allObjects) {
        if (![watcher isKindOfClass:UIView.class] || NLSPWindowShows(watcher)) return YES;
    }
    return NO;
}

- (void)wake {
    if (_timer || ![self nlWatched]) return;   // reading already, or nothing that shows wants it
    _prefs = NLReadPrefsNow();
    __weak typeof(self) weakSelf = self;
    _timer = [NSTimer scheduledTimerWithTimeInterval:kNLSPReadInterval repeats:YES block:^(NSTimer *timer) {
        NLSPFollower *follower = weakSelf;
        if (![follower nlWatched]) [follower nlStop];   // its watchers gone or out of sight
        else [follower nlReadSong];
    }];
    _infoObserver = [NSNotificationCenter.defaultCenter addObserverForName:@"kMRMediaRemoteNowPlayingInfoDidChangeNotification"
                                                                    object:nil queue:NSOperationQueue.mainQueue
                                                                usingBlock:^(NSNotification *note) { [weakSelf nlReadInfo]; }];
    [self nlReadSong];
    [self nlReadInfo];
}

- (void)nlStop {
    [_timer invalidate];
    _timer = nil;
    if (_infoObserver) [NSNotificationCenter.defaultCenter removeObserver:_infoObserver];
    _infoObserver = nil;
}

- (void)nlChanged {
    for (void (^changed)(void) in _watchers.objectEnumerator.allObjects) changed();
}

// Off the main queue (the first look for an app's container scans them all).
- (void)nlReadSong {
    NSString *bundleID = NLSpringBoardPlayingBundleID();
    NSUInteger generation = ++_readGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_async(NLSPQueue(), ^{
        NSDictionary *np = NLReadNowPlaying(bundleID);
        dispatch_async(dispatch_get_main_queue(), ^{
            NLSPFollower *follower = weakSelf;
            if (!follower || generation != follower->_readGeneration || (NLSame(np, follower->_np) && NLSame(bundleID, follower->_bundleID))) return;
            BOOL otherApp = !NLSame(bundleID, follower->_bundleID);
            follower->_np = np;
            follower->_bundleID = bundleID;
            if (otherApp) [follower nlReadInfo];
            [follower nlChanged];
        });
    });
}

- (void)nlReadInfo {
    __weak typeof(self) weakSelf = self;
    NLNowPlayingInfo(^(NSDictionary *info) {
        NLSPFollower *follower = weakSelf;
        if (!follower) return;
        follower->_info = info;
        [follower nlChanged];
    });
}

@end

// The lyrics as Apple Music shows them, in the room between the time and the
// transport row: every line in a column, the one being sung bright (lit as it
// is sung when the lyrics have word times) and the others dim and blurred,
// faded out at the edges; a new line scrolls the column up on a soft spring,
// each line a beat after the one above it. It watches what plays
// (NLSPFollower) while it is asked to.
@interface NLSPLyricsView : UIView
- (instancetype)initWithLook:(NLSPLyricsLook)look;
+ (CGFloat)heightOfRows:(NSInteger)rows look:(NLSPLyricsLook)look;   // `rows` one-row lines' room, at the sung line's place
+ (CGFloat)heightOfWholeRowsIn:(CGFloat)room look:(NLSPLyricsLook)look;   // as many as fit in `room` (0: not one)
@property (nonatomic, readonly) BOOL hasLines;   // the song has lyrics NowLyrics shows
@property (nonatomic, readonly, copy) NSString *songTitle, *songArtist;
@property (nonatomic, copy) void (^changed)(void);   // whether it has lines, or the song, changed
- (void)follow:(BOOL)follow;
@end

@interface CAFilter : NSObject
+ (instancetype)filterWithType:(NSString *)type;
@end

// A view's blur (Core Animation's gaussian blur filter, named "blur"), to
// `radius`, eased there when `animated`.
static void NLSPBlur(UIView *view, CGFloat radius, BOOL animated) {
    CALayer *layer = view.layer;
    NSArray *filters = [layer valueForKey:@"filters"];
    if (radius <= 0 && filters.count && !animated) {
        [layer setValue:nil forKey:@"filters"];   // sharp: no filter at all (one at 0 still renders it off screen, softer)
        return;
    }
    if (!filters.count) {
        if (radius <= 0) return;
        Class filterClass = NSClassFromString(@"CAFilter");
        id blur = [filterClass respondsToSelector:@selector(filterWithType:)] ? [filterClass filterWithType:@"gaussianBlur"] : nil;
        if (!blur) return;
        [blur setValue:@"blur" forKey:@"name"];
        [blur setValue:@0 forKey:@"inputRadius"];
        [layer setValue:@[blur] forKey:@"filters"];
    }
    NSNumber *from = [layer valueForKeyPath:@"filters.blur.inputRadius"];
    if (fabs(from.doubleValue - radius) < 0.01) return;
    [layer setValue:@(radius) forKeyPath:@"filters.blur.inputRadius"];
    if (!animated) return;
    CABasicAnimation *ease = [CABasicAnimation animationWithKeyPath:@"filters.blur.inputRadius"];
    ease.fromValue = from;
    ease.toValue = @(radius);
    ease.duration = kNLSPScrollDuration * 0.6;
    ease.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [CATransaction begin];
    [CATransaction setCompletionBlock:^{
        if (radius <= 0 && [[layer valueForKeyPath:@"filters.blur.inputRadius"] doubleValue] <= 0) [layer setValue:nil forKey:@"filters"];
    }];
    [layer addAnimation:ease forKey:@"nlspBlur"];
    [CATransaction commit];
}

// A label drawing its text kEdge in from each side, so it can be that much
// wider than the text and keep what reaches out of it.
@interface NLSPEdgeLabel : UILabel
@end

@implementation NLSPEdgeLabel
- (void)drawTextInRect:(CGRect)rect {
    [super drawTextInRect:CGRectInset(rect, kNLSPEdge, 0)];
}
@end

// One line, wrapped to the column's width: a bright copy over a dim one, the
// bright one shown as far as the line has been sung (word by word, each word
// lit across as it is sung, on the display's frames while it plays), all of
// it otherwise. Word by word each word is its own, where it is in the line,
// and grows and lifts a little as it lights, as in Apple Music (a word the
// line wraps inside of lights with the rest instead).
@interface NLSPLyricLineView : UIView
@property (nonatomic, readonly, copy) NSString *text;
- (instancetype)initWithText:(NSString *)text font:(UIFont *)font lift:(CGFloat)lift;
- (CGFloat)heightForWidth:(CGFloat)width;
- (void)setWords:(NLShownWords *)words;   // nil: the whole line lit
// Word by word: how far down the line the singing has got now (the foot of
// the row its latest started word is on); -1 for a line without word times
// (or not measured yet).
- (CGFloat)sungDepth;
@end

@implementation NLSPLyricLineView {
    UIFont *_font;
    CGFloat _lift;
    UILabel *_dim, *_lit;
    CAShapeLayer *_mask;
    NLShownWords *_words;
    CFTimeInterval _since;          // when the words' position was read
    NSArray<NSArray<NSValue *> *> *_wordRects;   // each word's glyphs, a rect per line it is on
    NSArray<UIView *> *_wordViews;               // word by word: each word on its own
    NSArray<CALayer *> *_wordMasks;              // and how much of its bright copy shows
    CGFloat _measuredWidth;
    CGFloat _heightWidth, _height;
    CADisplayLink *_link;
}

- (instancetype)initWithText:(NSString *)text font:(UIFont *)font lift:(CGFloat)lift {
    if ((self = [super initWithFrame:CGRectZero])) {
        _text = [text copy];
        _font = font;
        _lift = lift;
        self.userInteractionEnabled = NO;
        _dim = [self nlLabel];
        _dim.textColor = [UIColor colorWithWhite:1 alpha:kNLSPUnsungAlpha];
        _dim.hidden = YES;
        _lit = [self nlLabel];
        _lit.textColor = UIColor.whiteColor;
        _mask = [CAShapeLayer layer];
    }
    return self;
}

- (UILabel *)nlLabel {
    UILabel *label = [NLSPEdgeLabel new];
    label.font = _font;
    label.numberOfLines = 0;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.text = _text;
    [self addSubview:label];
    return label;
}

- (CGFloat)heightForWidth:(CGFloat)width {
    if (width != _heightWidth) {
        _heightWidth = width;
        _height = ceil([_text boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin
                                         attributes:@{NSFontAttributeName: _font} context:nil].size.height);
    }
    return _height;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _dim.frame = _lit.frame = CGRectInset(self.bounds, -kNLSPEdge, 0);   // their text over the line, room either side
    if (_words && self.bounds.size.width != _measuredWidth) {
        [self nlMeasure];
        [self nlBuildWords];
    }
    [self nlTick];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self nlRun];
}

- (void)setWords:(NLShownWords *)words {
    if (!words.texts.count && !_words) return;   // a line not sung, as it was
    BOOL same = words && _words && [words.texts isEqualToArray:_words.texts];
    _words = words.texts.count ? words : nil;
    _since = CACurrentMediaTime();
    if (!same) {
        for (UIView *word in _wordViews) [word removeFromSuperview];
        _wordViews = nil;
        _wordMasks = nil;
        _dim.hidden = _lit.hidden = NO;
    }
    _dim.hidden = !_words || _wordViews;
    _lit.layer.mask = _words ? _mask : nil;
    if (_words && !same) _measuredWidth = 0;
    [self setNeedsLayout];
    [self nlRun];
}

// Word by word with each word on one line: the words as views of their own
// (a dim copy, a bright one masked), over the line's place; the line's own
// copies hidden meanwhile.
- (void)nlBuildWords {
    for (UIView *word in _wordViews) [word removeFromSuperview];
    _wordViews = nil;
    _wordMasks = nil;
    NSUInteger count = MIN(_words.texts.count, _wordRects.count);
    for (NSUInteger i = 0; i < count; i++) {
        if (_wordRects[i].count > 1) return;   // wrapped inside: the whole line lights instead
    }
    NSMutableArray *views = [NSMutableArray array], *masks = [NSMutableArray array];
    for (NSUInteger i = 0; i < count; i++) {
        CGRect rect = _wordRects[i].count ? _wordRects[i].firstObject.CGRectValue : CGRectZero;
        UIView *word = [[UIView alloc] initWithFrame:rect];
        word.userInteractionEnabled = NO;
        for (int bright = 0; bright < 2; bright++) {
            UILabel *label = [NLSPEdgeLabel new];
            label.font = _font;
            label.text = _words.texts[i];
            label.textColor = bright ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:kNLSPUnsungAlpha];
            label.frame = CGRectInset(word.bounds, -kNLSPEdge, 0);
            [word addSubview:label];
            if (bright) {
                CALayer *mask = [CALayer layer];
                mask.backgroundColor = UIColor.blackColor.CGColor;
                mask.frame = CGRectMake(0, 0, 0, rect.size.height);
                label.layer.mask = mask;
                [masks addObject:mask];
            }
        }
        [self addSubview:word];
        [views addObject:word];
    }
    _wordViews = views;
    _wordMasks = masks;
    _dim.hidden = _lit.hidden = YES;
}

// The display's frames only while a line plays word by word and shows (its
// words told again as the window shows: NLSPFollower's wake).
- (void)nlRun {
    BOOL run = _words && _words.rate > 0 && NLSPWindowShows(self);
    if (run && !_link) {
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(nlTick)];
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    } else if (!run) {
        [_link invalidate];
        _link = nil;
    }
}

// Each word's glyphs as the label lays the line out (the same font, width and wrapping).
- (void)nlMeasure {
    CGFloat width = self.bounds.size.width;
    _measuredWidth = width;
    NSTextStorage *storage = [[NSTextStorage alloc] initWithString:_text attributes:@{NSFontAttributeName: _font}];
    NSLayoutManager *layout = [NSLayoutManager new];
    NSTextContainer *container = [[NSTextContainer alloc] initWithSize:CGSizeMake(width, CGFLOAT_MAX)];
    container.lineFragmentPadding = 0;
    [layout addTextContainer:container];
    [storage addLayoutManager:layout];
    [layout ensureLayoutForTextContainer:container];
    NSMutableArray *words = [NSMutableArray array];
    NSUInteger at = 0, length = _text.length;
    for (NSString *word in _words.texts) {
        NSRange range = NSMakeRange(MIN(at, length), MIN(word.length, length - MIN(at, length)));
        at += word.length;
        NSMutableArray<NSValue *> *rects = [NSMutableArray array];
        if (range.length) {
            NSRange glyphs = [layout glyphRangeForCharacterRange:range actualCharacterRange:NULL];
            [layout enumerateEnclosingRectsForGlyphRange:glyphs withinSelectedGlyphRange:NSMakeRange(NSNotFound, 0) inTextContainer:container
                                              usingBlock:^(CGRect rect, BOOL *stop) { [rects addObject:[NSValue valueWithCGRect:rect]]; }];
        }
        [words addObject:rects];
    }
    _wordRects = words;
}

- (CGFloat)sungDepth {
    NSUInteger count = MIN(_words.starts.count, _wordRects.count);
    if (!_words || !count || _measuredWidth != self.bounds.size.width) return -1;
    double now = NLClockAt(_words.position, _since, _words.rate);
    CGFloat depth = 0;
    for (NSUInteger i = 0; i < count; i++) {
        if (i > 0 && _words.starts[i].doubleValue > now) break;
        NSArray<NSValue *> *rects = _wordRects[i];
        NSValue *row = now >= _words.ends[i].doubleValue ? rects.lastObject : rects.firstObject;   // a word wrapped inside: its rows in turn
        if (row) depth = MAX(depth, CGRectGetMaxY(row.CGRectValue));
    }
    return depth;
}

// The bright copy shown as far as the line has been sung now; word by word,
// each word grown and lifted as far as it is lit.
- (void)nlTick {
    if (!_words) return;
    if (_link && !NLSPWindowShows(self)) {
        [self nlRun];   // its window hidden: stopped
        return;
    }
    double now = NLClockAt(_words.position, _since, _words.rate);
    if (_wordViews) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        for (NSUInteger i = 0; i < _wordViews.count; i++) {
            double start = _words.starts[i].doubleValue, end = _words.ends[i].doubleValue;
            CGFloat lit = now <= start ? 0 : (end > start ? MIN(1, (now - start) / (end - start)) : 1);
            CALayer *mask = _wordMasks[i];
            // Its text from kNLSPEdge in: the room before it once it lights, after it once all lit.
            CGFloat shown = lit > 0 ? kNLSPEdge + _wordViews[i].bounds.size.width * lit + (lit >= 1 ? kNLSPEdge : 0) : 0;
            mask.frame = CGRectMake(0, 0, shown, mask.frame.size.height);
            CGFloat eased = 1 - (1 - lit) * (1 - lit);
            CGFloat grow = 1 + kNLSPWordGrow * eased;
            _wordViews[i].transform = CGAffineTransformScale(CGAffineTransformMakeTranslation(0, -_lift * eased), grow, grow);
        }
        [CATransaction commit];
        if (_words.rate > 0 && _words.ends.count && now > _words.ends.lastObject.doubleValue) {
            [_link invalidate];   // all of it lit
            _link = nil;
        }
        return;
    }
    UIBezierPath *path = [UIBezierPath bezierPath];
    NSUInteger count = MIN(_words.texts.count, _wordRects.count);
    for (NSUInteger i = 0; i < count; i++) {
        double start = _words.starts[i].doubleValue, end = _words.ends[i].doubleValue;
        if (now <= start) break;
        CGFloat total = 0;
        for (NSValue *rect in _wordRects[i]) total += rect.CGRectValue.size.width;
        CGFloat lit = total * (end > start ? MIN(1, (now - start) / (end - start)) : 1);
        for (NSValue *value in _wordRects[i]) {
            CGRect rect = value.CGRectValue;
            CGFloat width = MIN(rect.size.width, lit);
            if (width <= 0) break;
            // In the bright copy's own room (kNLSPEdge in), the room before a line's first word lit with it.
            CGFloat before = rect.origin.x < 1 ? kNLSPEdge : 0;
            [path appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(rect.origin.x + kNLSPEdge - before, rect.origin.y, width + before, rect.size.height)]];
            lit -= width;
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _mask.path = path.CGPath;
    [CATransaction commit];
    if (_words.rate > 0 && _words.ends.count && now > _words.ends.lastObject.doubleValue) {
        [_link invalidate];   // all of it lit
        _link = nil;
    }
}

@end

// Apple Music's dots for a pause in the singing: three dots lighting one
// after another as the pause goes on, the three breathing a little while it
// plays (still while it is paused, the breath let go of).
@interface NLSPGapDotsView : UIView
- (instancetype)initWithSize:(CGFloat)size gap:(CGFloat)gap;
- (void)showGapFrom:(NSTimeInterval)start to:(NSTimeInterval)end position:(NSTimeInterval)position rate:(double)rate;
@end

@implementation NLSPGapDotsView {
    UIView *_group;
    NSArray<UIView *> *_dots;
    NSTimeInterval _start, _end, _position;
    double _rate;
    CGFloat _size, _gap;
    CFTimeInterval _since, _breathSince;
    CADisplayLink *_link;
}

- (instancetype)initWithSize:(CGFloat)size gap:(CGFloat)gap {
    if ((self = [super initWithFrame:CGRectZero])) {
        _size = size;
        _gap = gap;
        self.userInteractionEnabled = NO;
        _group = [UIView new];
        _group.layer.anchorPoint = CGPointMake(0, 0.5);   // breathes from its start, where the lines line up
        [self addSubview:_group];
        NSMutableArray *dots = [NSMutableArray array];
        for (int i = 0; i < 3; i++) {
            UIView *dot = [UIView new];
            dot.backgroundColor = UIColor.whiteColor;
            dot.layer.cornerRadius = size / 2;
            dot.frame = CGRectMake(i * (size + gap), 0, size, size);
            [_group addSubview:dot];
            [dots addObject:dot];
        }
        _dots = dots;
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _group.bounds = CGRectMake(0, 0, 3 * _size + 2 * _gap, _size);
    _group.center = CGPointMake(0, round(self.bounds.size.height / 2));
    [self nlTick];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self nlRun];
}

- (void)setHidden:(BOOL)hidden {
    [super setHidden:hidden];
    [self nlRun];
}

- (void)showGapFrom:(NSTimeInterval)start to:(NSTimeInterval)end position:(NSTimeInterval)position rate:(double)rate {
    if (rate != 0 && _rate == 0) _breathSince = CACurrentMediaTime();   // breathing from its rest
    _start = start;
    _end = end;
    _position = position;
    _rate = rate;
    _since = CACurrentMediaTime();
    [self nlRun];
    [self nlTick];
    if (rate == 0 && !CGAffineTransformIsIdentity(_group.transform)) {
        UIView *group = _group;
        [UIView animateWithDuration:0.4 delay:0 options:UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionCurveEaseOut
                         animations:^{ group.transform = CGAffineTransformIdentity; } completion:nil];
    }
}

- (void)nlRun {
    BOOL run = NLSPWindowShows(self) && !self.hidden && _rate != 0;
    if (run && !_link) {
        _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(nlTick)];
        [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    } else if (!run) {
        [_link invalidate];
        _link = nil;
    }
}

- (void)nlTick {
    if (_link && !NLSPWindowShows(self)) {
        [self nlRun];   // its window hidden: stopped
        return;
    }
    double now = NLClockAt(_position, _since, _rate);
    double done = _end > _start ? MIN(MAX((now - _start) / (_end - _start), 0), 1) : 0;
    for (NSUInteger i = 0; i < _dots.count; i++) {
        CGFloat lit = MIN(MAX(done * _dots.count - i, 0), 1);
        _dots[i].alpha = kNLSPOtherAlpha + (1 - kNLSPOtherAlpha) * lit;
    }
    if (_rate == 0) return;
    CGFloat breath = 1 + kNLSPDotBreath * sin((CACurrentMediaTime() - _breathSince) * 2 * M_PI / kNLSPDotBreathPeriod);
    _group.transform = CGAffineTransformMakeScale(breath, breath);
}

@end

@implementation NLSPLyricsView {
    NLSPLyricsLook _look;
    UIFont *_font;
    UIView *_column;
    CAGradientLayer *_fade;
    NSArray<NLLyricLine *> *_lines;                  // the lyrics the column is made from
    NSArray<NLSPLyricLineView *> *_lineViews;        // its lines with words, in order
    NSArray<NSNumber *> *_lineIndexes;               // each one's index in _lines
    NSInteger _active;                               // the sung one's (between lines the last one), -1 before the first
    NLSPGapDotsView *_dots;                          // a long pause: Apple Music's dots after the line before it
    BOOL _pause;
    BOOL _following;
    // A sung line taller than the room under its place: the column moved up
    // this far within it as it is sung (NLSPLyricsView nlFollowLongLine),
    // the song's clock and the line's time for that.
    CGFloat _shift;
    NSTimer *_shiftTimer;
    NSTimeInterval _position, _lineStart, _lineEnd;
    CFTimeInterval _since;
    double _rate;
}

+ (CGFloat)heightOfRows:(NSInteger)rows look:(NLSPLyricsLook)look {
    CGFloat row = ceil([UIFont systemFontOfSize:look.size weight:UIFontWeightBold].lineHeight);
    return ceil((row * rows + look.gap * (rows - 1)) / (1 - look.anchor));
}

+ (CGFloat)heightOfWholeRowsIn:(CGFloat)room look:(NLSPLyricsLook)look {
    CGFloat height = 0;
    for (NSInteger rows = 1; [self heightOfRows:rows look:look] <= room; rows++) height = [self heightOfRows:rows look:look];
    return height;
}

- (instancetype)initWithLook:(NLSPLyricsLook)look {
    if ((self = [super initWithFrame:CGRectZero])) {
        _look = look;
        _font = [UIFont systemFontOfSize:look.size weight:UIFontWeightBold];
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        _column = [UIView new];
        [self addSubview:_column];
        _dots = [[NLSPGapDotsView alloc] initWithSize:look.dotSize gap:look.dotGap];
        _dots.hidden = YES;
        [_column addSubview:_dots];
        _fade = [CAGradientLayer layer];
        _fade.colors = @[(id)UIColor.clearColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.blackColor.CGColor, (id)UIColor.clearColor.CGColor];
        _fade.locations = @[@0, @(look.fadeTop), @(look.fadeBottom), @1];
        self.layer.mask = _fade;
        _active = -1;
    }
    return self;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) [self follow:NO];
    else if (_following) [NLSPFollower.shared wake];   // made off screen, shown now
}

- (void)follow:(BOOL)follow {
    if (follow == _following) {
        if (follow) [NLSPFollower.shared wake];
        return;
    }
    _following = follow;
    NLSPFollower *follower = NLSPFollower.shared;
    if (!follow) {
        [follower unwatch:self];
        [_shiftTimer invalidate];
        _shiftTimer = nil;
        return;
    }
    __weak typeof(self) weakSelf = self;
    [follower watch:self changed:^{ [weakSelf nlUpdate]; }];
    [self nlUpdate];
}

- (void)nlUpdate {
    NLSPFollower *follower = NLSPFollower.shared;
    NSDictionary *np = follower.np;
    NLSungLines *sung = NLSungLinesNow(np, follower.info, follower.prefs, 1);
    NSString *title = NLString(np, NL_NP_TITLE), *artist = NLString(np, NL_NP_ARTIST);
    BOOL hasLines = sung.lines.count > 0;
    BOOL changed = hasLines != _hasLines || !NLSame(title, _songTitle) || !NLSame(artist, _songArtist);
    _hasLines = hasLines;
    _songTitle = title;
    _songArtist = artist;
    if (hasLines) [self nlShow:sung];
    if (changed && self.changed) self.changed();
}

// The column made again for other lyrics (another song, or looked up again).
- (void)nlBuild:(NSArray<NLLyricLine *> *)lines {
    for (UIView *view in _lineViews) [view removeFromSuperview];
    NSMutableArray *views = [NSMutableArray array], *indexes = [NSMutableArray array];
    [lines enumerateObjectsUsingBlock:^(NLLyricLine *line, NSUInteger i, BOOL *stop) {
        if (!line.text.length) return;
        NLSPLyricLineView *view = [[NLSPLyricLineView alloc] initWithText:line.text font:self->_font lift:self->_look.lift];
        view.alpha = kNLSPOtherAlpha;
        NLSPBlur(view, self->_look.blur, NO);
        [self->_column addSubview:view];
        [views addObject:view];
        [indexes addObject:@(i)];
    }];
    _lines = lines;
    _lineViews = views;
    _lineIndexes = indexes;
    _active = -1;
    _pause = NO;
    [self nlPlace:NO];
}

- (void)nlShow:(NLSungLines *)sung {
    if (sung.lines != _lines) [self nlBuild:sung.lines];
    NSInteger active = -1;
    for (NSInteger i = 0; i < (NSInteger)_lineIndexes.count && _lineIndexes[i].integerValue <= sung.index; i++) active = i;
    BOOL between = sung.line.length == 0;
    // A pause long enough for Apple Music's dots: from where the line before
    // ended (or the empty line marking it, or the song's start) to the next.
    BOOL pause = NO;
    if (between && active + 1 < (NSInteger)_lineViews.count) {
        NLLyricLine *next = _lines[_lineIndexes[active + 1].integerValue];
        NLLyricLine *mark = sung.index >= 0 && sung.index < (NSInteger)_lines.count ? _lines[sung.index] : nil;
        NLLyricLine *before = active >= 0 ? _lines[_lineIndexes[active].integerValue] : nil;
        NSTimeInterval start = !mark.text.length && mark ? mark.start : (before ? (before.end > 0 ? before.end : before.start) : 0);
        pause = next.start - start >= kNLSPPauseLeast && sung.position < next.start - kNLSPPauseEndsEarly;
        if (pause) [_dots showGapFrom:start to:next.start position:sung.position rate:sung.rate];
    }
    BOOL moved = active != _active || pause != _pause;
    BOOL scroll = NLSPWindowShows(self) && !self.hidden && (_active >= 0 || _pause);
    if (active != _active) _shift = 0;   // another line: from its top
    _active = active;
    _pause = pause;
    _position = sung.position;
    _rate = sung.rate;
    _since = CACurrentMediaTime();
    if (active >= 0) {
        NLLyricLine *line = _lines[_lineIndexes[active].integerValue];
        NLLyricLine *next = active + 1 < (NSInteger)_lineIndexes.count ? _lines[_lineIndexes[active + 1].integerValue] : nil;
        _lineStart = line.start;
        _lineEnd = line.end > line.start ? line.end : (next ? next.start : line.start + 5);
    }
    for (NSInteger i = 0; i < (NSInteger)_lineViews.count; i++) {
        if (between && i == active) continue;   // sung: kept as it ended, all lit, until the next
        [_lineViews[i] setWords:i == active ? sung.words : nil];
    }
    if (moved) [self nlPlace:scroll];
    else [self nlStyle:NO];
    [self nlFollowLongLine];
}

// The sung line too tall for the room under its place (down to where the
// fade begins): the column moved up within it a row at a time as it is
// sung, a row ahead of the singing kept in sight; by its words' rows word by
// word, evenly over its time otherwise; at its end once sung. Read again on
// a timer while such a line plays.
- (CGFloat)nlLongLineShift {
    CGFloat most = [self nlLongLineMost], row = ceil(_font.lineHeight);
    if (most <= 0 || row <= 0) return 0;
    NLSPLyricLineView *view = _lineViews[_active];
    CGFloat height = [view heightForWidth:[self nlTextWidth]], room = height - most;
    CGFloat reached = [view sungDepth];
    if (reached < 0) {
        double now = NLClockAt(_position, _since, _rate);
        double sung = _lineEnd > _lineStart ? MAX(0, MIN(1, (now - _lineStart) / (_lineEnd - _lineStart))) : 1;
        NSInteger rows = MAX(1, (NSInteger)round(height / row));
        reached = MIN(rows, (NSInteger)floor(sung * rows) + 1) * row;   // the foot of the row it is on
    }
    CGFloat shift = ceil(MAX(0, reached + row - room) / row) * row;   // whole rows, the top one whole
    return MIN(most, shift);
}

- (void)nlFollowLongLine {
    CGFloat shift = [self nlLongLineShift];
    if (fabs(shift - _shift) > 0.5) {
        _shift = shift;
        [self nlPlace:NLSPWindowShows(self) && !self.hidden];
    }
    BOOL run = shift < [self nlLongLineMost] && _rate > 0 && NLSPWindowShows(self) && !self.hidden && _following;
    if (run && !_shiftTimer) {
        __weak typeof(self) weakSelf = self;
        _shiftTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) { [weakSelf nlFollowLongLine]; }];
    } else if (!run) {
        [_shiftTimer invalidate];
        _shiftTimer = nil;
    }
}

// How far the sung line can move up (0: it fits).
- (CGFloat)nlLongLineMost {
    if (_pause || _active < 0 || _active >= (NSInteger)_lineViews.count) return 0;
    if (self.bounds.size.height < 1 || [self nlTextWidth] < 1) return 0;   // no size yet: nothing to move by
    CGFloat height = [_lineViews[_active] heightForWidth:[self nlTextWidth]];
    return MAX(0, height - (floor(self.bounds.size.height * _look.fadeBottom) - [self nlAnchorY]));
}

// The lines' width (the column's, its room either side kept clear), and
// where the sung one's top goes (the look's anchor of the height).
- (CGFloat)nlTextWidth {
    return self.bounds.size.width - kNLSPEdge * 2;
}
- (CGFloat)nlAnchorY {
    return round(self.bounds.size.height * _look.anchor);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _fade.frame = self.bounds;
    _column.frame = self.bounds;
    // A long sung line's move for this size: worked out before the column had
    // one (its lyrics come while it is still hidden) it pushed the line out of
    // sight. Its timer too, now that the column shows.
    _shift = [self nlLongLineShift];
    [self nlPlace:NO];
    [self nlFollowLongLine];
}

// The lines in their places and looks, moving there as a scroll when
// `animated`: the sung one's top (in a long pause the dots after the line
// before it; the first line before any is sung) at the look's anchor of the
// height, the others above and below it, each a beat after the one above
// from the one above it down; those far off hidden.
- (void)nlPlace:(BOOL)animated {
    CGFloat width = [self nlTextWidth];
    if (width < 1) return;
    NSMutableArray<UIView *> *rows = [NSMutableArray array];
    NSMutableArray<NSNumber *> *heights = [NSMutableArray array];
    NSInteger anchor = 0, count = (NSInteger)_lineViews.count;
    for (NSInteger i = 0; i <= count; i++) {
        if (_pause && i == _active + 1) {
            anchor = rows.count;
            [rows addObject:_dots];
            [heights addObject:@(_look.dotRow)];
        }
        if (i == count) break;
        if (!_pause && i == MAX(_active, 0)) anchor = rows.count;
        [rows addObject:_lineViews[i]];
        [heights addObject:@([_lineViews[i] heightForWidth:width])];
    }
    CGFloat anchorY = [self nlAnchorY] - (_pause ? 0 : _shift);   // a long sung line moved up within
    NSMutableArray<NSNumber *> *tops = [NSMutableArray arrayWithCapacity:rows.count];
    for (NSInteger r = 0; r < (NSInteger)rows.count; r++) [tops addObject:@0];
    CGFloat y = anchorY;
    for (NSInteger r = anchor; r < (NSInteger)rows.count; r++) {
        tops[r] = @(y);
        y += heights[r].doubleValue + _look.gap;
    }
    y = anchorY;
    for (NSInteger r = anchor - 1; r >= 0; r--) {
        y -= heights[r].doubleValue + _look.gap;
        tops[r] = @(y);
    }
    for (NSInteger r = 0; r < (NSInteger)rows.count; r++) {
        UIView *view = rows[r];
        CGRect frame = CGRectMake(kNLSPEdge, tops[r].doubleValue, width, heights[r].doubleValue);
        if (labs(r - anchor) > kNLSPShownAround) {
            view.hidden = YES;
            view.frame = frame;
            continue;
        }
        BOOL appearing = view.hidden;
        view.hidden = NO;
        if (!animated || appearing) {
            [UIView performWithoutAnimation:^{
                if (view == self->_dots && !animated) {
                    [view.layer removeAllAnimations];   // a fade out still going (it would hide them as it ends)
                    view.alpha = 1;
                }
                view.transform = CGAffineTransformIdentity;
                view.frame = frame;
                if (view == self->_dots && appearing && animated) {
                    view.alpha = 0;   // the dots come in growing (below)
                    view.transform = CGAffineTransformMakeScale(0.6, 0.6);
                }
            }];
            continue;
        }
        NSTimeInterval delay = MAX(0, r - anchor + 1) * kNLSPScrollStagger;
        [UIView animateWithDuration:kNLSPScrollDuration delay:delay usingSpringWithDamping:kNLSPScrollDamping initialSpringVelocity:0
                            options:UIViewAnimationOptionBeginFromCurrentState animations:^{ view.frame = frame; } completion:nil];
    }
    // The dots out of the column when there is no pause: shrinking away where they were.
    if (!_pause && !_dots.hidden) {
        NLSPGapDotsView *dots = _dots;
        if (animated) {
            [UIView animateWithDuration:kNLSPScrollDuration * 0.4 animations:^{
                dots.alpha = 0;
                dots.transform = CGAffineTransformMakeScale(0.6, 0.6);
            } completion:^(BOOL finished) {
                if (finished && !self->_pause) dots.hidden = YES;   // not when a pause has shown them again meanwhile
                dots.transform = CGAffineTransformIdentity;
            }];
        } else {
            dots.hidden = YES;
        }
    } else if (_pause && (_dots.alpha < 1 || !CGAffineTransformIsIdentity(_dots.transform))) {
        NLSPGapDotsView *dots = _dots;
        [UIView animateWithDuration:animated ? kNLSPScrollDuration * 0.6 : 0 animations:^{
            dots.alpha = 1;
            dots.transform = CGAffineTransformIdentity;
        }];
    }
    [self nlStyle:animated];
}

// The sung line bright and sharp (still lit after it ends, until the next;
// dim with the rest in a long pause), the others dim and blurred.
- (void)nlStyle:(BOOL)animated {
    for (NSInteger i = 0; i < (NSInteger)_lineViews.count; i++) {
        NLSPLyricLineView *view = _lineViews[i];
        if (view.hidden) continue;
        BOOL sung = i == _active && !_pause;
        CGFloat alpha = sung ? 1 : kNLSPOtherAlpha;
        NLSPBlur(view, sung ? 0 : _look.blur, animated);
        if (view.alpha == alpha) continue;
        if (!animated) {
            view.alpha = alpha;
            continue;
        }
        [UIView animateWithDuration:kNLSPScrollDuration * 0.6 delay:0 options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{ view.alpha = alpha; } completion:nil];
    }
}

@end

#pragma mark - Lyrics in the player

static char kNLSPLyricsKey, kNLSPUprightLyricsKey, kNLSPClosedLyricsKey, kNLSPTallLyricsKey, kNLSPSongKey, kNLSPAppleTitleKey, kNLSPAppleSubtitleKey;

// The card's title row with the song's own title and artist (`title` nil:
// MediaControls' again, which is the line being sung while NowLyrics puts it
// there). The label's setters put the song's in place of what they are given.
static void NLSPShowSongTitle(MRUNowPlayingView *nowPlayingView, NSString *title, NSString *artist) {
    MRUNowPlayingLabelView *label = [nowPlayingView respondsToSelector:@selector(headerView)] ? nowPlayingView.headerView.labelView : nil;
    if (![label respondsToSelector:@selector(setTitle:)] || ![label respondsToSelector:@selector(setSubtitle:)]) return;
    NSArray<NSString *> *song = title.length ? @[title, artist ?: @""] : nil;
    if (NLSame(objc_getAssociatedObject(label, &kNLSPSongKey), song)) return;
    objc_setAssociatedObject(label, &kNLSPSongKey, song, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NLSP_LOG(@"title %@ (player %.0fx%.0f state %lld)", song ? [song componentsJoinedByString:@" / "] : @"theirs",
             nowPlayingView.bounds.size.width, nowPlayingView.bounds.size.height, NLSPOwnerView(nowPlayingView).state);
    NSString *theirTitle = objc_getAssociatedObject(label, &kNLSPAppleTitleKey), *theirSubtitle = objc_getAssociatedObject(label, &kNLSPAppleSubtitleKey);
    if (song || theirTitle) label.title = theirTitle;
    if (song || theirSubtitle) label.subtitle = theirSubtitle;
}

// The output's name over the song (the label's route line) away while the
// open player shows NowLyrics' lyrics, the song and the lyrics taking its
// room; MediaControls' own choice again after (what it asks kept aside,
// -setShowRoute:). Applied before MediaControls lays the header out, as
// the last layout left it, the change itself laid out again at once.
static char kNLSPNoRouteKey, kNLSPAskedRouteKey;
static void NLSPHideRoute(MRUNowPlayingView *player, BOOL hide) {
    MRUNowPlayingLabelView *label = [player respondsToSelector:@selector(headerView)] ? player.headerView.labelView : nil;
    if (![label respondsToSelector:@selector(setShowRoute:)] || hide == [objc_getAssociatedObject(label, &kNLSPNoRouteKey) boolValue]) return;
    objc_setAssociatedObject(label, &kNLSPNoRouteKey, @(hide), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NSNumber *asked = objc_getAssociatedObject(label, &kNLSPAskedRouteKey) ?: @(label.showRoute);
    label.showRoute = asked.boolValue;   // through its hook, which leaves it off while hidden
    [player setNeedsLayout];
}

// The open player with lyrics. On its side: the volume and the transport row
// lower, near the card's bottom, and the lyrics in the room between them and
// the time. Upright (the player, not the outputs) as iOS 26's tall player
// with lyrics (NLSP26LayOut): the cover and the song as they are, the lyrics
// under the song (at 3×4's size, NLSPPlaceClosedLyrics), the time bar and
// the buttons (the output button at their end as ever) where 3×4 has them,
// in the volume's place. YES: the song's own title over them. Otherwise
// MediaControls' layout as it is.
static BOOL NLSPPlaceUprightLyrics(MRUNowPlayingView *nowPlayingView, NLSPLyricsView *lyrics);
static void NLSPGiveBackVolume(MRUNowPlayingView *nowPlayingView);

// A placement's lyrics column on `host` (under `key`: one per placement, each
// at its look), made the first time, hidden until placed. When the song's
// lyrics come or go, `relayout` (`host` or a view whose layout places it)
// laid out again on a spring, its rows making room for them or taking it back.
static NLSPLyricsView *NLSPColumn(UIView *host, const void *key, NLSPLyricsLook look, UIView *relayout) {
    NLSPLyricsView *lyrics = objc_getAssociatedObject(host, key);
    if (lyrics) return lyrics;
    lyrics = [[NLSPLyricsView alloc] initWithLook:look];
    lyrics.hidden = YES;
    objc_setAssociatedObject(host, key, lyrics, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host addSubview:lyrics];
    __weak UIView *weakHost = host, *weakRelayout = relayout ?: host;
    lyrics.changed = ^{
        UIView *changed = weakHost, *outer = weakRelayout;
        [changed setNeedsLayout];
        [outer setNeedsLayout];
        [UIView animateWithDuration:0.4 delay:0 usingSpringWithDamping:1 initialSpringVelocity:0
                            options:UIViewAnimationOptionAllowUserInteraction animations:^{ [outer layoutIfNeeded]; } completion:nil];
    };
    return lyrics;
}

// A column in and out with the player's rows, `by` the row it is placed by.
// In (opening, another layout, the song's lyrics come): in an animation
// (MediaControls' moving its rows, or the column's own relayout) from where
// that row shows now to `frame`, moving and fading in with it; outside one,
// in place at once and faded in. Out (closing, another layout, a song
// without lyrics): faded as it moves with that row, in the animation running
// when there is one, hidden once gone.
static const NSTimeInterval kNLSPLyricsFade = 0.3, kNLSPLyricsFadeDelay = 0.2;
static char kNLSPByKey, kNLSPByOffsetKey;
static void NLSPShowLyricsAt(NLSPLyricsView *lyrics, CGRect frame, UIView *by) {
    objc_setAssociatedObject(lyrics, &kNLSPByKey, by, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(lyrics, &kNLSPByOffsetKey, @(CGRectGetMinY(frame) - CGRectGetMinY(by.frame)), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (!lyrics.hidden) {
        lyrics.frame = frame;
        if (lyrics.alpha < 1) {   // back while still going
            [UIView animateWithDuration:kNLSPLyricsFade delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{ lyrics.alpha = 1; } completion:nil];
        }
        return;
    }
    BOOL moving = UIView.inheritedAnimationDuration > 0;
    CALayer *shown = by.layer.presentationLayer;
    CGRect start = frame;
    if (moving && shown) start.origin.y = CGRectGetMinY(shown.frame) + CGRectGetMinY(frame) - CGRectGetMinY(by.frame);
    [UIView performWithoutAnimation:^{
        lyrics.frame = start;
        lyrics.alpha = 0;
        lyrics.hidden = NO;
        [lyrics layoutIfNeeded];   // its lines in place in it, not moving there
    }];
    if (moving) {
        lyrics.frame = frame;   // in the animation running: with its row
        lyrics.alpha = 1;
        return;
    }
    [UIView animateWithDuration:kNLSPLyricsFade delay:kNLSPLyricsFadeDelay
                        options:UIViewAnimationOptionOverrideInheritedDuration | UIViewAnimationOptionOverrideInheritedCurve |
                                UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction
                     animations:^{ lyrics.alpha = 1; } completion:nil];
}
static void NLSPLetLyricsGo(NLSPLyricsView *lyrics) {
    if (!lyrics || lyrics.hidden) return;
    UIView *by = objc_getAssociatedObject(lyrics, &kNLSPByKey);
    NSNumber *offset = objc_getAssociatedObject(lyrics, &kNLSPByOffsetKey);
    if (!lyrics.window || !by || !offset) {
        lyrics.hidden = YES;
        return;
    }
    CGRect frame = lyrics.frame;
    frame.origin.y = CGRectGetMinY(by.frame) + offset.doubleValue;
    [UIView animateWithDuration:kNLSPLyricsFade delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        lyrics.frame = frame;
        lyrics.alpha = 0;
    } completion:^(BOOL finished) {
        if (lyrics.alpha > 0.01) return;   // shown again meanwhile
        lyrics.hidden = YES;
        lyrics.alpha = 1;
    }];
}

// The columns on `host` of the placements in `keys` other than `kept` (NULL:
// all of them) stopped and let go.
static void NLSPPutAwayColumns(UIView *host, const void *const *keys, size_t count, const void *kept) {
    for (size_t i = 0; i < count; i++) {
        if (keys[i] == kept) continue;
        NLSPLyricsView *away = objc_getAssociatedObject(host, keys[i]);
        [away follow:NO];
        NLSPLetLyricsGo(away);
    }
}

static BOOL NLSPPlaceLyrics(MRUNowPlayingView *nowPlayingView) {
    MRUControlCenterView *view = NLSPOwnerView(nowPlayingView);
    UIResponder *next = nowPlayingView.nextResponder;
    MRUNowPlayingViewController *nowPlaying = [next isKindOfClass:objc_getClass("MRUNowPlayingViewController")] ? (MRUNowPlayingViewController *)next : nil;
    BOOL sideways = view.bounds.size.width > view.bounds.size.height;
    BOOL wanted = view && nowPlaying && gNLSPEnabled && gNLSPOpenLyrics && view.state == kNLSPPlayerState && !NLSPIsClosed(view) &&
                  (nowPlaying.layout == kNLSPPlayerLayout || (sideways && nowPlaying.layout == kNLSPOutputsLayout)) &&
                  [nowPlayingView respondsToSelector:@selector(timeControlsView)] && [nowPlayingView respondsToSelector:@selector(volumeControlsView)] &&
                  [nowPlayingView respondsToSelector:@selector(artworkView)] && [nowPlayingView respondsToSelector:@selector(headerView)];
    const void *columns[] = {&kNLSPLyricsKey, &kNLSPUprightLyricsKey};   // a column each, at its size
    const void *key = columns[sideways ? 0 : 1];
    NLSPPutAwayColumns(nowPlayingView, columns, sizeof(columns) / sizeof(*columns), wanted ? key : NULL);
    if (!wanted || sideways) NLSPGiveBackVolume(nowPlayingView);   // only the upright one takes it
    if (!wanted) return NO;
    NLSPLyricsView *lyrics = NLSPColumn(nowPlayingView, key, sideways ? kNLSPSidewaysLook : kNLSPTallLook, nil);
    [lyrics follow:YES];
    if (!sideways) return NLSPPlaceUprightLyrics(nowPlayingView, lyrics);
    UIView *time = nowPlayingView.timeControlsView, *transport = nowPlayingView.transportControlsView, *volume = nowPlayingView.volumeControlsView;
    CGFloat volumeTop = nowPlayingView.bounds.size.height - volume.bounds.size.height - kNLSPBottomInset;
    CGFloat transportTop = volumeTop - transport.bounds.size.height + kNLSPRowsOverlap;
    CGFloat top = CGRectGetMaxY(time.frame) + 2, bottom = transportTop + 4;
    if (!lyrics.hasLines || time.hidden || time.alpha < 0.01 || transport.hidden || bottom - top < [NLSPLyricsView heightOfRows:1 look:kNLSPSidewaysLook]) {
        NLSPLetLyricsGo(lyrics);
        return NO;
    }
    CGRect row = volume.frame;
    row.origin.y = volumeTop;
    volume.frame = row;
    row = transport.frame;
    row.origin.y = transportTop;
    transport.frame = row;
    NLSPShowLyricsAt(lyrics, CGRectMake(time.frame.origin.x - kNLSPEdge, top, time.frame.size.width + kNLSPEdge * 2, bottom - top), time);   // its text in line with the time
    return YES;
}

// The volume taken away for them (its alpha 0): MediaControls' own visibility
// back once they go.
static char kNLSPUprightVolumeKey;
static void NLSPGiveBackVolume(MRUNowPlayingView *nowPlayingView) {
    if (!objc_getAssociatedObject(nowPlayingView, &kNLSPUprightVolumeKey)) return;
    objc_setAssociatedObject(nowPlayingView, &kNLSPUprightVolumeKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [nowPlayingView updateVisibility];
}
static BOOL NLSPPlaceUprightLyrics(MRUNowPlayingView *nowPlayingView, NLSPLyricsView *lyrics) {
    UIView *header = nowPlayingView.headerView, *time = nowPlayingView.timeControlsView;
    UIView *transport = nowPlayingView.transportControlsView, *volume = nowPlayingView.volumeControlsView;
    // The time bar and the buttons where 3×4 has them; the lyrics between the
    // song and the time bar in whole rows (one cut by the fade would sit on the
    // time bar), as many as fit, the room left over above them up to 3×4's
    // gap under its cover.
    NLSPFootRows foot = NLSPFootRowsIn(nowPlayingView.bounds.size.height);
    CGFloat songFoot = CGRectGetMaxY(header.frame), room = foot.roomFoot - songFoot - kNLSPLeastGap;
    CGFloat height = [NLSPLyricsView heightOfWholeRowsIn:room look:kNLSPTallLook];
    if (!lyrics.hasLines || !header || time.hidden || time.alpha < 0.01 || transport.hidden || height <= 0) {
        NLSPLetLyricsGo(lyrics);
        NLSPGiveBackVolume(nowPlayingView);
        return NO;
    }
    CGRect row = transport.frame;
    row.origin.y = round(foot.glyphsY - row.size.height / 2);
    transport.frame = row;
    row = time.frame;
    row.origin.y = round(foot.timeY - row.size.height / 2);
    time.frame = row;
    volume.alpha = 0;
    objc_setAssociatedObject(nowPlayingView, &kNLSPUprightVolumeKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CGFloat top = songFoot + kNLSPLeastGap + MIN(room - height, kNLSPUnderCover - kNLSPLeastGap);
    NLSPShowLyricsAt(lyrics, CGRectMake(time.frame.origin.x - kNLSPEdge, round(top), time.frame.size.width + kNLSPEdge * 2, height), time);   // its text in line with the time
    return YES;
}

// The closed player's lyrics column for its layout (NLSPPlaceClosedLyrics): 2×4's or 3×4's.
static const void *NLSPClosedColumnKey(NLSPClosedLayout layout) {
    return layout == NLSPClosedTall ? &kNLSPTallLyricsKey : &kNLSPClosedLyricsKey;
}

// 2×4's or 3×4's lyrics: the song has them, as last read.
static BOOL NLSPClosedHasLyrics(UIView *player) {
    NLSPLyricsView *lyrics = objc_getAssociatedObject(player, NLSPClosedColumnKey(NLSPClosedLayoutFor(player, player.bounds.size)));
    return gNLSPClosedLyrics && lyrics.hasLines;
}

// Closed at 2×4 or 3×4 with lyrics: them as on its side (the column), at
// 2×4 under the song, smaller, three lines' room down to the buttons' glyphs,
// at 3×4 under the cover across, as big as on its side, down to the time
// bar. YES: the song's own title over them.
static BOOL NLSPPlaceClosedLyrics(MRUNowPlayingView *player) {
    NLSPClosedLayout layout = gNLSPEnabled && [player respondsToSelector:@selector(headerView)] ?
                              NLSPClosedLayoutFor(player, player.bounds.size) : NLSPClosedNone;
    BOOL wanted = gNLSPClosedLyrics && (layout == NLSPClosedWide || layout == NLSPClosedTall);
    const void *columns[] = {&kNLSPClosedLyricsKey, &kNLSPTallLyricsKey};
    const void *key = NLSPClosedColumnKey(layout);
    NLSPPutAwayColumns(player, columns, sizeof(columns) / sizeof(*columns), wanted ? key : NULL);
    if (!wanted) return NO;
    BOOL tall = layout == NLSPClosedTall;
    NLSPLyricsLook look = tall ? kNLSPTallLook : kNLSPClosedLook;
    NLSPLyricsView *lyrics = NLSPColumn(player, key, look, nil);
    [lyrics follow:YES];
    CGRect header = player.headerView.frame, artwork = player.artworkView.frame;
    UIView *time = player.timeControlsView, *transport = player.transportControlsView;
    CGFloat x, top, room;
    if (tall) {
        x = CGRectGetMinX(artwork);
        top = CGRectGetMaxY(artwork) + kNLSPUnderCover;
        room = CGRectGetMidY(time.frame) - kNLSPTimeRow / 2 - 4 - top;
    } else {
        x = header.origin.x;
        top = CGRectGetMaxY(header) + 1;
        room = CGRectGetMidY(transport.frame) - 10 - 2 - top;   // the glyphs 20 pt closed
    }
    CGFloat width = player.bounds.size.width - CGRectGetMinX(artwork) - x;   // the right margin as the cover's left one
    if (!lyrics.hasLines || room < [NLSPLyricsView heightOfRows:1 look:look]) {
        NLSPLetLyricsGo(lyrics);
        return NO;
    }
    CGFloat height = MIN(room, [NLSPLyricsView heightOfRows:kNLSPClosedRows look:look]);
    NLSPShowLyricsAt(lyrics, CGRectMake(x - kNLSPEdge, round(top), width + kNLSPEdge * 2, floor(height)), tall ? time : transport);   // its text in line with the song's
    return YES;
}

#pragma mark - Control Center's grid

// Control Center's packing of modules into its grid
// (-[CCUIControlCenterPositionProvider _generateRect…]), as it is on iOS 16
// but with a place taken only when every cell under the module is free: the
// system's looks at the first cell alone, which is enough for modules two
// cells wide or less, but puts a wider one (the player at 1×4 or 2×4, or
// NowLyrics' own module at 2×4) over the lower half of one placed before it.
// In `order` (0: along the rows, 1: down the columns) from `start`, within
// `maximum`; each module at the first place it fits, the rest unplaced once
// one does not; `output` grown to what they take.
static NSDictionary *NLSPPackModules(NSArray *identifiers, NSArray<NSValue *> *sizes, unsigned long long order,
                                     NLSPLayoutPoint start, NLSPLayoutSize maximum, NLSPLayoutSize *output) {
    BOOL columns = order == 1;
    unsigned long long alongStart = columns ? start.y : start.x, acrossStart = columns ? start.x : start.y;
    unsigned long long alongMax = columns ? maximum.height : maximum.width, acrossMax = columns ? maximum.width : maximum.height;
    NSMutableSet<NSNumber *> *taken = [NSMutableSet set];
    NSMutableDictionary *rects = [NSMutableDictionary dictionary];
    unsigned long long extent = acrossStart;
    NSNumber *(^cell)(unsigned long long, unsigned long long) = ^NSNumber *(unsigned long long along, unsigned long long across) {
        return @((along << 32) | across);
    };
    for (NSUInteger i = 0; i < identifiers.count && i < sizes.count; i++) {
        NLSPLayoutSize size = [sizes[i] ccui_sizeValue];
        unsigned long long along = columns ? size.height : size.width, across = columns ? size.width : size.height;
        BOOL placed = NO;
        unsigned long long atAlong = 0, atAcross = 0;
        for (unsigned long long y = acrossStart; !placed && across <= acrossMax && y <= acrossMax - across; y++) {
            for (unsigned long long x = alongStart; !placed && along <= alongMax && x <= alongMax - along; x++) {
                BOOL free = YES;
                for (unsigned long long r = y; free && r < y + across; r++) {
                    for (unsigned long long c = x; free && c < x + along; c++) free = ![taken containsObject:cell(c, r)];
                }
                if (free) {
                    placed = YES;
                    atAlong = x;
                    atAcross = y;
                }
            }
        }
        if (!placed) break;
        NLSPLayoutRect rect = {{columns ? atAcross : atAlong, columns ? atAlong : atAcross}, size};
        rects[identifiers[i]] = [NSValue ccui_valueWithLayoutRect:rect];
        extent = MAX(extent, atAcross + across);
        for (unsigned long long r = atAcross; r < atAcross + across; r++) {
            for (unsigned long long c = atAlong; c < atAlong + along; c++) [taken addObject:cell(c, r)];
        }
    }
    if (output) {
        output->width = MAX(output->width, columns ? extent : maximum.width);
        output->height = MAX(output->height, columns ? maximum.height : extent);
    }
    return [rects copy];
}

#pragma mark - Debug

#ifdef NLI_FILELOG
// Debug builds: the closed player's frames while it opens or closes, and any
// transform above it, to see what bends it.
static void NLSPLogTransition(MRUNowPlayingView *player, NSString *when) {
    MRUControlCenterView *view = NLSPOwnerView(player);
    if (![view respondsToSelector:@selector(isTransitioning)] || !view.transitioning) return;
    static NSUInteger told;
    if (++told > 400) return;
    NSMutableString *bent = [NSMutableString string];
    for (UIView *up = player; up; up = up.superview) {
        if (!CGAffineTransformIsIdentity(up.transform)) [bent appendFormat:@" %@%@", NSStringFromClass(up.class), NSStringFromCGAffineTransform(up.transform)];
        if (!CATransform3DIsIdentity(up.layer.sublayerTransform)) [bent appendFormat:@" %@ sublayer", NSStringFromClass(up.class)];
    }
    CALayer *shown = player.artworkView.layer.presentationLayer;
    NLSP_LOG(@"transition %@: view %@ state %lld from %@ card %@ player %@ cover %@ (showing %@) header %@ transport %@ closed %ld bent%@",
             when, NSStringFromCGRect(view.bounds), view.state, NSStringFromCGRect(view.transitionFrame), NSStringFromCGRect(player.superview.frame),
             NSStringFromCGRect(player.frame), NSStringFromCGRect(player.artworkView.frame), shown ? NSStringFromCGRect(shown.frame) : @"-",
             NSStringFromCGRect(player.headerView.frame), NSStringFromCGRect(player.transportControlsView.frame),
             (long)NLSPClosedLayoutFor(player, player.bounds.size), bent.length ? bent : @" none");
}
#endif

#ifdef NLI_FILELOG
// Debug builds: a player's views, to place things against: each one's class,
// frame, hidden or alpha, a label's text, a Swift view's layouts and states
// (NLSPSwiftByte), a lyrics column's lines and dots; not inside buttons,
// sliders and the like.
static NSString *NLSPSwiftFields(id object) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *name in @[@"layout", @"moduleLayout", @"expandedLayout", @"isExpanded", @"onScreen", @"gridSizeClass", @"state"]) {
        int value = NLSPSwiftByte(object, name.UTF8String);
        if (value >= 0) [parts addObject:[NSString stringWithFormat:@"%@=%d", name, value]];
    }
    return parts.count ? [NSString stringWithFormat:@" [%@]", [parts componentsJoinedByString:@" "]] : @"";
}
static void NLSPDump(UIView *view, NSMutableString *out, int depth) {
    NSString *text = @"";
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        BOOL marquee = [label respondsToSelector:@selector(marqueeRunning)];
        text = [NSString stringWithFormat:@" \"%@\" fits %.0f%@", label.text, [label sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)].width,
                marquee ? [NSString stringWithFormat:@" marquee %@/%@", [label valueForKey:@"marqueeEnabled"], [label valueForKey:@"marqueeRunning"]] : @""];
    }
    [out appendFormat:@"%*s%@ %@%@%@%@%@\n", depth * 2, "", NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
     view.hidden ? @" hidden" : @"", view.alpha < 1 ? [NSString stringWithFormat:@" a%.2f", view.alpha] : @"", text, NLSPSwiftFields(view)];
    if ([view isKindOfClass:NSClassFromString(@"NLSPLyricLineView")]) {
        UILabel *line = (UILabel *)NLSPDescendant(view, UILabel.class);
        [out appendFormat:@"%*s  \"%@\"\n", depth * 2, "", line.text];
        return;
    }
    if ([view isKindOfClass:NSClassFromString(@"NLSPGapDotsView")] || [view.superview isKindOfClass:NSClassFromString(@"NLSPGapDotsView")]) {
        [out appendFormat:@"%*s  transform %@ bounds %@ layer opacity %.2f\n", depth * 2, "", NSStringFromCGAffineTransform(view.transform),
         NSStringFromCGRect(view.bounds), view.layer.presentationLayer ? view.layer.presentationLayer.opacity : -1];
    }
    for (NSString *leaf in @[@"MRUTransportButton", @"MRUSlider", @"MRUStepper", @"NUNextUpRowView", @"UIImageView", @"MRUArtworkView", @"NLPlayerTintView",
                             @"_TtC13MediaControls15TransportButton", @"_TtC13MediaControls17SessionAccessoryView", @"_TtC13MediaControls6Slider", @"NLSPRow"]) {
        if ([view isKindOfClass:NSClassFromString(leaf)]) return;
    }
    if (depth < 14) for (UIView *sub in view.subviews) NLSPDump(sub, out, depth + 1);
}
// The card's looks with the outputs or the sources showing, once each: every
// view's and loose layer's color, opacity, filters, to match the outputs' backdrop.
static NSString *NLSPColorText(CGColorRef color) {
    if (!color) return @"-";
    const CGFloat *parts = CGColorGetComponents(color);
    NSMutableArray<NSString *> *texts = [NSMutableArray array];
    for (size_t i = 0; i < CGColorGetNumberOfComponents(color); i++) [texts addObject:[NSString stringWithFormat:@"%.2f", parts[i]]];
    return [texts componentsJoinedByString:@","];
}
static void NLSPDumpLayer(CALayer *layer, NSMutableString *out, int depth, BOOL loose) {
    [out appendFormat:@"%*s%@%@ %@%@ o%.2f bg(%@) filter %@ filters %lu mask %d\n", depth * 2, "", loose ? @"layer " : @"",
     loose ? NSStringFromClass(layer.class) : NSStringFromClass([layer.delegate class]), NSStringFromCGRect(layer.frame),
     layer.hidden ? @" hidden" : @"", layer.opacity, NLSPColorText(layer.backgroundColor), [layer valueForKey:@"compositingFilter"],
     (unsigned long)[[layer valueForKey:@"filters"] count], layer.mask != nil];
    UIView *view = [layer.delegate isKindOfClass:UIView.class] ? (UIView *)layer.delegate : nil;
    for (NSString *leaf in @[@"MRUTransportButton", @"NLSPRow", @"MRUSlider", @"MRUStepper", @"UILabel", @"MRUArtworkView", @"UITableViewCellContentView", @"NLSPLyricsView", @"MRUNowPlayingLabelView"]) {
        if ([view isKindOfClass:NSClassFromString(leaf)]) return;
    }
    if (depth >= 9) return;
    for (CALayer *sub in layer.sublayers) {
        BOOL subLoose = ![sub.delegate isKindOfClass:UIView.class];
        NLSPDumpLayer(sub, out, depth + 1, subLoose);
    }
}
static void NLSPDumpLooks(MRUControlCenterView *view) {
    static NSMutableSet *seen;
    if (!seen) seen = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%.0fx%.0f", view.bounds.size.width, view.bounds.size.height];
    UIView *nowPlaying = NLSPDescendant(view, objc_getClass("MRUNowPlayingView"));
    if (!nowPlaying.superview || [seen containsObject:key]) return;
    [seen addObject:key];
    NSMutableString *out = [NSMutableString stringWithFormat:@"looks with the list open, %@\n", key];
    NLSPDumpLayer(nowPlaying.superview.layer, out, 0, NO);
    NLSP_LOG(@"%@", out);
}

static void NLSPDumpSettled(MRUControlCenterView *view, long long layout) {
    if (layout == kNLSPOutputsLayout) NLSPDumpLooks(view);
    static NSMutableSet *seen;
    if (!seen) seen = [NSMutableSet set];
    NSString *key = [NSString stringWithFormat:@"%lld layout %lld %.0fx%.0f", view.state, layout, view.bounds.size.width, view.bounds.size.height];
    if ([seen containsObject:key]) return;
    [seen addObject:key];
    NSMutableString *out = [NSMutableString stringWithFormat:@"settled: state %@\n", key];
    NLSPDump(view, out, 0);
    NLSP_LOG(@"%@", out);
}
#endif

#pragma mark - iOS 16 hooks

%hook MRUNowPlayingTransportControlsView
- (void)setLayout:(long long)layout {
    %orig(NLSPTallTransport((UIView *)self, layout));
}

- (void)layoutSubviews {
    %orig;
    NLSPLayOutClosedButtons(self);
}

// MediaControls showing its buttons again: the closed layout's own again.
- (void)updateVisibility {
    %orig;
    NLSPLayOutClosedButtons(self);
}

%end

%hook MRUControlCenterView
- (void)layoutSubviews {
    %orig;
    NLSPFillClosedCard(self);
    MRUNowPlayingView *player = (MRUNowPlayingView *)NLSPDescendant(self, objc_getClass("MRUNowPlayingView"));
    if (player) NLSPPlaceRowCorner(player);   // 1×4's output button back at the row's end
    NLSPPlaceOwnTile(self, player);
    NLSPShowLyricsGlyphs(self, player);
}
%end

%hook MRUTransportButton
// The own module's output buttons: the lyrics glyph whatever MediaControls gives them (NLSPAssetFor).
- (void)setAsset:(MRUAsset *)asset animated:(BOOL)animated {
    %orig(gNLSPAdopted ? NLSPAssetFor((UIView *)self, asset) : asset, animated);
}

- (void)setAsset:(MRUAsset *)asset {
    %orig(gNLSPAdopted ? NLSPAssetFor((UIView *)self, asset) : asset);
}
%end

%hook MRUNowPlayingView
// The closed player at its size, the open one's lyrics and the song's own
// title over them (NowLyrics' line in it otherwise).
- (void)layoutSubviews {
#ifdef NLI_FILELOG
    NLSPLogTransition(self, @"before");
#endif
    %orig;
    NLSPLayOutClosed(self);
#ifdef NLI_FILELOG
    NLSPLogTransition(self, @"after");
#endif
    BOOL open = NLSPPlaceLyrics(self), closed = NLSPPlaceClosedLyrics(self);   // both, each hiding its own when not wanted
    NLSPHideRoute(self, open);
    BOOL song = open || closed;
    NSDictionary *np = NLSPFollower.shared.np;
#ifdef NLI_FILELOG
    static NSString *told;
    NSString *tell = song && !NLString(np, NL_NP_TITLE) ? [NSString stringWithFormat:@"song wanted, no nowplaying.plist title (app %@)", NLSPFollower.shared.bundleID] : nil;
    if (tell && !NLSame(tell, told)) NLSP_LOG(@"%@", tell);
    told = tell;
#endif
    NLSPShowSongTitle(self, song ? NLString(np, NL_NP_TITLE) : nil, song ? NLString(np, NL_NP_ARTIST) : nil);
}
%end

%hook MRUNowPlayingTimeControlsView
// Its clock on while the closed player shows it (NLSPTimeRuns).
- (void)setOnScreen:(BOOL)onScreen {
    objc_setAssociatedObject(self, &kNLSPAskedOnScreenKey, @(onScreen), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(onScreen || NLSPTimeRuns((UIView *)self));
}

- (void)didMoveToWindow {
    %orig;
    NLSPRecheckTime((UIView *)self);   // off with Control Center away
}
%end

%hook MRUNowPlayingHeaderView
// Closed at a size picked: the label the header's whole width (no room kept
// for its own buttons, which the closed player hides), so it lines up with
// the cover.
- (void)layoutSubviews {
    %orig;
    UIView *player = self.superview;
    if ([player isKindOfClass:objc_getClass("MRUNowPlayingView")] && [self respondsToSelector:@selector(labelView)] &&
        NLSPClosedLayoutFor(self, player.bounds.size) != NLSPClosedNone) {
        self.labelView.frame = self.bounds;
    }
}
%end

%hook MRUNowPlayingLabelView
// (Logos hooks every method it sees, whatever the preprocessor leaves out: debug-only work goes inside them.)
- (void)layoutSubviews {
    %orig;
#ifdef NLI_FILELOG
    NLSPLogMarquee(self, @"layout");
#endif
}

// Closed (NLSPClosedMarquee): the title as wide as its text, its marquee on while it shows, as the open player's.
- (CGSize)sizeForText:(NSString *)text font:(UIFont *)font layout:(long long)layout availableSize:(CGSize)size {
    return %orig(text, font, layout == 0 && NLSPClosedMarquee(self) ? kNLSPMarqueeLayout : layout, size);
}

- (void)setMarqueeEnabled:(BOOL)enabled {
    %orig(enabled || (self.window && NLSPClosedMarquee(self)));
}

// Back in a window closed (Control Center put the card back while closing it): its marquee on again.
- (void)didMoveToWindow {
    %orig;
    if (self.window && NLSPClosedMarquee(self)) [self setMarqueeEnabled:YES];
}

- (void)updateMarquee {
#ifdef NLI_FILELOG
    NLSPLogMarquee(self, @"update before");
#endif
    static ptrdiff_t offset = -1;
    if (offset < 0) {
        Ivar ivar = class_getInstanceVariable(object_getClass(self), "_layout");
        offset = ivar && ivar_getTypeEncoding(ivar) && ivar_getTypeEncoding(ivar)[0] == 'q' ? ivar_getOffset(ivar) : 0;
    }
    long long *layout = offset > 0 ? (long long *)((char *)(__bridge void *)self + offset) : NULL;
    if (!layout || *layout != 0 || !NLSPClosedMarquee(self)) {
        %orig;
        return;
    }
    *layout = kNLSPMarqueeLayout;   // its marquee as the open player's, for this call only
    %orig;
    *layout = 0;
#ifdef NLI_FILELOG
    NLSPLogMarquee(self, @"update after");
#endif
}

// The output's name as MediaControls asks, off while NowLyrics' lyrics show (NLSPHideRoute).
- (void)setShowRoute:(BOOL)show {
    objc_setAssociatedObject(self, &kNLSPAskedRouteKey, @(show), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    %orig(show && ![objc_getAssociatedObject(self, &kNLSPNoRouteKey) boolValue]);
}

// MediaControls' title and subtitle kept, the song's shown in their place while asked (NLSPShowSongTitle).
- (void)setTitle:(NSString *)title {
    objc_setAssociatedObject(self, &kNLSPAppleTitleKey, title, OBJC_ASSOCIATION_COPY_NONATOMIC);
    NSArray<NSString *> *song = objc_getAssociatedObject(self, &kNLSPSongKey);
    %orig(song ? song[0] : title);
}

- (void)setSubtitle:(NSString *)subtitle {
    objc_setAssociatedObject(self, &kNLSPAppleSubtitleKey, subtitle, OBJC_ASSOCIATION_COPY_NONATOMIC);
    NSArray<NSString *> *song = objc_getAssociatedObject(self, &kNLSPSongKey);
    %orig(song ? song[1] : subtitle);
}
%end

%hook MRURoutingView
- (void)layoutSubviews {
    %orig;
    NLSPPlaceSources(self);
}

// The card as big as the outputs alone make it, the sources scrolled down to
// under them. MediaControls' measure, without them: the table's content
// (-_contentSize, from its rows, the footer in it) at least three rows high,
// with its insets, within the room given.
- (CGSize)sizeThatFits:(CGSize)size {
    CGSize fit = %orig;
    if (NLSPOwnModuleOf(self) && [self respondsToSelector:@selector(contentEdgeInsets)]) {
        // The own module's: the sources alone (in place before MediaControls first measures), with the outputs' insets.
        if (!objc_getAssociatedObject(self, &kNLSPListKey)) NLSPPlaceSources(self);
        NLSPSourceList *list = objc_getAssociatedObject(self, &kNLSPListKey);
        if (!list) return fit;
        if (!list.window) [list reload];   // its rows, before it shows
        UIEdgeInsets insets = self.contentEdgeInsets;
        fit.height = MIN([list heightForWidth:size.width > 0 ? size.width : fit.width] + insets.top + insets.bottom, size.height);
        return fit;
    }
    UITableView *table = [self respondsToSelector:@selector(tableView)] ? self.tableView : nil;
    UIView *footer = table.tableFooterView;
    if (![footer isKindOfClass:NLSPSourceList.class] || ![table respondsToSelector:@selector(_contentSize)] ||
        ![self respondsToSelector:@selector(contentEdgeInsets)]) return fit;
    CGFloat content = ((CGSize (*)(id, SEL))objc_msgSend)(table, @selector(_contentSize)).height - footer.bounds.size.height;
    UIEdgeInsets insets = ((UIEdgeInsets (*)(id, SEL))objc_msgSend)(self, @selector(contentEdgeInsets));
    fit.height = MIN(MAX(content, table.rowHeight * 3) + insets.top + insets.bottom, size.height);
    return fit;
}
%end

%group NLSPModuleGrid
%hook CCUIContentModuleContainerViewController
// The media module starting to open or close: its player laid out for that from the first frame.
- (void)transitionToExpandedMode:(BOOL)expanded {
    UIView *player = NLSPDescendant(((UIViewController *)self).viewIfLoaded, objc_getClass("MRUControlCenterView"));
    if (player) {
        objc_setAssociatedObject(player, &kNLSPOpenKey, @(expanded), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [player setNeedsLayout];
    }
    %orig;
}
%end

%hook CCUIControlCenterPositionProvider
// Packed by NLSPPackModules once a module is wider or taller than two cells;
// the system's own packing otherwise.
- (NSDictionary *)_generateRectByIdentifierWithOrderedIdentifiers:(NSArray *)identifiers orderedSizes:(NSArray<NSValue *> *)sizes
                                                     packingOrder:(unsigned long long)order startPosition:(NLSPLayoutPoint)start
                                                      maximumSize:(NLSPLayoutSize)maximum outputLayoutSize:(NLSPLayoutSize *)output {
    BOOL wide = NO;
    for (NSValue *value in sizes) {
        if (![value respondsToSelector:@selector(ccui_sizeValue)]) return %orig;
        NLSPLayoutSize size = [value ccui_sizeValue];
        if (size.width > 2 || size.height > 2) wide = YES;
    }
    if (!wide || !gNLSPEnabled || ![NSValue respondsToSelector:@selector(ccui_valueWithLayoutRect:)]) return %orig;
    return NLSPPackModules(identifiers, sizes, order, start, maximum, output);
}
%end

%hook CCUIModuleCollectionViewController
// The media module at the size picked in the list.
- (NSArray *)_sizesForModuleIdentifiers:(NSArray<NSString *> *)identifiers moduleInstanceByIdentifier:(NSDictionary *)instances interfaceOrientation:(long long)orientation {
    NSArray *sizes = %orig;
    gNLSPModuleGrid = (UIViewController *)self;
    NSUInteger at = [identifiers indexOfObject:kNLSPMediaModule];
    if (!gNLSPEnabled || !gNLSPPlayerSize || at == NSNotFound || at >= sizes.count ||
        ![NSValue respondsToSelector:@selector(ccui_valueWithLayoutSize:)]) return sizes;
    NSArray<NSString *> *parts = [NLSPPlayerSizeName() componentsSeparatedByString:@"x"];
    NLSPLayoutSize size = {(unsigned long long)parts[1].integerValue, (unsigned long long)parts[0].integerValue};
    NSMutableArray *changed = [sizes mutableCopy];
    changed[at] = [NSValue ccui_valueWithLayoutSize:size];
    return changed;
}
%end
%end

%hook MRUNowPlayingViewController
- (void)setLayout:(long long)layout {
    %orig;
#ifdef NLI_FILELOG
    __weak MRUControlCenterView *dumped = NLSPOwnerView(self.viewIfLoaded);
    __weak MRUNowPlayingViewController *dumpedLayout = self;
    NLAfter(0.8, ^{ if (dumped) NLSPDumpSettled(dumped, dumpedLayout.layout); });
#endif
}
%end

%hook MRUControlCenterViewController
// The card closed: its title's marquee started again where it now is (NLSPRestartClosedMarquee).
- (void)didTransitionToExpandedContentMode:(BOOL)expanded {
    %orig;
    if (expanded) return;
    MRUNowPlayingView *player = (MRUNowPlayingView *)NLSPDescendant(((UIViewController *)self).viewIfLoaded, objc_getClass("MRUNowPlayingView"));
    if (![player respondsToSelector:@selector(headerView)]) return;
    MRUNowPlayingLabelView *label = player.headerView.labelView;
    dispatch_async(dispatch_get_main_queue(), ^{ NLSPRestartClosedMarquee(label); });   // after the layout the close leaves
}

// Control Center sizing the module: MediaControls takes any size over 200 pt
// wide for the open player (viewWillTransitionToSize:), so 1×4 and 2×4 closed
// as it, with its big buttons and the output's name over the song. Closed at
// a size picked, the closed player's state, as a 2×2 closes.
- (void)setState:(long long)state {
    UIView *view = ((UIViewController *)self).viewIfLoaded;
    if (state != 0 && [view isKindOfClass:objc_getClass("MRUControlCenterView")] && NLSPIsClosed(view) && NLSPPickedSize(view)) state = 0;
    %orig(state);
}
%end

#pragma mark - iOS 26

// iOS 26's media module is MediaControls' Swift one: the module's view
// (MRUMediaControlsModuleViewController's) holds a session view per playing
// app (MediaControlsModuleSessionView), the player in it
// (MediaControlsModuleNowPlayingView: the cover, the song, the time, the
// buttons, the volume and two output buttons) over the outputs
// (RoutePickerItemsView, shown in the route layouts). Their fields are Swift's,
// read by name from their classes' ivars; their layouts
// (MediaControlsModuleSessionLayout): Control Center's sizes, then the outputs'.
typedef NS_ENUM(uint8_t, NLSP26Layout) {
    NLSP26SmallExtraWide, NLSP26Medium, NLSP26MediumWide, NLSP26Large, NLSP26LargeExtraTall, NLSP26LargeExtraWide,
    NLSP26RouteTall, NLSP26RouteWide,
};

@interface _TtC13MediaControls33MediaControlsModuleNowPlayingView : UIView
@end
@interface _TtC13MediaControls30MediaControlsModuleSessionView : UIView
@end

// In Control Center's media module (the views are the lock screen's too).
static BOOL NLSP26InModule(UIView *view) {
    Class module = objc_getClass("MRUMediaControlsModuleViewController");
    for (UIResponder *next = view; next; next = next.nextResponder) {
        if ([next isKindOfClass:module]) return YES;
    }
    return NO;
}

// The header's title and subtitle (UILabels), made this subclass (it adds
// no ivars: its state in associated objects). While a lyrics column shows,
// the song's own text in place of what MediaControls gives them (the line
// being sung, while NowLyrics puts it there). In the small sizes their
// marquee kept running while they show, a long title scrolling instead of
// cut: MediaControls runs it at 4×4 alone (UILabel's own marquee, which
// scrolls only text too long for it).
@interface UILabel (NLSP26Marquee)
- (BOOL)marqueeRunning;
- (void)setMarqueeRunning:(BOOL)running;
@end
@interface NLSP26HeaderLabel : UILabel
- (void)nlShowSong:(NSString *)song;   // nil: theirs again
- (void)nlKeepScrolling:(BOOL)keep;    // NO: running as MediaControls asks
@end
static char kNLSP26SongKey, kNLSP26TheirsKey, kNLSP26ScrollKey, kNLSP26AskedRunKey;
@implementation NLSP26HeaderLabel
- (void)setText:(NSString *)text {
    objc_setAssociatedObject(self, &kNLSP26TheirsKey, text, OBJC_ASSOCIATION_COPY_NONATOMIC);
    NSString *song = objc_getAssociatedObject(self, &kNLSP26SongKey);
    [super setText:song ?: text];
}
- (void)nlShowSong:(NSString *)song {
    if (NLSame(song, objc_getAssociatedObject(self, &kNLSP26SongKey))) return;
    objc_setAssociatedObject(self, &kNLSP26SongKey, song, OBJC_ASSOCIATION_COPY_NONATOMIC);
    [super setText:song ?: objc_getAssociatedObject(self, &kNLSP26TheirsKey)];
    [self.superview setNeedsLayout];
}
- (BOOL)nlKeeps {
    return [objc_getAssociatedObject(self, &kNLSP26ScrollKey) boolValue] && self.window;
}
- (void)setMarqueeRunning:(BOOL)running {
    objc_setAssociatedObject(self, &kNLSP26AskedRunKey, @(running), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [super setMarqueeRunning:running || [self nlKeeps]];
}
- (void)nlKeepScrolling:(BOOL)keep {
    if (keep == [objc_getAssociatedObject(self, &kNLSP26ScrollKey) boolValue]) return;
    objc_setAssociatedObject(self, &kNLSP26ScrollKey, @(keep), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [super setMarqueeRunning:[objc_getAssociatedObject(self, &kNLSP26AskedRunKey) boolValue] || [self nlKeeps]];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    if ([self nlKeeps] && ![super marqueeRunning]) [super setMarqueeRunning:YES];   // back on screen
}
@end

// The header's labels as NLSP26HeaderLabel (`take`: made so if not yet), with
// the song's `title` and `artist` (nil: theirs) and their marquee kept
// running or not.
static void NLSP26ShowSong(UIView *header, NSString *title, NSString *artist, BOOL keepScrolling, BOOL take) {
    NSArray *labels = @[NLSPSwiftObject(header, "titleLabel") ?: NSNull.null, NLSPSwiftObject(header, "subtitleLabel") ?: NSNull.null];
    NSArray<NSString *> *song = @[title ?: @"", artist ?: @""];
    for (NSUInteger i = 0; i < labels.count; i++) {
        UILabel *label = labels[i];
        if (![label isKindOfClass:UILabel.class]) return;
        if (object_getClass(label) == UILabel.class && take) {
            NSString *theirs = label.text;
            BOOL running = [label respondsToSelector:@selector(marqueeRunning)] && label.marqueeRunning;
            object_setClass(label, NLSP26HeaderLabel.class);
            objc_setAssociatedObject(label, &kNLSP26TheirsKey, theirs, OBJC_ASSOCIATION_COPY_NONATOMIC);
            objc_setAssociatedObject(label, &kNLSP26AskedRunKey, @(running), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (![label isKindOfClass:NLSP26HeaderLabel.class]) continue;
        NLSP26HeaderLabel *own = (NLSP26HeaderLabel *)label;
        [own nlShowSong:title.length ? song[i] : nil];
        if ([own respondsToSelector:@selector(marqueeRunning)]) [own nlKeepScrolling:keepScrolling];
    }
}

// MediaControls shows and hides its rows by their alpha; NowLyrics hides
// them with `hidden`, and shows the corner output button with an alpha kept
// aside (theirs back after).
static char kNLSP26HidKey, kNLSP26AlphaKey;
static void NLSP26Hide(UIView *view, BOOL hide) {
    BOOL hid = [objc_getAssociatedObject(view, &kNLSP26HidKey) boolValue];
    if (hide == hid) return;
    objc_setAssociatedObject(view, &kNLSP26HidKey, @(hide), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    view.hidden = hide;
}
static void NLSP26Show(UIView *view, BOOL show) {
    NSNumber *theirs = objc_getAssociatedObject(view, &kNLSP26AlphaKey);
    if (show) {
        if (!theirs) objc_setAssociatedObject(view, &kNLSP26AlphaKey, @(view.alpha), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        view.alpha = 1;
        view.userInteractionEnabled = YES;
    } else if (theirs) {
        view.alpha = theirs.doubleValue;
        objc_setAssociatedObject(view, &kNLSP26AlphaKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}

// The corner output button shown at 4×4, where MediaControls lays it out
// empty (its glyph 0 pt): the glyph of the output pill it takes the place of,
// at its size in the middle, as 2×4's. After the button's own layout.
@interface _TtC13MediaControls30MediaControlsModuleRouteButton : UIControl
@end
static UIImageView *NLSP26Glyph(UIView *button) {
    for (UIView *sub in button.subviews) {
        if ([sub isKindOfClass:UIImageView.class]) return (UIImageView *)sub;
    }
    return nil;
}
static void NLSP26FillCornerButton(UIView *button) {
    if (!objc_getAssociatedObject(button, &kNLSP26AlphaKey)) return;   // not shown by NowLyrics
    UIImageView *glyph = NLSP26Glyph(button);
    UIImage *image = NLSP26Glyph(NLSPSwiftObject(button.superview, "lowerRouteButton")).image ?: glyph.image;
    if (!glyph || !image) return;
    glyph.image = image;
    CGSize size = image.size, room = button.bounds.size;
    glyph.frame = CGRectMake(round((room.width - size.width) / 2), round((room.height - size.height) / 2), size.width, size.height);
    glyph.alpha = 1;
    for (UIView *sub in button.subviews) {
        if ([sub isKindOfClass:UILabel.class]) sub.alpha = 0;
    }
}

// The player at 2×4 and 4×4 with lyrics, laid out as on iOS 16 closed at
// those sizes (NLSPLayOutClosed): 2×4 the lyrics under the song beside the
// cover, the buttons along the bottom under them and no time bar; 4×4 the
// lyrics under the cover and the song, the time bar and the buttons along
// the bottom, the output button in the corner (as 2×4's) in the volume's and
// the output pill's place. Open on its side (largeExtraWide) as iOS 16's
// (NLSPPlaceLyrics): the lyrics between the time bar and the buttons, the
// buttons and the volume down to the cover's foot, the output button in the
// corner in the pill's place; with the outputs beside it (routeWide) as the
// open player on its side with the outputs on iOS 16: the cover small in its
// corner and the song beside it, the time bar under them, the lyrics, the
// buttons with the output button at their row's end, the volume at the foot
// (MediaControls has the rows away, out of sight, there). Without lyrics,
// MediaControls' layout as it is.
static char kNLSP26WideLyricsKey, kNLSP26LargeLyricsKey, kNLSP26TallLyricsKey, kNLSP26SidewaysLyricsKey;
static const CGFloat kNLSP26SmallCover = 60;   // routeWide's cover beside the song, as iOS 16's closed player's
// Where a time or volume row's track ends in its frame (the slider's foot).
static CGFloat NLSP26TrackFoot(UIView *row) {
    UIView *slider = NLSPDescendantNamed(row, "_TtC13MediaControls6Slider");
    return slider ? CGRectGetMaxY([slider convertRect:slider.bounds toView:row]) : row.bounds.size.height * 0.57;
}
// The time bar away from the screen to MediaControls (routeWide) but shown
// by NowLyrics: its clock kept going by a display link of NowLyrics' own
// calling its update (MediaControls' own one paused while it is away).
@interface UIView (NLSP26Time)
- (void)updateElapsedTimeWithDisplayLink:(CADisplayLink *)link;
@end
@interface NLSP26TimeTicker : NSObject
@property (nonatomic, weak) UIView *time;
@property (nonatomic, strong) CADisplayLink *link;
@end
@implementation NLSP26TimeTicker
- (void)nlTick:(CADisplayLink *)link {
    UIView *time = _time;
    if (!NLSPWindowShows(time)) {
        [link invalidate];   // Control Center gone; started again as it lays out
        _link = nil;
        return;
    }
    if ([time respondsToSelector:@selector(updateElapsedTimeWithDisplayLink:)]) [time updateElapsedTimeWithDisplayLink:link];
}
@end
static char kNLSP26TickerKey;
static void NLSP26TickTime(UIView *time, BOOL tick) {
    NLSP26TimeTicker *ticker = objc_getAssociatedObject(time, &kNLSP26TickerKey);
    if (!tick) {
        [ticker.link invalidate];
        ticker.link = nil;
        return;
    }
    if (!ticker) {
        ticker = [NLSP26TimeTicker new];
        ticker.time = time;
        objc_setAssociatedObject(time, &kNLSP26TickerKey, ticker, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (ticker.link) return;
    ticker.link = [CADisplayLink displayLinkWithTarget:ticker selector:@selector(nlTick:)];
    ticker.link.preferredFramesPerSecond = 30;
    [ticker.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}

static void NLSP26LayOut(UIView *player) {
    int layout = NLSPSwiftByte(player, "layout");
    BOOL wide = layout == NLSP26MediumWide, tall = layout == NLSP26LargeExtraTall, large = layout == NLSP26Large || tall;
    BOOL sideways = layout == NLSP26LargeExtraWide, corner = large || sideways, route = layout == NLSP26RouteWide;
    UIView *artwork = NLSPSwiftObject(player, "artworkControl"), *header = NLSPSwiftObject(player, "headerView");
    UIView *time = NLSPSwiftObject(player, "timeControlsView"), *transport = NLSPSwiftObject(player, "transportControlsView");
    UIView *volume = NLSPSwiftObject(player, "volumeControlsView");
    UIView *upper = NLSPSwiftObject(player, "upperRouteButton"), *lower = NLSPSwiftObject(player, "lowerRouteButton");
    // Closed in the grid (2×4, 4×4) as the closed-lyrics switch says, open (upright, on its side, beside the outputs) as the open one.
    BOOL shown = ((wide || (large && !tall)) && gNLSPClosedLyrics) || ((tall || sideways || route) && gNLSPOpenLyrics);
    BOOL wanted = gNLSPEnabled && shown && artwork && header && time && transport && volume && upper && lower && NLSP26InModule(player);
    const void *columns[] = {&kNLSP26WideLyricsKey, &kNLSP26LargeLyricsKey, &kNLSP26TallLyricsKey, &kNLSP26SidewaysLyricsKey};
    const void *key = columns[wide ? 0 : tall ? 2 : sideways || route ? 3 : 1];   // one column on its side, outputs or not
    NLSPPutAwayColumns(player, columns, sizeof(columns) / sizeof(*columns), wanted ? key : NULL);
    // 2×4 as iOS 16's closed one, 4×4 as its 3×4, the tall one as big as on its side.
    NLSPLyricsLook look = wide ? kNLSPClosedLook : tall ? NLSPLookPlaced(kNLSPSidewaysLook, kNLSPTallLook)
                        : sideways || route ? kNLSPSidewaysLook : kNLSPTallLook;
    // Laid out again with the session: routeWide's halves (NLSP26SplitRoute) too.
    NLSPLyricsView *lyrics = wanted ? NLSPColumn(player, key, look, player.superview) : nil;
    [lyrics follow:wanted];

    BOOL shows = NO;
    CGRect frame = CGRectZero;
    if (wanted && lyrics.hasLines) {
        CGSize size = player.bounds.size;
        CGFloat inset = CGRectGetMinY(artwork.frame);   // the card's margin (the cover's left, but routeWide's player is wider)
        CGRect headerFrame = header.frame, transportFrame = transport.frame, timeFrame = time.frame, volumeFrame = volume.frame;
        transportFrame.origin.y = size.height - inset - transportFrame.size.height;
        CGFloat x, top, bottom;
        NSInteger rows;
        CGRect coverFrame = artwork.frame, cornerFrame = upper.frame;
        if (route) {
            // The card's left half (NLSP26SplitRoute), its margins either side.
            CGFloat left = inset, right = size.width - inset;
            coverFrame = CGRectMake(inset, inset, kNLSP26SmallCover, kNLSP26SmallCover);
            timeFrame = CGRectMake(left, CGRectGetMaxY(coverFrame) + 6, right - left, timeFrame.size.height);
            volumeFrame = CGRectMake(left, round(size.height - inset - NLSP26TrackFoot(volume)), right - left, volumeFrame.size.height);
            transportFrame = CGRectMake(left, CGRectGetMinY(volumeFrame) - transportFrame.size.height - 2,
                                        right - left - cornerFrame.size.width - 8, transportFrame.size.height);
            cornerFrame.origin = CGPointMake(right - cornerFrame.size.width, round(CGRectGetMidY(transportFrame) - cornerFrame.size.height / 2));
            x = left;
            top = CGRectGetMaxY(timeFrame) + 4;
            bottom = CGRectGetMinY(transportFrame) + 6;
            rows = kNLSPAllTheRoom;
        } else if (sideways) {
            // The volume's track level with the cover's foot, the buttons just over it.
            volumeFrame.origin.y = round(CGRectGetMaxY(artwork.frame) - NLSP26TrackFoot(volume));
            transportFrame.origin.y = CGRectGetMinY(volumeFrame) - transportFrame.size.height - 4;
            x = timeFrame.origin.x;
            top = CGRectGetMaxY(timeFrame) + 4;
            bottom = CGRectGetMinY(transportFrame) + 4;
            rows = kNLSPAllTheRoom;
        } else if (wide) {
            x = headerFrame.origin.x;
            top = CGRectGetMaxY(headerFrame) + 1;
            bottom = CGRectGetMinY(transportFrame) - 2;
            rows = kNLSPClosedRows;
        } else {
            // The time bar's track is a third down its frame, the buttons' glyphs in theirs.
            timeFrame.origin.y = CGRectGetMinY(transportFrame) - timeFrame.size.height + 2;
            x = CGRectGetMinX(artwork.frame);
            top = MAX(CGRectGetMaxY(artwork.frame), CGRectGetMaxY(headerFrame)) + kNLSPUnderCover;   // the song under the cover in the tall one
            bottom = CGRectGetMinY(timeFrame) + timeFrame.size.height * 0.35;
            rows = tall ? kNLSPWholeRows : kNLSPClosedRows;
        }
        CGFloat room = bottom - top, width = size.width - inset - x;
        if (room >= [NLSPLyricsView heightOfRows:1 look:look]) {
            shows = YES;
            CGFloat height = rows == kNLSPAllTheRoom ? room
                           : rows == kNLSPWholeRows ? [NLSPLyricsView heightOfWholeRowsIn:room look:look]
                           : MIN(room, [NLSPLyricsView heightOfRows:rows look:look]);
            frame = CGRectMake(x - kNLSPEdge, round(top), width + kNLSPEdge * 2, floor(height));
            if (route) {
                CGFloat songX = CGRectGetMaxX(coverFrame) + 12, songRight = size.width - inset;
                header.frame = CGRectMake(songX, round(CGRectGetMidY(coverFrame) - headerFrame.size.height / 2), songRight - songX, headerFrame.size.height);
                artwork.frame = coverFrame;   // small in its corner, the song beside it
                upper.frame = cornerFrame;
            }
            transport.frame = transportFrame;
            if (large || route) time.frame = timeFrame;
            if (sideways || route) volume.frame = volumeFrame;
            if (corner) {
                CGRect cornerFrame = upper.frame;
                if (CGRectGetMinY(headerFrame) >= CGRectGetMaxY(cornerFrame)) {
                    cornerFrame.origin.y = round(CGRectGetMidY(headerFrame) - cornerFrame.size.height / 2);   // off the cover, on the song's row
                    upper.frame = cornerFrame;
                }
                headerFrame.size.width = NLSPWidthBeforeCorner(upper, player, headerFrame.origin.x, headerFrame.size.width, 8);
                header.frame = headerFrame;   // short of the corner button (shown below, NLSP26Show)
            }
        }
    }
    NLSP26Hide(time, shows && wide);
    NLSP26Hide(volume, shows && large);
    NLSP26Hide(lower, shows && corner);
    NLSP26Show(upper, shows && (corner || route));
    for (UIView *row in @[time, transport, volume]) NLSP26Show(row, shows && route);   // MediaControls' away in routeWide
    NLSP26TickTime(time, shows && route);
    if (shows && (corner || route)) [upper setNeedsLayout];   // its glyph filled in (NLSP26FillCornerButton)
    if (shows) NLSPShowLyricsAt(lyrics, frame, wide ? transport : time);   // 2×4's over the buttons (no time bar)
    else NLSPLetLyricsGo(lyrics);
    BOOL small = layout == NLSP26SmallExtraWide || layout == NLSP26Medium || layout == NLSP26MediumWide;
    BOOL scrolls = small && gNLSPEnabled && NLSP26InModule(player);
    NLSP26ShowSong(header, shows ? lyrics.songTitle : nil, lyrics.songArtist, scrolls, shows || scrolls);
}

// The sources under the outputs in the route layouts: in their collection
// view, under its rows (NLSPSourceList inOutputs26), their look from the
// output in use.
static char kNLSP26ListKey;
// routeWide with lyrics: the player the card's left half and the outputs the
// right, as on iOS 16 (MediaControls gives the player the big cover's width).
static void NLSP26SplitRoute(UIView *session) {
    if (NLSPSwiftByte(session, "layout") != NLSP26RouteWide) return;
    UIView *player = NLSPSwiftObject(session, "nowPlayingView"), *items = NLSPSwiftObject(session, "routePickerItemsView");
    NLSPLyricsView *lyrics = objc_getAssociatedObject(player, &kNLSP26SidewaysLyricsKey);
    if (!gNLSPEnabled || !player || !items || !lyrics.hasLines || !NLSP26InModule(session)) return;
    CGFloat half = round(session.bounds.size.width / 2);
    CGRect left = player.frame, right = items.frame;
    if (CGRectGetMinX(right) < CGRectGetMaxX(left) - 1 || CGRectGetMaxX(right) <= half) return;   // not side by side
    left.size.width = half - CGRectGetMinX(left);
    right.size.width = CGRectGetMaxX(right) - half;
    right.origin.x = half;
    player.frame = left;
    items.frame = right;
}

static void NLSP26PlaceSources(UIView *session) {
    int layout = NLSPSwiftByte(session, "layout");
    UIView *items = NLSPSwiftObject(session, "routePickerItemsView");
    UICollectionView *collection = NLSPSwiftObject(items, "collectionView");
    if (![collection isKindOfClass:UICollectionView.class]) return;
    NLSPSourceList *list = objc_getAssociatedObject(collection, &kNLSP26ListKey);
    BOOL wanted = gNLSPEnabled && gNLSPSourcesInOutputs && (layout == NLSP26RouteTall || layout == NLSP26RouteWide) && NLSP26InModule(session);
    if (!wanted) {
        if (list.superview) {
            [list removeFromSuperview];
            UIEdgeInsets insets = collection.contentInset;
            insets.bottom = 0;
            collection.contentInset = insets;
        }
        return;
    }
    if (!list) {
        list = [NLSPSourceList new];
        list.inOutputs26 = YES;
        objc_setAssociatedObject(collection, &kNLSP26ListKey, list, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    if (list.superview != collection) [collection addSubview:list];
    [list fit];   // its rows measured off the outputs' there
}

#ifdef NLI_FILELOG
// Debug builds: every media module's views (NLSPDump) when
// /var/mobile/Library/Logs/nlsp-dump shows up (then removed).
static void NLSP26FindModules(UIView *view, NSMutableArray *found) {
    if ([view.nextResponder isKindOfClass:objc_getClass("MRUMediaControlsModuleViewController")]) [found addObject:view.nextResponder];
    for (UIView *sub in view.subviews) NLSP26FindModules(sub, found);
}
static void NLSP26WatchDumpAsks(void) {
    [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        NSString *ask = @"/var/mobile/Library/Logs/nlsp-dump";
        if (![NSFileManager.defaultManager fileExistsAtPath:ask]) return;
        [NSFileManager.defaultManager removeItemAtPath:ask error:nil];
        NSMutableArray *modules = [NSMutableArray array];
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *window in ((UIWindowScene *)scene).windows) NLSP26FindModules(window, modules);
        }
        for (UIViewController *module in modules) {
            if (!module.view.window) continue;
            NSMutableString *out = [NSMutableString stringWithFormat:@"asked: %.0fx%.0f%@\n", module.view.bounds.size.width, module.view.bounds.size.height, NLSPSwiftFields(module)];
            NLSPDump(module.view, out, 0);
            NLSP_LOG(@"%@", out);
        }
    }];
}
#endif

%group NLSP26
%hook _TtC13MediaControls33MediaControlsModuleNowPlayingView
- (void)layoutSubviews {
    %orig;
    NLSP26LayOut(self);
}
%end

%hook _TtC13MediaControls30MediaControlsModuleSessionView
- (void)layoutSubviews {
    %orig;
    NLSP26SplitRoute(self);
    NLSP26PlaceSources(self);
}
%end

%hook _TtC13MediaControls30MediaControlsModuleRouteButton
- (void)layoutSubviews {
    %orig;
    NLSP26FillCornerButton(self);
}
%end
%end

%ctor {
    @autoreleasepool {
        dlopen("/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls", RTLD_NOW);
        // iOS 26's player (its own group); iOS 16's below. 17 to 18 lay it out otherwise.
        if (@available(iOS 26.0, *)) {
            if (!objc_getClass("_TtC13MediaControls33MediaControlsModuleNowPlayingView") ||
                !objc_getClass("_TtC13MediaControls30MediaControlsModuleSessionView") ||
                ![objc_getClass("_TtC13MediaControls33MediaControlsModuleNowPlayingView") instancesRespondToSelector:@selector(layoutSubviews)]) return;
            NLSPReadPrefs();
            NLObserveDarwin(NL_RELOAD_NOTIFICATION, NLSPPrefsChanged, CFNotificationSuspensionBehaviorCoalesce);
            %init(NLSP26);
#ifdef NLI_FILELOG
            dispatch_async(dispatch_get_main_queue(), ^{ NLSP26WatchDumpAsks(); });
#endif
            return;
        }
        if (@available(iOS 17.0, *)) return;
        if (!objc_getClass("MRUControlCenterView") || !objc_getClass("MRUNowPlayingViewController") ||
            !objc_getClass("MRUNowPlayingTransportControlsView") || !objc_getClass("MRURoutingView")) return;
        if (![objc_getClass("MRUControlCenterViewController") instancesRespondToSelector:@selector(nowPlayingViewController:applyLayout:)] ||
            ![objc_getClass("MRUControlCenterViewController") instancesRespondToSelector:@selector(setState:)] ||
            ![objc_getClass("MRUNowPlayingViewController") instancesRespondToSelector:@selector(layout)] ||
            ![objc_getClass("MRURoutingView") instancesRespondToSelector:@selector(tableView)]) return;
        NLSPReadPrefs();
        NLObserveDarwin(NL_RELOAD_NOTIFICATION, NLSPPrefsChanged, CFNotificationSuspensionBehaviorCoalesce);
        %init;
        gNLSPCanAdopt = [objc_getClass("MRUTransportButton") instancesRespondToSelector:@selector(setAsset:animated:)];   // NowLyrics' own module can hold a copy
        dlopen("/System/Library/PrivateFrameworks/ControlCenterUI.framework/ControlCenterUI", RTLD_NOW);
        if ([objc_getClass("CCUIModuleCollectionViewController") instancesRespondToSelector:@selector(_sizesForModuleIdentifiers:moduleInstanceByIdentifier:interfaceOrientation:)] &&
            [objc_getClass("CCUIControlCenterPositionProvider") instancesRespondToSelector:
                @selector(_generateRectByIdentifierWithOrderedIdentifiers:orderedSizes:packingOrder:startPosition:maximumSize:outputLayoutSize:)] &&
            [objc_getClass("CCUIContentModuleContainerViewController") instancesRespondToSelector:@selector(transitionToExpandedMode:)]) {
            %init(NLSPModuleGrid);
        }
    }
}
