//
//  NLListen.m
//  A song of the listening history listened to again (Shazam's More Ways to
//  Listen): in the app it played in, or another music app on this iPhone.
//  Apple Music opens the song itself, found in its catalog (NLAppleMusicFind);
//  the others open their search for the title and artist.
//

#import <objc/runtime.h>
#import "NLHistoryPages.h"
#import "../NLAppleMusicFind.h"

@interface LSApplicationWorkspace : NSObject
+ (instancetype)defaultWorkspace;
- (BOOL)openApplicationWithBundleID:(NSString *)bundleID;
@end

static NSString *const kNLAppleMusic = @"com.apple.Music";
static NSString *const kNLSpotify = @"com.spotify.client";
static NSString *const kNLYouTubeMusic = @"com.google.ios.youtubemusic";
static NSString *const kNLYouTube = @"com.google.ios.youtube";
static NSString *const kNLSoundCloud = @"com.soundcloud.TouchApp";

// The music apps offered, in this order.
static NSArray<NSString *> *NLListenServices(void) {
    return @[kNLSpotify, kNLAppleMusic, kNLYouTubeMusic, kNLYouTube, kNLSoundCloud];
}

NSArray<NSString *> *NLListenApps(NLHistoryItem *item) {
    NSMutableArray<NSString *> *apps = [NSMutableArray array];
    if (item.app.length && NLAppInstalled(item.app)) [apps addObject:item.app];
    for (NSString *service in NLListenServices()) {
        if (![apps containsObject:service] && NLAppInstalled(service)) [apps addObject:service];
    }
    return apps;
}

static BOOL NLIsListenService(NSString *bundleID) {
    return [NLListenServices() containsObject:bundleID];
}

NSString *NLListenName(NSString *bundleID) {
    return [bundleID isEqualToString:kNLAppleMusic] ? @"Apple Music" : NLAppName(bundleID);
}

NSString *NLListenTitle(NSString *bundleID) {
    return [NSString stringWithFormat:NLL(NLIsListenService(bundleID) ? @"Listen in %@" : @"Open %@"), NLListenName(bundleID)];
}

UIColor *NLListenColor(NSString *bundleID, UIColor **text) {
    NSDictionary<NSString *, NSString *> *colors = @{
        kNLSpotify: @"#1ED760", kNLAppleMusic: @"#FA2D48", kNLYouTubeMusic: @"#FF0033",
        kNLYouTube: @"#FF0033", kNLSoundCloud: @"#FF5500",
    };
    UIColor *color = NLColorFromHex(colors[bundleID]);
    if (text) *text = [bundleID isEqualToString:kNLSpotify] ? UIColor.blackColor : UIColor.whiteColor;
    return color ?: UIColor.tintColor;
}

