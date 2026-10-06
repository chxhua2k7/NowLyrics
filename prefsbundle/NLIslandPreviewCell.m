//
//  NLIslandPreviewCell.m
//  The top row of the "Lyrics Island" page: a compact Dynamic Island
//  drawn at its real size, singing random lines (NLPreviewLines.m) with the
//  page's current color, line change, font size and scroll speed. The strip in
//  it is NowLyricsIsland's own NLIslandStripView, so what it shows is what the
//  island will do.
//
//  It answers touches the way the real island does: it swells under a finger
//  with a light tap, a tap moves on to the next line, and a long press opens
//  it with a firmer one. Open, it stays until tapped.
//  Every move is a spring given as response and damping, the way UIKit's own
//  system animations are tuned.
//
//  With "Preview what's playing" on and music playing, it shows what is
//  playing instead: the real cover in the sample's place, a system waveform
//  view (MRUWaveformView, colored by the cover as the island's is; moved by
//  made-up levels, as the real ones need an audio tap Preferences has no
//  entitlement for) in the sample waveform's place, the island's own line
//  (word by word as the island does it, NLLocate.m), and opened, the open
//  island's title, progress and controls from MediaControls'
//  MRUActivityNowPlayingViewController, the controller MediaRemoteUI draws the
//  island with, which work. Cover and waveform move exactly as the sample's
//  do. Nothing playing, it goes back to the sample lines.
//
//  The page's controller posts NLIslandPreviewChangedNotification after each
//  change; the cell then reads the island page's settings again
//  (NLIslandPreviewValuesFromPlist, through its row's page).
//

#import "../NLIslandStrip.h"
#import "NLLyricsPages.h"
#import <objc/runtime.h>

// MRUActivityNowPlayingViewController, the island's now-playing element.
@interface NSObject (NLActivity)
- (void)setActiveLayoutMode:(NSInteger)mode;
- (UIView *)leadingView;   // its cover: closed at the leading side, open at the top left
- (UIView *)trailingView;  // its waveform: closed at the trailing side, open at the top right
@end

// MediaRemoteUI's numbering (SpringBoard's is one lower).
static const NSInteger kNLActivityCompact = 3;
static const NSInteger kNLActivityExpanded = 4;

#pragma mark - Standing in for the island's host

// The island's views ask their host what they are showing as
// (-[UIView SBUISA_layoutMode], the hosted element context's layout mode) and
// where the camera is (-SBUISA_systemApertureObstructedAreaLayoutGuide). Here
// there is no host: the answers would be "nothing" (its content stays hidden)
// and no camera (its header lands above the top). Views inside the preview's
// island get the preview's answers instead; every other view, the real ones.
static char kNLHostModeKey, kNLHostGuideKey;
static IMP gLayoutModeIMP, gObstructedIMP;

// The nearest answer the preview left on `view` or an ancestor under `key`,
// nil outside the preview's island.
static id NLHostAnswer(UIView *view, const void *key) {
    for (UIView *v = view; v; v = v.superview) {
        id value = objc_getAssociatedObject(v, key);
        if (value) return value;
    }
    return nil;
}

static NSInteger NLHostLayoutMode(UIView *self, SEL _cmd) {
    NSNumber *mode = NLHostAnswer(self, &kNLHostModeKey);
    return mode ? mode.integerValue : ((NSInteger (*)(id, SEL))gLayoutModeIMP)(self, _cmd);
}

static id NLHostObstructedGuide(UIView *self, SEL _cmd) {
    return NLHostAnswer(self, &kNLHostGuideKey) ?: ((id (*)(id, SEL))gObstructedIMP)(self, _cmd);
}

static void NLStandInForHost(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gLayoutModeIMP = NLReplaceMethod(UIView.class, NSSelectorFromString(@"SBUISA_layoutMode"), (IMP)NLHostLayoutMode);
        gObstructedIMP = NLReplaceMethod(UIView.class, NSSelectorFromString(@"SBUISA_systemApertureObstructedAreaLayoutGuide"), (IMP)NLHostObstructedGuide);
    });
}

NSString *const NLIslandPreviewChangedNotification = @"NLIslandPreviewChanged";
// The preview showing the island left the screen: another one still on it
// (a swipe back let go halfway) takes the island up again.
static NSString *const NLIslandPreviewFreedNotification = @"NLIslandPreviewFreed";

// The compact island on a 14 Pro with music playing, grown to the status bar,
// and the expanded one a long press opens.
// The island's black, inside its outline (kNLRing, drawn outside it, as the
// real one's is): measured with the outline at 191 x 50 closed, 371 x 198
// open with music.
static const CGFloat kNLRing = 1.5;
static const CGSize kNLCompact = {188, 47};
static const CGSize kNLExpanded = {330, 92};
static const CGSize kNLExpandedLive = {368, 195};   // the real one on a 14 Pro: cover, line, progress, controls
static const CGSize kNLOpenView = {371, 198};       // the open island's own view, laid out at the measured size
#define kNLClosedScale (kNLCompact.width / kNLExpandedLive.width)   // the closed island's width over the open one's
static const CGFloat kNLExpandedLiveRadius = 44.5;
// Crescendo's volume row in the open island (CRHooksDynamicIsland.x): the
// island opens this much taller, the 24 pt slider 24 pt above its bottom,
// 24 pt in from the sides; above NextUp 3's row it is centred between the
// transport controls and that row, with room to keep it off the row's line.
static const CGFloat kNLVolumeStrip = 40;
static const CGFloat kNLVolumeStripAboveNextUp = 44;
static const CGFloat kNLVolumeSlider = 24;

@interface NSObject (NLNextUpRow)
+ (CGFloat)preferredHeightForControlCenter;   // NUNextUpRowView: its height in the island
- (void)configureForDynamicIsland;
- (void)refreshFromManager;
@end
// The outline as SpringBoard's key line behaves: bright while the island
// changes or is touched, then settling to a dimmer, inert line.
static const NSTimeInterval kNLKeyLineHold = 2.5;
static const CGFloat kNLKeyLineInert = 0.45;
static const CGFloat kNLTopMargin = 8;   // from the top of the table to the island
static const CGFloat kNLPressScale = 1.06;
static const CGFloat kNLPressScaleOpen = 1.02;   // the swell when the island is open
static const NSTimeInterval kNLExpandDelay = 0.45;
static const NSTimeInterval kNLAutoClose = 5;   // "Auto compact": an open island untouched this long closes
static const NSUInteger kNLBars = 6;
static const NSUInteger kNLRecentLines = 20;   // not repeated until this many others came by

@interface NLIslandPreviewCell () <UIGestureRecognizerDelegate>
@end

// The open island's extra rows hang below their host, which takes the open
// view's geometry so they move as it moves: touches still reach them there.
// Its empty space is the island's.
@interface NLExtrasHostView : UIView
@end

@implementation NLExtrasHostView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    if (self.hidden || self.alpha < 0.01 || !self.userInteractionEnabled) return nil;
    for (UIView *sub in self.subviews.reverseObjectEnumerator) {
        UIView *hit = [sub hitTest:[self convertPoint:point toView:sub] withEvent:event];
        if (hit) return hit;
    }
    return nil;
}
@end


