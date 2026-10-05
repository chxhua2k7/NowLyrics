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
#import "../NowLyrics.h"
#import "../NLLocate.h"

// Localized from this bundle's Island.strings, the copies of
// prefs/<lang>.lproj/Localizable.strings the Makefile puts there.
NSString *NLL(NSString *key);

NSString *NLAppName(NSString *bundleID);
UIImage *NLAppIcon(NSString *bundleID);
void NLAlert(UIViewController *controller, NSString *title, NSString *message);
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
@property (nonatomic, strong) UIImage *artwork;   // colors the bars the way the system's are; nil for plain bars
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

@interface NLNowPlayingController : PSViewController
@end

@interface NLLibraryController : PSViewController
@end

@interface NLSourceOrderController : PSViewController
@end
// Every source's name once, in the order they are tried, read through
// `controller` (the page that shows them), or from the domain without one.
NSArray<NSString *> *NLSourceOrder(PSListController *controller);
// A preference read through `controller` the way its rows read theirs, or
// from the domain without one.
id NLReadPref(PSListController *controller, NSString *key);
void NLWritePref(PSListController *controller, NSString *key, id value);   // the same way
// Straight into the domain (NSNull removes one), then one reload notice to
// the apps.
void NLWritePrefs(NSDictionary<NSString *, id> *values);

// The pages the main page links to for its details (Lyrics Sources, Advanced,
// Apple Music): the plist named by the link's `subPlist`, from this bundle,
// localized by the <name>.strings copies the Makefile puts there
// (NLRootListController.m).
@interface NLSubListController : PSListController
@end

// NLPlayerHeader.m: the lock screen's player as `table`'s header, behind it
// its cover blurred. The owner calls -layout from viewDidLayoutSubviews (and
// when the platter's preferred size changes), -appear / -disappear, and -tick
// while on screen; -remove takes it off the table again.
@interface NLPlayerHeader : NSObject
- (instancetype)initWithOwner:(UIViewController *)owner table:(UITableView *)table;
- (void)layout;
- (void)appear;
- (void)disappear;
- (void)tick;
- (void)remove;
@end

// NLRootListController.m: what Advanced › Top of main page puts there,
// "player", "island" or "none", read through `controller` (or from the domain
// without one); and an island preview's values away from the Lyrics Island
// page, from that page's plist.
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
BOOL NLTopOnEveryPage(void);
@interface NLPageTop : NSObject
- (instancetype)initWithOwner:(UIViewController *)owner table:(UITableView *)table;
- (void)update;
- (void)layout;
- (void)appear;
- (void)disappear;
@end

// The pages' theme: the color of what the island preview shows
// (NLIslandPreviewCell.m), the album's or NowLyrics' own. NLThemeSetColor takes
// the raw color and posts NLThemeChangedNotification when it changed. Tint
// follows from the navigation controller's view; switches are set per cell.
extern NSString *const NLThemeChangedNotification;
UIColor *NLThemeColor(void);
void NLThemeSetColor(UIColor *color);
void NLThemeRefresh(void);   // from the preferences and what is playing
UIColor *NLNowLyricsColor(void);   // NLIslandPreviewCell.m
void NLThemeCell(UITableViewCell *cell);
void NLThemeTable(UITableView *table);

// NLRootListController.m: a Settings row icon, a white SF Symbol on a rounded
// tile of `hex` ("#RRGGBB").
UIImage *NLSettingsIcon(NSString *symbol, NSString *hex);
UIImage *NLSampleCoverIcon(void);   // the main switch's: a warm gradient with a note
// A row's icon as the plists give it: the installed app's (`app`), else the
// symbol on a tile of `hex`.
UIImage *NLRowIcon(NSString *app, NSString *symbol, NSString *hex);
// NLAppListController.m: Choose Apps' list (AltList's, with a filter for music
// apps), made once AltList is loaded (NLOffsetCell.m).
void NLRegisterAppListController(void);

