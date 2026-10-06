//
//  NLLocate.m
//  See NLLocate.h.
//

#import "NLLocate.h"
#import "NowLyrics.h"
#import <objc/runtime.h>
#import <dlfcn.h>

static NSString *const kNLContainersRoot = @"/var/mobile/Containers/Data/Application";

// The folder's modification date, which every container made, removed or
// moved in it changes.
static NSDate *NLContainersRootDate(void) {
    return [[NSFileManager defaultManager] attributesOfItemAtPath:kNLContainersRoot error:nil].fileModificationDate;
}

// bundle ID → container, from each container's metadata plist (what
// MobileContainerManager itself keeps there). No private API involved.
// `outDate` gets the folder's date from before the scan, or nil when the
// folder could not be listed or some container had no metadata (yet), so
// that a miss scans again.
static NSDictionary<NSString *, NSString *> *NLScanContainers(NSDate **outDate) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSDate *date = NLContainersRootDate();
    NSArray<NSString *> *uuids = [fm contentsOfDirectoryAtPath:kNLContainersRoot error:nil];
    if (!uuids) date = nil;
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    for (NSString *uuid in uuids) {
        NSString *dir = [kNLContainersRoot stringByAppendingPathComponent:uuid];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:
                              [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        NSString *identifier = NLString(meta, @"MCMMetadataIdentifier");
        if (identifier) map[identifier] = dir;
        else date = nil;
    }
    *outDate = date;
    return map;
}

static NSDictionary<NSString *, NSString *> *gContainers = nil;
static NSDate *gContainersDate = nil;   // the folder's date at the last scan that read every container

// Guards the two above, which the main queue reads while NLLyricsFolders
// scans on others: one lock, made once for both functions.
static NSLock *NLContainersLock(void) { return NL_ONCE([NSLock new]); }

NSString *NLDataContainerForBundle(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    NSLock *lock = NLContainersLock();
    [lock lock];
    NSString *dir = gContainers[bundleID];
    // An app installed (or reinstalled, which moves it) since the last scan.
    // One without a container at all (installed by the jailbreak, a system
    // app keeping its data elsewhere) is looked for again only once the
    // folder has changed, not on every ask.
    BOOL rescan = dir ? ![[NSFileManager defaultManager] fileExistsAtPath:dir]
                      : !gContainersDate || ![NLContainersRootDate() isEqual:gContainersDate];
    if (rescan) {
        NSDate *date = nil;
        gContainers = NLScanContainers(&date);
        gContainersDate = date;
        dir = gContainers[bundleID];
    }
    [lock unlock];
    return dir;
}

NSDictionary<NSString *, NSString *> *NLLyricsFolders(void) {
    NSLock *lock = NLContainersLock();
    [lock lock];
    // The last scan's map while the containers folder has not changed since
    // (the rule NLDataContainerForBundle goes by).
    NSDictionary<NSString *, NSString *> *all = (gContainersDate && [NLContainersRootDate() isEqual:gContainersDate]) ? gContainers : nil;
    [lock unlock];
    if (!all) {
        NSDate *date = nil;
        all = NLScanContainers(&date);   // outside the lock: the main queue's lookups do not wait on it
        [lock lock];
        gContainers = all;
        gContainersDate = date;
        [lock unlock];
    }

    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary dictionary];
    BOOL isDir = NO;
    for (NSString *bundleID in all) {
        NSString *folder = [all[bundleID] stringByAppendingPathComponent:NL_APP_FOLDER];
        if ([[NSFileManager defaultManager] fileExistsAtPath:folder isDirectory:&isDir] && isDir) out[bundleID] = folder;
    }
    return out;
}

NSDictionary *NLReadNowPlaying(NSString *bundleID) {
    NSString *folder = NLLyricsFolderForBundle(bundleID);
    return folder ? [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:NL_NOWPLAYING_FILE]] : nil;
}

void *NLMediaRemote(const char *symbol) {
    void *mr = NL_ONCE(dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY));
    return mr ? dlsym(mr, symbol) : NULL;
}

void NLNowPlayingBundleID(void (^completion)(NSString *bundleID)) {
    void (*getDisplayID)(dispatch_queue_t, void (^)(CFStringRef)) = NL_ONCE((void (*)(dispatch_queue_t, void (^)(CFStringRef)))NLMediaRemote("MRMediaRemoteGetNowPlayingApplicationDisplayID"));
    if (!getDisplayID) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    // MediaRemote may never answer (nothing has played since boot); give up
    // after a second rather than leave the page waiting.
    __block BOOL done = NO;
    void (^finish)(NSString *) = ^(NSString *bundleID) {
        if (done) return;
        done = YES;
        completion(bundleID);
    };
    getDisplayID(dispatch_get_main_queue(), ^(CFStringRef displayID) {
        finish(displayID ? [(__bridge NSString *)displayID copy] : nil);
    });
    NLAfter(1.0, ^{ finish(nil); });
}

