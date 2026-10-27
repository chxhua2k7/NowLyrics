//
//  NLCCShared.m
//  What the Control Center module's tile does with what plays: the song as
//  it shows it, play or pause, the cover made small.
//

#import "NLCC.h"

@interface UIImage (NLCCSharedPrivate)
+ (UIImage *)_applicationIconImageForBundleIdentifier:(NSString *)bundleID format:(int)format scale:(CGFloat)scale;
@end

NSString *NLCCNotPlaying(void) {
    return NL_ONCE(({
        NSBundle *controls = [NSBundle bundleWithPath:@"/System/Library/PrivateFrameworks/MediaControls.framework"];
        NSString *key = @"MEDIA_CONTROLS_EMPTY_STATE_TITLE";
        NSString *system = [controls localizedStringForKey:key value:@"" table:@"MediaControls"];
        system.length && ![system isEqualToString:key] ? system : NLCCL(@"Not Playing");
    }));
}

// The app's icon, looked up once per app.
static UIImage *NLCCAppIcon(NSString *bundleID) {
    static NSString *shownFor = nil;
    static UIImage *shownIcon = nil;
    if (!NLSame(shownFor, bundleID)) {
        shownFor = bundleID;
        shownIcon = bundleID ? [UIImage _applicationIconImageForBundleIdentifier:bundleID format:0 scale:UIScreen.mainScreen.scale] : nil;
    }
    return shownIcon;
}

NLCCSong *NLCCSongNow(NSString *bundleID, NSDictionary *np, NSDictionary *info, UIImage *cover) {
    NLCCSong *song = [NLCCSong new];
    song.title = np ? NLString(np, NL_NP_TITLE) : NLInfoTitle(info);
    song.artist = np ? NLString(np, NL_NP_ARTIST) : NLString(info, NL_MR_ARTIST);
    song.playing = song.title.length > 0;
    if (!song.playing) return song;
    song.playingNow = NLInfoPlaying(info);
    song.cover = cover;
    song.appIcon = NLCCAppIcon(bundleID);
    return song;
}

NSDictionary *NLCCTogglePlayPause(NSDictionary *info) {
    Boolean (*send)(int, CFDictionaryRef) = NL_ONCE((Boolean (*)(int, CFDictionaryRef))NLMediaRemote("MRMediaRemoteSendCommand"));
    if (!send) return info;
    send(2, NULL);   // kMRTogglePlayPause
    if (!info) return info;
    NSMutableDictionary *flipped = [info mutableCopy];
    flipped[NL_MR_RATE] = @(NLInfoPlaying(info) ? 0 : 1);
    return flipped;
}

void NLCCMakeCover(NSData *artwork, CGFloat points, void (^done)(UIImage *cover)) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ queue = dispatch_queue_create("com.c3x14n.nowlyrics.cover", DISPATCH_QUEUE_SERIAL); });
    CGFloat pixels = points * UIScreen.mainScreen.scale;
    dispatch_async(queue, ^{
        UIImage *image = [UIImage imageWithData:artwork];
        CGSize size = image.size;
        CGFloat scale = size.width > 0 && size.height > 0 ? MIN(1, pixels / MAX(size.width, size.height)) : 1;
        UIImage *small = [image imageByPreparingThumbnailOfSize:CGSizeMake(round(size.width * scale), round(size.height * scale))] ?: image;
        dispatch_async(dispatch_get_main_queue(), ^{ done(small); });
    });
}
