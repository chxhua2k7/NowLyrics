//
//  NLCCViews.m
//  The Control Center module's tile (NLCC.h), closed at 1×1 and 1×2 over
//  the media player's copy the module holds. White text over the cover's tint
//  or Control Center's dark material, as the media player's.
//

#import "NLCC.h"

static UIColor *NLCCSecondary(void) { return NL_ONCE([UIColor colorWithWhite:1 alpha:0.62]); }

@implementation NLCCSong
@end

#pragma mark - Cover

// The cover in `view`, or a note on a dim tile without one.
static void NLCCShowCover(UIImageView *view, UIImage *cover) {
    if (cover) {
        view.image = cover;
        view.contentMode = UIViewContentModeScaleAspectFill;
        view.backgroundColor = UIColor.clearColor;
        return;
    }
    CGFloat side = MIN(view.bounds.size.width, view.bounds.size.height);
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:MAX(round(side * 0.42), 10) weight:UIImageSymbolWeightMedium];
    view.image = [UIImage systemImageNamed:@"music.note" withConfiguration:config];
    view.tintColor = [UIColor colorWithWhite:1 alpha:0.55];
    view.contentMode = UIViewContentModeCenter;
    view.backgroundColor = [UIColor colorWithWhite:1 alpha:0.14];
}

static UIImageView *NLCCCoverView(void) {
    UIImageView *view = [UIImageView new];
    view.clipsToBounds = YES;
    view.layer.cornerCurve = kCACornerCurveContinuous;
    NLCCShowCover(view, nil);
    return view;
}

// A cover view given its frame `inset` from the module's edges, its corners
// concentric with the module's (`moduleRadius`), the note redrawn to fit.
static void NLCCPlaceCover(UIImageView *view, CGRect frame, CGFloat moduleRadius, CGFloat inset, UIImage *cover) {
    view.frame = frame;
    view.layer.cornerRadius = MAX(moduleRadius - inset, 4);
    NLCCShowCover(view, cover);
}

#pragma mark - Scrolling text

// MediaControls' scrolling label (the media player's title and artist): a
// text too long for its room scrolls through and comes round again, faded at
// the edges, while it is on (the owner gives it the text's whole size). Each
// of the tile's lines scrolls on its own, at the system's rate (MediaControls
// ties its title's to its subtitle's, which slows the shorter one).
@interface MRUMarqueeLabel : UIView
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) UIFont *font;
@property (nonatomic, strong) UIColor *textColor;
@property (nonatomic, assign) CGSize contentSize;
@property (nonatomic, assign) CGFloat contentGap;
@property (nonatomic, assign) UIEdgeInsets fadeEdgeInsets;
// What a scroll is measured against: it runs on past the text's copy by as
// much as this view is wider than the text (MPUMarqueeView), so the line
// itself (MediaControls' title's is its label, as wide as it).
@property (nonatomic, weak) UIView *animationReferenceView;
@property (nonatomic, assign, getter=isMarqueeEnabled) BOOL marqueeEnabled;
@end

static Class NLCCMarqueeClass(void) {
    return NL_ONCE(({
        Class cls = NLLoadedClass("MRUMarqueeLabel", "/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls");
        BOOL usable = [cls instancesRespondToSelector:@selector(setContentSize:)] && [cls instancesRespondToSelector:@selector(setMarqueeEnabled:)] &&
                      [cls instancesRespondToSelector:@selector(setFadeEdgeInsets:)] && [cls instancesRespondToSelector:@selector(setAnimationReferenceView:)];
        usable ? cls : Nil;
    }));
}

// A line of the tile's text, scrolling as the media player's title does
// (MediaControls' gap and fades); a plain label, cut short, where this iOS
// has no such label. Both answer to the text, the font and the colour.
static MRUMarqueeLabel *NLCCLine(CGFloat size, UIFontWeight weight, BOOL secondary) {
    Class marquee = NLCCMarqueeClass();
    MRUMarqueeLabel *line = marquee ? [[marquee alloc] initWithFrame:CGRectZero] : (MRUMarqueeLabel *)[UILabel new];
    line.font = [UIFont systemFontOfSize:size weight:weight];
    line.textColor = secondary ? NLCCSecondary() : UIColor.whiteColor;
    if (marquee) {
        line.contentGap = 26;
        line.fadeEdgeInsets = UIEdgeInsetsMake(0, 3, 0, 3);
        line.animationReferenceView = line;   // the tile, wider, left it running on and jumping back
    }
    return line;
}

