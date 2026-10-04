//
//  NLAppleMusicSB.x
//  SpringBoard gets Apple Music's lyrics for apps that cannot (Spotify has
//  neither the song's catalog ID nor Apple Music access): the song is found in
//  the catalog (NLAppleMusicFind.h), then its lyrics are asked for the way
//  Music's lyrics view asks, MediaPlayer's MPStoreLyricsMusicKitRequestOperation
//  by catalog (adam) ID as the signed-in subscriber. Part of NowLyricsIsland.
//
//  Requests come as `am-request.plist` beside the answers: in an app's
//  Library/NowLyrics (the only place a sandboxed app can write), or in
//  NL_AM_DIR for the settings page's test, each announced by
//  NL_AM_REQUEST_NOTIFICATION. The answer, `am-response.plist` in the same
//  folder, is announced by NL_AM_RESPONSE_NOTIFICATION (NLShared.h).
//
//  Request: `id`, `title`, `artist`, `duration`, `time` (or `adamID` to skip
//  the search). Answer: the same `id`, `elapsed`, and `ttml`, or `notFound`,
//  or `error`; with the song it was found as (`adamID`, `matchTitle`,
//  `matchArtist`).
//
//  It also tells the settings page whether there is an Apple Music
//  subscription (NL_AM_CHECK_REQUEST_FILE): what iTunesCloud's subscription
//  status says (as Music and Settings ask), else StoreKit's cloud service
//  capabilities, else whether a well-known song's lyrics can be had.
//

#import <objc/runtime.h>
#import <dlfcn.h>
#import "NLShared.h"
#import "NLLocate.h"
#import "NLAppleMusicFind.h"

@interface NSObject (NLStoreLyrics)
+ (instancetype)sharedInstance;
+ (instancetype)sharedStatusController;                                   // ICMusicSubscriptionStatusController
- (void)getSubscriptionStatusWithCompletionHandler:(void (^)(id status, NSError *error))handler;
- (BOOL)hasCatalogPlaybackCapability;                                     // ICMusicSubscriptionStatus
- (void)requestCapabilitiesWithCompletionHandler:(void (^)(NSUInteger capabilities, NSError *error))handler;   // SKCloudServiceController
- (id)nowPlayingApplication;
- (NSString *)bundleIdentifier;
- (void)setSongAdamID:(long long)adamID;
- (void)setResponseHandler:(void (^)(id response, NSError *error))handler;
- (NSString *)lyricsContent;   // MPStoreLyricsResponse
@end

static const NSTimeInterval kNLRequestLifetime = 60;   // older requests were given up on
static const NSUInteger kNLFoundLimit = 300;

static NSMutableSet<NSString *> *gAnswered;                     // request IDs already taken
static NSMutableDictionary<NSString *, id> *gFound;              // song → match, or NSNull when not on Apple Music

// An error with what lies under it, for the test's readout.
static NSString *NLDescribeError(NSError *error) {
    NSMutableString *text = [NSMutableString string];
    for (NSError *e = error; e; e = e.userInfo[NSUnderlyingErrorKey]) {
        if (text.length) [text appendString:@" ← "];
        [text appendFormat:@"%@ %ld", e.domain, (long)e.code];
        NSString *reason = e.userInfo[NSLocalizedDescriptionKey] ?: e.userInfo[NSDebugDescriptionErrorKey];
        if ([reason isKindOfClass:NSString.class] && reason.length) [text appendFormat:@" (%@)", reason];
    }
    return text;
}

// The lyrics by catalog ID. Calls back on the main queue with the TTML, or
// nil and why.
static void NLStoreLyrics(long long adamID, void (^done)(NSString *ttml, NSString *problem)) {
    Class operationClass = objc_getClass("MPStoreLyricsMusicKitRequestOperation");
    if (!operationClass) {
        dlopen("/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer", RTLD_NOW);
        operationClass = objc_getClass("MPStoreLyricsMusicKitRequestOperation");
    }
    if (!operationClass) {
        done(nil, @"MPStoreLyricsMusicKitRequestOperation is not here");
        return;
    }
    static NSOperationQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [NSOperationQueue new];
        queue.name = @"app.nowlyrics.applemusic";
    });
    NSOperation *operation = [operationClass new];
    [(id)operation setSongAdamID:adamID];
    [(id)operation setResponseHandler:^(id response, NSError *error) {
        NSString *text = [response respondsToSelector:@selector(lyricsContent)] ? [response lyricsContent] : nil;
        BOOL got = [text isKindOfClass:NSString.class] && text.length;
        NSString *problem = got ? nil : error ? NLDescribeError(error)
                                  : response ? [NSString stringWithFormat:@"no lyrics in %@", [response class]] : @"no response";
        dispatch_async(dispatch_get_main_queue(), ^{ done(got ? text : nil, problem); });
    }];
    [queue addOperation:operation];
}

static void NLWriteAnswer(NSString *folder, NSDictionary *answer) {
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    [answer writeToFile:[folder stringByAppendingPathComponent:@"am-response.plist"] atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)NL_AM_RESPONSE_NOTIFICATION, NULL, NULL, YES);
}

