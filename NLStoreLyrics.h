//
//  NLStoreLyrics.h
//  Apple Music's lyrics asked for by catalog ID, the way Music's lyrics view
//  asks: in Music (NowLyrics.xm) and in SpringBoard for other apps
//  (NLAppleMusicSB.x), and whether a request failed. Static inline, so each
//  binary keeps its own queue.
//

#import <Foundation/Foundation.h>
#import "NLShared.h"

// The request Music's lyrics view makes: by the song's catalog (adam) ID,
// through the MusicKit lyrics endpoint, as the signed-in subscriber.
@interface NSObject (NLStoreLyricsRequest)
- (void)setSongAdamID:(long long)adamID;
- (void)setResponseHandler:(void (^)(id response, NSError *error))handler;
- (NSString *)lyricsContent;   // MPStoreLyricsResponse
@end

// MediaPlayer's MPStoreLyricsMusicKitRequestOperation (iOS 16 and later),
// MediaPlayer loaded first where it is not yet. NO when this iOS has no such
// request. `done` runs on the request's own queue with the lyrics (TTML; nil
// unless a non-empty string), the response and the error.
static inline BOOL NLAskStoreLyrics(long long adamID, void (^done)(NSString *text, id response, NSError *error)) {
    Class operationClass = NLLoadedClass("MPStoreLyricsMusicKitRequestOperation", "/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer");
    if (!operationClass) return NO;
    static NSOperationQueue *queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = [NSOperationQueue new];
        queue.name = @"com.c3x14n.nowlyrics.applemusic";
    });
    NSOperation *operation = [operationClass new];
    [(id)operation setSongAdamID:adamID];
    [(id)operation setResponseHandler:^(id response, NSError *error) {
        NSString *text = [response respondsToSelector:@selector(lyricsContent)] ? [response lyricsContent] : nil;
        done(([text isKindOfClass:[NSString class]] && text.length) ? text : nil, response, error);
    }];
    [queue addOperation:operation];
    return YES;
}

// Whether the request failed (refused, or not answered) rather than found the
// song has no lyrics. MediaPlayer reports both as an error in
// MPStoreLyricsRequestErrorDomain; no lyrics is the catalog's 404 (-3003 with
// HTTPStatusCodeKey) or an answer without TTML (-3004). Any other status, the
// bag or the data request failing (-3002, -3007), or another domain is a
// failure, which a lapsed subscription can be. A request that never reached
// the store, this iPhone being offline (the network's error somewhere under
// -3002 or -3007), is neither: it says nothing about the subscription, and a
// check then could not reach the store either.
static inline BOOL NLStoreLyricsFailed(NSError *error) {
    if (!error) return NO;
    for (NSError *e = error; [e isKindOfClass:NSError.class]; e = e.userInfo[NSUnderlyingErrorKey]) {
        if (![e.domain isEqualToString:NSURLErrorDomain]) continue;
        switch (e.code) {
            case NSURLErrorNotConnectedToInternet: case NSURLErrorNetworkConnectionLost:
            case NSURLErrorTimedOut: case NSURLErrorCannotFindHost: case NSURLErrorCannotConnectToHost:
            case NSURLErrorDNSLookupFailed: case NSURLErrorDataNotAllowed: case NSURLErrorInternationalRoamingOff:
            case NSURLErrorCallIsActive: case NSURLErrorSecureConnectionFailed:
                return NO;
        }
    }
    if (![error.domain isEqualToString:@"MPStoreLyricsRequestErrorDomain"]) return YES;
    if (error.code == -3004) return NO;
    return !(error.code == -3003 && NLLooseNum(error.userInfo[@"HTTPStatusCodeKey"], 0) == 404);
}