@implementation NLIslandPreviewCell {
    UIView *_pill;
    UIView *_ring;   // the outline, around the pill rather than on it
    UIImageView *_art;
    NLWaveformView *_wave;
    // The real island, while music plays and the switch wants it (nil: the
    // sample lines run).
    BOOL _liveWanted;
    NSDictionary *_liveInfo;
    NSString *_liveBundle;
    NSTimer *_liveTimer;
    NSUInteger _liveTicks;
    UIViewController *_activity;
    UIView *_liveWave;                     // the island's own waveform view, in the sample waveform's place
    UIView *_liveArt;                      // the island's own cover view, in the sample cover's place
    NLWaveformDriver *_activityWave;       // moves its waveform, which has no audio tap here
    NSUInteger _liveArtworkPrint;          // the cover the album color was taken from (NLArtworkPrint; 0: none)
    BOOL _activityPlacesLive;              // the open view may move the cover and waveform (opening, once)
    BOOL _keepingLiveViews;                // inside -nlKeepLiveViewsThrough: (a nested pass is left alone)
    BOOL _collapsingLive;                  // the live island is closing: the cover and waveform are the close animation's
    NSUInteger _closeGeneration;           // invalidates a close animation's last step when reopened
    CFTimeInterval _quietUntil;            // live updates wait until the open/close animation is over
    NLIslandStripView *_strip;
    UILabel *_titleLabel;      // expanded only
    UILabel *_lineLabel;       // expanded only
    UIColor *_albumColor;
    NSString *_line;
    NSMutableArray<NSString *> *_recent;
    NSUInteger _generation;    // invalidates the pending line change
    NSUInteger _pressGeneration;
    BOOL _pressStartedOpen;
    CGFloat _fontSize;
    BOOL _scrollUp;
    BOOL _wordByWord;
    BOOL _expanded;
    BOOL _pressCancelled;
    NSString *_openMode;       // islandPreviewOpen: "closed", "open" or "auto"
    NSUInteger _autoCloseGeneration;   // invalidates the pending auto close
    BOOL _quiet;               // opening or closing by itself: no tap felt
    BOOL _stretching;   // the press became a sideways pull
    UIViewPropertyAnimator *_pressAnimator;   // the swell under the finger, stopped when a pull takes over
    CGPoint _pressStart;
    UIImpactFeedbackGenerator *_lightTap, *_firmTap;
    UIView *_volumeRow;        // Crescendo's slider in the open island, when it wants one there
    UIView *_nextUpRow;        // NextUp 3's Up Next row (its NUNextUpRowView), when it wants one there
    UIView *_extrasHost;       // holds them over the open view, moving as it moves (not in it: see -nlLayoutExtraRows)
    CGFloat _extraHeight;      // what they add to the open island
    BOOL _crescendoWanted, _nextUpWanted;
    id _nextUpObserver;
    NSUInteger _keyLineGeneration;   // invalidates the pending settle of the outline
}

// The stand-in cover: NowLyrics' own icon (the 87 px one in this bundle). Its
// album color comes from the same NLColorFromArtwork() the island uses.
static UIImage *NLSampleArtwork(void) {
    return NL_ONCE([UIImage imageNamed:@"NowLyrics" inBundle:NLPrefsBundle()
                    compatibleWithTraitCollection:[UITraitCollection traitCollectionWithDisplayScale:3]]);
}

// That color, worked out once (through a PNG of the icon): the icon never
// changes, and every new cell and every return from the live island want it.
static UIColor *NLSampleArtworkColor(void) {
    return NL_ONCE(NLColorFromArtwork(UIImagePNGRepresentation(NLSampleArtwork())));
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    if ((self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier])) {
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        self.clipsToBounds = NO;
        self.contentView.clipsToBounds = NO;

        _pill = [[UIView alloc] initWithFrame:CGRectMake(0, 0, kNLCompact.width, kNLCompact.height)];
        _pill.backgroundColor = UIColor.blackColor;
        _pill.layer.cornerRadius = kNLCompact.height / 2;
        _pill.layer.cornerCurve = kCACornerCurveContinuous;
        // The real island's outline, measured from a screenshot: 1.5 pt of 16 %
        // white, around the black rather than over its edge.
        _ring = [UIView new];
        _ring.userInteractionEnabled = NO;
        _ring.layer.borderWidth = kNLRing;
        _ring.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.16].CGColor;
        _ring.layer.cornerCurve = kCACornerCurveContinuous;
        [self.contentView addSubview:_ring];
        _pill.clipsToBounds = YES;
        [self.contentView addSubview:_pill];

        UIImage *art = NLSampleArtwork();
        _art = [[UIImageView alloc] initWithImage:art];
        _art.layer.cornerCurve = kCACornerCurveContinuous;
        _art.clipsToBounds = YES;
        [_pill addSubview:_art];
        _albumColor = NLSampleArtworkColor();

        _wave = [[NLWaveformView alloc] initWithBars:kNLBars];
        _wave.artwork = art;   // colored by the sample cover, the way the island's is by the real one
        [_pill addSubview:_wave];

        _strip = [[NLIslandStripView alloc] initWithFrame:CGRectZero];
        [_pill addSubview:_strip];

        _titleLabel = [UILabel new];
        _titleLabel.text = @"NowLyrics";
        _titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        _titleLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
        _titleLabel.alpha = 0;
        [_pill addSubview:_titleLabel];

        _lineLabel = [UILabel new];
        _lineLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
        _lineLabel.numberOfLines = 2;
        _lineLabel.adjustsFontSizeToFitWidth = YES;
        _lineLabel.minimumScaleFactor = 0.8;
        _lineLabel.alpha = 0;
        [_pill addSubview:_lineLabel];

        UILongPressGestureRecognizer *press = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(nlPressed:)];
        press.minimumPressDuration = 0;
        press.delegate = self;
        [_pill addGestureRecognizer:press];

        _lightTap = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        _firmTap = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
        _recent = [NSMutableArray array];
        _fontSize = kNLDefaultFontSize;

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nlApplyValues)
                                                     name:NLIslandPreviewChangedNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nlIslandFreed)
                                                     name:NLIslandPreviewFreedNotification object:nil];
    }
    return self;
}

// NowLyrics' own color: that of the main switch's icon (NLSampleCoverIcon).
UIColor *NLNowLyricsColor(void) {
    return NL_ONCE(NLColorFromArtwork(UIImagePNGRepresentation(NLSampleCoverIcon())));
}

// The theme is the color of what the island shows: the album's, or NowLyrics'
// for the sample (and for a grey cover).
- (void)nlReportTheme {
    if (![self nlOnScreen]) return;   // a cell waiting for reuse has no say
    NLThemeSetColor((_liveInfo && _albumColor) ? _albumColor : NLNowLyricsColor());
}

// `block` on the main queue after `delay` seconds, given the cell if it is still
// around. The block reads state only through `cell`.
- (void)nlAfter:(NSTimeInterval)delay run:(void (^)(NLIslandPreviewCell *cell))block {
    __weak typeof(self) weakSelf = self;
    NLAfter(delay, ^{
        NLIslandPreviewCell *cell = weakSelf;
        if (cell) block(cell);
    });
}

// The outline lights up, and settles again after a while.
- (void)nlWakeKeyLine {
    NSUInteger generation = ++_keyLineGeneration;
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction;
    [UIView animateWithDuration:0.2 delay:0 options:options animations:^{ self->_ring.alpha = 1; } completion:nil];
    [self nlAfter:kNLKeyLineHold run:^(NLIslandPreviewCell *cell) {
        if (cell->_keyLineGeneration != generation) return;
        [UIView animateWithDuration:0.8 delay:0 options:options animations:^{ cell->_ring.alpha = kNLKeyLineInert; } completion:nil];
    }];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    if (_nextUpObserver) [[NSNotificationCenter defaultCenter] removeObserver:_nextUpObserver];
    [_liveTimer invalidate];
    [_activity removeFromParentViewController];
}

#pragma mark Layout

// No card behind it: the island floats on the page, in a group of its own.
- (void)nlClearBackground {
    self.backgroundColor = UIColor.clearColor;
    self.contentView.backgroundColor = UIColor.clearColor;
    self.backgroundView = nil;
    self.selectedBackgroundView = nil;
    self.separatorInset = UIEdgeInsetsMake(0, CGFLOAT_MAX / 4, 0, 0);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self nlClearBackground];
    if (_pill.superview != self.contentView && ![self nlOnScreen]) [self nlScreenChanged];   // its row was taken away
    [self nlLayoutPill];
}

// The island floats over the whole table rather than sitting in its row, as
// the real one floats over the app: opening, it keeps its top edge (where the
// camera is) and grows down and out over the rows below, wider than the row's
// card if it must, and pushes nothing aside.
- (UITableView *)nlTable {
    return (UITableView *)NLAncestorOfClass(self.superview, UITableView.class);
}

// Showing the real island (what plays, through its own controller) rather
// than the sample.
- (BOOL)nlLive {
    return _liveInfo != nil && _activity != nil;
}

// The island and its outline move as one.
- (void)nlSetIslandTransform:(CGAffineTransform)t {
    _pill.transform = t;
    _ring.transform = t;
}

