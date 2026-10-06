//
//  NLLocate.h
//  Where the apps keep their lyrics, for the two places that look from outside:
//  the settings page (Preferences) and the island (SpringBoard). Neither is
//  sandboxed, so both can read and write app containers directly.
//

#import <Foundation/Foundation.h>
#import "NLShared.h"

#ifdef __cplusplus
extern "C" {
#endif

// The app's data container, e.g. /var/mobile/Containers/Data/Application/<UUID>.
// Looked up from the container metadata once and remembered; a miss rescans
// once the containers folder has changed.
NSString *NLDataContainerForBundle(NSString *bundleID);
// <container>/Library/NowLyrics for one app, whether or not it exists yet;
// nil without a container.
static inline NSString *NLLyricsFolderForBundle(NSString *bundleID) {
    NSString *container = NLDataContainerForBundle(bundleID);
    return container ? [container stringByAppendingPathComponent:NL_APP_FOLDER] : nil;
}

// <container>/Library/NowLyrics for every app that has one, by bundle ID. The
// containers are scanned again only once their folder has changed, the rule
// NLDataContainerForBundle goes by.
NSDictionary<NSString *, NSString *> *NLLyricsFolders(void);

// The app's nowplaying.plist (NLShared.h's NL_NP_* keys), nil if it has none.
NSDictionary *NLReadNowPlaying(NSString *bundleID);

void *NLMediaRemote(const char *symbol);   // a MediaRemote function, NULL when this iOS lacks it

// Which app MediaRemote says is playing. Calls back on the main queue, nil if
// it does not know.
void NLNowPlayingBundleID(void (^completion)(NSString *bundleID));
// SpringBoard only: the app its SBMediaController says is playing,
// synchronously; nil elsewhere or when nothing is.
NSString *NLSpringBoardPlayingBundleID(void);

// Whether MediaRemote says something is playing. Main queue.
void NLNowPlayingIsPlaying(void (^completion)(BOOL playing));

// The now-playing info dictionary (kMRMediaRemoteNowPlayingInfo… keys, artwork
// included). Called and answered on the main queue; nil when nothing is
// playing. Callers in one turn of the main queue share one request.
void NLNowPlayingInfo(void (^completion)(NSDictionary *info));
// Its keys, and the values the island, the tint and the pages read from it.
#define NL_MR_TITLE     @"kMRMediaRemoteNowPlayingInfoTitle"
#define NL_MR_ARTWORK   @"kMRMediaRemoteNowPlayingInfoArtworkData"
#define NL_MR_RATE      @"kMRMediaRemoteNowPlayingInfoPlaybackRate"
#define NL_MR_EXPLICIT  @"kMRMediaRemoteNowPlayingInfoIsExplicitTrack"
#define NL_MR_ELAPSED   @"kMRMediaRemoteNowPlayingInfoElapsedTime"
#define NL_MR_TIMESTAMP @"kMRMediaRemoteNowPlayingInfoTimestamp"
// The title, nil unless a non-empty string (a song that has one).
static inline NSString *NLInfoTitle(NSDictionary *info) {
    NSString *title = NLString(info, NL_MR_TITLE);
    return title.length ? title : nil;
}
// The cover, nil unless non-empty data.
static inline NSData *NLInfoArtwork(NSDictionary *info) {
    id artwork = info[NL_MR_ARTWORK];
    return [artwork isKindOfClass:[NSData class]] && [artwork length] ? artwork : nil;
}
// Between songs MediaRemote reports no cover for a moment. A cover missing for
// less than this is waited out; one missing this long is a song without one.
static const NSTimeInterval kNLMissingGrace = 2.5;
// Playing: a playback rate above 0.
static inline BOOL NLInfoPlaying(NSDictionary *info) { return NLPrefNum(info, NL_MR_RATE, 0) > 0; }

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
