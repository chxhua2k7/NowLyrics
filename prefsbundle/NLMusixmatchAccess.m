//
//  NLMusixmatchAccess.m
//  Musixmatch on Lyrics Sources stays behind "Unlock Musixmatch lyrics" until
//  the Musixmatch app is installed, where its User Token comes from; kept as
//  `musixmatchVerified`. With the app gone it stays unlocked while a User Token
//  or API key is saved (neither needs the app), and without one it locks again
//  and Musixmatch goes off.
//

#import "NLLyricsPages.h"

NSString *const NLMusixmatchBundleID = @"com.musixmatch.lyrics";
NSString *const NLMusixmatchStoreURL = @"itms-apps://apps.apple.com/app/id448278467";

static NSString *const kNLVerifiedKey = @"musixmatchVerified";

static id NLAccessPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, (__bridge CFStringRef)NL_PREFS_DOMAIN));
}

static void NLAccessSet(NSDictionary<NSString *, id> *values) {
    for (NSString *key in values) {
        CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)values[key], (__bridge CFStringRef)NL_PREFS_DOMAIN);
    }
    CFPreferencesAppSynchronize((__bridge CFStringRef)NL_PREFS_DOMAIN);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)NL_RELOAD_NOTIFICATION, NULL, NULL, YES);
}

BOOL NLMusixmatchInstalled(void) {
    return NLAppInstalled(NLMusixmatchBundleID);
}

// A User Token (pasted debug info) or an API key: what the requests use.
static BOOL NLMusixmatchHasCredentials(void) {
    for (NSString *key in @[@"musixmatchToken", @"musixmatchKey"]) {
        id value = NLAccessPref(key);
        if ([value isKindOfClass:NSString.class] &&
            [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return YES;
    }
    return NO;
}

BOOL NLMusixmatchVerified(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)NL_PREFS_DOMAIN);
    return [NLAccessPref(kNLVerifiedKey) boolValue];
}

BOOL NLUnlockMusixmatch(void) {
    if (!NLMusixmatchInstalled()) return NO;
    NLAccessSet(@{kNLVerifiedKey: @YES, @"useMusixmatch": @YES});
    return YES;
}

// Musixmatch switched on before there was an unlock (an earlier version)
// counts as unlocked while it can work; switched on with no way to work, it
// goes off.
BOOL NLRecheckMusixmatch(void) {
    BOOL verified = NLMusixmatchVerified();
    BOOL on = [NLAccessPref(@"useMusixmatch") boolValue];
    BOOL usable = NLMusixmatchInstalled() || NLMusixmatchHasCredentials();
    if (verified && !usable) {
        NLAccessSet(@{kNLVerifiedKey: @NO, @"useMusixmatch": @NO});
        return YES;
    }
    if (!verified && on) {
        NLAccessSet(usable ? @{kNLVerifiedKey: @YES} : @{@"useMusixmatch": @NO});
        return YES;
    }
    return NO;
}
