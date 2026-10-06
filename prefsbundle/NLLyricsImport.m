//
//  NLLyricsImport.m
//  Lyrics brought in by hand (pasted or from Files), and the small helpers the
//  lyrics pages share.
//
//  TTML (NLTTML.m) is converted to LRC on the way in.
//

#import "NLLyricsPages.h"
#import <objc/runtime.h>

#pragma mark - Helpers

NSString *NLL(NSString *key) {
    return [NLPrefsBundle() localizedStringForKey:key value:key table:@"Island"];
}

@interface NSObject (NLLaunchServices)
+ (instancetype)applicationProxyForIdentifier:(NSString *)bundleID;
- (NSString *)localizedName;
@end

NSString *NLAppName(NSString *bundleID) {
    if (bundleID.length == 0) return @"";
    id proxy = [objc_getClass("LSApplicationProxy") applicationProxyForIdentifier:bundleID];
    NSString *name = [proxy respondsToSelector:@selector(localizedName)] ? [proxy localizedName] : nil;
    return name.length ? name : bundleID;
}

UIImage *NLAppIcon(NSString *bundleID) {
    if (bundleID.length == 0) return nil;
    return [UIImage _applicationIconImageForBundleIdentifier:bundleID format:2 scale:UIScreen.mainScreen.scale];
}

void NLAlert(UIViewController *controller, NSString *title, NSString *message) {
    NLPresentAlert(controller, title, message, @[[UIAlertAction actionWithTitle:NLL(@"OK") style:UIAlertActionStyleDefault handler:nil]]);
}

void NLPlayingSong(void (^done)(NSString *bundleID, NSDictionary *np)) {
    NLNowPlayingBundleID(^(NSString *playing) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSString *bundleID = playing;
            NSDictionary *np = NLReadNowPlaying(bundleID);
            if (!np) {
                // By the stamp: two apps writing within the same second tie on
                // the date.
                CFAbsoluteTime latest = -INFINITY;
                bundleID = nil;
                NSDictionary<NSString *, NSString *> *folders = NLLyricsFolders();
                for (NSString *candidate in folders) {
                    // In the folder the scan just found (NLReadNowPlaying
                    // would look its container up again).
                    NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[folders[candidate] stringByAppendingPathComponent:NL_NOWPLAYING_FILE]];
                    CFAbsoluteTime written = NLNowPlayingWritten(info, NULL);
                    if (written > latest) {
                        latest = written;
                        bundleID = candidate;
                        np = info;
                    }
                }
            }
            dispatch_async(dispatch_get_main_queue(), ^{ done(bundleID, np); });
        });
    });
}

#pragma mark - Pasted and imported text

NSString *NLLyricsFileText(NSString *text, NSString *title, NSString *artist) {
    NSString *trimmed = NLTrimmed(text);
    if (trimmed.length == 0) return nil;

    if (NLLooksLikeTTML(trimmed)) {
        NSArray<NLLyricLine *> *lines = NLParseTTML(trimmed);
        if (!NLHasContent(lines)) return nil;
        return NLLinesToLRCWithHeader(lines, @{NL_LRC_TITLE: title ?: @"", NL_LRC_ARTIST: artist ?: @"", NL_LRC_SOURCE: @"TTML"});
    }

    if (!NLHasContent(NLParseLRC(trimmed))) return nil;
    // Kept as given (its own tags, [offset:] and all), named on top when it is
    // not, so the library can list it. A tag it has is left empty, which
    // writes none: with both, nothing goes on top.
    NSDictionary *own = NLParseLRCHeader(trimmed);
    NSDictionary *named = @{NL_LRC_TITLE: own[NL_LRC_TITLE] ? @"" : (title ?: @""),
                            NL_LRC_ARTIST: own[NL_LRC_ARTIST] ? @"" : (artist ?: @"")};
    return [NLLinesToLRCWithHeader(@[], named) stringByAppendingFormat:@"%@\n", trimmed];
}
