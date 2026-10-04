//
//  NLLocate.h
//  Where the apps keep their lyrics, for the two places that look from outside:
//  the settings page (Preferences) and the island (SpringBoard). Neither is
//  sandboxed, so both can read and write app containers directly.
//

#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

// The app's data container, e.g. /var/mobile/Containers/Data/Application/<UUID>.
// Looked up from the container metadata once and remembered; a miss rescans.
NSString *NLDataContainerForBundle(NSString *bundleID);

// <container>/Library/NowLyrics for every app that has one, by bundle ID. Scans.
NSDictionary<NSString *, NSString *> *NLLyricsFolders(void);

// The app's nowplaying.plist (NLShared.h's NL_NP_* keys), nil if it has none.
NSDictionary *NLReadNowPlaying(NSString *bundleID);

// Which app MediaRemote says is playing. Calls back on the main queue, nil if
// it does not know.
void NLNowPlayingBundleID(void (^completion)(NSString *bundleID));

// Whether MediaRemote says something is playing. Main queue.
void NLNowPlayingIsPlaying(void (^completion)(BOOL playing));

// The now-playing info dictionary (kMRMediaRemoteNowPlayingInfo… keys, artwork
// included). Main queue; nil when nothing is playing.
void NLNowPlayingInfo(void (^completion)(NSDictionary *info));

// Tells the apps their lyrics files changed (NL_LYRICS_CHANGED_NOTIFICATION).
void NLPostLyricsChanged(void);

// Word by word for the line on screen, found the way the playing app picks it:
// in the lyrics file its nowplaying.plist names, by the position MediaRemote
// reports (`info`, from MRMediaRemoteGetNowPlayingInfo) plus the offsets in
// `prefs`. nil unless that line has word times and its text is `shown`.
@interface NLShownWords : NSObject
@property (nonatomic, copy) NSArray<NSString *> *texts;
@property (nonatomic, copy) NSArray<NSNumber *> *starts, *ends;
@property (nonatomic, assign) NSTimeInterval position;   // on the same clock, as of the call
@property (nonatomic, assign) double rate;
@end

NLShownWords *NLWordsForShownLine(NSString *bundleID, NSString *shown, NSDictionary *info, NSDictionary *prefs);

#ifdef __cplusplus
}
#endif
