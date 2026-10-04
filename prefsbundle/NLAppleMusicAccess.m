//
//  NLAppleMusicAccess.m
//  Apple Music's lyrics come with a subscription only, so everything Apple
//  Music on these pages stays hidden until one is confirmed: SpringBoard asks
//  (NLAppleMusicSB.x, NL_AM_CHECK_REQUEST_FILE) and the answer is kept as
//  `appleMusicVerified` (with `appleMusicVerifiedAt`). A confirmed one is asked
//  about again after a day; a definite "none" locks it again and turns Apple
//  Music off, so the apps stop asking. "Could not tell" changes nothing.
//

#import "NLLyricsPages.h"

static NSString *const kNLVerifiedKey = @"appleMusicVerified";
static NSString *const kNLVerifiedAtKey = @"appleMusicVerifiedAt";
static const NSTimeInterval kNLRecheckAfter = 24 * 60 * 60;
static const NSTimeInterval kNLCheckTimeout = 20;

static id NLAccessPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)NL_PREFS_DOMAIN));
}

static void NLAccessSet(NSDictionary<NSString *, id> *values) {
    for (NSString *key in values) {
        id value = values[key] == NSNull.null ? nil : values[key];
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)NL_PREFS_DOMAIN);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)NL_PREFS_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)NL_RELOAD_NOTIFICATION, NULL, NULL, YES);
}

BOOL NLAppleMusicVerified(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)NL_PREFS_DOMAIN);
    return [NLAccessPref(kNLVerifiedKey) boolValue];
}

void NLApplyAppleMusicSubscription(NLSubscription result) {
    if (result == NLSubscriptionActive) {
        NLAccessSet(@{kNLVerifiedKey: @YES, kNLVerifiedAtKey: [NSDate date]});
    } else if (result == NLSubscriptionNone) {
        NLAccessSet(@{kNLVerifiedKey: @NO, kNLVerifiedAtKey: NSNull.null, @"useAppleMusic": @NO});
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
                                    : [result isEqual:@"none"] ? NLSubscriptionNone : NLSubscriptionUnknown;
        NLCheckFinished(subscription, [answer[@"detail"] isKindOfClass:NSString.class] ? answer[@"detail"] : @"");
    });
}

void NLCheckAppleMusicSubscription(void (^done)(NLSubscription result, NSString *detail)) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gWaiting = [NSMutableArray array];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, NLCheckAnswered,
                                        (__bridge CFStringRef)NL_AM_RESPONSE_NOTIFICATION, NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    });
    if (done) [gWaiting addObject:[done copy]];
    if (gCheckID) return;   // one on its way already: its answer is for everyone
    gCheckID = NSUUID.UUID.UUIDString;
    [[NSFileManager defaultManager] createDirectoryAtPath:NL_AM_DIR withIntermediateDirectories:YES attributes:nil error:nil];
    [@{@"id": gCheckID, @"time": [NSDate date]} writeToFile:NL_AM_CHECK_REQUEST_FILE atomically:YES];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)NL_AM_REQUEST_NOTIFICATION, NULL, NULL, YES);
    gCheckTimeout = [NSTimer scheduledTimerWithTimeInterval:kNLCheckTimeout repeats:NO block:^(NSTimer *timer) {
        NLCheckFinished(NLSubscriptionUnknown, NLL(@"SpringBoard did not answer"));
    }];
}

void NLRecheckAppleMusicIfDue(void (^changed)(void)) {
    BOOL verified = NLAppleMusicVerified();
    NSDate *at = NLAccessPref(kNLVerifiedAtKey);
    BOOL fresh = verified && [at isKindOfClass:NSDate.class] && -[at timeIntervalSinceNow] < kNLRecheckAfter;
    BOOL onUnchecked = !verified && [NLAccessPref(@"useAppleMusic") boolValue];   // switched on before there was a check
    if (fresh || (!verified && !onUnchecked)) return;
    NLCheckAppleMusicSubscription(^(NLSubscription result, NSString *detail) {
        BOOL was = NLAppleMusicVerified();
        NLApplyAppleMusicSubscription(result);
        if (changed && NLAppleMusicVerified() != was) changed();
    });
}
