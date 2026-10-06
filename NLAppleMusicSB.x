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
//  Request: `id`, `title`, `artist`, `duration`, `time`. Answer: the same
//  `id`, `elapsed`, and `ttml`, or `notFound`, or `error`; with the song it
//  was found as (`adamID`, `matchTitle`, `matchArtist`).
//
//  It also tells the settings page whether there is an Apple Music
//  subscription (NL_AM_CHECK_REQUEST_FILE): first whether an Apple ID is
//  signed in for Media & Purchases at all, then what iTunesCloud's
//  subscription status says (as Music and Settings ask), else StoreKit's cloud
//  service capabilities, else whether a well-known song's lyrics can be had.
//  Once Apple Music is unlocked there, it checks again by itself, on events
//  rather than a schedule: when iTunesCloud says the subscription changed,
//  after SpringBoard starts, and when a lyrics request fails. A lapsed
//  subscription, or the Apple ID signed out, locks Apple Music again and turns
//  it off.
//
//  Nothing goes to the store while Apple Music's privacy notice waits to be
//  agreed to on this iPhone (Music shows it on first launch): StoreKit put it
//  up over whatever was on screen and waited for an answer.
//

#import "NowLyrics.h"
#import "NLLocate.h"
#import "NLAppleMusicFind.h"
#import "NLStoreLyrics.h"

@interface NSObject (NLAppleMusicSB)
+ (instancetype)sharedStatusController;                                   // ICMusicSubscriptionStatusController
- (void)getSubscriptionStatusWithCompletionHandler:(void (^)(id status, NSError *error))handler;
- (void)getSubscriptionStatusForUserIdentity:(id)identity bypassingCache:(BOOL)bypass withCompletionHandler:(void (^)(id status, NSError *error))handler;
+ (id)activeAccount;                                                      // ICUserIdentity
- (BOOL)hasCatalogPlaybackCapability;                                     // ICMusicSubscriptionStatus
- (void)requestCapabilitiesWithCompletionHandler:(void (^)(NSUInteger capabilities, NSError *error))handler;   // SKCloudServiceController
+ (BOOL)acknowledgementNeededForPrivacyIdentifier:(NSString *)identifier;   // AMSAcknowledgePrivacyTask
+ (id)ams_sharedAccountStore;                                             // ACAccountStore (AppleMediaServices' category)
- (id)ams_activeiTunesAccount;
- (NSArray *)accountsWithAccountTypeIdentifiers:(NSArray<NSString *> *)identifiers error:(NSError **)error;   // ACAccountStore
- (BOOL)isActive;                                                         // ACAccount
@end

static const NSTimeInterval kNLRequestLifetime = 60;   // older requests were given up on
static const NSUInteger kNLFoundLimit = 300;
static const NSUInteger kNLAnsweredLimit = 500;   // request IDs remembered

static NSMutableSet<NSString *> *gAnswered;                     // request IDs already taken
static NSMutableDictionary<NSString *, id> *gFound;              // song → match, or NSNull when not on Apple Music

static void NLRecheckSoon(BOOL fresh);   // the subscription checked again (Keeping the unlock in step, below)
static BOOL NLUnlockedSinceBoot(void);   // MobileKeyBag's (Keeping the unlock in step, below)

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

// Whether Apple Music's privacy notice still waits to be agreed to here, as
// AppleMediaServices keeps it (the notice Music shows on first launch). It
// reads the active account from accountsd: off the main queue (NLCheckMediaAccount).
static BOOL NLAppleMusicPrivacyNeeded(void) {
    Class task = NLLoadedClass("AMSAcknowledgePrivacyTask", "/System/Library/PrivateFrameworks/AppleMediaServices.framework/AppleMediaServices");
    if (![task respondsToSelector:@selector(acknowledgementNeededForPrivacyIdentifier:)]) return NO;
    return [task acknowledgementNeededForPrivacyIdentifier:@"com.apple.onboarding.applemusic"];
}

