//
//  NLLyricsPages.h
//  The lyrics pages of the settings bundle: "Now Playing" (the current song's
//  lyrics and offset), the lyrics library, and the editor both open. They work
//  on the apps' lyrics files directly (NLLocate.h): Preferences is not
//  sandboxed, and the apps are told to look again (NLPostLyricsChanged).
//

#import <UIKit/UIKit.h>
#import <Preferences/PSViewController.h>
#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>
#import "../NowLyrics.h"
#import "../NLLocate.h"

// Localized from this bundle's Island.strings, the copies of
// prefs/<lang>.lproj/Localizable.strings the Makefile puts there.
NSString *NLL(NSString *key);

NSString *NLAppName(NSString *bundleID);
UIImage *NLAppIcon(NSString *bundleID);
void NLAlert(UIViewController *controller, NSString *title, NSString *message);
@interface UIImage (NLPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(CGFloat)scale;
@end
// An alert with these actions, presented over `controller`; returned so its
// message can change while it is up.
static inline UIAlertController *NLPresentAlert(UIViewController *controller, NSString *title, NSString *message, NSArray<UIAlertAction *> *actions) {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    for (UIAlertAction *action in actions) [alert addAction:action];
    [controller presentViewController:alert animated:YES completion:nil];
    return alert;
}
// A question with Cancel and one destructive answer, `action`, which runs `confirmed`.
static inline void NLConfirm(UIViewController *controller, NSString *title, NSString *message, NSString *action, void (^confirmed)(void)) {
    NLPresentAlert(controller, title, message, @[
        [UIAlertAction actionWithTitle:NLL(@"Cancel") style:UIAlertActionStyleCancel handler:nil],
        [UIAlertAction actionWithTitle:action style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) { confirmed(); }],
    ]);
}
// Another app, or the App Store, by its URL.
static inline void NLOpenURL(NSString *url) {
    [UIApplication.sharedApplication openURL:[NSURL URLWithString:url] options:@{} completionHandler:nil];
}
// The song on screen, from its app's nowplaying.plist (the now-playing title
// MediaRemote has is a lyric line): the app MediaRemote names, else whichever
// wrote its nowplaying.plist last. Looked up off the main queue, answered on
// it; both nil when no app has one.
void NLPlayingSong(void (^done)(NSString *bundleID, NSDictionary *np));

// NLLyricsImport.m. Pasted or imported text as it should be stored: LRC
// (word-by-word too) as given, with the track named on top when it is not;
// TTML converted to LRC. nil when it holds no timed lyrics.
NSString *NLLyricsFileText(NSString *text, NSString *title, NSString *artist);

// NLWaveformView.m: a made-up now-playing waveform (the real one needs an
// audio tap). Bounces while `playing`, dots otherwise.
@interface NLWaveformView : UIView
- (instancetype)initWithBars:(NSUInteger)count;
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, strong) UIImage *artwork;   // colors the bars the way the system's are: a window onto the cover
@end

// Moves the system's own waveform views (MRUWaveformView) found under a view
// the way NLWaveformView moves: their real levels come from an audio tap
// Preferences cannot have. They keep their own coloring from the cover.
@interface NLWaveformDriver : NSObject
@property (nonatomic, assign) BOOL playing;
- (void)driveViewsIn:(UIView *)root;   // adds the waveform views found there
- (void)stop;
@end

