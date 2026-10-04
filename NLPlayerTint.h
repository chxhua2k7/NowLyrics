//
//  NLPlayerTint.h
//  The now-playing player's background from its cover, shared by the
//  settings pages' copy of the player and the real ones on the lock screen and
//  in Control Center (NLPlayerTintSB.x).
//
//  A cover gives the cover itself, blurred, under a dark scrim as strong as
//  its brightest parts need, whatever color the lyrics are. A song without a
//  cover: NowLyrics' own coral. Nothing playing: the same coral in Settings,
//  none of it (the system's own material) on the lock screen and in Control
//  Center.
//

#import <UIKit/UIKit.h>

#define NL_PLAYER_TINT_KEY @"playerTint"   // preference, default on

@interface NLPlayerTintView : UIView
// `info`: MediaRemote's now-playing info (its title and artwork are used).
// Work is done off the main queue and only when the artwork changed; the
// change fades when `animated`. A missing cover keeps the current look for a while
// (between songs). With nothing playing it shows NowLyrics' coral, or with
// `clearsWhenNothingPlays` goes clear, showing what is under it (the system's
// material), as it is until it is first given something.
- (void)showNowPlaying:(NSDictionary *)info animated:(BOOL)animated;
@property (nonatomic, assign) BOOL clearsWhenNothingPlays;   // the lock screen's and Control Center's
@end
