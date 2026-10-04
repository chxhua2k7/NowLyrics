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

BOOL NLMusixmatchInstalled(void) {
    return NLAppInstalled(NLMusixmatchBundleID);
}

// A User Token (pasted debug info) or an API key: what the requests use.
static BOOL NLMusixmatchHasCredentials(void) {
    for (NSString *key in @[@"musixmatchToken", @"musixmatchKey"]) {
        id value = NLReadPref(nil, key);
        if ([value isKindOfClass:NSString.class] &&
            [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet].length) return YES;
    }
    return NO;
}

BOOL NLMusixmatchVerified(void) {
    CFPreferencesAppSynchronize((__bridge CFStringRef)NL_PREFS_DOMAIN);
    return [NLReadPref(nil, kNLVerifiedKey) boolValue];
}

BOOL NLUnlockMusixmatch(void) {
    if (!NLMusixmatchInstalled()) return NO;
    NLWritePrefs(@{kNLVerifiedKey: @YES, @"useMusixmatch": @YES});
    return YES;
}

// Musixmatch switched on before there was an unlock (an earlier version)
// counts as unlocked while it can work; switched on with no way to work, it
// goes off.
BOOL NLRecheckMusixmatch(void) {
    BOOL verified = NLMusixmatchVerified();
    BOOL on = [NLReadPref(nil, @"useMusixmatch") boolValue];
    BOOL usable = NLMusixmatchInstalled() || NLMusixmatchHasCredentials();
    if (verified && !usable) {
        NLWritePrefs(@{kNLVerifiedKey: @NO, @"useMusixmatch": @NO});
        return YES;
    }
    if (!verified && on) {
        NLWritePrefs(usable ? @{kNLVerifiedKey: @YES} : @{@"useMusixmatch": @NO});
        return YES;
    }
    return NO;
}