// Whether an Apple ID is signed in for Media & Purchases, as AppleMediaServices
// keeps it: its category on Accounts' ACAccountStore, which asks accountsd, so
// off the main queue. Calls back on the main queue, with whether the privacy
// notice waits (NLAppleMusicPrivacyNeeded, which asks accountsd too, so here
// rather than on the main queue). Unknown where this iOS has no such call,
// before this iPhone has been unlocked since it started (the accounts may not
// be readable yet, so finding none says nothing), and when accountsd did not
// answer: AppleMediaServices finds no active account then as well (its
// ams_iTunesAccounts logs the error and returns none), so signed out is only
// said when the iTunes Store accounts, asked again with the error, came back
// and none of them is active.
typedef NS_ENUM(NSInteger, NLMediaAccount) { NLMediaAccountUnknown = 0, NLMediaAccountSignedIn, NLMediaAccountSignedOut };

static void NLCheckMediaAccount(void (^done)(NLMediaAccount account, BOOL privacyNeeded)) {
    NLLoadedClass("AMSAcknowledgePrivacyTask", "/System/Library/PrivateFrameworks/AppleMediaServices.framework/AppleMediaServices");   // the category's
    Class storeClass = NLLoadedClass("ACAccountStore", "/System/Library/Frameworks/Accounts.framework/Accounts");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // Asked before the accounts: a first unlock while they are read would
        // otherwise let a read that failed for want of it count as signed out.
        BOOL unlocked = NLUnlockedSinceBoot();
        NSObject *store = [storeClass respondsToSelector:@selector(ams_sharedAccountStore)] ? [storeClass ams_sharedAccountStore] : nil;
        NLMediaAccount account = NLMediaAccountUnknown;
        if (![store respondsToSelector:@selector(ams_activeiTunesAccount)]) {
            // Not on this iOS: unknown.
        } else if ([store ams_activeiTunesAccount]) {
            account = NLMediaAccountSignedIn;
        } else if (unlocked && [store respondsToSelector:@selector(accountsWithAccountTypeIdentifiers:error:)]) {
            NSError *error = nil;
            NSArray *accounts = [store accountsWithAccountTypeIdentifiers:@[@"com.apple.account.iTunesStore"] error:&error];
            if (accounts && !error) {
                account = NLMediaAccountSignedOut;
                for (NSObject *each in accounts)
                    if ([each respondsToSelector:@selector(isActive)] && [each isActive]) account = NLMediaAccountSignedIn;
            }
        }
        // Signed out, AppleMediaServices counts the notice as not agreed to anyway.
        BOOL privacyNeeded = account == NLMediaAccountSignedOut || NLAppleMusicPrivacyNeeded();
        dispatch_async(dispatch_get_main_queue(), ^{ done(account, privacyNeeded); });
    });
}

// The lyrics by catalog ID. Calls back on the main queue with the TTML, or
// nil and why; `failed` when the store refused or did not answer, rather than
// had no lyrics for the song or was not reached (NLStoreLyricsFailed).
static void NLStoreLyrics(long long adamID, void (^done)(NSString *ttml, NSString *problem, BOOL failed)) {
    BOOL asked = NLAskStoreLyrics(adamID, ^(NSString *text, id response, NSError *error) {
        NSString *problem = text ? nil : error ? NLDescribeError(error)
                          : response ? [NSString stringWithFormat:@"no lyrics in %@", [response class]] : @"no response";
        BOOL failed = !text && NLStoreLyricsFailed(error);
        dispatch_async(dispatch_get_main_queue(), ^{ done(text, problem, failed); });
    });
    if (!asked) done(nil, @"MPStoreLyricsMusicKitRequestOperation is not here", NO);
}

// The answer to request `requestID` (taken at `start`): `fields` with the id
// and the time it took, into `path`, announced.
static void NLWriteAnswer(NSString *path, NSString *requestID, NSDate *start, NSDictionary *fields) {
    NSMutableDictionary *answer = [fields mutableCopy];
    answer[@"id"] = requestID;
    answer[@"elapsed"] = @(-[start timeIntervalSinceNow]);
    NLWritePlistAndPost(answer, path, NL_AM_RESPONSE_NOTIFICATION);
}

