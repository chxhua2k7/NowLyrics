//
//  NowLyrics.h
//  Shared declarations. Everything here is internal to the tweak.
//
//  Layout:
//    NLSettings.m   preference file lookup, the per-app switch, process checks
//    NLLyrics.m     LRC parsing and serialisation, title cleaning, cache and manual files
//    NLTTML.m       TTML parsing (Apple Music's lyrics, imported TTML)
//    NLSources.m    HTTP, the lyrics providers (Musixmatch, LRCLIB, NetEase, Apple Music) and the order they are tried in
//    NLEngine.m     track state, virtual clock, line lookup, flip timer, fetch queue
//    NLAppleMusicRemote.m  Apple Music's lyrics through SpringBoard, for apps other than Music
//    NowLyrics.xm   the hooks and the two publishers (dictionary and content item)
//
//  NowLyrics.xm is compiled as Objective-C++ (Logos), the .m files as plain
//  Objective-C, hence the extern "C" guard around the functions.
//

#import <Foundation/Foundation.h>
#import "NLShared.h"

#if DEBUG
#define NLLog(fmt, ...) NSLog(@"[NowLyrics] " fmt, ##__VA_ARGS__)
#else
#define NLLog(fmt, ...) do {} while (0)
#endif

#pragma mark - Types

// One timed piece of a line, for word-by-word lyrics. A piece is whatever the
// source timed: a word with its trailing space, or one CJK character.
@interface NLLyricWord : NSObject
@property (nonatomic, assign) NSTimeInterval start;
@property (nonatomic, assign) NSTimeInterval end;   // 0 when the source did not say
@property (nonatomic, copy) NSString *text;
+ (instancetype)wordAt:(NSTimeInterval)start end:(NSTimeInterval)end text:(NSString *)text;
@end

@interface NLLyricLine : NSObject
@property (nonatomic, assign) NSTimeInterval start;
@property (nonatomic, assign) NSTimeInterval end;   // 0 when the source did not say
@property (nonatomic, copy) NSString *text;          // the words' texts joined, for the title field
@property (nonatomic, copy) NSArray<NLLyricWord *> *words;   // nil for line-timed lyrics
@property (nonatomic, assign) BOOL chorus;        // inside the block NLMarkChorus() picked
@property (nonatomic, assign) BOOL chorusStart;   // first line of one occurrence of it
+ (instancetype)lineAt:(NSTimeInterval)start text:(NSString *)text;   // no end, no words
@end

// LRC header tags NowLyrics writes at the top of the files it stores, so they
// can be listed with a title and artist (cache file names are not readable).
#define NL_LRC_TITLE   @"ti"
#define NL_LRC_ARTIST  @"ar"
#define NL_LRC_ALBUM   @"al"
#define NL_LRC_SOURCE  @"nl-source"
#define NL_LRC_CHECKED @"nl-checked"   // fetched since word times are checked against the song (1.2.0)

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
    NLSourceAppleMusic,     // Apple Music's own lyrics: in Music by its item, elsewhere through SpringBoard
};

// sourceOrder's names, in the default order: Apple Music, Musixmatch for its
// timing, LRCLIB, free and broad, then NetEase for Chinese tracks.
static inline NSArray<NSString *> *NLSourceNamesInOrder(void) {
    return @[@"applemusic", @"musixmatch", @"lrclib", @"netease"];
}
// A source by its preference name, NLSourceNone for anything else.
static inline NLSource NLSourceNamed(id name) {
    if ([name isEqual:@"musixmatch"]) return NLSourceMusixmatch;
    if ([name isEqual:@"lrclib"]) return NLSourceLRCLIB;
    if ([name isEqual:@"netease"]) return NLSourceNetease;
    if ([name isEqual:@"applemusic"]) return NLSourceAppleMusic;
    return NLSourceNone;
}
// The order the sources are tried in, by name, every known one once: the
// user's `sourceOrder` (`saved`), then any it does not name, in the default
// order. Before there was an order: Apple Music, then the old preferred source.
static inline NSArray<NSString *> *NLCompletedSourceOrder(id saved, id preferred) {
    NSArray *names = [saved isKindOfClass:[NSArray class]] ? saved : @[@"applemusic", preferred ?: @""];
    NSMutableArray<NSString *> *order = [NSMutableArray array];
    for (id name in [names arrayByAddingObjectsFromArray:NLSourceNamesInOrder()]) {
        if (NLSourceNamed(name) != NLSourceNone && ![order containsObject:name]) [order addObject:name];
    }
    return order;
}

