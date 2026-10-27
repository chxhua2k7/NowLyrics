//
//  NLSystemPlayer.h
//  What NowLyrics' own Control Center modules (cc/NLCCModule.m) and the
//  system player's code (NLSystemPlayerSB.x, in NowLyricsIsland) share. Both
//  run in SpringBoard; the modules, another binary, find these classes at
//  runtime (NSClassFromString).
//

#import <UIKit/UIKit.h>

// A module's copy of the media player (MediaControls' MRUControlCenter-
// ViewController, made as the media module makes it), laid out as the media
// module's is, at the module's own size.
@interface NLSPOwnModule : NSObject
// This iOS's player is one NowLyrics lays out (iOS 16's).
@property (class, nonatomic, readonly) BOOL canAdopt;
// `player` at the module's `size` (rows × columns, as "2x4"), `tile` over it
// closed at 1×1 and 1×2.
+ (void)adopt:(UIViewController *)player size:(NSString *)size tile:(UIView *)tile;
@property (nonatomic, copy) NSString *size;
@property (nonatomic, strong) UIView *tile;
@end

// What plays, for everything that shows it, followed while anything watches
// and shows: the playing app's nowplaying.plist on a timer, MediaRemote's
// info when it changes.
@interface NLSPFollower : NSObject
+ (instancetype)shared;
@property (nonatomic, readonly) NSString *bundleID;
@property (nonatomic, readonly) NSDictionary *np, *info, *prefs;
- (void)watch:(id)watcher changed:(void (^)(void))changed;   // until unwatched or gone
- (void)unwatch:(id)watcher;
// Reading again, should it have stopped, once anything watching shows (iOS 26
// lays Control Center's module out before it shows; closed, Control Center's
// window is hidden). Also as any window shows.
- (void)wake;
@end