@interface NSObject (NLMediaController)
+ (instancetype)sharedInstance;   // SBMediaController
- (id)nowPlayingApplication;      // an SBApplication
@end

// objc_getClass is Nil outside SpringBoard, so it answers nil there.
NSString *NLSpringBoardPlayingBundleID(void) {
    id app = [[objc_getClass("SBMediaController") sharedInstance] nowPlayingApplication];
    return [app respondsToSelector:@selector(bundleIdentifier)] ? [app bundleIdentifier] : nil;
}

void NLNowPlayingIsPlaying(void (^completion)(BOOL playing)) {
    void (*isPlaying)(dispatch_queue_t, void (^)(Boolean)) = NL_ONCE((void (*)(dispatch_queue_t, void (^)(Boolean)))NLMediaRemote("MRMediaRemoteGetNowPlayingApplicationIsPlaying"));
    if (!isPlaying) { completion(NO); return; }
    isPlaying(dispatch_get_main_queue(), ^(Boolean playing) { completion(playing); });
}

// Callers in one turn of the main queue share one request (each answer
// carries the artwork across XPC): the island and the player tints on a
// now-playing change in SpringBoard, the player header and the theme on the
// settings pages. It goes out after them, so none gets an older answer.
void NLNowPlayingInfo(void (^completion)(NSDictionary *info)) {
    void (*getInfo)(dispatch_queue_t, void (^)(CFDictionaryRef)) = NL_ONCE((void (*)(dispatch_queue_t, void (^)(CFDictionaryRef)))NLMediaRemote("MRMediaRemoteGetNowPlayingInfo"));
    if (!getInfo) { completion(nil); return; }
    static NSMutableArray<void (^)(NSDictionary *)> *waiting = nil;
    if (waiting) {
        [waiting addObject:[completion copy]];
        return;
    }
    waiting = [NSMutableArray arrayWithObject:[completion copy]];
    dispatch_async(dispatch_get_main_queue(), ^{
        NSArray<void (^)(NSDictionary *)> *askers = waiting;
        waiting = nil;
        getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
            NSDictionary *dict = (__bridge NSDictionary *)info;
            NSDictionary *answer = dict.count ? [dict copy] : nil;
            for (void (^done)(NSDictionary *) in askers) done(answer);
        });
    });
}

void NLPostLyricsChanged(void) {
    NLPostDarwin(NL_LYRICS_CHANGED_NOTIFICATION);
}

#pragma mark - Word by word for the line on screen

@implementation NLShownWords
@end

// The lines of the app's lyrics file when it has word times, parsed once per
// version of the file. `outKey` is the track key, for its offset. Main queue.
static NSArray<NLLyricLine *> *NLWordLyrics(NSString *bundleID, NSString **outKey) {
    NSDictionary *np = NLReadNowPlaying(bundleID);
    NSString *path = NLString(np, NL_NP_PATH);
    if (!path || !NLPrefBool(np, NL_NP_WORDS, NO)) return nil;
    *outKey = np[NL_NP_KEY];
    return NLParseLRCFile(path);
}

NLShownWords *NLWordsForShownLine(NSString *bundleID, NSString *shown, NSDictionary *info, NSDictionary *prefs) {
    if (shown.length == 0) return nil;
    NSString *key = nil;
    NSArray<NLLyricLine *> *lines = NLWordLyrics(bundleID, &key);
    id elapsed = info[NL_MR_ELAPSED];
    if (lines.count == 0 || ![elapsed isKindOfClass:NSNumber.class]) return nil;

    double rate = NLPrefNum(info, NL_MR_RATE, 0);
    NSDate *stamp = info[NL_MR_TIMESTAMP];
    double position = [elapsed doubleValue] + ([stamp isKindOfClass:NSDate.class] ? -stamp.timeIntervalSinceNow * rate : 0);
    double lookup = position + NLOffsetForTrack(prefs, key);

    // The line by position, or a neighbour should the two clocks disagree by one.
    NSInteger at = (NSInteger)NLLinesStartedBy(lines, lookup) - 1;
    NLLyricLine *line = nil;
    NSInteger candidates[] = { at, at - 1, at + 1 };
    for (int k = 0; k < 3; k++) {
        NSInteger i = candidates[k];
        if (i >= 0 && i < (NSInteger)lines.count && [lines[i].text isEqualToString:shown]) { line = lines[i]; break; }
    }
    if (line.words.count == 0) return nil;

    NSMutableArray *texts = [NSMutableArray array], *starts = [NSMutableArray array], *ends = [NSMutableArray array];
    for (NLLyricWord *word in line.words) {
        [texts addObject:word.text];
        [starts addObject:@(word.start)];
        [ends addObject:@(word.end)];
    }
    NLShownWords *words = [NLShownWords new];
    words.texts = texts;
    words.starts = starts;
    words.ends = ends;
    words.position = lookup;
    words.rate = rate;
    return words;
}