// The outline and the island into `host`: over the table's cells (which the
// table adds and reorders) when it is the table, plainly in the row otherwise.
- (void)nlMoveIslandTo:(UIView *)host overCells:(BOOL)over {
    [host addSubview:_ring];
    [host addSubview:_pill];
    _ring.layer.zPosition = over ? 99 : 0;
    _pill.layer.zPosition = over ? 100 : 0;
}

// The live cover and waveform that exist (either may be nil), to loop over.
static NSArray<UIView *> *NLExisting(UIView *a, UIView *b) {
    return a && b ? @[a, b] : a ? @[a] : b ? @[b] : @[];
}

// `view` where the sample cover or waveform `sample` is: bounds and centre
// (closing gives the live ones a scale for a moment).
static void NLPlaceLike(UIView *view, UIView *sample) {
    view.bounds = (CGRect){CGPointZero, sample.bounds.size};
    view.center = sample.center;
}

// The one preview whose island is up on the page. The table makes a new cell
// for the row now and then (scrolling, reloads) and keeps the old one for
// reuse, hidden but still in its window: its island, hosted in the table
// rather than in the row, stayed up next to the new one's.
static __weak NLIslandPreviewCell *gIslandOwner;

- (BOOL)nlOnScreen {
    if (self.window == nil || self.hidden) return NO;
    // A row its page took away (the main page's top set to something else)
    // can stay in the table a while, not hidden, for the delete animation.
    id page = self.specifier.target;
    return ![page isKindOfClass:PSListController.class] || [(PSListController *)page indexOfSpecifier:self.specifier] != NSNotFound;
}

- (void)nlHostPill {
    UIView *table = [self nlOnScreen] ? [self nlTable] : nil;
    if (table) {
        NLIslandPreviewCell *other = gIslandOwner;
        if (other && other != self) [other nlStandDown];
        gIslandOwner = self;
    } else if (gIslandOwner == self) {
        gIslandOwner = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:NLIslandPreviewFreedNotification object:nil];
        });
    }
    UIView *host = table ?: self.contentView;
    if (_pill.superview == host) return;
    // Often inside the page's push animation, which must not carry it along.
    [UIView performWithoutAnimation:^{
        [self nlMoveIslandTo:host overCells:table != nil];
        [self nlLayoutPill];
        [self->_pill layoutIfNeeded];
    }];
}

// The row moves when rows above it come and go.
- (void)setFrame:(CGRect)frame {
    [super setFrame:frame];
    if (_pill) [self nlLayoutPill];
}

// Where the island's centre goes for a given size: its top right under the
// navigation bar (or centred in the row before it is in the table), centred
// on the page, as the real one is on the screen (the row's card is not quite
// centred). The page is what the safe area leaves: a sidebar floating over
// the table (iPad Settings, iOS 26) takes its side.
- (CGPoint)nlPillCentre:(CGSize)size {
    UIView *host = _pill.superview ?: self.contentView;
    CGPoint top;
    if ([host isKindOfClass:UITableView.class]) {
        UIEdgeInsets safe = host.safeAreaInsets;
        top = CGPointMake(safe.left + round(host.bounds.size.width - safe.left - safe.right) / 2, kNLTopMargin);
    } else {
        CGRect b = self.contentView.bounds;
        top = [self.contentView convertPoint:CGPointMake(round(CGRectGetMidX(b)), round(CGRectGetMidY(b) - kNLCompact.height / 2))
                                      toView:host];
    }
    return CGPointMake(top.x, top.y + size.height / 2);
}

// Bounds and centre rather than frame, so the press transform can stay on.
- (void)nlLayoutPill {
    BOOL live = [self nlLive];
    [self nlUpdateExtraHeight];   // NextUp's row only while live
    CGSize liveSize = CGSizeMake(kNLExpandedLive.width, kNLExpandedLive.height + _extraHeight);
    CGSize size = _expanded ? (live ? liveSize : kNLExpanded) : kNLCompact;
    // The closed island's top: right under the navigation bar, at the top of
    // the table (its own row below only keeps room for it to open into);
    // open, it keeps that top.
    _pill.bounds = CGRectMake(0, 0, size.width, size.height);
    _pill.center = [self nlPillCentre:size];
    _pill.layer.cornerRadius = _expanded ? (live ? kNLExpandedLiveRadius : 38) : size.height / 2;
    _ring.bounds = CGRectInset(_pill.bounds, -kNLRing, -kNLRing);
    _ring.center = _pill.center;
    _ring.layer.cornerRadius = _pill.layer.cornerRadius + kNLRing;

    // Open with music, where the real open island has them (measured on a 14 Pro).
    CGFloat art = _expanded ? (live ? 66 : 52) : 23;
    _art.frame = _expanded ? (live ? CGRectMake(22 - kNLRing, 22 - kNLRing, art, art) : CGRectMake(20, (size.height - art) / 2, art, art))
                           : CGRectMake(10, 12, art, art);
    _art.layer.cornerRadius = _expanded ? (live ? 13 : 11) : 5;

    CGFloat barsRight = size.width - (_expanded ? (live ? 28 - kNLRing : 22) : 10);
    CGFloat barsMidY = _expanded ? (live ? 49 - kNLRing : 28) : 23.5;
    _wave.bounds = CGRectMake(0, 0, kNLBars * 4, 20);
    _wave.center = CGPointMake(barsRight - kNLBars * 2, barsMidY);
    // Closing, the cover and waveform are moved by the close animation alone
    // (-nlSetExpanded:), and put in their closed places when it ends.
    // The open view first: laying it out can move the cover and waveform.
    [self nlLayoutActivity:size];
    if (!_collapsingLive) [self nlPlaceLiveViews];

    CGFloat textX = CGRectGetMaxX(_art.frame) + 14, textW = barsRight - 30 - textX;
    // Bounds and centre here too: these carry a scale while they appear.
    CGFloat lineW = size.width - 22 - textX;
    _titleLabel.bounds = CGRectMake(0, 0, textW, 18);
    _titleLabel.center = CGPointMake(textX + textW / 2, 18 + 9);
    _lineLabel.bounds = CGRectMake(0, 0, lineW, 40);
    _lineLabel.center = CGPointMake(textX + lineW / 2, 36 + 20);

    // The strip as NowLyricsIsland lays it out: the font's exact line height on
    // the bottom edge, centred at the camera's width less a little each side.
    CGRect strip = NLIslandStripFrame(size, kNLDefaultSensorWidth - kNLContentGap * 2, NLIslandLineHeight(_fontSize));
    // Never carried along by the island's spring: it is hidden while the
    // island is open and comes back in place once it has closed.
    [UIView performWithoutAnimation:^{
        if (!CGRectEqualToRect(self->_strip.frame, strip)) self->_strip.frame = strip;
    }];
}

#pragma mark Lifecycle

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self nlScreenChanged];
}

// Hidden by the table to wait for reuse: off the page as much as out of the window.
- (void)setHidden:(BOOL)hidden {
    BOOL was = self.hidden;
    [super setHidden:hidden];
    if (was != hidden && _pill) [self nlScreenChanged];
}

- (void)nlIslandFreed {
    if (!gIslandOwner && [self nlOnScreen]) [self nlScreenChanged];
}

// Another cell shows the island now: this one's goes back into its own row
// (hidden with it) and stops.
- (void)nlStandDown {
    if (gIslandOwner == self) gIslandOwner = nil;
    [self nlStop];
    [UIView performWithoutAnimation:^{ [self nlMoveIslandTo:self.contentView overCells:NO]; }];
}

- (void)nlStop {
    _generation++;   // stops the cycle
    [_liveTimer invalidate];
    _liveTimer = nil;
    _closeGeneration++;   // a close on its way has no last step left: done below
    if (_expanded || _collapsingLive) {
        _expanded = NO;   // back closed next time, without animating off screen
        _titleLabel.alpha = _lineLabel.alpha = 0;
        _strip.alpha = 1;
        [self nlSetIslandTransform:CGAffineTransformIdentity];
        // Live, the open island's own view and the cover and waveform too, as
        // a close leaves them: it stayed up in the closed island, its line
        // over the strip's, when the island came back.
        [self nlEndLiveClose];
        [self nlLayoutPill];
    }
}