// A snapshot of the preference file. Replaced wholesale on reload and never
// mutated afterwards, so the fetch queue can keep using the one it started with.
@interface NLSettings : NSObject
@property (nonatomic, readonly) BOOL enabled;                 // this app is switched on
@property (nonatomic, readonly) NLArtistMode artistMode;
// The order the sources are tried in (NLSource numbers, each once): the
// user's `sourceOrder` from the Lyrics Sources page, or for settings from
// before it, Apple Music, the old `preferredSource`, then the default order.
@property (nonatomic, readonly, copy) NSArray<NSNumber *> *sourceOrder;
@property (nonatomic, readonly) BOOL useMusixmatch;           // NO when no credentials are set
@property (nonatomic, readonly) BOOL useLRCLIB;
@property (nonatomic, readonly) BOOL useNetease;
@property (nonatomic, readonly) BOOL useAppleMusic;           // Apple Music's own lyrics: in Music by its item
@property (nonatomic, readonly) BOOL useAppleMusicElsewhere;  // ... and in other apps through SpringBoard (appleMusicOtherApps)
@property (nonatomic, readonly, copy) NSString *musixmatchKey;
@property (nonatomic, readonly, copy) NSString *musixmatchToken;
@property (nonatomic, readonly) BOOL killOnChange;
@property (nonatomic, readonly) BOOL diagnostics;
@property (nonatomic, readonly) BOOL spotifyConnect;   // split "Track • Artist" + "Playing on X" reported during Spotify Connect
@property (nonatomic, readonly) BOOL hideExplicit;     // clear the explicit flag, so no "E" badge next to the line
- (NSTimeInterval)offsetForTrack:(NSString *)key;             // the global offset plus this song's own; positive means lyrics appear earlier
- (NLSource)sourceForTrack:(NSString *)key;                   // the source picked for this song, NLSourceNone if none
@property (nonatomic, readonly) NSTimeInterval cacheClearedAt; // when "Clear lyrics cache" was last tapped, 0 if never
// Everything that invalidates lyrics already fetched, folded into one comparable string.
@property (nonatomic, readonly, copy) NSString *sourceSignature;
// Whether this app behaves exactly the same under `other`: every value above,
// the offsets and per-song sources included. Settings only the settings page
// or SpringBoard read (another app's switch among them) make no difference.
- (BOOL)sameEffectAs:(NLSettings *)other;
// Apple Music unlocked on the settings page (`appleMusicVerified`), which
// SpringBoard keeps in step with the subscription. Nothing here acts on it,
// so sameEffectAs: leaves it out; it tells a lock from Apple Music switched
// off in Settings (NowLyrics.xm).
@property (nonatomic, readonly) BOOL appleMusicVerified;
@end

