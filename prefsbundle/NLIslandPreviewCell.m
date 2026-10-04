//
//  NLIslandPreviewCell.m
//  The top row of the "Lyrics in the island" page: a compact Dynamic Island
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
//  change; the cell then asks it (-nlIslandPreviewValues) for the values.
//

#import <UIKit/UIKit.h>
#import <Preferences/PSTableCell.h>
#import <Preferences/PSSpecifier.h>
#import "../NLIslandStrip.h"
#import "NLLyricsPages.h"
#import <dlfcn.h>
#import <objc/runtime.h>

// MRUActivityNowPlayingViewController, the island's now-playing element.
@interface NSObject (NLActivity)
- (void)setActiveLayoutMode:(NSInteger)mode;
// MRUWaveformView and its settings.
+ (id)currentSettings;
- (instancetype)initWithFrame:(CGRect)frame context:(NSInteger)context settings:(id)settings;
- (void)setArtworkImage:(UIImage *)image;
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

static NSInteger NLHostLayoutMode(UIView *self, SEL _cmd) {
    for (UIView *v = self; v; v = v.superview) {
        NSNumber *mode = objc_getAssociatedObject(v, &kNLHostModeKey);
        if (mode) return mode.integerValue;
    }
    return ((NSInteger (*)(id, SEL))gLayoutModeIMP)(self, _cmd);
}

static id NLHostObstructedGuide(UIView *self, SEL _cmd) {
    for (UIView *v = self; v; v = v.superview) {
        id guide = objc_getAssociatedObject(v, &kNLHostGuideKey);
        if (guide) return guide;
    }
    return ((id (*)(id, SEL))gObstructedIMP)(self, _cmd);
}

static void NLStandInForHost(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Method mode = class_getInstanceMethod(UIView.class, NSSelectorFromString(@"SBUISA_layoutMode"));
        Method guide = class_getInstanceMethod(UIView.class, NSSelectorFromString(@"SBUISA_systemApertureObstructedAreaLayoutGuide"));
        if (mode) gLayoutModeIMP = method_setImplementation(mode, (IMP)NLHostLayoutMode);
        if (guide) gObstructedIMP = method_setImplementation(guide, (IMP)NLHostObstructedGuide);
    });
}

NSString *const NLIslandPreviewChangedNotification = @"NLIslandPreviewChanged";
NSArray<NSString *> *NLPreviewLinePool(NSBundle *bundle);   // NLPreviewLines.m

@interface NSObject (NLIslandPreview)
- (NSDictionary *)nlIslandPreviewValues;
@end

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
static const CGFloat kNLExpandedLiveRadius = 44.5;
// Crescendo's volume row in the open island (CRHooksDynamicIsland.x): the
// island opens this much taller, the 24 pt slider 24 pt above its bottom,
// 24 pt in from the sides.
static const CGFloat kNLVolumeStrip = 40;
static const CGFloat kNLVolumeSlider = 24;
// The outline as SpringBoard's key line behaves: bright while the island
// changes or is touched, then settling to a dimmer, inert line.
static const NSTimeInterval kNLKeyLineHold = 2.5;
static const CGFloat kNLKeyLineInert = 0.45;
static const CGFloat kNLTopMargin = 8;   // from the top of the table to the island
static const CGFloat kNLSensorWidth = 125;   // the line is centred under the camera at this width
static const CGFloat kNLPressScale = 1.06;
static const NSTimeInterval kNLExpandDelay = 0.45;
static const NSUInteger kNLBars = 6;
static const NSUInteger kNLRecentLines = 20;   // not repeated until this many others came by

@interface NLIslandPreviewCell : PSTableCell <UIGestureRecognizerDelegate>
@end