// One request, taken already (NLTakeRequest), answered into `folder`. Main queue.
static void NLServe(NSDictionary *request, NSString *folder) {
    NSString *requestID = request[@"id"];
    NSDate *start = [NSDate date];
    NSString *title = NLString(request, @"title") ?: @"";
    NSString *artist = NLString(request, @"artist") ?: @"";
    NSTimeInterval duration = NLLooseNum(request[@"duration"], 0);

    NSString *answerPath = [folder stringByAppendingPathComponent:NL_AM_RESPONSE_NAME];
    void (^finish)(NSDictionary *) = ^(NSDictionary *fields) { NLWriteAnswer(answerPath, requestID, start, fields); };
    void (^lyrics)(NSDictionary *) = ^(NSDictionary *match) {
        NLStoreLyrics([match[@"id"] longLongValue], ^(NSString *ttml, NSString *problem, BOOL failed) {
            if (failed) NLRecheckSoon(YES);   // the subscription may have lapsed
            NSMutableDictionary *fields = [NSMutableDictionary dictionary];
            fields[@"adamID"] = match[@"id"];
            fields[@"matchTitle"] = match[@"title"];
            fields[@"matchArtist"] = match[@"artist"];
            if (ttml) fields[@"ttml"] = ttml;
            else fields[@"error"] = problem ?: @"no lyrics";
            finish(fields);
        });
    };

    // No Apple ID signed in for Media & Purchases: nothing to ask the store as
    // (AppleMediaServices then counts the privacy notice as not agreed to as
    // well). A failed request, so the unlock is checked again and locked.
    NLCheckMediaAccount(^(NLMediaAccount account, BOOL privacyNeeded) {
        if (account == NLMediaAccountSignedOut) {
            NLRecheckSoon(YES);
            finish(@{@"error": @"no Apple ID signed in"});
            return;
        }
        if (privacyNeeded) {
            finish(@{@"error": @"Apple Music's privacy notice is not agreed to"});
            return;
        }
        if (!title.length) {
            finish(@{@"error": @"no title"});
            return;
        }
        NSString *key = [NLTrackKey(title.lowercaseString, artist.lowercaseString) stringByAppendingFormat:@"|%.0f", duration];
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
    });
}

// The request at `path`, if there is one not yet taken and not given up on:
// taken now (its id remembered).
static NSDictionary *NLTakeRequest(NSString *path) {
    NSDictionary *request = [NSDictionary dictionaryWithContentsOfFile:path];
    NSString *requestID = NLString(request, @"id");
    if (!requestID || [gAnswered containsObject:requestID]) return nil;
    NSDate *time = request[@"time"];
    if ([time isKindOfClass:NSDate.class] && -[time timeIntervalSinceNow] > kNLRequestLifetime) return nil;
    [gAnswered addObject:requestID];
    return request;
}

// The request in `folder`, if there is one not yet taken and not given up on.
static BOOL NLServeFolder(NSString *folder) {
    NSDictionary *request = NLTakeRequest([folder stringByAppendingPathComponent:NL_AM_REQUEST_NAME]);
    if (request) NLServe(request, folder);
    return request != nil;
}

#pragma mark - Is there a subscription

static const NSUInteger kNLCatalogPlayback = 1 << 0;   // SKCloudServiceCapabilityMusicCatalogPlayback