// The real island as its close leaves it, at once: the open view shrunk away,
// the cover and waveform whole and back in the island, the controller in its
// closed layout.
- (void)nlEndLiveClose {
    if (!_activity) return;
    CGAffineTransform closed = NLOpenViewClosed();
    [UIView performWithoutAnimation:^{
        self->_activity.view.alpha = 0;
        self->_activity.view.transform = closed;
        self->_extrasHost.alpha = 0;
        self->_extrasHost.transform = closed;
        for (UIView *view in NLExisting(self->_liveArt, self->_liveWave)) {
            view.transform = CGAffineTransformIdentity;
            view.alpha = 1;
        }
    }];
    [self nlSetActivityMode:kNLActivityCompact];
    [self nlReturnLiveViews];
}

- (void)nlScreenChanged {
    [self nlHostPill];
    // Its waveform drawn nowhere (the page covered): the driver's display link
    // rests until it is in a window again.
    if (_liveWave.window) [_activityWave driveViewsIn:nil];
    else [_activityWave stop];
    if (![self nlOnScreen]) {
        [self nlStop];
        return;
    }
    _generation++;
    [self nlApplyValues];
    [self nlReportTheme];
    [self nlWakeKeyLine];
    [self nlAnimateBars];
    [self nlNextLine];
    [_liveTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _liveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        NLIslandPreviewCell *cell = weakSelf;
        if (![cell nlOnScreen]) {
            [timer invalidate];
            [cell nlScreenChanged];   // its island back into its row
            return;
        }
        [cell nlLiveTick];
    }];
    [self nlLiveTick];
    [self nlOpenAsWanted:YES];
}

// "Expanded" and "Auto compact" open the island as it comes up (after the
// page's push), "Compact" leaves it closed; changed on the page, at once.
- (void)nlOpenAsWanted:(BOOL)appearing {
    if (appearing && [_openMode isEqualToString:@"closed"]) return;
    NSString *mode = _openMode;
    [self nlAfter:appearing ? kNLExpandDelay : 0 run:^(NLIslandPreviewCell *cell) {
        if (![cell nlOnScreen] || ![cell->_openMode isEqualToString:mode]) return;
        cell->_quiet = YES;
        [cell nlSetExpanded:![mode isEqualToString:@"closed"]];
        cell->_quiet = NO;
    }];
}

// "Auto compact": the open island closes once left alone for kNLAutoClose;
// every touch on it starts the wait again.
- (void)nlScheduleAutoClose {
    NSUInteger generation = ++_autoCloseGeneration;
    if (!_expanded || ![_openMode isEqualToString:@"auto"]) return;
    [self nlAfter:kNLAutoClose run:^(NLIslandPreviewCell *cell) {
        if (cell->_autoCloseGeneration != generation || !cell->_expanded || ![cell nlOnScreen]) return;
        cell->_quiet = YES;
        [cell nlSetExpanded:NO];
        cell->_quiet = NO;
    }];
}

- (void)nlApplyValues {
    id target = self.specifier.target;
    NSDictionary *values = NLIslandPreviewValuesFromPlist([target isKindOfClass:PSListController.class] ? target : nil);
    _fontSize = NLLooseNum(values[@"islandFontSize"], kNLDefaultFontSize);
    CGFloat speed = NLLooseNum(values[@"islandMarqueeSpeed"], kNLDefaultSpeed);
    _scrollUp = [values[@"islandTransition"] isEqual:@"up"];
    _liveWanted = NLLooseBool(values[@"islandPreviewLive"], YES);
    NSString *openMode = [NL_ONCE((@[@"open", @"auto"])) containsObject:values[@"islandPreviewOpen"]] ? values[@"islandPreviewOpen"] : @"closed";
    BOOL openChanged = _openMode && ![openMode isEqualToString:_openMode];
    _openMode = openMode;
    if (openChanged) [self nlOpenAsWanted:NO];
    _wordByWord = NLLooseBool(values[@"islandWordByWord"], YES);
    UIColor *textColor = NLIslandTextColor([values[@"islandColor"] isEqual:@"artwork"], _albumColor);
    _crescendoWanted = NLCrescendoShows(NLCrescendoDynamicIsland);
    _nextUpWanted = NLNextUpShowsInIsland();   // its library is loaded then
    _lineLabel.textColor = textColor;
    [self nlLayoutPill];   // which works out the extra rows' height first
    [_strip layoutIfNeeded];
    [_strip applyFontSize:_fontSize color:textColor speed:speed];
}

#pragma mark Lines

// The preview lines have no word times, so word by word is shown with made-up
// ones: a CJK character or a word (with its space) every kNLPreviewPieceTime.
static const NSTimeInterval kNLPreviewPieceTime = 0.26;

static NSArray<NSString *> *NLPreviewPieces(NSString *line) {
    NSMutableArray<NSString *> *pieces = [NSMutableArray array];
    NSMutableString *word = [NSMutableString string];
    NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
    [line enumerateSubstringsInRange:NSMakeRange(0, line.length) options:NSStringEnumerationByComposedCharacterSequences
                          usingBlock:^(NSString *ch, NSRange r, NSRange er, BOOL *stop) {
        unichar c = [ch characterAtIndex:0];
        BOOL isSpace = [space characterIsMember:c];
        if (isSpace) {
            [word appendString:ch];   // a word keeps its trailing space
            return;
        }
        BOOL latin = c < 0x2E80;   // below the CJK blocks: letters that make up words
        if (word.length && (!latin || [space characterIsMember:[word characterAtIndex:word.length - 1]])) {
            [pieces addObject:[word copy]];
            [word setString:@""];
        }
        [word appendString:ch];
        if (!latin) {
            [pieces addObject:[word copy]];
            [word setString:@""];
        }
    }];
    if (word.length) {
        if (pieces.count && [[word stringByTrimmingCharactersInSet:space] length] == 0) {
            pieces[pieces.count - 1] = [pieces.lastObject stringByAppendingString:word];
        } else {
            [pieces addObject:word];
        }
    }
    return pieces;
}

// A line that has not come by recently.
- (NSString *)nlPickLine {
    NSArray<NSString *> *pool = NLPreviewLinePool(NLPrefsBundle());
    NSMutableArray<NSString *> *fresh = [NSMutableArray array];
    for (NSString *line in pool) {
        if (![_recent containsObject:line] && ![line isEqualToString:_line]) [fresh addObject:line];
    }
    NSArray<NSString *> *from = fresh.count ? fresh : pool;
    NSString *line = from[arc4random_uniform((uint32_t)from.count)];
    [_recent addObject:line];
    while (_recent.count > MIN(kNLRecentLines, pool.count / 2)) [_recent removeObjectAtIndex:0];
    return line;
}

// Shows a new line, then waits for it: a short one for a moment, a long one
// until it has scrolled through at the set speed. Held still while expanded.
- (void)nlNextLine {
    NSUInteger generation = ++_generation;
    if ([self nlLive]) return;   // the real island's lines come from what is playing
    _line = [self nlPickLine];
    [_strip setText:_line explicit:NO scrollUp:_scrollUp];
    NSTimeInterval shown = _strip.marqueeReadDuration;
    if (_wordByWord) {
        NSArray<NSString *> *pieces = NLPreviewPieces(_line);
        NSMutableArray *starts = [NSMutableArray array], *ends = [NSMutableArray array];
        for (NSUInteger i = 0; i < pieces.count; i++) {
            [starts addObject:@(0.2 + i * kNLPreviewPieceTime)];
            [ends addObject:@(0.2 + (i + 1) * kNLPreviewPieceTime)];
        }
        [_strip setWordTexts:pieces starts:starts ends:ends position:0 rate:1];
        shown = 0.2 + pieces.count * kNLPreviewPieceTime + 1.2;
    }
    NSTimeInterval dwell = MAX(shown, 2.6);
    [UIView transitionWithView:_lineLabel duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ self->_lineLabel.text = self->_line; } completion:nil];
    [self nlAfter:dwell run:^(NLIslandPreviewCell *cell) {
        if (cell->_generation != generation || !cell.window) return;
        if (cell->_expanded) { cell->_generation++; return; }   // resumes on collapse
        [cell nlNextLine];
    }];
}

#pragma mark Springs