static NSString *NLSongKey(NSString *title, NSString *artist, NSTimeInterval duration) {
    return [NSString stringWithFormat:@"%@|%@|%.0f", title.lowercaseString ?: @"", artist.lowercaseString ?: @"", duration];
}

// One request, answered into `folder`. Main queue.
static void NLServe(NSDictionary *request, NSString *folder) {
    NSString *requestID = request[@"id"];
    [gAnswered addObject:requestID];
    NSDate *start = [NSDate date];
    NSString *title = [request[@"title"] isKindOfClass:NSString.class] ? request[@"title"] : @"";
    NSString *artist = [request[@"artist"] isKindOfClass:NSString.class] ? request[@"artist"] : @"";
    NSTimeInterval duration = [request[@"duration"] respondsToSelector:@selector(doubleValue)] ? [request[@"duration"] doubleValue] : 0;
    long long given = [request[@"adamID"] respondsToSelector:@selector(longLongValue)] ? [request[@"adamID"] longLongValue] : 0;

    void (^finish)(NSDictionary *) = ^(NSDictionary *fields) {
        NSMutableDictionary *answer = [NSMutableDictionary dictionaryWithDictionary:fields];
        answer[@"id"] = requestID;
        answer[@"elapsed"] = @(-[start timeIntervalSinceNow]);
        NLWriteAnswer(folder, answer);
    };
    void (^lyrics)(NSDictionary *) = ^(NSDictionary *match) {
        NLStoreLyrics([match[@"id"] longLongValue], ^(NSString *ttml, NSString *problem) {
            NSMutableDictionary *fields = [NSMutableDictionary dictionary];
            fields[@"adamID"] = match[@"id"];
            if (match[@"title"]) fields[@"matchTitle"] = match[@"title"];
            if (match[@"artist"]) fields[@"matchArtist"] = match[@"artist"];
            if (ttml) fields[@"ttml"] = ttml;
            else fields[@"error"] = problem ?: @"no lyrics";
            finish(fields);
        });
    };

    if (given > 0) {
        lyrics(@{@"id": @(given)});
        return;
    }
    if (!title.length) {
        finish(@{@"error": @"no title"});
        return;
    }
    NSString *key = NLSongKey(title, artist, duration);
    id known = gFound[key];
    if (known == NSNull.null) {
        finish(@{@"notFound": @YES});
        return;
    }
    if (known) {
        lyrics(known);
        return;
    }
    NLFindOnAppleMusic(title, artist, duration, ^(NSDictionary *match, NSString *problem) {
        if (gFound.count > kNLFoundLimit) [gFound removeAllObjects];
        if (!match) {
            if (!problem) gFound[key] = NSNull.null;   // a failed search is asked again next time
            finish(problem ? @{@"error": problem} : @{@"notFound": @YES});
            return;
        }
        gFound[key] = match;
        lyrics(match);
    });
}

// The request in `folder`, if there is one not yet taken and not given up on.
static BOOL NLServeFolder(NSString *folder) {
    NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:[folder stringByAppendingPathComponent:@"am-request.plist"]];
    NSString *requestID = request[@"id"];
    if (![requestID isKindOfClass:NSString.class] || [gAnswered containsObject:requestID]) return NO;
    NSDate *time = request[@"time"];
    if ([time isKindOfClass:NSDate.class] && -[time timeIntervalSinceNow] > kNLRequestLifetime) return NO;
    NLServe(request, folder);
    return YES;
}

static NSString *NLAppFolder(NSString *bundleID) {
    NSString *container = NLDataContainerForBundle(bundleID);
    return container ? [container stringByAppendingPathComponent:@"Library/NowLyrics"] : nil;
}

#pragma mark - Is there a subscription

static const NSUInteger kNLCatalogPlayback = 1 << 0;   // SKCloudServiceCapabilityMusicCatalogPlayback