// Calls back once on the main queue: "active", "none" (a definite answer
// without catalog playback), "signedOut" (no Apple ID signed in for Media &
// Purchases, so nothing else was asked), "privacy" (iTunesCloud did not say
// active, and the privacy notice keeps the rest from being asked) or
// "unknown", and what each way said. `fresh`: iTunesCloud asks the store
// rather than answers from its cache (step 1).
static void NLCheckSubscription(BOOL fresh, void (^done)(NSString *result, NSString *detail)) {
    NSMutableArray<NSString *> *said = [NSMutableArray array];
    __block BOOL finished = NO, saidNone = NO;
    __block BOOL privacyNeeded = NO;   // as found with the account, first of all (below)
    void (^finish)(NSString *) = ^(NSString *result) {
        if (finished) return;
        finished = YES;
        done(result, [said componentsJoinedByString:@"; "]);
    };
    NLAfter(15, ^{
        [said addObject:@"timed out"];
        finish(saidNone ? @"none" : @"unknown");
    });

    // 3. Lyrics only come with a subscription: one well-known song's. Asked
    // even after a "no" above, which a stale or cautious status can say: the
    // lyrics are what counts. Its failure is this check's answer, not a reason
    // for another (as a failed request in NLServe is).
    void (^probe)(void) = ^{
        if (finished) return;
        NLFindOnAppleMusic(@"Shape of You", @"Ed Sheeran", 233, ^(NSDictionary *match, NSString *problem) {
            if (!match) {
                [said addObject:[NSString stringWithFormat:@"probe: %@", problem ?: @"song not found"]];
                finish(saidNone ? @"none" : @"unknown");
                return;
            }
            NLStoreLyrics([match[@"id"] longLongValue], ^(NSString *ttml, NSString *why, BOOL failed) {
                [said addObject:ttml ? @"probe: lyrics came" : [NSString stringWithFormat:@"probe: %@", why]];
                finish(ttml ? @"active" : saidNone ? @"none" : @"unknown");
            });
        });
    };

    // 2. StoreKit's cloud service capabilities (SpringBoard may read the media library).
    void (^storeKit)(void) = ^{
        if (finished) return;
        if (privacyNeeded) {
            [said addObject:@"privacy notice not agreed to"];
            finish(@"privacy");
            return;
        }
        NSObject *cloud = [NLLoadedClass("SKCloudServiceController", "/System/Library/Frameworks/StoreKit.framework/StoreKit") new];
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

    // 1. iTunesCloud's subscription status, as Music and Settings ask: the
    // active account's, from iTunesCloud's cache while that holds one. With
    // `fresh`, from the store past that cache: a lapse that first shows as
    // refused lyrics requests is not in a status saved before it.
    void (^iTunesCloud)(void) = ^{
        Class statusClass = NLLoadedClass("ICMusicSubscriptionStatusController", "/System/Library/PrivateFrameworks/iTunesCloud.framework/iTunesCloud");
        Class identityClass = NLLoadedClass("ICUserIdentity", "/System/Library/PrivateFrameworks/iTunesCloud.framework/iTunesCloud");
        NSObject *controller = [statusClass respondsToSelector:@selector(sharedStatusController)] ? [statusClass sharedStatusController] : nil;
        if (![controller respondsToSelector:@selector(getSubscriptionStatusWithCompletionHandler:)]) {
            [said addObject:@"iTunesCloud: not here"];
            storeKit();
            return;
        }
        void (^answered)(id, NSError *) = ^(id status, NSError *error) {
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
        };
        if (fresh && [identityClass respondsToSelector:@selector(activeAccount)] &&
            [controller respondsToSelector:@selector(getSubscriptionStatusForUserIdentity:bypassingCache:withCompletionHandler:)]) {
            [controller getSubscriptionStatusForUserIdentity:[identityClass activeAccount] bypassingCache:YES withCompletionHandler:answered];
        } else {
            [controller getSubscriptionStatusWithCompletionHandler:answered];
        }
    };

    // First of all, an Apple ID signed in for Media & Purchases, without which
    // there is no subscription and nothing is asked: signed out,
    // AppleMediaServices counts the privacy notice as not agreed to as well,
    // and the check would stop at "privacy" with Apple Music left unlocked.
    NLCheckMediaAccount(^(NLMediaAccount account, BOOL privacy) {
        if (finished) return;
        if (account == NLMediaAccountSignedOut) {
            [said addObject:@"no Apple ID signed in for Media & Purchases"];
            finish(@"signedOut");
            return;
        }
        privacyNeeded = privacy;
        iTunesCloud();
    });
}

static void NLServeCheck(void) {
    NSDictionary *request = NLTakeRequest(NL_AM_CHECK_REQUEST_FILE);
    if (!request) return;
    NSString *requestID = request[@"id"];
    NSDate *start = [NSDate date];
    NLCheckSubscription(NO, ^(NSString *result, NSString *detail) {
        NLWriteAnswer(NL_AM_CHECK_RESPONSE_FILE, requestID, start, @{@"result": result, @"detail": detail ?: @""});
    });
}

#pragma mark - Keeping the unlock in step

// Apple Music unlocked on the settings page (`appleMusicVerified`, or
// `useAppleMusic` switched on before there was a check) is checked again
// here, on events only: iTunesCloud saying the subscription status changed,
// SpringBoard starting, and a lyrics request to the store failing (NLServe
// here; Music's own posts NL_AM_FAILED_NOTIFICATION), which has iTunesCloud
// ask the store rather than its cache. The answer goes by the settings page's
// rules (NLAppleMusicAccess.m): active marks Apple Music that was on without a
// check as checked, none or signedOut locks it and turns it off, privacy and
// unknown change nothing. Unlocking stays the settings page's button.
//
// iTunesCloud's notice reaches SpringBoard in process. itunescloudd's
// ICMusicSubscriptionStatusController, told by its cache that the status
// changed, posts _ICMusicSubscriptionStatusDidChangeDistributedNotification
// through NSDistributedNotificationCenter (distnoted, not a Darwin
// notification); the shared controller in every other process hears that and
// posts ICMusicSubscriptionStatusDidChangeNotification on its own
// NSNotificationCenter, which is what is observed here. SpringBoard's shared
// controller comes with its first subscription check (NLCheckSubscription
// asks it): the unlock's, or the one after SpringBoard starts. The cache's
// own distributed notice,
// com.apple.itunescloud.ICMusicSubscriptionStatusDidChangeDistributedNotification,
// is left alone: it is posted on every save of the cache, changed or not, the
// saves a check here causes included.

static NSString *const kNLStatusChanged = @"ICMusicSubscriptionStatusDidChangeNotification";   // iTunesCloud's
static NSString *const kNLVerifiedKey = @"appleMusicVerified";       // the settings page's keys
static NSString *const kNLVerifiedAtKey = @"appleMusicVerifiedAt";   // left by earlier versions; removed with the verification
static NSString *const kNLUseKey = @"useAppleMusic";
static const NSTimeInterval kNLRecheckSettle = 5;          // notices this close together share one check
static const NSTimeInterval kNLRecheckSpacing = 10 * 60;   // checks start at least this far apart, so the store is probed no more often
static const NSTimeInterval kNLStartCheckDelay = 60;       // after SpringBoard starts or the first unlock, out of their way

static BOOL gRecheckDue;                          // a check is waiting to start
static BOOL gRecheckFresh;                        // ... and a failed request asked for it (NLRecheckSoon)
static NSTimeInterval gLastRecheck = -INFINITY;   // when the last one started (system uptime)

// Reads and writes of the preferences, which cfprefsd answers: off the main queue.
static dispatch_queue_t NLPrefsQueue(void) {
    return NL_ONCE(dispatch_queue_create("app.nowlyrics.subscription", DISPATCH_QUEUE_SERIAL));
}

// The unlock as the domain has it now: whether there is one to keep in step,
// with `verified` and `on` (useAppleMusic). Never below iOS 16, where the
// settings page offers no Apple Music. Off the main queue.
static BOOL NLReadUnlock(BOOL *verified, BOOL *on) {
    *verified = *on = NO;
    if (@available(iOS 16.0, *)) {
        CFStringRef domain = (__bridge CFStringRef)NL_PREFS_DOMAIN;
        CFPreferencesAppSynchronize(domain);
        *verified = NLLooseBool(CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)kNLVerifiedKey, domain)), NO);
        *on = NLLooseBool(CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)kNLUseKey, domain)), NO);
    }
    return *verified || *on;
}