@implementation NLIslandPreviewCell {
    UIView *_pill;
    UIView *_ring;   // the outline, around the pill rather than on it
    UIImageView *_art;
    UIImage *_sampleArt;                   // the stand-in cover, back when nothing plays
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
    NSUInteger _liveArtworkLength;         // the cover the album color was taken from
    BOOL _morphing;                        // inside the open/close spring: frames set now are animated
    BOOL _collapsingLive;                  // the live island is closing: the cover and waveform are the close animation's
    NSUInteger _closeGeneration;           // invalidates a close animation's last step when reopened
    CFTimeInterval _quietUntil;            // live updates wait until the open/close animation is over
    NLIslandStripView *_strip;
    UILabel *_titleLabel;      // expanded only
    UILabel *_lineLabel;       // expanded only
    UIColor *_albumColor;
    UIColor *_textColor;
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
    BOOL _stretching;   // the press became a sideways pull
    UIViewPropertyAnimator *_pressAnimator;   // the swell under the finger, stopped when a pull takes over
    CGPoint _pressStart;
    UIImpactFeedbackGenerator *_lightTap, *_firmTap;
    UIView *_volumeRow;        // Crescendo's slider in the open island, when it wants one there
    UIView *_volumeHost;       // holds it over the open view, moving as it moves (not in it: see -nlLayoutVolumeRow)
    CGFloat _volumeExtra;      // kNLVolumeStrip then, else 0
    NSUInteger _keyLineGeneration;   // invalidates the pending settle of the outline
}

// The stand-in cover: NowLyrics' own icon (the 87 px one in this bundle). Its
// album color comes from the same NLColorFromArtwork() the island uses.
static UIImage *NLSampleArtwork(CGFloat side) {
    static UIImage *icon;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        icon = [UIImage imageNamed:@"NowLyrics" inBundle:[NSBundle bundleForClass:NLIslandPreviewCell.class]
             compatibleWithTraitCollection:[UITraitCollection traitCollectionWithDisplayScale:3]];
    });
    return icon;
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
        // The real island's outline, measured from a screenshot: 1.5 pt of 16 % white.
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

        UIImage *art = NLSampleArtwork(64);
        _art = [[UIImageView alloc] initWithImage:art];
        _art.layer.cornerCurve = kCACornerCurveContinuous;
        _art.clipsToBounds = YES;
        [_pill addSubview:_art];
        _albumColor = NLColorFromArtwork(UIImagePNGRepresentation(art));
        _sampleArt = art;

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
        _fontSize = 11;
        _textColor = [UIColor colorWithWhite:1 alpha:0.92];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(nlValuesChanged:)
                                                     name:NLIslandPreviewChangedNotification object:nil];
    }
    return self;
}

// NowLyrics' own color: that of the main switch's icon (NLSampleCoverIcon).
UIColor *NLNowLyricsColor(void) {
    static UIColor *color;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ color = NLColorFromArtwork(UIImagePNGRepresentation(NLSampleCoverIcon())); });
    return color;
}

// The theme is the color of what the island shows: the album's, or NowLyrics'
// for the sample (and for a grey cover).
- (void)nlReportTheme {
    NLThemeSetColor((_liveInfo && _albumColor) ? _albumColor : NLNowLyricsColor());
}

// The outline lights up, and settles again after a while.
- (void)nlWakeKeyLine {
    NSUInteger generation = ++_keyLineGeneration;
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | UIViewAnimationOptionAllowUserInteraction;
    [UIView animateWithDuration:0.2 delay:0 options:options animations:^{ self->_ring.alpha = 1; } completion:nil];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNLKeyLineHold * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NLIslandPreviewCell *cell = weakSelf;
        if (!cell || cell->_keyLineGeneration != generation) return;
        [UIView animateWithDuration:0.8 delay:0 options:options animations:^{ cell->_ring.alpha = kNLKeyLineInert; } completion:nil];
    });
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
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
    [self nlLayoutPill];
}

// The island floats over the whole table rather than sitting in its row, as
// the real one floats over the app: opening, it keeps its top edge (where the
// camera is) and grows down and out over the rows below, wider than the row's
// card if it must, and pushes nothing aside.
- (UIView *)nlTable {
    UIView *table = self.superview;
    while (table && ![table isKindOfClass:UITableView.class]) table = table.superview;
    return table;
}

