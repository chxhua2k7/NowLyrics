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
#define NL_PLAYER_TINT_CLEAR_KEY @"playerTintClear"   // preference: how clear, a percentage, default 50

// iOS 26's lock screen player is glass, which shows what is behind the platter
// over a tint inside it, and its Control Center's media module takes the
// cover's colors itself. From 26 on every player keeps the system's look,
// the settings page's copy too (so it looks like the lock screen's), and the
// setting is hidden.
static inline BOOL NLPlayerTintAvailable(void) {
    if (@available(iOS 26.0, *)) return NO;
    return YES;
}

// `tint` right above `material` among its siblings (moved there unless it is
// already), exactly over it: its transform, anchor point, size and centre.
// Not its frame, which under a transform is the transformed box (and setting
// one there is undefined), so a scaled material would get a tint of the wrong
// size. The centre is where the anchor point sits, so the anchor goes too.
static inline void NLPlaceTintAbove(UIView *tint, UIView *material) {
    UIView *container = material.superview;
    if (tint.superview != container ||
        [container.subviews indexOfObject:tint] != [container.subviews indexOfObject:material] + 1) {
        [container insertSubview:tint aboveSubview:material];
    }
    CGAffineTransform transform = material.transform;
    if (!CGAffineTransformEqualToTransform(tint.transform, transform)) tint.transform = transform;
    CGPoint anchor = material.layer.anchorPoint;
    if (!CGPointEqualToPoint(tint.layer.anchorPoint, anchor)) tint.layer.anchorPoint = anchor;
    tint.bounds = (CGRect){tint.bounds.origin, material.bounds.size};
    tint.center = material.center;
}
@class CIImage;
// `input` scaled to `width` pixels wide and blurred by `sigma`, its edges
// clamped so they do not darken; NULL on failure. One shared CIContext; any queue.
CGImageRef NLCreateBlurredImage(CIImage *input, CGFloat width, CGFloat sigma) CF_RETURNS_RETAINED;

@interface NLPlayerTintView : UIView
// `info`: MediaRemote's now-playing info (its title and artwork are used).
// Work is done off the main queue and only when the artwork changed; the
// change fades when `animated`. A missing cover keeps the current look for a while
// (between songs). With nothing playing it shows NowLyrics' coral, or with
// `clearsWhenNothingPlays` goes clear, showing what is under it (the system's
// material), as it is until it is first given something.
- (void)showNowPlaying:(NSDictionary *)info animated:(BOOL)animated;
@property (nonatomic, assign) BOOL clearsWhenNothingPlays;   // the lock screen's and Control Center's
// The system's material it lies over (an MTMaterialView), thinned with
// `clearness` while the look shows and given back whole when the look goes or
// this view is hidden.
@property (nonatomic, weak) UIView *material;
// 0 (opaque) to 1: how much of what is under the look shows through it. The
// look grows clearer and the material under it thinner (-weighting, its blur
// and tint), so on the lock screen and in Control Center the wallpaper behind
// comes through.
@property (nonatomic, assign) CGFloat clearness;
@end