// A check's answer applied to the unlock there is then. Only values that
// change are written, and the apps and the island told once (NLWritePrefs).
// Off the main queue.
static void NLApplySubscription(NSString *result) {
    BOOL verified, on;
    if (!NLReadUnlock(&verified, &on)) return;   // locked meanwhile
    NSMutableDictionary *changes = [NSMutableDictionary dictionary];
    if ([result isEqualToString:@"active"] && !verified) changes[kNLVerifiedKey] = @YES;
    if ([result isEqualToString:@"none"] || [result isEqualToString:@"signedOut"]) {
        if (verified) changes[kNLVerifiedKey] = @NO;
        if (on) changes[kNLUseKey] = @NO;
    }
    if (!changes.count) return;
    if (changes[kNLVerifiedKey]) changes[kNLVerifiedAtKey] = NSNull.null;
    NLWritePrefs(changes);
}

// The check, if there is an unlock to keep in step; nothing is asked
// otherwise. Main queue.
static void NLRecheckNow(void) {
    dispatch_async(NLPrefsQueue(), ^{
        BOOL verified, on;
        BOOL unlocked = NLReadUnlock(&verified, &on);
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL fresh = gRecheckFresh;
            gRecheckDue = gRecheckFresh = NO;
            if (!unlocked) return;
            gLastRecheck = NSProcessInfo.processInfo.systemUptime;
            NLCheckSubscription(fresh, ^(NSString *result, NSString *detail) {
                dispatch_async(NLPrefsQueue(), ^{ NLApplySubscription(result); });
            });
        });
    });
}