// A spring the way Apple describes theirs: how quickly it settles (response,
// seconds) and how much it overshoots (damping ratio, 1 = none).
static UIViewPropertyAnimator *NLSpring(NSTimeInterval response, CGFloat damping, void (^animations)(void)) {
    UISpringTimingParameters *spring = [[UISpringTimingParameters alloc] initWithDampingRatio:damping
                                                                              initialVelocity:CGVectorMake(0, 0)];
    UIViewPropertyAnimator *animator = [[UIViewPropertyAnimator alloc] initWithDuration:response timingParameters:spring];
    animator.interruptible = YES;
    [animator addAnimations:animations];
    [animator startAnimation];
    return animator;
}

#pragma mark Touch

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)other {
    return YES;   // the table still scrolls when the drag starts on the island
}

// The open real island's controls take their own touches.
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gesture shouldReceiveTouch:(UITouch *)touch {
    if (_expanded) [self nlScheduleAutoClose];   // the open island's own controls too
    if (!_expanded || !_liveInfo) return YES;
    for (UIView *v = touch.view; v && v != _pill; v = v.superview) {
        if ([v isKindOfClass:UIControl.class] || v == _nextUpRow) return NO;   // NextUp's row: its taps and swipes
    }
    return YES;
}

- (void)nlPressed:(UILongPressGestureRecognizer *)press {
    switch (press.state) {
        case UIGestureRecognizerStateBegan: {
            _pressCancelled = NO;
            _stretching = NO;
            _pressStartedOpen = _expanded;
            _pressStart = [press locationInView:self];
            [_lightTap prepare];
            [_firmTap prepare];
            [_lightTap impactOccurred];
            [self nlSetPressed:YES];
            [self nlWakeKeyLine];
            _autoCloseGeneration++;   // not while the finger is down
            if (_expanded) break;   // open already: this press is a tap to close
            NSUInteger generation = ++_pressGeneration;
            [self nlAfter:kNLExpandDelay run:^(NLIslandPreviewCell *cell) {
                if (cell->_pressGeneration == generation && !cell->_pressCancelled) [cell nlSetExpanded:YES];
            }];
            break;
        }
        case UIGestureRecognizerStateChanged: {
            CGPoint p = [press locationInView:self];
            CGFloat dx = p.x - _pressStart.x, dy = p.y - _pressStart.y;
            // Dragged, the island stretches after the finger, as the real one
            // does; it is no longer a tap or a long press then.
            if (!_pressCancelled && (_stretching || hypot(dx, dy) > 8)) {
                if (!_stretching) {
                    _stretching = YES;
                    _pressGeneration++;   // no opening on a hold any more
                    [self nlSetPageScrolls:NO];
                }
                [self nlStretch:CGPointMake(dx, dy)];
            }
            break;
        }
        case UIGestureRecognizerStateEnded: {
            if (_stretching) {
                _stretching = NO;
                [self nlSetPageScrolls:YES];
                [self nlSetPressed:NO];   // springs back
                [self nlScheduleAutoClose];
                break;
            }
            if (_pressCancelled) break;
            _pressGeneration++;
            [self nlSetPressed:NO];
            if (_pressStartedOpen) [self nlSetExpanded:NO];   // a tap on the open island closes it
            else if (_expanded) [self nlScheduleAutoClose];     // just opened by this press: open until tapped (or left alone, auto)
            else if (!_liveInfo) [self nlNextLine];            // a tap: the next sample line
            break;
        }
        default:   // cancelled, failed
            if (_stretching) [self nlSetPageScrolls:YES];
            _stretching = NO;
            _pressCancelled = YES;
            _pressGeneration++;
            [self nlSetPressed:NO];
            break;
    }
}

// Pulled, the island leans after the finger in any direction and stretches
// along the pull (a little thinner across it), with resistance that grows
// the further it goes (a rubber band: at most about 40 pt each way). Follows
// the finger directly; letting go springs it back (-nlSetPressed:).
- (void)nlStretch:(CGPoint)d {
    CGFloat limit = 40;
    CGFloat px = limit * tanh(d.x / (limit * 3)), py = limit * tanh(d.y / (limit * 3));
    CGFloat ax = fabs(px) / limit, ay = fabs(py) / limit;   // 0...1 along each axis
    CGFloat base = _expanded ? kNLPressScaleOpen : kNLPressScale;
    CGAffineTransform t = CGAffineTransformMakeTranslation(px, py);
    t = CGAffineTransformScale(t, base * (1 + ax * 0.12 - ay * 0.04), base * (1 + ay * 0.12 - ax * 0.04));
    if (_pressAnimator.state == UIViewAnimatingStateActive) [_pressAnimator stopAnimation:YES];
    _pressAnimator = nil;
    [UIView performWithoutAnimation:^{ [self nlSetIslandTransform:t]; }];
}

// The page does not scroll while the island is being pulled.
- (void)nlSetPageScrolls:(BOOL)scrolls {
    [self nlTable].scrollEnabled = scrolls;
}

// Swells under the finger (less when open) and settles back when it lifts.
- (void)nlSetPressed:(BOOL)pressed {
    CGFloat scale = _expanded ? kNLPressScaleOpen : kNLPressScale;
    if (_pressAnimator.state == UIViewAnimatingStateActive) [_pressAnimator stopAnimation:YES];
    _pressAnimator = NLSpring(pressed ? 0.25 : 0.4, pressed ? 0.8 : 0.6, ^{
        [self nlSetIslandTransform:pressed ? CGAffineTransformMakeScale(scale, scale) : CGAffineTransformIdentity];
    });
}

