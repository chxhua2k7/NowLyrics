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
    static NSBundle *bundle;
    if (!bundle) bundle = [NSBundle bundleForClass:[NLLyricsEditorController class]];
    return [bundle localizedStringForKey:key value:key table:@"Island"];
}

@interface NSObject (NLLaunchServices)
+ (instancetype)applicationProxyForIdentifier:(NSString *)bundleID;
- (NSString *)localizedName;
@end

@interface UIImage (NLPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(CGFloat)scale;
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:NLL(@"OK") style:UIAlertActionStyleDefault handler:nil]];
    [controller presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Pasted and imported text

NSString *NLLyricsFileText(NSString *text, NSString *title, NSString *artist) {
    NSString *trimmed = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0) return nil;
    NSMutableDictionary<NSString *, NSString *> *header = [NSMutableDictionary dictionary];
    header[NL_LRC_TITLE] = title;
    header[NL_LRC_ARTIST] = artist;

    if ([trimmed rangeOfString:@"<tt" options:NSCaseInsensitiveSearch].location != NSNotFound) {
        NSArray<NLLyricLine *> *lines = NLParseTTML(trimmed);
        if (!NLHasContent(lines)) return nil;
        header[NL_LRC_SOURCE] = @"TTML";
        return NLLinesToLRCWithHeader(lines, header);
    }

    if (!NLHasContent(NLParseLRC(trimmed))) return nil;
    // Kept as given (its own tags, [offset:] and all), named on top when it is
    // not, so the library can list it.
    NSDictionary *own = NLParseLRCHeader(trimmed);
    if (own[NL_LRC_TITLE] && own[NL_LRC_ARTIST]) return [trimmed stringByAppendingString:@"\n"];
    if (own[NL_LRC_TITLE]) [header removeObjectForKey:NL_LRC_TITLE];
    if (own[NL_LRC_ARTIST]) [header removeObjectForKey:NL_LRC_ARTIST];
    return [NLLinesToLRCWithHeader(@[], header) stringByAppendingFormat:@"%@\n", trimmed];
}