// Its scrolling from the start again, while it is in a window: the marquee
// starts only as it is turned on (one turned on before its text or room
// changed, or while Control Center moved it, stays still).
static void NLCCRestartLine(MRUMarqueeLabel *line) {
    if (![line respondsToSelector:@selector(setMarqueeEnabled:)]) return;
    line.marqueeEnabled = NO;
    line.marqueeEnabled = line.window != nil;
}

// `line` at `frame`, its text's whole size given; scrolling from the start
// again when they changed or `restart`.
static void NLCCPlaceLine(MRUMarqueeLabel *line, CGRect frame, BOOL restart) {
    BOOL moved = !CGRectEqualToRect(line.frame, frame);
    line.frame = frame;
    if (![line respondsToSelector:@selector(setContentSize:)]) return;
    CGSize content = CGSizeMake(line.text.length ? ceil([line.text sizeWithAttributes:@{NSFontAttributeName: line.font}].width) : 0, frame.size.height);
    if (!moved && !restart && CGSizeEqualToSize(line.contentSize, content)) return;
    line.contentSize = content;
    [line layoutIfNeeded];
    NLCCRestartLine(line);
}

#pragma mark - Play button

// MediaControls' own play and pause (the system's media player's): its CA
// package in an MRUTransportButton, which presses and morphs it as the player does.
@interface MRUCAPackageAsset : NSObject
+ (instancetype)packageNamed:(NSString *)name glyphState:(NSString *)state;
@end
@interface MRUAsset : NSObject
+ (instancetype)packageAsset:(MRUCAPackageAsset *)package symbolName:(NSString *)symbol image:(UIImage *)image;
@end
@interface MRUAssetsProvider : NSObject
+ (NSString *)playPauseStopPackageName;
+ (NSString *)playSymbol;
+ (NSString *)pauseSymbol;
@end
@interface UIButton (NLCCTransportButton)   // MRUTransportButton's
- (void)setAsset:(MRUAsset *)asset animated:(BOOL)animated;
- (void)setPackageScale:(CGFloat)scale;
- (void)setShowHighlightCircle:(BOOL)show;   // the round backdrop it shows while pressed
@end

// The system's button class, when this iOS has it with what is used of it.
static Class NLCCSystemButtonClass(void) {
    return NL_ONCE(({
        Class cls = NLLoadedClass("MRUTransportButton", "/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls");
        BOOL usable = cls && [cls instancesRespondToSelector:@selector(setAsset:animated:)] &&
                      [cls instancesRespondToSelector:@selector(setPackageScale:)] &&
                      [objc_getClass("MRUAsset") respondsToSelector:@selector(packageAsset:symbolName:image:)] &&
                      [objc_getClass("MRUCAPackageAsset") respondsToSelector:@selector(packageNamed:glyphState:)] &&
                      [objc_getClass("MRUAssetsProvider") respondsToSelector:@selector(playPauseStopPackageName)];
        usable ? cls : Nil;
    }));
}

// Play or pause, the system's glyph as MediaControls makes it (MRUTransportControls).
static MRUAsset *NLCCPlayPauseAsset(BOOL playing) {
    Class provider = objc_getClass("MRUAssetsProvider");
    MRUCAPackageAsset *package = [objc_getClass("MRUCAPackageAsset") packageNamed:[provider playPauseStopPackageName] glyphState:playing ? @"pause" : @"play"];
    return [objc_getClass("MRUAsset") packageAsset:package symbolName:playing ? [provider pauseSymbol] : [provider playSymbol] image:nil];
}

// Pause while the song plays, play otherwise; the system's button where there
// is one, an SF Symbol otherwise.
@interface NLCCPlayButton : UIView
@property (nonatomic, copy) void (^tapped)(void);
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, assign) CGFloat glyphSize;   // in points
@end

@implementation NLCCPlayButton {
    UIButton *_button;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        Class system = NLCCSystemButtonClass();
        _button = system ? [[system alloc] initWithFrame:CGRectZero] : [UIButton buttonWithType:UIButtonTypeSystem];
        _button.tintColor = UIColor.whiteColor;
        [_button addTarget:self action:@selector(nlTapped) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_button];
        _glyphSize = 12;
        [self nlShowGlyph:NO];
    }
    return self;
}

- (void)setPlaying:(BOOL)playing {
    if (playing == _playing) return;
    _playing = playing;
    [self nlShowGlyph:YES];
}

- (void)setGlyphSize:(CGFloat)glyphSize {
    if (glyphSize == _glyphSize) return;
    _glyphSize = glyphSize;
    [self nlShowGlyph:NO];
}