- (void)nlHostPill {
    UIView *table = self.window ? [self nlTable] : nil;
    UIView *host = table ?: self.contentView;
    if (_pill.superview == host) return;
    // Often inside the page's push animation, which must not carry it along.
    [UIView performWithoutAnimation:^{
        [host addSubview:self->_ring];
        [host addSubview:self->_pill];
        self->_ring.layer.zPosition = table ? 99 : 0;    // over the cells, which the table adds and reorders
        self->_pill.layer.zPosition = table ? 100 : 0;
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
// centred).
- (CGPoint)nlPillCentre:(CGSize)size {
    CGRect b = self.contentView.bounds;
    UIView *host = _pill.superview ?: self.contentView;
    CGPoint top = [self.contentView convertPoint:CGPointMake(round(CGRectGetMidX(b)), round(CGRectGetMidY(b) - kNLCompact.height / 2))
                                          toView:host];
    if ([host isKindOfClass:UITableView.class]) top = CGPointMake(round(host.bounds.size.width / 2 * 2) / 2, kNLTopMargin);
    return CGPointMake(top.x, top.y + size.height / 2);
}

// Bounds and centre rather than frame, so the press transform can stay on.
- (void)nlLayoutPill {
    BOOL live = _liveInfo != nil && _activity != nil;
    CGSize liveSize = CGSizeMake(kNLExpandedLive.width, kNLExpandedLive.height + _volumeExtra);
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
    void (^placeLive)(void) = ^{
        self->_liveWave.bounds = self->_wave.bounds;
        self->_liveWave.center = self->_wave.center;
        // Bounds and centre: closing gives it a scale for a moment.
        self->_liveArt.bounds = CGRectMake(0, 0, self->_art.frame.size.width, self->_art.frame.size.height);
        self->_liveArt.center = CGPointMake(CGRectGetMidX(self->_art.frame), CGRectGetMidY(self->_art.frame));
    };
    // The open view first: laying it out can move the cover and waveform.
    [self nlLayoutActivity:size];
    if (!_collapsingLive) placeLive();

    CGFloat textX = CGRectGetMaxX(_art.frame) + 14, textW = barsRight - 30 - textX;
    // Bounds and centre here too: these carry a scale while they appear.
    CGFloat lineW = size.width - 22 - textX;
    _titleLabel.bounds = CGRectMake(0, 0, textW, 18);
    _titleLabel.center = CGPointMake(textX + textW / 2, 18 + 9);
    _lineLabel.bounds = CGRectMake(0, 0, lineW, 40);
    _lineLabel.center = CGPointMake(textX + lineW / 2, 36 + 20);

    // The strip as NowLyricsIsland lays it out: the font's exact line height on
    // the bottom edge, centred at the camera's width less a little each side.
    CGFloat h = [UIFont systemFontOfSize:_fontSize weight:UIFontWeightSemibold].lineHeight;
    CGFloat width = kNLSensorWidth - 8;
    CGRect strip = CGRectMake(round((size.width - width) / 2), size.height - h, width, h);
    // Never carried along by the island's spring: it is hidden while the
    // island is open and comes back in place once it has closed.
    [UIView performWithoutAnimation:^{
        if (!CGRectEqualToRect(self->_strip.frame, strip)) self->_strip.frame = strip;
    }];
}

#pragma mark Lifecycle

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [self nlHostPill];
    _generation++;   // stops the cycle while off screen
    if (!self.window) {
        [_liveTimer invalidate];
        _liveTimer = nil;
        if (_expanded) {
            _expanded = NO;   // back closed next time, without animating off screen
            _titleLabel.alpha = _lineLabel.alpha = 0;
            _strip.alpha = 1;
            _pill.transform = CGAffineTransformIdentity;
            _ring.transform = CGAffineTransformIdentity;
            [self nlLayoutPill];
        }
        return;
    }
    [self nlApplyValues];
    [self nlReportTheme];
    [self nlWakeKeyLine];
    [self nlAnimateBars];
    [self nlNextLine];
    [_liveTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _liveTimer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer *timer) {
        NLIslandPreviewCell *cell = weakSelf;
        if (!cell.window) { [timer invalidate]; return; }
        [cell nlLiveTick];
    }];
    [self nlLiveTick];
}

- (void)nlValuesChanged:(NSNotification *)note {
    [self nlApplyValues];
}

- (void)nlApplyValues {
    NSDictionary *values = nil;
    id target = self.specifier.target;
    if ([target respondsToSelector:@selector(nlIslandPreviewValues)]) values = [target nlIslandPreviewValues];
    _fontSize = [values[@"islandFontSize"] respondsToSelector:@selector(doubleValue)] ? [values[@"islandFontSize"] doubleValue] : 11;
    CGFloat speed = [values[@"islandMarqueeSpeed"] respondsToSelector:@selector(doubleValue)] ? [values[@"islandMarqueeSpeed"] doubleValue] : kNLDefaultSpeed;
    _scrollUp = [values[@"islandTransition"] isEqual:@"up"];
    _liveWanted = [values[@"islandPreviewLive"] respondsToSelector:@selector(boolValue)] ? [values[@"islandPreviewLive"] boolValue] : YES;
    _wordByWord = [values[@"islandWordByWord"] respondsToSelector:@selector(boolValue)] ? [values[@"islandWordByWord"] boolValue] : YES;
    _textColor = ([values[@"islandColor"] isEqual:@"artwork"] && _albumColor) ? _albumColor : [UIColor colorWithWhite:1 alpha:0.92];
    _volumeExtra = NLCrescendoShows(NLCrescendoDynamicIsland) ? kNLVolumeStrip : 0;
    _lineLabel.textColor = _textColor;
    [self nlLayoutPill];
    [_strip layoutIfNeeded];
    [_strip applyFontSize:_fontSize color:_textColor speed:speed];
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
    NSArray<NSString *> *pool = NLPreviewLinePool([NSBundle bundleForClass:self.class]);
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
    if (_liveInfo && _activity) return;   // the real island's lines come from what is playing
    _line = [self nlPickLine];
    [_strip setText:_line explicit:NO scrollUp:_scrollUp];
    NSTimeInterval dwell = MAX(_strip.marqueeReadDuration, 2.6);
    if (_wordByWord) {
        NSArray<NSString *> *pieces = NLPreviewPieces(_line);
        NSMutableArray *starts = [NSMutableArray array], *ends = [NSMutableArray array];
        for (NSUInteger i = 0; i < pieces.count; i++) {
            [starts addObject:@(0.2 + i * kNLPreviewPieceTime)];
            [ends addObject:@(0.2 + (i + 1) * kNLPreviewPieceTime)];
        }
        [_strip setWordTexts:pieces starts:starts ends:ends position:0 rate:1];
        dwell = MAX(0.2 + pieces.count * kNLPreviewPieceTime + 1.2, 2.6);
    }
    [UIView transitionWithView:_lineLabel duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve
                    animations:^{ self->_lineLabel.text = self->_line; } completion:nil];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(dwell * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        NLIslandPreviewCell *cell = weakSelf;
        if (!cell || cell->_generation != generation || !cell.window) return;
        if (cell->_expanded) { cell->_generation++; return; }   // resumes on collapse
        [cell nlNextLine];
    });
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
    if (!_expanded || !_liveInfo) return YES;
    for (UIView *v = touch.view; v && v != _pill; v = v.superview) {
        if ([v isKindOfClass:UIControl.class]) return NO;
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
            if (_expanded) break;   // open already: this press is a tap to close
            NSUInteger generation = ++_pressGeneration;
            __weak typeof(self) weakSelf = self;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kNLExpandDelay * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                NLIslandPreviewCell *cell = weakSelf;
                if (cell && cell->_pressGeneration == generation && !cell->_pressCancelled) [cell nlSetExpanded:YES];
            });
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
                break;
            }
            if (_pressCancelled) break;
            _pressGeneration++;
            [self nlSetPressed:NO];
            if (_pressStartedOpen) [self nlSetExpanded:NO];   // a tap on the open island closes it
            else if (_expanded) {}                              // just opened by this press: stays open until tapped
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
    CGFloat base = _expanded ? 1.02 : kNLPressScale;
    CGAffineTransform t = CGAffineTransformMakeTranslation(px, py);
    t = CGAffineTransformScale(t, base * (1 + ax * 0.12 - ay * 0.04), base * (1 + ay * 0.12 - ax * 0.04));
    if (_pressAnimator.state == UIViewAnimatingStateActive) [_pressAnimator stopAnimation:YES];
    _pressAnimator = nil;
    [UIView performWithoutAnimation:^{
        self->_pill.transform = t;
        self->_ring.transform = t;
    }];
}