// Opening morphs the island and its artwork in one spring with a little
// overshoot; the compact contents go first and the expanded ones arrive
// growing from 85 %. Closing is the same in reverse, without the overshoot.
- (void)nlSetExpanded:(BOOL)expanded {
    [self nlWakeKeyLine];
    if (_expanded == expanded) return;
    _expanded = expanded;
    _quietUntil = CACurrentMediaTime() + 0.9;
    if (!_quiet) [(expanded ? _firmTap : _lightTap) impactOccurred];
    BOOL live = [self nlLive];
    if (!live) _lineLabel.text = _line;
    // Back to the sample while the real island was still closing: that close
    // loses its last steps to this change (the generation below), so they are
    // taken now.
    if (!live && _collapsingLive) [self nlEndLiveClose];

    // The open island's title, progress and controls grow with the island the
    // way SpringBoard grows an element's content: scaled from the closed
    // island's width about its top centre while fading in. Closing is the
    // reverse with the cover and waveform in it too: everything the open
    // island shows shrinks towards its top centre and fades, the island's view
    // still in its open layout (switching it first hid everything at once);
    // only then do the cover and waveform grow in where the closed island has
    // them.
    UIView *openView = live ? _activity.view : nil;
    UIView *extrasHost = live ? _extrasHost : nil;
    UIView *cover = live ? _liveArt : nil, *wave = live ? _liveWave : nil;
    CGFloat startWidth = _pill.bounds.size.width;
    NSUInteger generation = ++_closeGeneration;
    if (live && expanded) {
        [self nlReturnLiveViews];   // still out of the island from closing
        _collapsingLive = NO;
        // Its open layout once, as it lays it out (the cover at its open size
        // from the start); the spring then takes them to the preview's places.
        _activityPlacesLive = YES;
        [self nlSetActivityMode:kNLActivityExpanded];
        _activityPlacesLive = NO;
        [UIView performWithoutAnimation:^{
            openView.transform = NLOpenViewClosed();
            extrasHost.transform = openView.transform;
            cover.transform = CGAffineTransformIdentity;
            wave.transform = CGAffineTransformIdentity;
        }];
        [UIView animateWithDuration:0.35 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            openView.alpha = 1;
            extrasHost.alpha = 1;
            cover.alpha = 1;   // if reopened before they came back
            wave.alpha = 1;
        } completion:nil];
    }
    if (live && !expanded) {
        _collapsingLive = YES;
        // The rows tweaks add go at once: NextUp's buttons sit on a material,
        // which does not fade with the views above it and was left behind as a
        // ghost while the island closed.
        [UIView performWithoutAnimation:^{ extrasHost.alpha = 0; }];
        [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            openView.alpha = 0;
            cover.alpha = 0;
            wave.alpha = 0;
        } completion:nil];
    }
    // Softer and longer than before (0.5 / 0.42 s, 0.78 / 0.95): it read as fast and stiff.
    NLSpring(expanded ? 0.6 : 0.52, expanded ? 0.82 : 0.9, ^{
        [self nlLayoutPill];
        openView.transform = expanded ? CGAffineTransformIdentity : NLOpenViewClosed();
        extrasHost.transform = openView.transform;
        if (live && !expanded) {
            // About the island's top centre, which is at half its width in its
            // own coordinates: half the open width now, half the closed one at
            // the end of this same spring.
            for (UIView *view in NLExisting(cover, wave)) {
                CGPoint c = view.center;
                view.center = CGPointMake(kNLCompact.width / 2 + kNLClosedScale * (c.x - startWidth / 2), kNLClosedScale * c.y);
                view.transform = CGAffineTransformMakeScale(kNLClosedScale, kNLClosedScale);
            }
        }
        [self nlSetIslandTransform:CGAffineTransformIdentity];
    });
    if (live && !expanded) {
        // While the island is still closing (about two thirds of the way),
        // the cover and waveform grow in. Inside the island they would ride
        // in with its edges, so for now they hang over it, outside it, where
        // they end up on screen, and go back in once all has stopped.
        NLAfter(0.2, ^{
            if (self->_expanded || self->_closeGeneration != generation) return;   // opened again meanwhile
            [self nlSetActivityMode:kNLActivityCompact];
            UIView *host = self->_pill.superview;
            CGPoint origin = self->_pill.frame.origin;   // the closed island's, already
            CGAffineTransform small = CGAffineTransformMakeScale(0.6, 0.6);
            [UIView performWithoutAnimation:^{
                cover.transform = CGAffineTransformIdentity;
                wave.transform = CGAffineTransformIdentity;
                [self nlPlaceLiveViews];
                for (UIView *view in NLExisting(cover, wave)) {
                    CGPoint c = view.center;
                    [host addSubview:view];
                    view.layer.zPosition = self->_pill.layer.zPosition + 1;
                    view.center = CGPointMake(c.x + origin.x, c.y + origin.y);
                    view.transform = small;
                }
            }];
            UIViewPropertyAnimator *grow = [[UIViewPropertyAnimator alloc] initWithDuration:0.42 dampingRatio:0.8 animations:^{
                cover.transform = CGAffineTransformIdentity;
                wave.transform = CGAffineTransformIdentity;
            }];
            [grow addCompletion:^(UIViewAnimatingPosition position) {
                if (self->_closeGeneration == generation && !self->_expanded) [self nlReturnLiveViews];
            }];
            [grow startAnimation];
            [UIView animateWithDuration:0.18 animations:^{ cover.alpha = 1; wave.alpha = 1; }];
        });
    }

    CGAffineTransform small = CGAffineTransformMakeScale(0.85, 0.85);
    NSArray<UILabel *> *labels = @[_titleLabel, _lineLabel];   // the sample's open contents
    if (expanded && !live) for (UILabel *label in labels) label.transform = small;
    // The line goes at once when opening (it would ride down with the island's
    // bottom edge) and comes back once the island has nearly closed.
    if (expanded) [UIView performWithoutAnimation:^{ self->_strip.alpha = 0; }];
    [UIView animateWithDuration:expanded ? 0.12 : 0.24 delay:expanded ? 0 : 0.34
                        options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        if (!expanded) self->_strip.alpha = 1;
        self->_wave.alpha = expanded ? 0.6 : 1;
    } completion:nil];
    NLSpring(expanded ? 0.5 : 0.3, 1, ^{
        for (UILabel *label in labels) {
            label.alpha = (expanded && !live) ? 1 : 0;
            label.transform = expanded ? CGAffineTransformIdentity : small;
        }
    });

    [self nlScheduleAutoClose];   // open: the wait for an auto close; closed: none
    if (!expanded) {
        // Pick the cycle up again where it stopped.
        NSUInteger generation = ++_generation;
        [self nlAfter:1.2 run:^(NLIslandPreviewCell *cell) {
            if (cell->_generation == generation && cell.window && !cell->_expanded) [cell nlNextLine];
        }];
    }
}

// The waveform: bouncing while the sample lines run, or while the music plays.
- (void)nlAnimateBars {
    BOOL playing = _liveInfo ? NLInfoPlaying(_liveInfo) : YES;
    _wave.playing = playing;
    _activityWave.playing = playing && _liveInfo;
}


#pragma mark The real island

// The island's open view (MRUActivityNowPlayingView) sets the frames of its
// cover and waveform in its own -layoutSubviews on every pass, through its
// ivars and in its own 371 x 198 space, wherever they live now (16.5.1:
// {0,0} / {349,0} at 22 pt closed, {21.67,24} 66 pt / {315.33,35} 28 pt open).
// A pass runs whenever something marks the view for layout: its safe area
// changing as the island is pulled up under the navigation bar, a back swipe,
// NextUp. After each pass they go back to where they were before it, in the
// same pass, so the wrong place is never drawn.
static char kNLActivityOwnerKey;
static IMP gActivityLayoutIMP;

static void NLPutBack(UIView *view, CGRect bounds, CGPoint center) {
    if (!view) return;
    if (!CGRectEqualToRect(view.bounds, bounds)) view.bounds = bounds;
    if (!CGPointEqualToPoint(view.center, center)) view.center = center;
}

- (void)nlKeepLiveViewsThrough:(NS_NOESCAPE void (^)(void))layout {
    UIView *art = _liveArt, *wave = _liveWave;
    if (_keepingLiveViews || _activityPlacesLive || (!art && !wave)) { layout(); return; }
    _keepingLiveViews = YES;
    // Bounds and centre, in whatever they are in now (the pill, or the table
    // while the island closes): they can carry a scale then.
    CGRect artBounds = art.bounds, waveBounds = wave.bounds;
    CGPoint artCenter = art.center, waveCenter = wave.center;
    layout();
    [UIView performWithoutAnimation:^{
        NLPutBack(art, artBounds, artCenter);
        NLPutBack(wave, waveBounds, waveCenter);
    }];
    _keepingLiveViews = NO;
}

static void NLActivityLayoutSubviews(UIView *view, SEL cmd) {
    void (*original)(id, SEL) = (void (*)(id, SEL))gActivityLayoutIMP;
    NLIslandPreviewCell *(^owner)(void) = objc_getAssociatedObject(view, &kNLActivityOwnerKey);
    NLIslandPreviewCell *cell = owner ? owner() : nil;
    if (!cell) { original(view, cmd); return; }
    [cell nlKeepLiveViewsThrough:^{ original(view, cmd); }];
}

// Only where the class has its own -layoutSubviews (16.5.1 does): replacing an
// inherited one would replace UIView's for every view.
static void NLKeepLiveViewsInPlace(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class viewClass = objc_getClass("MRUActivityNowPlayingView");
        Method own = viewClass ? class_getInstanceMethod(viewClass, @selector(layoutSubviews)) : NULL;
        if (own && own != class_getInstanceMethod(class_getSuperclass(viewClass), @selector(layoutSubviews))) {
            gActivityLayoutIMP = method_setImplementation(own, (IMP)NLActivityLayoutSubviews);
        }
    });
}

// The island's now-playing controller class, when this iOS has one the
// preview can drive; Nil for good otherwise (iOS 15), and the preview keeps
// the sample.
static Class NLActivityClass(void) {
    static Class activityClass;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class c = NLLoadedClass("MRUActivityNowPlayingViewController", "/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls");
        if ([c instancesRespondToSelector:@selector(leadingView)] && [c instancesRespondToSelector:@selector(setActiveLayoutMode:)]) activityClass = c;
    });
    return activityClass;
}

// Whether the preview can show what plays at all: the theme, worked out
// without the preview (NLThemeRefresh), follows what it would show.
BOOL NLIslandPreviewCanGoLive(void) {
    return NLActivityClass() != Nil;
}

