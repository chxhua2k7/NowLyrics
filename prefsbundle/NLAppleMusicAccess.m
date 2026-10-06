//
//  NLAppleMusicAccess.m
//  Apple Music's lyrics come with a subscription only, so everything Apple
//  Music on these pages stays hidden until one is confirmed: SpringBoard asks
//  (NLAppleMusicSB.x, NL_AM_CHECK_REQUEST_FILE) and the answer is kept as
//  `appleMusicVerified`. After that SpringBoard keeps it in step by itself,
//  checking again when iTunesCloud says the subscription changed, when
//  SpringBoard starts and when an Apple Music lyrics request fails: a definite
//  "none", or no Apple ID signed in for Media & Purchases, locks it again and
//  turns Apple Music off, so the apps stop asking. "Could not tell" changes
//  nothing, nor does a privacy notice not yet agreed to. The pages read the
//  result as they appear.
//

#import "NLLyricsPages.h"

static NSString *const kNLVerifiedKey = @"appleMusicVerified";
static NSString *const kNLVerifiedAtKey = @"appleMusicVerifiedAt";   // left by earlier versions; removed with the verification
static const NSTimeInterval kNLCheckTimeout = 20;

// The lyrics request (MPStoreLyricsMusicKitRequestOperation) is iOS 16 and
// later; iOS 15 has only an older one. Below that, nothing Apple Music shows,
// whatever the subscription check would say.
BOOL NLAppleMusicAvailable(void) {
    if (@available(iOS 16.0, *)) return YES;
    return NO;
}

BOOL NLAppleMusicVerified(void) {
    if (!NLAppleMusicAvailable()) return NO;
    NLSyncPrefs();
    return NLReadPrefBool(nil, kNLVerifiedKey, NO);
}

void NLApplyAppleMusicSubscription(NLSubscription result, BOOL switchOn) {
    if (result == NLSubscriptionActive) {
        NSMutableDictionary *values = [@{kNLVerifiedKey: @YES, kNLVerifiedAtKey: NSNull.null} mutableCopy];
        if (switchOn) values[@"useAppleMusic"] = @YES;
        NLWritePrefs(values);
    } else if (result == NLSubscriptionNone || result == NLSubscriptionSignedOut) {
        NLWritePrefs(@{kNLVerifiedKey: @NO, kNLVerifiedAtKey: NSNull.null, @"useAppleMusic": @NO});
    }
}

#pragma mark - Asking SpringBoard

static NSString *gCheckID;                                                // the request waiting for its answer
static NSMutableArray<void (^)(NLSubscription, NSString *)> *gWaiting;    // who wants it
static NSTimer *gCheckTimeout;

static void NLCheckFinished(NLSubscription result, NSString *detail) {
    NSArray *waiting = [gWaiting copy];
    [gWaiting removeAllObjects];
    gCheckID = nil;
    [gCheckTimeout invalidate];
    gCheckTimeout = nil;
    for (void (^done)(NLSubscription, NSString *) in waiting) done(result, detail);
}

static void NLCheckAnswered(CFNotificationCenterRef center, void *observer, CFStringRef name,
                            const void *object, CFDictionaryRef userInfo) {
    dispatch_async(dispatch_get_main_queue(), ^{
        NSDictionary *answer = [NSDictionary dictionaryWithContentsOfFile:NL_AM_CHECK_RESPONSE_FILE];
        if (!gCheckID || ![answer[@"id"] isEqual:gCheckID]) return;   // a lyrics answer, or not ours
        NSString *result = answer[@"result"];
        NLSubscription subscription = [result isEqual:@"active"] ? NLSubscriptionActive
                                    : [result isEqual:@"none"] ? NLSubscriptionNone
                                    : [result isEqual:@"signedOut"] ? NLSubscriptionSignedOut
                                    : [result isEqual:@"privacy"] ? NLSubscriptionPrivacy : NLSubscriptionUnknown;
        NLCheckFinished(subscription, NLString(answer, @"detail") ?: @"");
    });
}

void NLCheckAppleMusicSubscription(void (^done)(NLSubscription result, NSString *detail)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWaiting = [NSMutableArray array];
        NLObserveDarwin(NL_AM_RESPONSE_NOTIFICATION, NLCheckAnswered, CFNotificationSuspensionBehaviorDeliverImmediately);
    });
    if (done) [gWaiting addObject:[done copy]];
    if (gCheckID) return;   // one on its way already: its answer is for everyone
    gCheckID = NSUUID.UUID.UUIDString;
    NLWritePlistAndPost(@{@"id": gCheckID, @"time": [NSDate date]}, NL_AM_CHECK_REQUEST_FILE, NL_AM_REQUEST_NOTIFICATION);
    gCheckTimeout = [NSTimer scheduledTimerWithTimeInterval:kNLCheckTimeout repeats:NO block:^(NSTimer *timer) {
        NLCheckFinished(NLSubscriptionUnknown, NLL(@"SpringBoard did not answer"));
    }];
}