@interface NLLyricsEditorController : UIViewController
- (instancetype)initWithPath:(NSString *)path title:(NSString *)title;
@property (nonatomic, copy) void (^onChange)(void);   // saved or deleted
@end
// This bundle (NowLyricsPrefs.bundle): the one these pages and their
// resources are in. Looked up once per file.
static inline NSBundle *NLPrefsBundle(void) { return NL_ONCE([NSBundle bundleForClass:NLLyricsEditorController.class]); }
// A lyrics file written (UTF-8, atomically) and the apps told; on failure,
// why, over `controller`, and NO.
static inline BOOL NLSaveLyricsFile(UIViewController *controller, NSString *text, NSString *path) {
    NSError *error = nil;
    if (![text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:&error]) {
        NLAlert(controller, NLL(@"Could not save"), error.localizedDescription);
        return NO;
    }
    NLPostLyricsChanged();
    return YES;
}
// A lyrics file deleted and the apps told.
static inline void NLDeleteLyricsFile(NSString *path) {
    [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NLPostLyricsChanged();
}
// The lines' texts that are sung (not empty), in order, at most `limit` of them.
static inline NSArray<NSString *> *NLSungTexts(NSArray<NLLyricLine *> *lines, NSUInteger limit) {
    NSMutableArray<NSString *> *sung = [NSMutableArray array];
    for (NLLyricLine *line in lines) {
        if (sung.count >= limit) break;
        if (line.text.length) [sung addObject:line.text];
    }
    return sung;
}
// A row that only says something (nothing playing, no results): secondary text, not selectable.
static inline UITableViewCell *NLNoteCell(NSString *text) {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = text;
    cell.textLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
}
// An action row: its title and symbol in one tint.
static inline UITableViewCell *NLActionCell(NSString *title, NSString *symbol, UIColor *tint) {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = title;
    cell.textLabel.textColor = tint;
    cell.imageView.image = [UIImage systemImageNamed:symbol];
    cell.imageView.tintColor = tint;
    return cell;
}
// The pages that are a table of their own: inset grouped, filling `owner`'s
// view, `owner` its data source and delegate, the keyboard going on a drag.
static inline UITableView *NLMakeTable(UIViewController *owner) {
    UITableView *table = [[UITableView alloc] initWithFrame:owner.view.bounds style:UITableViewStyleInsetGrouped];
    table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    table.dataSource = (id<UITableViewDataSource>)owner;
    table.delegate = (id<UITableViewDelegate>)owner;
    table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [owner.view addSubview:table];
    return table;
}

@interface NLNowPlayingController : PSViewController
@end
// NLNowPlayingController.m, for the songs' pages (Now Playing, a song in the
// listening history): the Offset row for one song, `offset` being the default
// plus its own, the control calling `action` on `target`; and a per-song
// dictionary with `key`'s entry set to `value` (NLTrackEntries, NLShared.h).
UITableViewCell *NLSongOffsetRow(double offset, id target, SEL action);
NSDictionary *NLSettingTrackEntry(NSDictionary *all, NSString *key, id value);

// A page that is a table of its own under the main page's top (NLPageTop):
// -viewDidLoad makes both (NLMakeTable), and the top follows the page's
// appearance and layout. Subclasses call super first in -viewDidLoad and
// -viewWillAppear:. NLSourceOrderController.m.
@interface NLTablePage : PSViewController {
@protected
    UITableView *_table;
}
@end
@interface NLLibraryController : NLTablePage
@end
@interface NLSourceOrderController : NLTablePage
@end
// Every source's name once, in the order they are tried, read through
// `controller` (the page that shows them), or from the domain without one.
NSArray<NSString *> *NLSourceOrder(PSListController *controller);
// A preference read through `controller` the way its rows read theirs, or
// from the domain without one.
id NLReadPref(PSListController *controller, NSString *key);
void NLWritePref(PSListController *controller, NSString *key, id value);   // the same way; several straight into the domain: NLWritePrefs (NLShared.h)
// A switch read the same way: its value, or `fallback` when unset (or not a number or numeric string).
static inline BOOL NLReadPrefBool(PSListController *controller, NSString *key, BOOL fallback) {
    return NLLooseBool(NLReadPref(controller, key), fallback);
}
// The domain read again, for what SpringBoard, an app or another page just wrote.
static inline void NLSyncPrefs(void) { CFPreferencesAppSynchronize((__bridge CFStringRef)NL_PREFS_DOMAIN); }
// A page pushed from a list page reads and writes the preferences through it,
// the way its own rows do (that page writes them and posts the reload
// notification); without one, the domain. NLSourceOrderController.m.
@interface PSViewController (NLPrefs)
- (PSListController *)nlParentList;
- (id)nlPref:(NSString *)key;
- (void)nlSetPref:(id)value forKey:(NSString *)key;
- (BOOL)nlBoolPref:(NSString *)key fallback:(BOOL)fallback;
@end
// Whether a source's switch is on, read through `controller`, its default when
// unset; NO for a name that is not a source. NLSourceOrderController.m.
BOOL NLSourceSwitchOn(PSListController *controller, NSString *name);

// The pages loaded from a plist of this bundle (NLRootListController.m): rows
// prepared (icons, links, defaults, the island preview's room), shown as their
// showIf rules want, cells themed.
// NLRootListController.m: Apply, at the top right of every NowLyrics page but
// the lyrics editor (Save is there): after a confirmation, SpringBoard restarts.
UIBarButtonItem *NLApplyButton(UIViewController *controller);

@interface NLListController : PSListController
@end
// The pages loaded from the plist a link's `subPlist` names: Lyrics Sources
// and Advanced from the main page, Musixmatch and Apple Music
// (NLAppleMusicController, a subclass) from Lyrics Sources, Supported Tweaks
// from Advanced; localized by the <name>.strings copies the Makefile puts there.
@interface NLSubListController : NLListController
@end

// NLPlayerHeader.m: the lock screen's player as `table`'s header, behind it
// its cover blurred. The owner calls -layout from viewDidLayoutSubviews (and
// when the platter's preferred size changes), -appear / -disappear, -tick
// while on screen and -refresh every fourth tick (NLPageTick); -remove takes
// it off the table again.
@interface NLPlayerHeader : NSObject
- (instancetype)initWithOwner:(UIViewController *)owner table:(UITableView *)table;
- (void)layout;
- (void)appear;
- (void)disappear;
- (void)tick;
- (void)refresh;   // the background from the cover again
- (void)remove;
@end

// NLRootListController.m: what Advanced › Top of main page puts there,
// "player", "island" or "none", read through `controller` (or from the domain
// without one); and any island preview's values, from the Lyrics Island
// page's plist.
NSString *NLMainPageTop(PSListController *controller);
NSDictionary *NLIslandPreviewValuesFromPlist(PSListController *controller);

// NLPlayerHeader.m: the top of the other pages (Lyrics Sources, Advanced,
// Apple Music, Musixmatch, Source order, the library, Choose Apps) as the main
// page's while Advanced › Other pages too is on (the default): the player, the
// island preview or nothing. Now Playing keeps its own player and the Lyrics
// Island page its own island preview. The owner calls -update before its
// viewWillAppear: super (and when either setting changes), -layout from
// viewDidLayoutSubviews (and when a child's preferred size changes), -appear
// and -disappear; while appeared it follows what is playing on its own.
@interface NLPageTop : NSObject
- (instancetype)initWithOwner:(UIViewController *)owner table:(UITableView *)table;
- (void)update;
- (void)layout;
- (void)appear;
- (void)disappear;
@end
static const NSTimeInterval kNLPageRefreshInterval = 0.75;   // how often a page looks at what is playing

// The pages' theme, which goes with Player over its cover: the color of the
// song playing, or NowLyrics' own (NLThemeRefresh). NLThemeSetColor takes
// the raw color and posts NLThemeChangedNotification when it changed. Tint
// follows from the navigation controller's view; switches are set per cell.
extern NSString *const NLThemeChangedNotification;
UIColor *NLThemeColor(void);
void NLThemeSetColor(UIColor *color);
void NLThemeRefresh(void);   // from the preferences and what is playing
UIColor *NLThemeGreyCover(void);   // the raw color for a cover with no color of its own: the theme goes grey
id NLThemeFollowNowPlaying(void);   // an observer that refreshes the theme at every now-playing change; remove it when done
id NLObserveNowPlaying(void (^block)(void));   // MediaRemote's now-playing changes, main queue; remove it when done
UIColor *NLNowLyricsColor(void);   // NLIslandPreviewCell.m
void NLThemeCell(UITableViewCell *cell);
void NLThemeTable(UITableView *table);
UIColor *NLArtworkColorCached(NSData *artwork);   // NLPlayerHeader.m: NLColorFromArtwork, the last cover remembered; nil for no data. Main queue.
// One tick of a page's refresh timer: the player follows what plays, and every
// fourth tick its background and the theme are refreshed together (one
// MediaRemote request answers both).
static inline void NLPageTick(NLPlayerHeader *player, NSUInteger *ticks) {
    [player tick];
    if ((*ticks)++ % 4 == 0) {
        [player refresh];
        NLThemeRefresh();
    }
}

static const CGFloat kNLIconSize = 29;            // what a Settings row shows
static const CGFloat kNLIconCornerRadius = 6.5;
// NLRootListController.m: a Settings row icon, a white SF Symbol on a rounded
// tile of `hex` ("#RRGGBB").
UIImage *NLSettingsIcon(NSString *symbol, NSString *hex);
UIColor *NLColorFromHex(id value);   // "#RRGGBB"; nil for anything else
UIImage *NLSampleCoverIcon(void);   // the main switch's: a warm gradient with a note
// A row's icon as the plists give it: the installed app's (`app`), else the
// symbol on a tile of `hex`.
UIImage *NLRowIcon(NSString *app, NSString *symbol, NSString *hex);
// An image at a row icon's size: drawn into the tile, clipped to its rounded
// corners when `rounded`; as it is when it is that size already and not to be rounded.
static inline UIImage *NLRowSizedImage(UIImage *image, BOOL rounded) {
    if (!rounded && fabs(image.size.width - kNLIconSize) < 0.5 && fabs(image.size.height - kNLIconSize) < 0.5) return image;
    CGRect tile = CGRectMake(0, 0, kNLIconSize, kNLIconSize);
    return [[[UIGraphicsImageRenderer alloc] initWithSize:tile.size] imageWithActions:^(UIGraphicsImageRendererContext *context) {
        if (rounded) [[UIBezierPath bezierPathWithRoundedRect:tile cornerRadius:kNLIconCornerRadius] addClip];
        [image drawInRect:tile];
    }];
}

// NLSourceOrderController.m: a lyrics source's icon by its preference name
// ("applemusic", …; "" for automatic), as Lyrics Sources shows it.
UIImage *NLSourceIcon(NSString *name);
NSString *NLSourceTitle(NSString *name);   // the same, its title, localized

// NowLyrics in Control Center's media player (NLSystemPlayerSB.x): iOS 16's
// and 26's, its sizes iOS 16's alone (26 sizes it in Control Center itself).
static inline BOOL NLSystemPlayerAvailable(void) {
    if (@available(iOS 26.0, *)) return YES;
    if (@available(iOS 17.0, *)) return NO;
    return YES;
}
static inline BOOL NLSystemPlayerSizesAvailable(void) {
    if (@available(iOS 17.0, *)) return NO;
    return YES;
}
// NowLyrics' own Control Center modules: CCSupport installed, on iOS 16 (where they hold the media player's copy).
static inline BOOL NLCCModulesAvailable(void) {
    return NLSystemPlayerSizesAvailable() &&
           [NSFileManager.defaultManager fileExistsAtPath:NLJBPath(@"/Library/MobileSubstrate/DynamicLibraries/CCSupport.dylib")];
}

// NLCrescendo.m: Crescendo's volume slider in the copies of the system's
// players on these pages, while Crescendo is installed and wants it there.
typedef NS_ENUM(NSInteger, NLCrescendoPlace) { NLCrescendoLockScreen, NLCrescendoDynamicIsland };
BOOL NLCrescendoShows(NLCrescendoPlace place);
BOOL NLCrescendoInstalled(void);
BOOL NLCrescendoSyncPlayer(UIViewController *platter);   // YES when it changed the player
// The settings player's height as it asks for it, with what tweaks add to
// -[MRUNowPlayingView sizeThatFits:] (Crescendo, NextUp 3). 0 without a player.
CGFloat NLPlayerFittingHeight(UIViewController *platter, CGFloat width);
UIView *NLCrescendoMakeVolumeRow(UIView *host);           // nil when this iOS lacks the parts
// Supported Tweaks: Crescendo's slider is the system's own from iOS 17 on, and
// NextUp's rows here were made against iOS 16.
static inline BOOL NLCrescendoUsed(void) {
    if (@available(iOS 17.0, *)) return NO;
    return YES;
}
static inline BOOL NLNextUpUsed(void) {
    if (@available(iOS 16.0, *)) return YES;
    return NO;
}
// Crescendo's CRPrefs.h and NextUp 3's NUPrefs.h publish their switches the
// same way, as a notify state (`state`): bit 63 = published; value bit n, and
// bit n + 32 when the publishing build knew that key. Without one, the
// tweak's preferences (`domain`). `token` is the caller's, -1 until
// registered. NLCrescendo.m.
BOOL NLTweakStatePref(const char *state, int *token, CFStringRef domain, NSString *key, uint64_t bit, BOOL fallback);

// NLPopUpCell.m: a choice picked in place, as Settings' pop-up rows: the
// title in use with a chevron, the others in a menu. `picked` gets a new value.
UIButton *NLPopUpButton(NSArray<NSString *> *titles, NSArray *values, id current, void (^picked)(id value));
// One action per choice, the current one checked; `picked` gets another
// one's value. `symbols` may be nil. NLPopUpCell.m.
NSArray<UIAction *> *NLChoiceActions(NSArray<NSString *> *titles, NSArray<NSString *> *symbols, NSArray *values, id current, void (^picked)(id value));

// NLAppleMusicAccess.m: Apple Music stays hidden until SpringBoard confirms a
// subscription (kept as `appleMusicVerified`); SpringBoard keeps it in step
// from then on (NLAppleMusicSB.x), so a lapsed one locks it again and the
// pages show that as they appear.
// Privacy: Apple Music's privacy notice is not agreed to here yet, so nothing
// past iTunesCloud was asked (NLAppleMusicSB.x). SignedOut: no Apple ID is
// signed in for Media & Purchases, so nothing was asked; it locks as None does.
typedef NS_ENUM(NSInteger, NLSubscription) { NLSubscriptionUnknown = 0, NLSubscriptionActive, NLSubscriptionNone, NLSubscriptionPrivacy, NLSubscriptionSignedOut };
BOOL NLAppleMusicAvailable(void);   // this iOS can ask Apple Music for lyrics (16 and later)
BOOL NLAppleMusicVerified(void);
void NLCheckAppleMusicSubscription(void (^done)(NLSubscription result, NSString *detail));   // main queue
void NLApplyAppleMusicSubscription(NLSubscription result, BOOL switchOn);   // active: unlocked (and Apple Music on with `switchOn`); none or signed out: locked, Apple Music off

// NLMusixmatchAccess.m: Musixmatch stays behind "Unlock Musixmatch lyrics"
// until its app is installed (`musixmatchVerified`); with the app gone it stays
// while a User Token or API key is saved.
extern NSString *const NLMusixmatchBundleID;
extern NSString *const NLMusixmatchStoreURL;   // its App Store page
BOOL NLMusixmatchVerified(void);
BOOL NLUnlockMusixmatch(void);    // unlocked and on; NO without the app
BOOL NLRecheckMusixmatch(void);   // YES when it changed anything
BOOL NLAppInstalled(NSString *bundleID);   // NLRootListController.m

// NLNextUp.m: NextUp 3's Up Next row in these pages' copies of the players.
BOOL NLNextUpInstalled(void);
void NLNextUpLoad(void);            // its library, once: the settings player then gets its row as the lock screen's does
BOOL NLNextUpShowsInIsland(void);   // its switches want the island's row; its library is loaded then
BOOL NLNextUpActive(void);          // it has a next track for what plays
void NLNextUpStart(void);
void NLNextUpKeepOut(UIView *view);   // the island preview's view: none of NextUp's own row or layout
#define NL_NEXTUP_CHANGED_NOTIFICATION @"NUNextUpDidChangeNotification"   // NextUp 3's own; also posted when Supported Tweaks changes
// `changed` on the main queue a turn after each NextUp change (its row lays
// itself out first). The observer goes to -removeObserver: in the owner's
// dealloc. NLNextUp.m.
id NLObserveNextUp(void (^changed)(void));

// NLIslandPreviewCell.m: the most the open island preview grows by for the rows
// tweaks add, which the island page keeps room for under it.
CGFloat NLIslandPreviewMostExtraHeight(void);
CGFloat NLIslandPreviewOpenBottom(void);   // the open island's bottom, from the table's top
// NLIslandPreviewCell.m: the island preview row (its page posts
// NLIslandPreviewChangedNotification after an island setting changed).
@interface NLIslandPreviewCell : PSTableCell
@end
extern NSString *const NLIslandPreviewChangedNotification;
NSArray<NSString *> *NLPreviewLinePool(NSBundle *bundle);   // NLPreviewLines.m: what the preview sings now

// `selector`'s implementation on `cls` replaced by `replacement`; the one it
// had, or NULL without such a method (or class).
static inline IMP NLReplaceMethod(Class cls, SEL selector, IMP replacement) {
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    return method ? method_setImplementation(method, replacement) : NULL;
}