// The page does not scroll while the island is being pulled.
- (void)nlSetPageScrolls:(BOOL)scrolls {
    UIView *table = [self nlTable];
    if ([table isKindOfClass:UIScrollView.class]) ((UIScrollView *)table).scrollEnabled = scrolls;
}

// Swells under the finger (less when open) and settles back when it lifts.
- (void)nlSetPressed:(BOOL)pressed {
    CGFloat scale = _expanded ? 1.02 : kNLPressScale;
    if (_pressAnimator.state == UIViewAnimatingStateActive) [_pressAnimator stopAnimation:YES];
    _pressAnimator = NLSpring(pressed ? 0.25 : 0.4, pressed ? 0.8 : 0.6, ^{
        self->_pill.transform = pressed ? CGAffineTransformMakeScale(scale, scale) : CGAffineTransformIdentity;
        self->_ring.transform = self->_pill.transform;
    });
}

// Opening morphs the island and its artwork in one spring with a little
// overshoot; the compact contents go first and the expanded ones arrive
// growing from 85 %. Closing is the same in reverse, without the overshoot.
- (void)nlSetExpanded:(BOOL)expanded {
    [self nlWakeKeyLine];
    if (_expanded == expanded) return;
    _expanded = expanded;
    _quietUntil = CACurrentMediaTime() + 0.75;
    if (expanded) [_firmTap impactOccurred];
    else [_lightTap impactOccurred];
    BOOL live = _liveInfo != nil && _activity != nil;
    if (!live) _lineLabel.text = _line;

    // The open island's title, progress and controls grow with the island the
    // way SpringBoard grows an element's content: scaled from the closed
    // island's width about its top centre while fading in. Closing is the
    // reverse with the cover and waveform in it too: everything the open
    // island shows shrinks towards its top centre and fades, the island's view
    // still in its open layout (switching it first hid everything at once);
    // only then do the cover and waveform grow in where the closed island has
    // them.
    UIView *openView = live ? _activity.view : nil;
    UIView *volumeHost = live ? _volumeHost : nil;
    UIView *cover = live ? _liveArt : nil, *wave = live ? _liveWave : nil;
    CGFloat closedScale = kNLCompact.width / kNLExpandedLive.width;
    CGFloat startWidth = _pill.bounds.size.width;
    NSUInteger generation = ++_closeGeneration;
    if (live && expanded) {
        [self nlReturnLiveViews];   // still out of the island from closing
        _collapsingLive = NO;
        [self nlSetActivityMode:kNLActivityExpanded];
        [UIView performWithoutAnimation:^{
            openView.transform = NLTopScale(closedScale, kNLOpenView.height);
            volumeHost.transform = openView.transform;
            cover.transform = CGAffineTransformIdentity;
            wave.transform = CGAffineTransformIdentity;
        }];
        [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            openView.alpha = 1;
            volumeHost.alpha = 1;
            cover.alpha = 1;   // if reopened before they came back
            wave.alpha = 1;
        } completion:nil];
    }
    if (live && !expanded) {
        _collapsingLive = YES;
        [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
            openView.alpha = 0;
            volumeHost.alpha = 0;
            cover.alpha = 0;
            wave.alpha = 0;
        } completion:nil];
    }
    UIViewPropertyAnimator *morph = NLSpring(expanded ? 0.5 : 0.42, expanded ? 0.78 : 0.95, ^{
        self->_morphing = YES;
        [self nlLayoutPill];
        self->_morphing = NO;
        openView.transform = expanded ? CGAffineTransformIdentity : NLTopScale(closedScale, kNLOpenView.height);
        volumeHost.transform = openView.transform;
        if (live && !expanded) {
            // About the island's top centre, which is at half its width in its
            // own coordinates: half the open width now, half the closed one at
            // the end of this same spring.
            for (UIView *view in @[cover ?: [NSNull null], wave ?: [NSNull null]]) {
                if (![view isKindOfClass:UIView.class]) continue;
                CGPoint c = view.center;
                view.center = CGPointMake(kNLCompact.width / 2 + closedScale * (c.x - startWidth / 2), closedScale * c.y);
                view.transform = CGAffineTransformMakeScale(closedScale, closedScale);
            }
        }
        self->_pill.transform = CGAffineTransformIdentity;
        self->_ring.transform = CGAffineTransformIdentity;
    });
    (void)morph;
    if (live && !expanded) {
        // While the island is still closing (about two thirds of the way),
        // the cover and waveform grow in. Inside the island they would ride
        // in with its edges, so for now they hang over it, outside it, where
        // they end up on screen, and go back in once all has stopped.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->_expanded || self->_closeGeneration != generation) return;   // opened again meanwhile
            [self nlSetActivityMode:kNLActivityCompact];
            UIView *host = self->_pill.superview;
            CGPoint origin = self->_pill.frame.origin;   // the closed island's, already
            CGAffineTransform small = CGAffineTransformMakeScale(0.6, 0.6);
            [UIView performWithoutAnimation:^{
                for (UIView *view in @[cover ?: [NSNull null], wave ?: [NSNull null]]) {
                    if (![view isKindOfClass:UIView.class]) continue;
                    view.transform = CGAffineTransformIdentity;
                }
                self->_liveWave.bounds = self->_wave.bounds;
                self->_liveWave.center = self->_wave.center;
                self->_liveArt.bounds = CGRectMake(0, 0, self->_art.frame.size.width, self->_art.frame.size.height);
                self->_liveArt.center = CGPointMake(CGRectGetMidX(self->_art.frame), CGRectGetMidY(self->_art.frame));
                for (UIView *view in @[cover ?: [NSNull null], wave ?: [NSNull null]]) {
                    if (![view isKindOfClass:UIView.class]) continue;
                    CGPoint c = view.center;
                    [host addSubview:view];
                    view.layer.zPosition = self->_pill.layer.zPosition + 1;
                    view.center = CGPointMake(c.x + origin.x, c.y + origin.y);
                    view.transform = small;
                }
            }];
            UIViewPropertyAnimator *grow = [[UIViewPropertyAnimator alloc] initWithDuration:0.36 dampingRatio:0.75 animations:^{
                cover.transform = CGAffineTransformIdentity;
                wave.transform = CGAffineTransformIdentity;
            }];
            [grow addCompletion:^(UIViewAnimatingPosition position) {
                if (self->_closeGeneration == generation && !self->_expanded) [self nlReturnLiveViews];
            }];
            [grow startAnimation];
            [UIView animateWithDuration:0.15 animations:^{ cover.alpha = 1; wave.alpha = 1; }];
        });
    }

    CGAffineTransform small = CGAffineTransformMakeScale(0.85, 0.85);
    if (expanded && !live) {
        _titleLabel.transform = small;
        _lineLabel.transform = small;
    }
    // The line goes at once when opening (it would ride down with the island's
    // bottom edge) and comes back once the island has nearly closed.
    if (expanded) [UIView performWithoutAnimation:^{ self->_strip.alpha = 0; }];
    [UIView animateWithDuration:expanded ? 0.12 : 0.2 delay:expanded ? 0 : 0.28
                        options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        if (!expanded) self->_strip.alpha = 1;
        self->_wave.alpha = expanded ? 0.6 : 1;
    } completion:nil];
    NLSpring(expanded ? 0.45 : 0.25, 1, ^{
        self->_titleLabel.alpha = (expanded && !live) ? 1 : 0;
        self->_lineLabel.alpha = (expanded && !live) ? 1 : 0;
        self->_titleLabel.transform = expanded ? CGAffineTransformIdentity : small;
        self->_lineLabel.transform = expanded ? CGAffineTransformIdentity : small;
    });

    if (!expanded) {
        // Pick the cycle up again where it stopped.
        NSUInteger generation = ++_generation;
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            NLIslandPreviewCell *cell = weakSelf;
            if (cell && cell->_generation == generation && cell.window && !cell->_expanded) [cell nlNextLine];
        });
    }
}