// The system's: play and pause morphing into each other, scaled from their
// size at 1 (about 20 pt), without the open player's press circle. Ours: SF Symbols.
- (void)nlShowGlyph:(BOOL)animated {
    if (NLCCSystemButtonClass()) {
        [_button setAsset:NLCCPlayPauseAsset(_playing) animated:animated];
        [_button setPackageScale:_glyphSize / 20];
        if ([_button respondsToSelector:@selector(setShowHighlightCircle:)]) [_button setShowHighlightCircle:NO];
        return;
    }
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:round(_glyphSize * 4 / 3) weight:UIImageSymbolWeightRegular];
    [_button setImage:[UIImage systemImageNamed:_playing ? @"pause.fill" : @"play.fill" withConfiguration:config] forState:UIControlStateNormal];
}

- (void)nlTapped {
    self.playing = !_playing;   // at once; MediaRemote confirms after
    if (self.tapped) self.tapped();
}

- (void)layoutSubviews {
    [super layoutSubviews];
    _button.frame = self.bounds;
}

@end

#pragma mark - Tile

@implementation NLCCTileView {
    UIImageView *_cover, *_appIcon;
    MRUMarqueeLabel *_title, *_artist;
    NLCCPlayButton *_play;
    NLCCSong *_song;
    BOOL _newText;   // the lines scroll from the start at the next layout
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _moduleRadius = CCUICompactModuleContinuousCornerRadius();
        _cover = NLCCCoverView();
        _appIcon = [UIImageView new];
        _title = NLCCLine(13, UIFontWeightSemibold, NO);
        _artist = NLCCLine(11, UIFontWeightRegular, YES);
        _play = [NLCCPlayButton new];
        __weak typeof(self) weakSelf = self;
        _play.tapped = ^{
            if (weakSelf.playPause) weakSelf.playPause();
        };
        for (UIView *view in @[_cover, _appIcon, _title, _artist, _play]) [self addSubview:view];
    }
    return self;
}

// Only the button takes touches: anywhere else they go on to the module
// underneath (a tap opens it).
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return !_play.hidden && [hit isDescendantOfView:_play] && hit != _play ? hit : nil;
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) return;
    _newText = YES;   // scrolling again where it was left still
    [self setNeedsLayout];
}

- (void)showSong:(NLCCSong *)song {
    _song = song;
    NSString *title = song.playing ? song.title : NLCCNotPlaying(), *artist = song.playing ? song.artist : nil;
    if (!NLSame(title, _title.text) || !NLSame(artist, _artist.text)) _newText = YES;
    _title.text = title;
    _title.textColor = song.playing ? UIColor.whiteColor : NLCCSecondary();
    _artist.text = artist;
    _appIcon.image = song.playing ? song.appIcon : nil;
    _play.playing = song.playingNow;
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGSize size = self.bounds.size;
    if (size.width < 1 || size.height < 1) return;
    if (size.width < size.height * 1.5) [self nlLayOutSmall:size];
    else [self nlLayOutRow:size];
}

// 1×1: the cover, the app's icon on its corner.
- (void)nlLayOutSmall:(CGSize)size {
    _title.hidden = _artist.hidden = _play.hidden = YES;
    CGFloat inset = round(size.width * 0.12);
    NLCCPlaceCover(_cover, CGRectInset((CGRect){CGPointZero, size}, inset, inset), _moduleRadius, inset, _song.cover);
    CGFloat icon = round(size.width * 0.26);
    _appIcon.hidden = NO;
    _appIcon.frame = CGRectMake(size.width - icon - 4, size.height - icon - 4, icon, icon);
}

// 1×2: the cover, beside it the title and the artist, play or pause at the
// end (with nothing playing too: play goes on with the last app, as the
// system's player does).
- (void)nlLayOutRow:(CGSize)size {
    _appIcon.hidden = YES;
    _play.hidden = NO;
    CGFloat inset = round(size.height * 0.15), side = size.height - inset * 2, button = 34;
    NLCCPlaceCover(_cover, CGRectMake(inset, inset, side, side), _moduleRadius, inset, _song.cover);
    _play.frame = CGRectMake(size.width - inset - button + 4, 0, button, size.height);
    // The title and the artist one line each, together in the middle, scrolling when long.
    CGFloat x = inset + side + 9, width = CGRectGetMinX(_play.frame) - x;
    CGFloat titleHeight = ceil(_title.font.lineHeight), artistHeight = _artist.text.length ? ceil(_artist.font.lineHeight) : 0;
    CGFloat y = round((size.height - titleHeight - (artistHeight ? artistHeight + 1 : 0)) / 2);
    _title.hidden = NO;
    _artist.hidden = !artistHeight;
    NLCCPlaceLine(_title, CGRectMake(x, y, width, titleHeight), _newText);
    NLCCPlaceLine(_artist, CGRectMake(x, y + titleHeight + 1, width, artistHeight), _newText);
    _newText = NO;
}

@end
