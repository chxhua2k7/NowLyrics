//
//  NLAppleMusicRemote.m
//  Apple Music's lyrics in apps other than Music, through SpringBoard
//  (NLAppleMusicSB.x): the request goes in this app's Library/NowLyrics (the
//  only place it can write), SpringBoard finds the song on Apple Music, asks
//  for its lyrics and writes the answer beside it.
//

#import "NowLyrics.h"
#import "NLShared.h"
#import <notify.h>

static NSString *NLRemoteFolder(void) {
    static NSString *folder;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        folder = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject
                  stringByAppendingPathComponent:@"NowLyrics"];
    });
    return folder;
}

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
            NSDictionary *answer = [NSDictionary dictionaryWithContentsOfFile:
                                    [NLRemoteFolder() stringByAppendingPathComponent:@"am-response.plist"]];
            NSString *answered = answer[@"id"];
            dispatch_semaphore_t sleeper = [answered isKindOfClass:NSString.class] ? waiting[answered] : nil;
            if (!sleeper) return;   // another app's answer, or one given up on
            answers[answered] = answer;
            [waiting removeObjectForKey:answered];
            dispatch_semaphore_signal(sleeper);
        });
    });

    NSString *requestID = NSUUID.UUID.UUIDString;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_sync(queue, ^{ waiting[requestID] = done; });
    NSString *folder = NLRemoteFolder();
    [[NSFileManager defaultManager] createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:nil];
    NSDictionary *request = @{@"id": requestID, @"title": title ?: @"", @"artist": artist ?: @"",
                              @"duration": @(duration), @"time": [NSDate date]};
    [request writeToFile:[folder stringByAppendingPathComponent:@"am-request.plist"] atomically:YES];
    notify_post(NL_AM_REQUEST_NOTIFICATION.UTF8String);

    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
    __block NSDictionary *answer = nil;
    dispatch_sync(queue, ^{
        answer = answers[requestID];
        [answers removeObjectForKey:requestID];
        [waiting removeObjectForKey:requestID];
    });

    NSString *ttml = [answer[@"ttml"] isKindOfClass:NSString.class] ? answer[@"ttml"] : nil;
    if (ttml.length) return ttml;
    if (note) {
        if (!answer) *note = @"SpringBoard did not answer";
        else if ([answer[@"notFound"] boolValue]) *note = @"not on Apple Music";
        else *note = [answer[@"error"] isKindOfClass:NSString.class] ? answer[@"error"] : @"no lyrics";
    }
    return nil;
}