#ifdef __cplusplus
extern "C" {
#endif

#pragma mark - Constants

extern NSString *const kNLUserAgent;

#pragma mark - NLSettings.m

BOOL NLProcessIsEligible(void);         // load-time safety check, independent of user settings
BOOL NLProcessUsesContentItems(void);   // Apple's Music app publishes through content items
NLSettings *NLSettingsCurrent(void);    // the latest snapshot; loads one if there is none yet
NLSettings *NLSettingsReload(void);     // re-reads the file and computes `enabled` for this process
// The same with a source picked for one track on top (NL_LOOKUP_FILE): what
// the preference file will say once it has been written.
NLSettings *NLSettingsReloadPicking(NSString *trackKey, NSString *source);

#pragma mark - NLLyrics.m

NSString *NLCleanTitle(NSString *title);
BOOL NLSplitConnectInfo(NSString *title, NSString *artist, NSString **outTitle, NSString **outArtist);
NSString *NLPrimaryArtist(NSString *artist);
NSString *NLTrackKey(NSString *title, NSString *artist);
NSString *NLManualFileName(NSString *title, NSString *artist);   // "Title - Artist.lrc", as NLManualLyrics looks for it
NSArray<NLLyricLine *> *NLParseLRC(NSString *lrc);           // also reads enhanced LRC's <mm:ss.xx> word times
BOOL NLLRCHasWordTimes(NSString *lrc);   // some timed line carries <mm:ss.xx> word times, as NLParseLRC reads them
// Lines a source hands over already timed (Musixmatch's subtitle), finished
// the way NLParseLRC finishes a file's (trimmed, credits dropped, sorted, the
// short blanks gone), so they show as their cached copy will.
NSArray<NLLyricLine *> *NLFinishTimedLines(NSArray<NLLyricLine *> *lines);
NSArray<NLLyricLine *> *NLParseYRC(NSString *yrc);           // NetEase's word-by-word format
NSArray<NLLyricLine *> *NLParseTTML(NSString *ttml);         // NLTTML.m: Apple Music / AMLL TTML
// Whether text is TTML rather than LRC: it has a <tt> element (Apple Music's, AMLL's).
static inline BOOL NLLooksLikeTTML(NSString *text) {
    return [text rangeOfString:@"<tt" options:NSCaseInsensitiveSearch].location != NSNotFound;
}
// For the word-timed formats: one line from its pieces (trimmed; nil when it is
// empty or a credit), and the finished list with breaks marked from line ends.
NLLyricLine *NLLineFromWords(NSMutableArray<NLLyricWord *> *words, NSTimeInterval start, NSTimeInterval end);
NSArray<NLLyricLine *> *NLFinishWordLines(NSMutableArray<NLLyricLine *> *lines);
NSDictionary<NSString *, NSString *> *NLParseLRCHeader(NSString *lrc);   // [ti:], [ar:], ... before the first timed line
NSString *NLLinesToLRCWithHeader(NSArray<NLLyricLine *> *lines, NSDictionary<NSString *, NSString *> *header);
BOOL NLHasContent(NSArray<NLLyricLine *> *lines);   // at least two sung lines
BOOL NLHasWords(NSArray<NLLyricLine *> *lines);     // some line is timed word by word
BOOL NLWordTimesPlausible(NSArray<NLLyricLine *> *lines);   // NO when the words go faster than anyone sings
BOOL NLWordLinesAgree(NSArray<NLLyricLine *> *words, NSArray<NLLyricLine *> *timed);   // same lines at about the same times
void NLMarkChorus(NSArray<NLLyricLine *> *lines);   // sets chorus/chorusStart; leaves them NO when nothing repeats
NSString *NLCacheDir(void);                         // Library/NowLyrics, without creating it
NSString *NLCachePath(NSString *key);
NSString *NLNowPlayingPath(void);                   // Library/NowLyrics/nowplaying.plist
NSArray<NLLyricLine *> *NLManualLyrics(NSString *title, NSString *artist, NSString **outPath);
BOOL NLClearCacheIfRequested(NSTimeInterval requestedAt);   // deletes cached files older than the request; YES if any went
void NLPruneCache(NSUInteger limit);                       // keeps only the newest `limit` cached files
// A listed file's modification date (asked for in the listing), distantPast when unknown.
static inline NSDate *NLModificationDate(NSURL *url) {
    NSDate *date = nil;
    [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
    return date ?: [NSDate distantPast];
}
// Lines are sorted (every parser sorts them on the way out): how many have started
// by `position`, each switching NL_LINE_MARGIN early, which is the index of
// the first still to come; the line up is the one before it. Binary search.
static inline NSUInteger NLLinesStartedBy(NSArray<NLLyricLine *> *lines, NSTimeInterval position) {
    NSTimeInterval cutoff = position + NL_LINE_MARGIN;
    NSUInteger lo = 0, hi = lines.count;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        if (lines[mid].start <= cutoff) lo = mid + 1;
        else hi = mid;
    }
    return lo;
}
// The lines of a lyrics file, parsed once per version of it (its path and
// modification date); nil for a missing file. Main queue; each file that
// calls it keeps its own copy.
static inline NSArray<NLLyricLine *> *NLParseLRCFile(NSString *path) {
    static NSString *parsedPath = nil;
    static NSDate *parsedDate = nil;
    static NSArray<NLLyricLine *> *parsed = nil;
    NSDate *date = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil].fileModificationDate;
    if (![path isEqualToString:parsedPath] || ![date isEqual:parsedDate]) {
        parsedPath = path;
        parsedDate = date;
        parsed = NLParseLRC([NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]);
    }
    return parsed;
}
// `a` and `b` joined by `separator`, or whichever is not empty.
static inline NSString *NLJoinNonEmpty(NSString *a, NSString *b, NSString *separator) {
    return a.length && b.length ? [NSString stringWithFormat:@"%@%@%@", a, separator, b] : (a.length ? a : b);
}