// A check soon: notices that come together share one, and one starts no
// sooner than kNLRecheckSpacing after the last (a notice meanwhile waits for
// then, so the latest change is still checked). `fresh` for a failed lyrics
// request: iTunesCloud's cached status may not know of the lapse yet, so the
// check has it ask the store (NLCheckSubscription). Main queue.
static void NLRecheckSoon(BOOL fresh) {
    gRecheckFresh = gRecheckFresh || fresh;
    if (gRecheckDue) return;   // the check already waiting covers this notice too
    gRecheckDue = YES;
    NSTimeInterval spaced = gLastRecheck + kNLRecheckSpacing - NSProcessInfo.processInfo.systemUptime;
    NLAfter(MAX(kNLRecheckSettle, spaced), ^{ NLRecheckNow(); });
}

// MobileKeyBag's: whether this iPhone has been unlocked since it started; yes
// where the function is missing. It answers 1 or 0, or a (negative)
// MobileKeyBag error when the key store could not be asked, which is no yes.
static BOOL NLUnlockedSinceBoot(void) {
    static int (*unlockedSinceBoot)(void);
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *keyBag = dlopen("/System/Library/PrivateFrameworks/MobileKeyBag.framework/MobileKeyBag", RTLD_LAZY);
        if (keyBag) unlockedSinceBoot = (int (*)(void))dlsym(keyBag, "MKBDeviceUnlockedSinceBoot");
    });
    return !unlockedSinceBoot || unlockedSinceBoot() == 1;
}

// Once after SpringBoard starts, for a change while it was not running. Not
// before the iPhone has been unlocked since it started, and not just after
// the first unlock either: until then the account and iTunesCloud's saved
// status are kept locked by data protection, and right after it they are
// still being loaded, so a check could answer "none". Looked at every
// kNLStartCheckDelay; the check comes at the look after one that found it
// unlocked (`unlockedBefore`): on a respring kNLStartCheckDelay after
// SpringBoard starts, after a boot one to two kNLStartCheckDelay after the
// first unlock. Main queue.
static void NLRecheckAfterStart(BOOL unlockedBefore) {
    if (unlockedBefore) {
        NLRecheckSoon(NO);
        return;
    }
    BOOL unlocked = NLUnlockedSinceBoot();
    NLAfter(kNLStartCheckDelay, ^{ NLRecheckAfterStart(unlocked); });
}

// Music's own lyrics request failed (NowLyrics.xm).
static void NLAppleMusicFailed(CFNotificationCenterRef center, void *observer, CFStringRef name,
                               const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{ NLRecheckSoon(YES); });
}

#pragma mark - Requests

static void NLAppleMusicRequested(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                  const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gAnswered.count > kNLAnsweredLimit) [gAnswered removeAllObjects];
        NLServeCheck();             // the settings page: is there a subscription
        NLServeFolder(NL_AM_DIR);   // the settings page's test
        // An app's: the one playing asks almost always; any other is found by
        // looking through every app's NowLyrics folder (off the main queue).
        NSString *folder = NLLyricsFolderForBundle(NLSpringBoardPlayingBundleID());
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
        NLObserveDarwin(NL_AM_REQUEST_NOTIFICATION, NLAppleMusicRequested, CFNotificationSuspensionBehaviorDeliverImmediately);
        // Keeping the unlock in step with the subscription.
        [[NSNotificationCenter defaultCenter] addObserverForName:kNLStatusChanged object:nil queue:nil usingBlock:^(NSNotification *note) {
            dispatch_async(dispatch_get_main_queue(), ^{ NLRecheckSoon(NO); });
        }];
        NLObserveDarwin(NL_AM_FAILED_NOTIFICATION, NLAppleMusicFailed, CFNotificationSuspensionBehaviorCoalesce);
        NLAfter(0, ^{ NLRecheckAfterStart(NO); });
    }
}