// Calls back once on the main queue: "active", "none" (a definite answer
// without catalog playback) or "unknown", and what each way said.
static void NLCheckSubscription(void (^done)(NSString *result, NSString *detail)) {
    NSMutableArray<NSString *> *said = [NSMutableArray array];
    __block BOOL finished = NO, saidNone = NO;
    void (^finish)(NSString *) = ^(NSString *result) {
        if (finished) return;
        finished = YES;
        done(result, [said componentsJoinedByString:@"; "]);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [said addObject:@"timed out"];
        finish(saidNone ? @"none" : @"unknown");
    });

    // 3. Lyrics only come with a subscription: one well-known song's. Asked
    // even after a "no" above, which a stale or cautious status can say: the
    // lyrics are what counts.
    void (^probe)(void) = ^{
        if (finished) return;
        NLFindOnAppleMusic(@"Shape of You", @"Ed Sheeran", 233, ^(NSDictionary *match, NSString *problem) {
            if (!match) {
                [said addObject:[NSString stringWithFormat:@"probe: %@", problem ?: @"song not found"]];
                finish(saidNone ? @"none" : @"unknown");
                return;
            }
            NLStoreLyrics([match[@"id"] longLongValue], ^(NSString *ttml, NSString *why) {
                [said addObject:ttml ? @"probe: lyrics came" : [NSString stringWithFormat:@"probe: %@", why]];
                finish(ttml ? @"active" : saidNone ? @"none" : @"unknown");
            });
        });
    };

    // 2. StoreKit's cloud service capabilities (SpringBoard may read the media library).
    void (^storeKit)(void) = ^{
        if (finished) return;
        dlopen("/System/Library/Frameworks/StoreKit.framework/StoreKit", RTLD_NOW);
        NSObject *cloud = [objc_getClass("SKCloudServiceController") new];
        if (![cloud respondsToSelector:@selector(requestCapabilitiesWithCompletionHandler:)]) {
            [said addObject:@"StoreKit: not here"];
            probe();
            return;
        }
        [cloud requestCapabilitiesWithCompletionHandler:^(NSUInteger capabilities, NSError *error) {
            dispatch_async(dispatch_get_main_queue(), ^{
                (void)cloud;   // kept alive until it answers
                if (error) {
                    [said addObject:[NSString stringWithFormat:@"StoreKit: %@", NLDescribeError(error)]];
                    probe();
                    return;
                }
                BOOL active = (capabilities & kNLCatalogPlayback) != 0;
                [said addObject:[NSString stringWithFormat:@"StoreKit: capabilities %lu", (unsigned long)capabilities]];
                if (active) { finish(@"active"); return; }
                saidNone = YES;
                probe();
            });
        }];
    };

    // 1. iTunesCloud's subscription status, as Music and Settings ask.
    dlopen("/System/Library/PrivateFrameworks/iTunesCloud.framework/iTunesCloud", RTLD_NOW);
    Class statusClass = objc_getClass("ICMusicSubscriptionStatusController");
    NSObject *controller = [statusClass respondsToSelector:@selector(sharedStatusController)] ? [statusClass sharedStatusController] : nil;
    if (![controller respondsToSelector:@selector(getSubscriptionStatusWithCompletionHandler:)]) {
        [said addObject:@"iTunesCloud: not here"];
        storeKit();
        return;
    }
    [controller getSubscriptionStatusWithCompletionHandler:^(id status, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([status respondsToSelector:@selector(hasCatalogPlaybackCapability)]) {
                BOOL active = [status hasCatalogPlaybackCapability];
                [said addObject:[NSString stringWithFormat:@"iTunesCloud: %@", active ? @"catalog playback" : @"no catalog playback"]];
                if (active) { finish(@"active"); return; }
                saidNone = YES;
            } else {
                [said addObject:[NSString stringWithFormat:@"iTunesCloud: %@", error ? NLDescribeError(error) : @"no status"]];
            }
            storeKit();
        });
    }];
}

static void NLServeCheck(void) {
    NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:NL_AM_CHECK_REQUEST_FILE];
    NSString *requestID = request[@"id"];
    if (![requestID isKindOfClass:NSString.class] || [gAnswered containsObject:requestID]) return;
    NSDate *time = request[@"time"];
    if ([time isKindOfClass:NSDate.class] && -[time timeIntervalSinceNow] > kNLRequestLifetime) return;
    [gAnswered addObject:requestID];
    NSDate *start = [NSDate date];
    NLCheckSubscription(^(NSString *result, NSString *detail) {
        NSDictionary *answer = @{@"id": requestID, @"result": result, @"detail": detail ?: @"",
                                 @"elapsed": @(-[start timeIntervalSinceNow])};
        [[NSFileManager defaultManager] createDirectoryAtPath:NL_AM_DIR withIntermediateDirectories:YES attributes:nil error:nil];
        [answer writeToFile:NL_AM_CHECK_RESPONSE_FILE atomically:YES];
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             (__bridge CFStringRef)NL_AM_RESPONSE_NOTIFICATION, NULL, NULL, YES);
    });
}

#pragma mark - Requests

static void NLAppleMusicRequested(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                  const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gAnswered.count > 500) [gAnswered removeAllObjects];
        NLServeCheck();             // the settings page: is there a subscription
        NLServeFolder(NL_AM_DIR);   // the settings page's test
        // An app's: the one playing asks almost always; any other is found by
        // looking through every app's NowLyrics folder (off the main queue).
        id app = [[objc_getClass("SBMediaController") sharedInstance] nowPlayingApplication];
        NSString *playing = [app respondsToSelector:@selector(bundleIdentifier)] ? [app bundleIdentifier] : nil;
        NSString *folder = NLAppFolder(playing);
        if (folder && NLServeFolder(folder)) return;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSArray<NSString *> *folders = NLLyricsFolders().allValues;
            dispatch_async(dispatch_get_main_queue(), ^{
                for (NSString *other in folders) NLServeFolder(other);
            });
        });
    });
}

%ctor {
    @autoreleasepool {
        gAnswered = [NSMutableSet set];
        gFound = [NSMutableDictionary dictionary];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, NLAppleMusicRequested,
                                        (__bridge CFStringRef)NL_AM_REQUEST_NOTIFICATION, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
