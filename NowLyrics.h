//
//  NowLyrics.h
//  Shared declarations. Everything here is internal to the tweak.
//
//  Layout:
//    NLSettings.m   preference file lookup, the per-app switch, process checks
//    NLLyrics.m     LRC parsing and serialisation, title cleaning, cache and manual files
//    NLSources.m    HTTP and the three lyrics providers, resolution order
//    NLEngine.m     track state, virtual clock, line lookup, flip timer, fetch queue
//    NowLyrics.xm   the hooks and the two publishers (dictionary and content item)
//
//  NowLyrics.xm is compiled as Objective-C++ (Logos), the .m files as plain
//  Objective-C, hence the extern "C" guard around the functions.
//

#import <Foundation/Foundation.h>

#if DEBUG
#define NLLog(fmt, ...) NSLog(@"[NowLyrics] " fmt, ##__VA_ARGS__)
#else
#define NLLog(fmt, ...) do {} while (0)
#endif

#pragma mark - Types

@interface NLLyricLine : NSObject
@property (nonatomic, assign) NSTimeInterval start;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, assign) BOOL chorus;        // inside the block NLMarkChorus() picked
@property (nonatomic, assign) BOOL chorusStart;   // first line of one occurrence of it
@end

// What to put in the artist field while a lyric line occupies the title.
typedef NS_ENUM(NSInteger, NLArtistMode) {
    NLArtistModeNone = 0,   // leave whatever the player set
    NLArtistModeTitle,      // "Track — Artist"
    NLArtistModeNextLine,   // the upcoming lyric line
};

typedef NS_ENUM(NSInteger, NLSource) {
    NLSourceNone = -1,      // no preference, keep the default order
    NLSourceMusixmatch = 0,
    NLSourceLRCLIB,
    NLSourceNetease,
    NLSourceCount,
};

// A snapshot of the preference file. Replaced wholesale on reload and never
// mutated afterwards, so the fetch queue can keep using the one it started with.
@interface NLSettings : NSObject
@property (nonatomic, readonly) BOOL enabled;                 // this app is switched on
@property (nonatomic, readonly) NLArtistMode artistMode;
@property (nonatomic, readonly) NLSource preferredSource;
@property (nonatomic, readonly) BOOL useMusixmatch;           // NO when no credentials are set
@property (nonatomic, readonly) BOOL useLRCLIB;
@property (nonatomic, readonly) BOOL useNetease;
@property (nonatomic, readonly, copy) NSString *musixmatchKey;
@property (nonatomic, readonly, copy) NSString *musixmatchToken;
@property (nonatomic, readonly) BOOL killOnChange;
@property (nonatomic, readonly) BOOL diagnostics;
@property (nonatomic, readonly) BOOL spotifyConnect;   // split "Track • Artist" + "Playing on X" reported during Spotify Connect
@property (nonatomic, readonly) NSTimeInterval offset;        // positive means lyrics appear earlier
@property (nonatomic, readonly) NSTimeInterval cacheClearedAt; // when "Clear lyrics cache" was last tapped, 0 if never
// Everything that invalidates lyrics already fetched, folded into one comparable string.
@property (nonatomic, readonly, copy) NSString *sourceSignature;
@end

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Constants

extern NSString *const kNLPrefsDomain;
extern NSString *const kNLReloadNotification;
extern NSString *const kNLApplyNotification;   // settings page's Apply button: enabled players quit so they relaunch fresh
extern NSString *const kNLUserAgent;
extern const NSTimeInterval kNLDurationTolerance;   // max track-length mismatch when matching

#pragma mark - NLSettings.m

BOOL NLProcessIsEligible(void);         // load-time safety check, independent of user settings
BOOL NLProcessUsesContentItems(void);   // Apple's Music app publishes through content items
NLSettings *NLSettingsCurrent(void);    // the latest snapshot; loads one if there is none yet
NLSettings *NLSettingsReload(void);     // re-reads the file and computes `enabled` for this process

#pragma mark - NLLyrics.m

double NLNum(id value, double fallback);   // doubleValue that survives JSON null
NSString *NLCleanTitle(NSString *title);
BOOL NLSplitConnectInfo(NSString *title, NSString *artist, NSString **outTitle, NSString **outArtist);
NSString *NLPrimaryArtist(NSString *artist);
NSString *NLTrackKey(NSString *title, NSString *artist);
NSString *NLLegacyTrackKey(NSString *title, NSString *artist, NSTimeInterval duration);   // pre-2.19 cache names
NSArray<NLLyricLine *> *NLParseLRC(NSString *lrc);
NSString *NLLinesToLRC(NSArray<NLLyricLine *> *lines);
BOOL NLHasContent(NSArray<NLLyricLine *> *lines);   // at least two sung lines
void NLMarkChorus(NSArray<NLLyricLine *> *lines);   // sets chorus/chorusStart; leaves them NO when nothing repeats
NSString *NLCachePath(NSString *key);
NSArray<NLLyricLine *> *NLManualLyrics(NSString *title, NSString *artist);
BOOL NLClearCacheIfRequested(NSTimeInterval requestedAt);   // deletes cached files older than the request; YES if any went
void NLPruneCache(NSUInteger limit);                       // keeps only the newest `limit` cached files

#pragma mark - NLSources.m

// Manual file, then the disk cache, then the enabled providers in order. Blocks;
// runs on the engine's fetch queue. On a miss, `source` says what each provider
// answered and `transient` whether some request never got an answer at all.
NSArray<NLLyricLine *> *NLResolveLyrics(NLSettings *settings, NSString *key,
                                        NSString *title, NSString *artist, NSString *album,
                                        NSTimeInterval duration,
                                        NSString **source, BOOL *transient);

#pragma mark - NLEngine.m (main queue unless noted)

void NLEngineStart(void);   // once, from %ctor
// One now-playing update, whichever way the app publishes. A new track starts a
// fetch; the same track just redraws.
void NLEngineIngest(NSString *title, NSString *artist, NSString *album,
                    NSTimeInterval duration, NSNumber *elapsed, NSNumber *rate);
void NLEnginePushUpdate(void);          // redraw for the current position and reschedule the flip
void NLEngineCancelFlip(void);          // e.g. the app was just switched off
void NLEngineForgetLyrics(void);        // sources changed: drop the in-memory cache and the current track
NSTimeInterval NLEnginePosition(void);  // extrapolated playback position
NSString *NLEngineTrackTitle(void);     // what the player really reported for the current track
NSString *NLEngineTrackArtist(void);

#pragma mark - NowLyrics.xm

// Where the composed strings go. nil means "whatever the player set".
void NLPublish(NSString *title, NSString *artist);
// Put the player's own values back. Only the content-item path has anything to do.
void NLPublishRestore(void);

#ifdef __cplusplus
}
#endif