// The waveform: bouncing while the sample lines run, or while the music plays.
- (void)nlAnimateBars {
    BOOL playing = _liveInfo ? NLPrefNum(_liveInfo, @"kMRMediaRemoteNowPlayingInfoPlaybackRate", 0) > 0 : YES;
    _wave.playing = playing;
    _activityWave.playing = playing && _liveInfo;
}


#pragma mark The real island

- (UIViewController *)nlHostController {
    for (UIResponder *r = self.nextResponder; r; r = r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) return (UIViewController *)r;
    }
    return nil;
}

// Made once, as MediaRemoteUI makes it: it brings its own now-playing
// controller and loads what is playing by itself.
- (UIViewController *)nlActivity {
    if (_activity) return _activity;
    dlopen("/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls", RTLD_NOW);
    Class activityClass = objc_getClass("MRUActivityNowPlayingViewController");
    UIViewController *host = [self nlHostController];
    if (!activityClass || !host) return nil;
    NLStandInForHost();
    // The camera, as the island's host reports it: a 14 Pro's sensor region,
    // at the top of the island, centred.
    objc_setAssociatedObject(_pill, &kNLHostModeKey, @(kNLActivityCompact), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UIViewController *activity = [activityClass new];
    if (![activity respondsToSelector:@selector(leadingView)] || ![activity respondsToSelector:@selector(setActiveLayoutMode:)]) return nil;
    UILayoutGuide *camera = [UILayoutGuide new];
    [activity.view addLayoutGuide:camera];
    [NSLayoutConstraint activateConstraints:@[
        [camera.topAnchor constraintEqualToAnchor:activity.view.topAnchor],
        [camera.centerXAnchor constraintEqualToAnchor:activity.view.centerXAnchor],
        [camera.widthAnchor constraintEqualToConstant:kNLSensorWidth],
        [camera.heightAnchor constraintEqualToConstant:37],
    ]];
    objc_setAssociatedObject(activity.view, &kNLHostGuideKey, camera, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [host addChildViewController:activity];
    activity.view.alpha = 0;
    [_pill insertSubview:activity.view atIndex:0];
    [activity didMoveToParentViewController:host];
    [(id)activity setActiveLayoutMode:kNLActivityCompact];
    _activity = activity;
    return activity;
}

// The cover and waveform back inside the island after closing, at the same
// place on screen.
- (void)nlReturnLiveViews {
    CGPoint origin = _pill.frame.origin;
    [UIView performWithoutAnimation:^{
        for (UIView *view in @[self->_liveArt ?: [NSNull null], self->_liveWave ?: [NSNull null]]) {
            if (![view isKindOfClass:UIView.class] || view.superview == self->_pill) continue;
            CGPoint c = view.center;
            [self->_pill addSubview:view];
            view.layer.zPosition = 0;
            view.center = CGPointMake(c.x - origin.x, c.y - origin.y);
        }
    }];
    _collapsingLive = NO;
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

// A scale about the top centre of a view `height` tall (transforms scale
// about the centre, so the top is moved back up).
static CGAffineTransform NLTopScale(CGFloat scale, CGFloat height) {
    return CGAffineTransformScale(CGAffineTransformMakeTranslation(0, -(1 - scale) * height / 2), scale, scale);
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

// Live: the real cover in the sample's cover view, a system waveform view
// over the sample waveform's place, and the open island's view always at its
// open size, kept still on screen as the island changes shape.
- (void)nlLayoutActivity:(CGSize)size {
    BOOL live = _liveInfo != nil && _activity != nil;
    _wave.hidden = live;
    _liveWave.hidden = !live;
    _art.hidden = live && _liveArt;
    _liveArt.hidden = !live;
    if (!_activity) return;
    if (!live) {
        _activity.view.alpha = 0;
        _volumeHost.alpha = 0;
        return;
    }
    // The waveform is the island's own too (its trailing view), moved by
    // made-up levels (the real ones need an audio tap), in the sample
    // waveform's place, closed at the side and open at the top right.
    if (!_liveWave && [_activity respondsToSelector:@selector(trailingView)]) {
        UIView *wave = [(id)_activity trailingView];
        if (wave) {
            _liveWave = wave;
            [UIView performWithoutAnimation:^{
                wave.bounds = self->_wave.bounds;
                wave.center = self->_wave.center;
                wave.alpha = 1;
                [self->_pill insertSubview:wave aboveSubview:self->_wave];
                [wave layoutIfNeeded];
            }];
            NLStopAnimations(wave.layer);
            NLDisableTaps(wave);
            _activityWave = [NLWaveformDriver new];
            _activityWave.playing = NLPrefNum(_liveInfo, @"kMRMediaRemoteNowPlayingInfoPlaybackRate", 0) > 0;
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
            [UIView performWithoutAnimation:^{
                cover.frame = self->_art.frame;
                cover.alpha = 1;
                [self->_pill insertSubview:cover aboveSubview:self->_art];
                [cover layoutIfNeeded];
            }];
            NLStopAnimations(cover.layer);   // it would settle into its first frame from elsewhere
            NLDisableTaps(cover);
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
    [self nlLayoutVolumeRow];
}

// Crescendo's row hangs below the open view's measured height, in the strip
// the island grew by, and scales and fades with the open view. It sits in a
// view of its own laid over the open view rather than in it: anything that
// lays the open view out (adding the row, the row's volume updates) has it
// place its cover and waveform, which live in the pill, in its own
// coordinates, and they drifted off.
- (void)nlLayoutVolumeRow {
    UIView *openView = _activity.view;
    if (_volumeExtra <= 0 || !openView) {
        _volumeHost.hidden = YES;
        return;
    }
    if (!_volumeRow) {
        _volumeRow = NLCrescendoMakeVolumeRow(openView);
        if (!_volumeRow) return;
        _volumeHost = [UIView new];
        [_volumeHost addSubview:_volumeRow];
        [_pill insertSubview:_volumeHost aboveSubview:openView];
        _volumeHost.alpha = openView.alpha;
        _volumeHost.transform = openView.transform;
    }
    _volumeHost.hidden = NO;
    // The open view's own place: the same bounds and centre, so its transform
    // means the same here.
    CGFloat bottom = kNLExpandedLive.height + _volumeExtra + kNLRing;
    CGFloat y = bottom - kNLVolumeSlider - kNLVolumeSlider;
    Class transport = objc_getClass("MRUNowPlayingTransportControlsView");
    for (UIView *sub in openView.subviews) {
        if (transport && [sub isKindOfClass:transport] && !sub.hidden) y = MAX(y, CGRectGetMaxY(sub.frame));
    }
    [UIView performWithoutAnimation:^{
        self->_volumeHost.bounds = openView.bounds;
        self->_volumeHost.center = openView.center;
        self->_volumeRow.frame = CGRectMake(24 + kNLRing, y, kNLOpenView.width - 48 - kNLRing * 2, kNLVolumeSlider);
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
        id title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
        BOOL usable = [title isKindOfClass:NSString.class] && [title length];
        [self nlSetLive:usable ? info : nil];
    });
}

- (NSDictionary *)nlOffsetsPrefs {
    NSMutableDictionary *prefs = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"offset", NL_TRACK_OFFSETS_KEY]) {
        id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("app.nowlyrics")));
        if (value) prefs[key] = value;
    }
    return prefs;
}

// Into the real island, out of it, or its next state.
- (void)nlSetLive:(NSDictionary *)info {
    if (info && ![self nlActivity]) info = nil;   // no such controller on this iOS: keep the sample
    BOOL wasLive = _liveInfo != nil;
    _liveInfo = info;
    if (!info) {
        if (!wasLive) return;
        if (_expanded) [self nlSetExpanded:NO];
        _liveArtworkLength = 0;
        _art.image = _sampleArt;
        _art.alpha = 1;
        _albumColor = NLColorFromArtwork(UIImagePNGRepresentation(_sampleArt));   // the sample cover's again
        [self nlApplyValues];
        [self nlLayoutPill];
        [self nlAnimateBars];
        [self nlNextLine];   // the sample lines again
        [self nlReportTheme];
        return;
    }
    if (!wasLive) {
        [self nlWakeKeyLine];
        _generation++;   // the sample cycle stops
        if (_expanded) [self nlSetExpanded:NO];
    }

    // The album color for the line, from the same artwork the island uses
    // (none for a grey or dark cover: white, as the island does then).
    NSData *artwork = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
    NSUInteger length = [artwork isKindOfClass:NSData.class] ? artwork.length : 0;
    if (length != _liveArtworkLength) {
        _liveArtworkLength = length;
        _albumColor = length ? NLColorFromArtwork(artwork) : nil;
        UIImage *cover = length ? [UIImage imageWithData:artwork] : nil;
        _art.image = cover ?: _sampleArt;
        [self nlApplyValues];
    }
    [self nlReportTheme];

    NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"];
    BOOL explicitTrack = NLPrefBool(info, @"kMRMediaRemoteNowPlayingInfoIsExplicitTrack", NO);
    [_strip setText:title explicit:explicitTrack scrollUp:_scrollUp];
    NLShownWords *words = _wordByWord ? NLWordsForShownLine(_liveBundle, title, info, [self nlOffsetsPrefs]) : nil;
    [_strip setWordTexts:words.texts starts:words.starts ends:words.ends position:words.position rate:words.rate];
    [self nlAnimateBars];
    if (!wasLive) [self nlLayoutPill];   // the island itself only changes going live
}

@end
