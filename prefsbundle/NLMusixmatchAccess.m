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

static BOOL NLMusixmatchInstalled(void) {
    return NLAppInstalled(NLMusixmatchBundleID);
}

BOOL NLMusixmatchVerified(void) {
    NLSyncPrefs();
    return NLReadPrefBool(nil, kNLVerifiedKey, NO);
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
    BOOL on = NLReadPrefBool(nil, @"useMusixmatch", NO);
    if (!verified && !on) return NO;   // nothing to keep or turn off
    BOOL usable = NLMusixmatchInstalled() || NLMusixmatchHasCredentials(NLReadPref(nil, @"musixmatchToken"), NLReadPref(nil, @"musixmatchKey"));
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