// Made once, as MediaRemoteUI makes it: it brings its own now-playing
// controller and loads what is playing by itself.
- (UIViewController *)nlActivity {
    if (_activity) return _activity;
    Class activityClass = NLActivityClass();
    if (!activityClass) return nil;
    UIViewController *host = NLViewControllerOf(self);
    if (!host) return nil;   // not in a page yet: asked again
    NLStandInForHost();
    NLKeepLiveViewsInPlace();
    // The camera, as the island's host reports it: a 14 Pro's sensor region,
    // at the top of the island, centred.
    objc_setAssociatedObject(_pill, &kNLHostModeKey, @(kNLActivityCompact), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIViewController *activity = [activityClass new];
    __weak NLIslandPreviewCell *weakSelf = self;
    objc_setAssociatedObject(activity.view, &kNLActivityOwnerKey, ^NLIslandPreviewCell *{ return weakSelf; },
                             OBJC_ASSOCIATION_COPY_NONATOMIC);
    UILayoutGuide *camera = [UILayoutGuide new];
    [activity.view addLayoutGuide:camera];
    [NSLayoutConstraint activateConstraints:@[
        [camera.topAnchor constraintEqualToAnchor:activity.view.topAnchor],
        [camera.centerXAnchor constraintEqualToAnchor:activity.view.centerXAnchor],
        [camera.widthAnchor constraintEqualToConstant:kNLDefaultSensorWidth],
        [camera.heightAnchor constraintEqualToConstant:37],
    ]];
    objc_setAssociatedObject(activity.view, &kNLHostGuideKey, camera, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host addChildViewController:activity];
    activity.view.alpha = 0;
    [_pill insertSubview:activity.view atIndex:0];
    [activity didMoveToParentViewController:host];
    NLNextUpKeepOut(activity.view);   // before its first layout with NextUp's mark on it
    [(id)activity setActiveLayoutMode:kNLActivityCompact];
    _activity = activity;
    return activity;
}

// The cover and waveform back inside the island after closing, where the
// closed island has them (the pill's frame would be its pressed or pulled box).
- (void)nlReturnLiveViews {
    [UIView performWithoutAnimation:^{
        for (UIView *view in NLExisting(self->_liveArt, self->_liveWave)) {
            if (view.superview == self->_pill) continue;
            [self->_pill addSubview:view];
            view.layer.zPosition = 0;
            NLPlaceLike(view, view == self->_liveArt ? self->_art : self->_wave);
        }
    }];
    _collapsingLive = NO;
}

// The live cover and waveform where the sample ones are. Bounds and centre:
// closing gives them a scale for a moment.
- (void)nlPlaceLiveViews {
    NLPlaceLike(_liveWave, _wave);
    NLPlaceLike(_liveArt, _art);
}

// The layout the island's controller lays out for, and what its views are
// told the island shows (-SBUISA_layoutMode). Laid out at once: its own
// change of layout runs a transition of its own (the title's marquee showed
// twice while it ran).
- (void)nlSetActivityMode:(NSInteger)mode {
    if (!_activity) return;
    objc_setAssociatedObject(_pill, &kNLHostModeKey, @(mode), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [UIView performWithoutAnimation:^{
        [(id)self->_activity setActiveLayoutMode:mode];
        [self->_activity.view setNeedsLayout];
        [self->_activity.view layoutIfNeeded];
    }];
    NLStopAnimations(_activity.view.layer);
    NLDisableTaps(_activity.view);   // once per layout it builds, not on every pass of ours
}

// The open view as the closed island shows it: scaled about its top centre
// (transforms scale about the centre, so the top is moved back up).
static CGAffineTransform NLOpenViewClosed(void) {
    return CGAffineTransformScale(CGAffineTransformMakeTranslation(0, -(1 - kNLClosedScale) * kNLOpenView.height / 2), kNLClosedScale, kNLClosedScale);
}

// Takes the running animations off a layer tree.
static void NLStopAnimations(CALayer *layer) {
    [layer removeAllAnimations];
    for (CALayer *sub in layer.sublayers) NLStopAnimations(sub);
}

// A tap on the preview is the preview's (open, close); the island's own taps
// open the playing app, which is not what a settings page should do.
static void NLDisableTaps(UIView *view) {
    if ([view isKindOfClass:UIControl.class]) return;
    for (UIGestureRecognizer *gesture in view.gestureRecognizers) {
        if ([gesture isKindOfClass:UITapGestureRecognizer.class] || [gesture isKindOfClass:UILongPressGestureRecognizer.class]) {
            gesture.enabled = NO;
        }
    }
    for (UIView *sub in view.subviews) NLDisableTaps(sub);
}

// One of the island's own views into the pill over the sample's `sample`,
// placed by `place`: shown, laid out at once, its running animations taken off
// (it would settle into its first frame from elsewhere) and its taps off.
- (void)nlAdopt:(UIView *)view over:(UIView *)sample place:(void (^)(void))place {
    [UIView performWithoutAnimation:^{
        place();
        view.alpha = 1;
        [self->_pill insertSubview:view aboveSubview:sample];
        [view layoutIfNeeded];
    }];
    NLStopAnimations(view.layer);
    NLDisableTaps(view);
}

// Live: the real cover in the sample's cover view, a system waveform view
// over the sample waveform's place, and the open island's view always at its
// open size, kept still on screen as the island changes shape.
- (void)nlLayoutActivity:(CGSize)size {
    BOOL live = [self nlLive];
    _wave.hidden = live;
    _liveWave.hidden = !live;
    _art.hidden = live && _liveArt;
    _liveArt.hidden = !live;
    if (!_activity) return;
    NLNextUpKeepOut(_activity.view);   // NextUp's hooks reach this view; the preview places its row itself
    if (!live) {
        _activity.view.alpha = 0;
        _extrasHost.alpha = 0;
        return;
    }
    // The waveform is the island's own too (its trailing view), moved by
    // made-up levels (the real ones need an audio tap), in the sample
    // waveform's place, closed at the side and open at the top right.
    // On iOS 17 and later the trailing view only shows a waveform when
    // MediaRemoteUI hands the controller a waveform controller (it has
    // -setShowWaveform: then); made here it shows the route glyph or nothing,
    // so the made-up one stays.
    if (!_liveWave && [_activity respondsToSelector:@selector(trailingView)]) {
        UIView *wave = [(id)_activity trailingView];
        if (wave && [wave respondsToSelector:@selector(setShowWaveform:)]) wave = nil;
        if (wave) {
            _liveWave = wave;
            [self nlAdopt:wave over:_wave place:^{ NLPlaceLike(wave, self->_wave); }];
            _activityWave = [NLWaveformDriver new];
            _activityWave.playing = NLInfoPlaying(_liveInfo);
            [_activityWave driveViewsIn:wave];
        } else {
            _wave.hidden = NO;   // none on this iOS: the made-up one
        }
    }

    // The cover is the island's own (its leading view), the one view it shows
    // closed at the side and moves to the top left open: same look, and turned
    // by what turns the island's (ArtworkSpinner). Here it lives in the pill
    // in the sample cover's place and moves with the island as the sample does.
    if (!_liveArt && [_activity respondsToSelector:@selector(leadingView)]) {
        UIView *cover = [(id)_activity leadingView];
        if (cover) {
            _liveArt = cover;
            [self nlAdopt:cover over:_art place:^{ cover.frame = self->_art.frame; }];
            _art.hidden = YES;
        }
    }

    // Its open view keeps its open size, centred under the island's top; the
    // spring scales it with the island (-nlSetExpanded:), as SpringBoard does.
    UIView *openView = _activity.view;
    if (!CGSizeEqualToSize(openView.bounds.size, kNLOpenView)) {
        [UIView performWithoutAnimation:^{
            openView.bounds = CGRectMake(0, 0, kNLOpenView.width, kNLOpenView.height);
            [openView layoutIfNeeded];
        }];
    }
    openView.center = CGPointMake(size.width / 2, -kNLRing + kNLOpenView.height / 2);
    [self nlLayoutExtraRows];
}

// NextUp's row view, when this NextUp build has what the preview calls on it.
static Class NLNextUpRowClass(void) {
    static Class found;   // once there, for good
    if (!found) {
        Class c = objc_getClass("NUNextUpRowView");
        if ([c respondsToSelector:@selector(preferredHeightForControlCenter)] &&
            [c instancesRespondToSelector:@selector(configureForDynamicIsland)] &&
            [c instancesRespondToSelector:@selector(refreshFromManager)]) found = c;
    }
    return found;
}

// What the rows tweaks add to the open island can come to: NextUp's row with
// Crescendo's slider above it, or the slider alone. The page keeps that much
// more room under the preview for it to open into.
static CGFloat NLExtraRowsHeight(BOOL nextUpRow, BOOL crescendo) {
    Class rowClass = nextUpRow ? NLNextUpRowClass() : Nil;
    CGFloat height = rowClass ? [(id)rowClass preferredHeightForControlCenter] : 0;
    if (crescendo) height += rowClass ? kNLVolumeStripAboveNextUp : kNLVolumeStrip;
    return height;
}

// How far down the table the open island reaches from the table's top, with
// what music adds to it: the room a page keeps when no rows below take part
// of it (the other pages' header, NLPageTop).
CGFloat NLIslandPreviewOpenBottom(void) {
    return kNLTopMargin + kNLExpandedLive.height + NLIslandPreviewMostExtraHeight();
}

CGFloat NLIslandPreviewMostExtraHeight(void) {
    BOOL crescendo = NLCrescendoShows(NLCrescendoDynamicIsland);
    return NLExtraRowsHeight(NLNextUpShowsInIsland(), crescendo);
}

// NextUp's row is there while NextUp has a next track for what plays.
- (BOOL)nlNextUpShown {
    return _nextUpWanted && _liveInfo && NLNextUpActive() && NLNextUpRowClass();
}

// What the rows under the controls add to the open island, as on the real one:
// NextUp's row at the bottom, Crescendo's slider above it (or alone, lower).
- (void)nlUpdateExtraHeight {
    _extraHeight = NLExtraRowsHeight([self nlNextUpShown], _crescendoWanted);
}

- (void)nlNextUpChanged {
    [_nextUpRow refreshFromManager];
    CGFloat was = _extraHeight;
    [self nlUpdateExtraHeight];
    if (was != _extraHeight) [self nlLayoutPill];
    else [self nlLayoutExtraRows];
}

// The rows hang below the open view's measured height, in the strip the island
// grew by, and scale and fade with the open view. They sit in a view of their
// own laid over the open view rather than in it: anything that lays the open
// view out (adding a row, the slider's volume updates) has it place its cover
// and waveform, which live in the pill, in its own coordinates, and they
// drifted off.
- (void)nlLayoutExtraRows {
    UIView *openView = _activity.view;
    if (_extraHeight <= 0 || !openView) {
        _extrasHost.hidden = YES;
        return;
    }
    if (!_extrasHost) {
        _extrasHost = [NLExtrasHostView new];
        [_pill insertSubview:_extrasHost aboveSubview:openView];
        _extrasHost.alpha = openView.alpha;
        _extrasHost.transform = openView.transform;
    }
    if (_crescendoWanted && !_volumeRow) {
        _volumeRow = NLCrescendoMakeVolumeRow(openView);
        if (_volumeRow) [_extrasHost addSubview:_volumeRow];
    }
    if (_nextUpWanted && !_nextUpRow) {
        NLNextUpStart();
        Class rowClass = NLNextUpRowClass();
        if (rowClass) {
            _nextUpRow = [[rowClass alloc] initWithFrame:CGRectZero];
            [(id)_nextUpRow configureForDynamicIsland];
            [(id)_nextUpRow refreshFromManager];
            [_extrasHost addSubview:_nextUpRow];
            __weak typeof(self) weakSelf = self;
            _nextUpObserver = NLObserveNextUp(^{ [weakSelf nlNextUpChanged]; });
        }
    }
    _extrasHost.hidden = !_expanded;   // only open: a material on it would show through a mere alpha of 0

    // In the open view's coordinates (its top is kNLRing above the island's),
    // at the island's width.
    BOOL nextUp = [self nlNextUpShown];
    CGFloat rowHeight = nextUp ? [(id)NLNextUpRowClass() preferredHeightForControlCenter] : 0;
    CGFloat bottom = kNLExpandedLive.height + _extraHeight + kNLRing;
    CGFloat transportBottom = 0;
    static Class transport;
    if (!transport) transport = objc_getClass("MRUNowPlayingTransportControlsView");
    for (UIView *sub in openView.subviews) {
        if (transport && [sub isKindOfClass:transport] && !sub.hidden) transportBottom = MAX(transportBottom, CGRectGetMaxY(sub.frame));
    }
    CGFloat sliderY;
    if (nextUp) {
        CGFloat bandBottom = bottom - rowHeight;
        CGFloat bandTop = MAX(transportBottom, bandBottom - kNLVolumeStripAboveNextUp);
        sliderY = bandTop + ((bandBottom - bandTop) - kNLVolumeSlider) / 2;
    } else {
        sliderY = MAX(transportBottom, bottom - kNLVolumeSlider - kNLVolumeSlider);
    }
    [UIView performWithoutAnimation:^{
        self->_extrasHost.bounds = openView.bounds;
        self->_extrasHost.center = openView.center;
        self->_volumeRow.hidden = !self->_crescendoWanted;
        self->_volumeRow.frame = CGRectMake(24 + kNLRing, sliderY, kNLOpenView.width - 48 - kNLRing * 2, kNLVolumeSlider);
        self->_nextUpRow.hidden = !nextUp;
        if (nextUp) self->_nextUpRow.frame = CGRectMake(kNLRing, bottom - rowHeight, kNLExpandedLive.width, rowHeight);
    }];
}

#pragma mark Live

// Twice a second while on screen: what is playing, if anything, and whether
// the switch wants it shown. The app MediaRemote names is asked for less often.
- (void)nlLiveTick {
    // Not while the island opens or closes: the work on the main queue (asking
    // MediaRemote, laying out) cost frames in the middle of the spring.
    if (CACurrentMediaTime() < _quietUntil) return;
    if (!_liveWanted) {
        [self nlSetLive:nil];
        return;
    }
    if (_liveTicks++ % 6 == 0) NLNowPlayingBundleID(^(NSString *bundleID) { self->_liveBundle = bundleID; });
    NLNowPlayingInfo(^(NSDictionary *info) {
        [self nlSetLive:NLInfoTitle(info) ? info : nil];
    });
}

- (NSDictionary *)nlOffsetsPrefs {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
    for (NSString *key in NL_ONCE((@[@"offset", NL_TRACK_OFFSETS_KEY]))) {
        id value = NLReadPref(nil, key);
        if (value) prefs[key] = value;
    }
    return prefs;
}

// Into the real island, out of it, or its next state.
- (void)nlSetLive:(NSDictionary *)info {
    if (info && ![self nlActivity]) info = nil;   // no such controller on this iOS: keep the sample
    BOOL wasLive = _liveInfo != nil;
    // Into the real island or out of it, an open island first closes as what
    // it shows: the real one's close puts its controller back in the closed
    // layout and its open view, cover and waveform back in their closed places.
    if (wasLive != (info != nil) && _expanded) [self nlSetExpanded:NO];
    _liveInfo = info;
    if (!info) {
        if (!wasLive) return;
        _liveArtworkPrint = 0;
        _art.image = NLSampleArtwork();
        _albumColor = NLSampleArtworkColor();   // the sample cover's again
        [self nlApplyValues];
        [self nlAnimateBars];
        [self nlNextLine];   // the sample lines again
        [self nlReportTheme];
        return;
    }
    if (!wasLive) {
        [self nlWakeKeyLine];
        _generation++;   // the sample cycle stops
    }

    // The album color for the line, from the same artwork the island uses
    // (none for a grey or dark cover: white, as the island does then). A new
    // cover is told by its print: the next song's can be just as long.
    NSData *artwork = NLInfoArtwork(info);
    NSUInteger print = artwork ? NLArtworkPrint(artwork) : 0;
    if (print != _liveArtworkPrint) {
        _liveArtworkPrint = print;
        _albumColor = artwork ? NLArtworkColorCached(artwork) : nil;
        UIImage *cover = artwork ? [UIImage imageWithData:artwork] : nil;
        _art.image = cover ?: NLSampleArtwork();
        [self nlApplyValues];
    }
    [self nlReportTheme];

    NSString *title = NLInfoTitle(info);
    BOOL explicitTrack = NLPrefBool(info, NL_MR_EXPLICIT, NO);
    [_strip setText:title explicit:explicitTrack scrollUp:_scrollUp];
    NLShownWords *words = _wordByWord ? NLWordsForShownLine(_liveBundle, title, info, [self nlOffsetsPrefs]) : nil;
    [_strip setWordTexts:words.texts starts:words.starts ends:words.ends position:words.position rate:words.rate];
    [self nlAnimateBars];
    if (!wasLive && !artwork) [self nlLayoutPill];   // the island itself only changes going live (with a cover, -nlApplyValues above laid it out)
}

@end
