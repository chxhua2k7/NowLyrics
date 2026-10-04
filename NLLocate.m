//
//  NLLocate.m
//  See NLLocate.h.
//

#import "NLLocate.h"
#import "NowLyrics.h"
#import <dlfcn.h>

static NSString *const kNLContainersRoot = @"/var/mobile/Containers/Data/Application";

// bundle ID → container, from each container's metadata plist (what
// MobileContainerManager itself keeps there). No private API involved.
static NSDictionary<NSString *, NSString *> *NLScanContainers(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableDictionary<NSString *, NSString *> *map = [NSMutableDictionary dictionary];
    for (NSString *uuid in [fm contentsOfDirectoryAtPath:kNLContainersRoot error:nil]) {
        NSString *dir = [kNLContainersRoot stringByAppendingPathComponent:uuid];
        NSDictionary *meta = [NSDictionary dictionaryWithContentsOfFile:
                              [dir stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        id identifier = meta[@"MCMMetadataIdentifier"];
        if ([identifier isKindOfClass:[NSString class]]) map[identifier] = dir;
    }
    return map;
}

static NSDictionary<NSString *, NSString *> *gContainers = nil;
static NSLock *gContainersLock = nil;

NSString *NLDataContainerForBundle(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gContainersLock = [NSLock new]; });
    [gContainersLock lock];
    NSString *dir = gContainers[bundleID];
    // An app installed (or reinstalled, which moves it) since the last scan.
    if (!dir || ![[NSFileManager defaultManager] fileExistsAtPath:dir]) {
        gContainers = NLScanContainers();
        dir = gContainers[bundleID];
    }
    [gContainersLock unlock];
    return dir;
}

NSDictionary<NSString *, NSString *> *NLLyricsFolders(void) {
    NSDictionary<NSString *, NSString *> *all = NLScanContainers();
    static dispatch_once_t once;
    dispatch_once(&once, ^{ gContainersLock = [NSLock new]; });
    [gContainersLock lock];
    gContainers = all;
    [gContainersLock unlock];

    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary dictionary];
    BOOL isDir = NO;
    for (NSString *bundleID in all) {
        NSString *folder = [all[bundleID] stringByAppendingPathComponent:@"Library/NowLyrics"];
        if ([[NSFileManager defaultManager] fileExistsAtPath:folder isDirectory:&isDir] && isDir) out[bundleID] = folder;
    }
    return out;
}

NSDictionary *NLReadNowPlaying(NSString *bundleID) {
    NSString *dir = NLDataContainerForBundle(bundleID);
    if (!dir) return nil;
    NSString *path = [dir stringByAppendingPathComponent:@"Library/NowLyrics/" NL_NOWPLAYING_FILE];
    return [NSDictionary dictionaryWithContentsOfFile:path];
}

void NLNowPlayingBundleID(void (^completion)(NSString *bundleID)) {
    static void (*getDisplayID)(dispatch_queue_t, void (^)(CFStringRef)) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (mr) getDisplayID = (void (*)(dispatch_queue_t, void (^)(CFStringRef)))dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationDisplayID");
    });
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ finish(nil); });
}

static void *NLMediaRemote(const char *symbol) {
    static void *mr = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY); });
    return mr ? dlsym(mr, symbol) : NULL;
}

void NLNowPlayingIsPlaying(void (^completion)(BOOL playing)) {
    void (*isPlaying)(dispatch_queue_t, void (^)(Boolean)) =
        (void (*)(dispatch_queue_t, void (^)(Boolean)))NLMediaRemote("MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    if (!isPlaying) { completion(NO); return; }
    isPlaying(dispatch_get_main_queue(), ^(Boolean playing) { completion(playing); });
}

void NLNowPlayingInfo(void (^completion)(NSDictionary *info)) {
    void (*getInfo)(dispatch_queue_t, void (^)(CFDictionaryRef)) =
        (void (*)(dispatch_queue_t, void (^)(CFDictionaryRef)))NLMediaRemote("MRMediaRemoteGetNowPlayingInfo");
    if (!getInfo) { completion(nil); return; }
    getInfo(dispatch_get_main_queue(), ^(CFDictionaryRef info) {
        NSDictionary *dict = (__bridge NSDictionary *)info;
        completion(dict.count ? [dict copy] : nil);
    });
}

void NLPostLyricsChanged(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)NL_LYRICS_CHANGED_NOTIFICATION, NULL, NULL, YES);
}

#pragma mark - Word by word for the line on screen

@implementation NLShownWords
@end

// The lines of the app's lyrics file when it has word times, parsed once per
// version of the file. `outKey` is the track key, for its offset. Main queue.
static NSArray<NLLyricLine *> *NLWordLyrics(NSString *bundleID, NSString **outKey) {
    NSDictionary *np = NLReadNowPlaying(bundleID);
    NSString *path = np[NL_NP_PATH];
    if (![path isKindOfClass:NSString.class] || !NLPrefBool(np, NL_NP_WORDS, NO)) return nil;
    *outKey = np[NL_NP_KEY];

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

NLShownWords *NLWordsForShownLine(NSString *bundleID, NSString *shown, NSDictionary *info, NSDictionary *prefs) {
    if (shown.length == 0) return nil;
    NSString *key = nil;
    NSArray<NLLyricLine *> *lines = NLWordLyrics(bundleID, &key);
    id elapsed = info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"];
    if (lines.count == 0 || ![elapsed isKindOfClass:NSNumber.class]) return nil;

    double rate = NLPrefNum(info, @"kMRMediaRemoteNowPlayingInfoPlaybackRate", 0);
    NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
    double position = [elapsed doubleValue] + ([stamp isKindOfClass:NSDate.class] ? -stamp.timeIntervalSinceNow * rate : 0);
    double lookup = position + NLPrefNum(prefs, @"offset", 0) + NLTrackOffset(prefs, key);

    // The line by position, or a neighbour should the two clocks disagree by one.
    NSInteger at = -1;
    for (NSUInteger i = 0; i < lines.count && lines[i].start <= lookup + NL_LINE_MARGIN; i++) at = (NSInteger)i;
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