#pragma mark - NLSources.m

// Manual file, then the disk cache, then the enabled providers in order. Blocks;
// runs on the engine's fetch queue. On a miss, `source` says what each provider
// answered and `transient` whether some request never got an answer at all.
// On a hit, `path` is the file the lyrics are in (manual or cache).
// `superseded` (may be nil) is asked before a provider's hit is written to the
// cache: YES when the engine will throw this lookup's result away, and the
// cache is then left as it is for the lookup that replaced it.
NSArray<NLLyricLine *> *NLResolveLyrics(NLSettings *settings, NSString *key,
                                        NSString *title, NSString *artist, NSString *album,
                                        NSTimeInterval duration,
                                        NSString **source, NSString **path, BOOL *transient,
                                        BOOL (^superseded)(void));

#pragma mark - NLEngine.m (main queue unless noted)

void NLEngineStart(void);   // once, from %ctor
// One now-playing update, whichever way the app publishes. A new track starts a
// fetch; the same track just redraws.
void NLEngineIngest(NSString *title, NSString *artist, NSString *album,
                    NSTimeInterval duration, NSNumber *elapsed, NSNumber *rate);
void NLEnginePushUpdate(void);          // redraw for the current position and reschedule the flip
void NLEngineCancelFlip(void);          // e.g. the app was just switched off
void NLEngineForgetLyrics(void);        // sources changed: drop the in-memory cache, look the current track up again
void NLEngineClearCacheLater(NSTimeInterval requestedAt);   // NLClearCacheIfRequested on the fetch queue, ahead of any fetch
NSTimeInterval NLEnginePosition(void);  // extrapolated playback position, never negative
NSString *NLEngineTrackTitle(void);     // what the player really reported for the current track
NSString *NLEngineTrackArtist(void);

#pragma mark - NowLyrics.xm

// Where the composed strings go. nil means "whatever the player set".
void NLPublish(NSString *title, NSString *artist);
// Put the player's own values back (title and artist, and for the dictionary path the whole info).
void NLPublishRestore(void);
// Music only: the lyrics Apple Music has for the playing item (TTML), asked
// for by its catalog ID the way Music's lyrics view does. nil when the item is
// not `title`, has none, or no answer came within `timeout`. Blocks; call off
// the main queue.
NSString *NLAppleMusicLyrics(NSString *title, NSTimeInterval timeout);
// NLAppleMusicRemote.m: the same for the song another app plays, found on
// Apple Music and asked for by SpringBoard (NLAppleMusicSB.x). TTML, or nil
// with why in *note. Waits up to `timeout`; not on the main queue.
NSString *NLAppleMusicLyricsFromSpringBoard(NSString *title, NSString *artist, NSTimeInterval duration,
                                            NSTimeInterval timeout, NSString **note);

#ifdef __cplusplus
}
#endif
