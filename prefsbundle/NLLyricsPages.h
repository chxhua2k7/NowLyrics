//
//  NLLyricsPages.h
//  The lyrics pages of the settings bundle: "Now Playing" (the current song's
//  lyrics and offset), the lyrics library, and the editor both open. They work
//  on the apps' lyrics files directly (NLLocate.h): Preferences is not
//  sandboxed, and the apps are told to look again (NLPostLyricsChanged).
//

#import <UIKit/UIKit.h>
#import <Preferences/PSViewController.h>
#import "../NowLyrics.h"
#import "../NLLocate.h"

// Localized from this bundle's Island.strings, the copies of
// prefs/<lang>.lproj/Localizable.strings the Makefile puts there.
NSString *NLL(NSString *key);

NSString *NLAppName(NSString *bundleID);
UIImage *NLAppIcon(NSString *bundleID);
void NLAlert(UIViewController *controller, NSString *title, NSString *message);

// NLLyricsImport.m. Pasted or imported text as it should be stored: LRC
// (word-by-word too) as given, with the track named on top when it is not;
// TTML converted to LRC. nil when it holds no timed lyrics.
NSString *NLLyricsFileText(NSString *text, NSString *title, NSString *artist);

// NLWaveformView.m: a made-up now-playing waveform (the real one needs an
// audio tap). Bounces while `playing`, dots otherwise.
@interface NLWaveformView : UIView
- (instancetype)initWithBars:(NSUInteger)count;
@property (nonatomic, assign) BOOL playing;
@property (nonatomic, strong) UIColor *barColor;
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
