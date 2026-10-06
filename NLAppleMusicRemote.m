//
//  NLAppleMusicRemote.m
//  Apple Music's lyrics in apps other than Music, through SpringBoard
//  (NLAppleMusicSB.x): the request goes in this app's Library/NowLyrics (the
//  only place it can write), SpringBoard finds the song on Apple Music, asks
//  for its lyrics and writes the answer beside it.
//

#import "NowLyrics.h"
#import <notify.h>

NSString *NLAppleMusicLyricsFromSpringBoard(NSString *title, NSString *artist, NSTimeInterval duration,
                                            NSTimeInterval timeout, NSString **note) {
    // The answers arrive on this queue; a waiting request is woken by its ID.
    static dispatch_queue_t queue;
    static NSMutableDictionary<NSString *, dispatch_semaphore_t> *waiting;
    static NSMutableDictionary<NSString *, NSDictionary *> *answers;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("app.nowlyrics.applemusic.remote", DISPATCH_QUEUE_SERIAL);
        waiting = [NSMutableDictionary dictionary];
        answers = [NSMutableDictionary dictionary];
        int token = 0;
        notify_register_dispatch(NL_AM_RESPONSE_NOTIFICATION.UTF8String, &token, queue, ^(int t) {
            if (waiting.count == 0) return;   // nothing of ours waiting: not worth reading the file
            NSDictionary *answer = [NSDictionary dictionaryWithContentsOfFile:[NLCacheDir() stringByAppendingPathComponent:NL_AM_RESPONSE_NAME]];
            NSString *answered = NLString(answer, @"id");
            dispatch_semaphore_t sleeper = answered ? waiting[answered] : nil;
            if (!sleeper) return;   // another app's answer, or one given up on
            answers[answered] = answer;
            [waiting removeObjectForKey:answered];
            dispatch_semaphore_signal(sleeper);
        });
    });

    NSString *requestID = NSUUID.UUID.UUIDString;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_sync(queue, ^{ waiting[requestID] = done; });
    NSDictionary *request = @{@"id": requestID, @"title": title ?: @"", @"artist": artist ?: @"",
                              @"duration": @(duration), @"time": [NSDate date]};
    // NLCacheDir() does not make the folder; this does, on every request.
    NLWritePlistAndPost(request, [NLCacheDir() stringByAppendingPathComponent:NL_AM_REQUEST_NAME], NL_AM_REQUEST_NOTIFICATION);

    dispatch_semaphore_wait(done, NLTimeIn(timeout));
    __block NSDictionary *answer = nil;
    dispatch_sync(queue, ^{
        answer = answers[requestID];
        [answers removeObjectForKey:requestID];
        [waiting removeObjectForKey:requestID];
    });

    NSString *ttml = NLString(answer, @"ttml");
    if (ttml.length) return ttml;
    if (note) {
        if (!answer) *note = @"SpringBoard did not answer";
        else if ([answer[@"notFound"] boolValue]) *note = @"not on Apple Music";
        else *note = NLString(answer, @"error") ?: @"no lyrics";
    }
    return nil;
}