UIImage *NLListenIcon(NSString *bundleID) {
    return [NLHistoryAppIcon(bundleID, 24) imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

// What the apps are asked to search for: the title without its bracketed
// parts, and the first artist.
static NSString *NLListenQuery(NLHistoryItem *item) {
    return NLJoinNonEmpty(NLCleanTitle(item.title), NLPrimaryArtist(item.artist), @" ");
}

static NSURL *NLSearchURL(NSString *bundleID, NSString *query) {
    NSMutableCharacterSet *allowed = [NSCharacterSet.URLQueryAllowedCharacterSet mutableCopy];
    [allowed removeCharactersInString:@"&=+?#/:"];
    NSString *q = [query stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
    NSString *country = [NSLocale.currentLocale.countryCode lowercaseString] ?: @"us";
    NSDictionary<NSString *, NSString *> *formats = @{
        kNLSpotify: @"spotify:search:%@",
        kNLAppleMusic: [NSString stringWithFormat:@"https://music.apple.com/%@/search?term=%%@", country],
        kNLYouTubeMusic: @"https://music.youtube.com/search?q=%@",
        kNLYouTube: @"https://www.youtube.com/results?search_query=%@",
        kNLSoundCloud: @"https://soundcloud.com/search?q=%@",
    };
    NSString *format = formats[bundleID];
    return format ? [NSURL URLWithString:[NSString stringWithFormat:format, q]] : nil;
}

// A link for the app (its scheme, or one of its universal links), else the
// app opened as it is.
static void NLOpenInApp(NSURL *url, NSString *bundleID) {
    void (^launch)(void) = ^{
        LSApplicationWorkspace *workspace = [objc_getClass("LSApplicationWorkspace") defaultWorkspace];
        if ([workspace respondsToSelector:@selector(openApplicationWithBundleID:)]) [workspace openApplicationWithBundleID:bundleID];
    };
    if (!url) {
        launch();
        return;
    }
    BOOL web = [url.scheme isEqualToString:@"https"];
    [UIApplication.sharedApplication openURL:url options:web ? @{UIApplicationOpenURLOptionUniversalLinksOnly: @YES} : @{}
                           completionHandler:^(BOOL opened) {
        if (!opened) launch();
    }];
}

void NLListen(NLHistoryItem *item, NSString *bundleID) {
    if (![bundleID isEqualToString:kNLAppleMusic]) {
        NLOpenInApp(NLSearchURL(bundleID, NLListenQuery(item)), bundleID);
        return;
    }
    NLFindOnAppleMusic(item.title, item.artist, item.duration, ^(NSDictionary *match, NSString *problem) {
        NSString *link = [match[@"url"] isKindOfClass:NSString.class] ? match[@"url"] : nil;
        NLOpenInApp(link.length ? [NSURL URLWithString:link] : NLSearchURL(bundleID, NLListenQuery(item)), bundleID);
    });
}

void NLShareSong(NLHistoryItem *item, UIViewController *from, UIView *source) {
    NSString *text = NLJoinNonEmpty(item.title, item.artist, @" — ");
    UIActivityViewController *share = [[UIActivityViewController alloc] initWithActivityItems:@[text] applicationActivities:nil];
    UIView *anchor = source ?: from.view;
    share.popoverPresentationController.sourceView = anchor;
    share.popoverPresentationController.sourceRect = source ? source.bounds : CGRectMake(CGRectGetMidX(anchor.bounds), CGRectGetMidY(anchor.bounds), 1, 1);
    [from presentViewController:share animated:YES completion:nil];
}

UIMenu *NLListenMenu(NLHistoryItem *item, NSArray<NSString *> *apps, UIViewController *from, UIView *source) {
    NSMutableArray<UIAction *> *others = [NSMutableArray array];
    for (NSString *app in apps) {
        [others addObject:[UIAction actionWithTitle:NLListenName(app) image:NLListenIcon(app) identifier:nil
                                            handler:^(UIAction *action) { NLListen(item, app); }]];
    }
    UIAction *share = [UIAction actionWithTitle:NLL(@"Share") image:[UIImage systemImageNamed:@"square.and.arrow.up"] identifier:nil
                                        handler:^(UIAction *action) { NLShareSong(item, from, source); }];
    NSMutableArray<UIMenuElement *> *sections = [NSMutableArray array];
    if (others.count) [sections addObject:[UIMenu menuWithTitle:NLL(@"Other Apps") image:nil identifier:nil options:UIMenuOptionsDisplayInline children:others]];
    [sections addObject:[UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[share]]];
    return [UIMenu menuWithTitle:@"" children:sections];
}

UIContextMenuConfiguration *NLSongContextMenu(NLHistoryItem *item, UIViewController *from) {
    if (!item) return nil;
    __weak UIViewController *weakFrom = from;
    return [UIContextMenuConfiguration configurationWithIdentifier:nil previewProvider:nil actionProvider:^UIMenu *(NSArray *suggested) {
        NSArray<NSString *> *apps = NLListenApps(item);
        UIMenu *more = NLListenMenu(item, apps.count ? [apps subarrayWithRange:NSMakeRange(1, apps.count - 1)] : @[], weakFrom, nil);
        if (!apps.count) return more;
        NSString *first = apps.firstObject;
        UIAction *listen = [UIAction actionWithTitle:NLListenTitle(first) image:NLListenIcon(first) identifier:nil
                                             handler:^(UIAction *action) { NLListen(item, first); }];
        UIMenu *top = [UIMenu menuWithTitle:@"" image:nil identifier:nil options:UIMenuOptionsDisplayInline children:@[listen]];
        return [UIMenu menuWithTitle:@"" children:[@[top] arrayByAddingObjectsFromArray:more.children]];
    }];
}