// NLSourceOrderController.m: a lyrics source's icon by its preference name
// ("applemusic", …; "" for automatic), as Lyrics Sources shows it.
UIImage *NLSourceIcon(NSString *name);
NSString *NLSourceTitle(NSString *name);   // the same, its title, localized

// NLCrescendo.m: Crescendo's volume slider in the copies of the system's
// players on these pages, while Crescendo is installed and wants it there.
typedef NS_ENUM(NSInteger, NLCrescendoPlace) { NLCrescendoLockScreen, NLCrescendoDynamicIsland };
BOOL NLCrescendoShows(NLCrescendoPlace place);
BOOL NLCrescendoSyncPlayer(UIViewController *platter);   // YES when it changed the player
// The settings player's height as it asks for it, with what tweaks add to
// -[MRUNowPlayingView sizeThatFits:] (Crescendo, NextUp 3). 0 without a player.
CGFloat NLPlayerFittingHeight(UIViewController *platter, CGFloat width);
UIView *NLCrescendoMakeVolumeRow(UIView *host);           // nil when this iOS lacks the parts

// NLPopUpCell.m: a choice picked in place, as Settings' pop-up rows: the
// title in use with a chevron, the others in a menu. `picked` gets a new value.
UIButton *NLPopUpButton(NSArray<NSString *> *titles, NSArray *values, id current, void (^picked)(id value));

// NLAppleMusicAccess.m: Apple Music stays hidden until SpringBoard confirms a
// subscription (kept as `appleMusicVerified`); a lapsed one locks it again.
// Privacy: Apple Music's privacy notice is not agreed to here yet, so nothing
// past iTunesCloud was asked (NLAppleMusicSB.x).
typedef NS_ENUM(NSInteger, NLSubscription) { NLSubscriptionUnknown = 0, NLSubscriptionActive, NLSubscriptionNone, NLSubscriptionPrivacy };
BOOL NLAppleMusicAvailable(void);   // this iOS can ask Apple Music for lyrics (16 and later)
BOOL NLAppleMusicVerified(void);
void NLCheckAppleMusicSubscription(void (^done)(NLSubscription result, NSString *detail));   // main queue
void NLApplyAppleMusicSubscription(NLSubscription result);   // active: unlocked; none: locked, Apple Music off
void NLRecheckAppleMusicIfDue(void (^changed)(void));        // silent; `changed` when it locked or unlocked

// NLMusixmatchAccess.m: Musixmatch stays behind "Unlock Musixmatch lyrics"
// until its app is installed (`musixmatchVerified`); with the app gone it stays
// while a User Token or API key is saved.
extern NSString *const NLMusixmatchBundleID;
extern NSString *const NLMusixmatchStoreURL;   // its App Store page
BOOL NLMusixmatchInstalled(void);
BOOL NLMusixmatchVerified(void);
BOOL NLUnlockMusixmatch(void);    // unlocked and on; NO without the app
BOOL NLRecheckMusixmatch(void);   // YES when it changed anything
BOOL NLAppInstalled(NSString *bundleID);   // NLRootListController.m

// NLNextUp.m: NextUp 3's Up Next row in these pages' copies of the players.
BOOL NLNextUpInstalled(void);
void NLNextUpLoad(void);            // its library, once: the settings player then gets its row as the lock screen's does
BOOL NLNextUpShowsInIsland(void);   // its switches want the island's row
BOOL NLNextUpActive(void);          // it has a next track for what plays
void NLNextUpStart(void);
void NLNextUpKeepOut(UIView *view);   // the island preview's view: none of NextUp's own row or layout

// NLIslandPreviewCell.m: the most the open island preview grows by for the rows
// tweaks add, which the island page keeps room for under it.
CGFloat NLIslandPreviewMostExtraHeight(void);
CGFloat NLIslandPreviewOpenBottom(void);   // the open island's bottom, from the table's top
BOOL NLDeviceHasDynamicIsland(void);   // NLRootListController.m
