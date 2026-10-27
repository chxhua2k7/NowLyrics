//
//  NLCC.h
//  What the Control Center module's files share: the module (NLCCModule.m),
//  its tile (NLCCViews.m) and what the tile does with what plays (NLCCShared.m).
//

#import "NLCCPrivate.h"
#import "../NowLyrics.h"
#import "../NLLocate.h"

// This bundle's copy of the settings' Localizable.strings (the Makefile puts it there).
NSString *NLCCL(NSString *key);
// "Not Playing" as the system's media player says it (MediaControls), ours without it.
NSString *NLCCNotPlaying(void);

// The song as the tile shows it: from the app's nowplaying.plist (`np`), or
// MediaRemote's (`info`) in an app NowLyrics is not on in; the app's icon, `cover` (made small).
@class NLCCSong;
NLCCSong *NLCCSongNow(NSString *bundleID, NSDictionary *np, NSDictionary *info, UIImage *cover);
// Play or pause sent to the app playing, as the system's media player sends
// it; `info` back with the two flipped at once, so a refresh before
// MediaRemote's own change does not undo it.
NSDictionary *NLCCTogglePlayPause(NSDictionary *info);
// The cover made small off the main queue (`points` its longer side), handed back on it.
void NLCCMakeCover(NSData *artwork, CGFloat points, void (^done)(UIImage *cover));

// The modules' sizes, rows × columns as Control Center lays modules out, a
// module each (NLCCProvider): 1×1 and 1×2 the tile, the others the media
// player's copy laid out as NowLyrics lays out the media module's.
static inline NSArray<NSString *> *NLCCSizeNames(void) { return @[@"1x1", @"1x2", @"1x4", @"2x2", @"2x4", @"3x4"]; }

@interface NLCCSong : NSObject
@property (nonatomic, assign) BOOL playing;      // a song to show
@property (nonatomic, assign) BOOL playingNow;   // playing rather than paused: the button shows pause
@property (nonatomic, copy) NSString *title, *artist;
@property (nonatomic, strong) UIImage *cover, *appIcon;
@end

// The closed module at 1×1 (the cover, the app's icon on its corner) or 1×2
// (the cover, the title and the artist beside it, play or pause at the end).
// Touches go through to the module underneath, but for the button.
@interface NLCCTileView : UIView
@property (nonatomic, assign) CGFloat moduleRadius;   // the module's corners, which the cover's follow (compact by default)
@property (nonatomic, copy) void (^playPause)(void);   // the button tapped
- (void)showSong:(NLCCSong *)song;
@end
