//
//  NLAppleMusicController.m
//  The Apple Music page under Lyrics Sources: its switches, and a test that
//  asks SpringBoard (NLAppleMusicSB.x) for the lyrics of the song playing
//  exactly as an app does (title, artist, length; SpringBoard finds it on
//  Apple Music and asks for its lyrics), then shows each step: the song it was
//  found as, and what came back, parsed as the apps would.
//

#import "NLLyricsPages.h"

#pragma mark - The page

@interface NLAppleMusicController : NLSubListController
@end

static void NLAppleMusicAnswered(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                 const void *object, CFDictionaryRef userInfo);

@implementation NLAppleMusicController {
    UIAlertController *_alert;
    NSMutableArray<NSString *> *_report;
    NSString *_requestID;
    NSTimer *_timeout;
    NSUInteger _test;   // the running test's number, moved on as it ends
    BOOL _listening;
}

- (void)dealloc {
    [self nlStopListening];
    [_timeout invalidate];
}

- (void)nlSay:(NSString *)line {
    [_report addObject:line];
    _alert.message = [_report componentsJoinedByString:@"\n\n"];
}

- (void)nlTestAppleMusic:(PSSpecifier *)specifier {
    if (_alert) return;
    _report = [NSMutableArray array];
    __weak typeof(self) weakSelf = self;
    _alert = NLPresentAlert(self, NLL(@"Apple Music test"), @"", @[
        [UIAlertAction actionWithTitle:NLL(@"OK") style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) { [weakSelf nlEndTest]; }],
    ]);
    [self nlSay:NLL(@"Looking at what is playing…")];

    // Ended (OK) before the song was known, or followed by another test, this
    // one goes no further: no request to SpringBoard, nothing said in the next
    // test's report. Told apart by number, so the answer, which may never
    // come, keeps no dismissed alert alive.
    NSUInteger test = ++_test;
    NLPlayingSong(^(NSString *bundleID, NSDictionary *np) {
        NLAppleMusicController *me = weakSelf;
        if (!me || me->_test != test) return;
        NSString *title = NLString(np, NL_NP_TITLE);
        NSString *artist = NLString(np, NL_NP_ARTIST) ?: @"";
        double duration = NLLooseNum(np[NL_NP_DURATION], 0);
        if (!title.length) {
            [me nlSay:NLL(@"Nothing is playing in an app NowLyrics is on for.")];
            return;
        }
        [me nlSay:[NSString stringWithFormat:NLL(@"Playing in %@: %@ — %@"), NLAppName(bundleID), title, artist]];
        [me nlAskSpringBoard:@{@"title": title, @"artist": artist, @"duration": @(duration)}];
    });
}

#pragma mark SpringBoard

- (void)nlStartListening {
    if (_listening) return;
    _listening = YES;
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self, NLAppleMusicAnswered,
                                    (__bridge CFStringRef)NL_AM_RESPONSE_NOTIFICATION, NULL,
                                    CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)nlStopListening {
    if (!_listening) return;
    _listening = NO;
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(), (__bridge const void *)self,
                                       (__bridge CFStringRef)NL_AM_RESPONSE_NOTIFICATION, NULL);
}

- (void)nlAskSpringBoard:(NSDictionary *)song {
    [self nlSay:NLL(@"Asking SpringBoard to find it on Apple Music and get its lyrics…")];
    _requestID = NSUUID.UUID.UUIDString;
    NSMutableDictionary *request = [song mutableCopy];
    request[@"id"] = _requestID;
    request[@"time"] = [NSDate date];
    [self nlStartListening];   // first: the answer is matched by its id
    NLWritePlistAndPost(request, NL_AM_REQUEST_FILE, NL_AM_REQUEST_NOTIFICATION);
    __weak typeof(self) weakSelf = self;
    [_timeout invalidate];
    _timeout = [NSTimer scheduledTimerWithTimeInterval:20 repeats:NO block:^(NSTimer *timer) {
        NLAppleMusicController *me = weakSelf;
        if (!me || !me->_requestID) return;
        me->_requestID = nil;
        [me nlStopListening];
        [me nlSay:NLL(@"SpringBoard did not answer. Respring once after installing (Apply), then try again.")];
    }];
}

- (void)nlAnswered {
    NSDictionary *answer = [NSDictionary dictionaryWithContentsOfFile:NL_AM_RESPONSE_FILE];
    if (!_requestID || ![answer[@"id"] isEqual:_requestID]) return;   // not ours, or too late
    _requestID = nil;
    [_timeout invalidate];
    _timeout = nil;
    [self nlStopListening];
    double elapsed = [answer[@"elapsed"] doubleValue];
    if ([answer[@"notFound"] boolValue]) {
        [self nlSay:NLL(@"Not found on Apple Music (title, artist and length must agree). The next source is used.")];
        return;
    }
    if (answer[@"adamID"]) {
        [self nlSay:[NSString stringWithFormat:NLL(@"On Apple Music: %@ — %@ (ID %@)"),
                     answer[@"matchTitle"] ?: @"?", answer[@"matchArtist"] ?: @"?", answer[@"adamID"]]];
    }
    NSString *ttml = NLString(answer, @"ttml");
    if (!ttml.length) {
        [self nlSay:[NSString stringWithFormat:NLL(@"SpringBoard could not get them: %@"), answer[@"error"] ?: @"?"]];
        return;
    }
    NSArray<NLLyricLine *> *lines = NLParseTTML(ttml);
    if (!lines.count) {
        [self nlSay:[NSString stringWithFormat:NLL(@"SpringBoard got an answer, but no timed lines in it (%lu characters)."),
                     (unsigned long)ttml.length]];
        return;
    }
    NSArray<NSString *> *first = NLSungTexts(lines, 2);
    [self nlSay:[NSString stringWithFormat:NLL(@"SpringBoard got the lyrics in %.1f s: %lu lines, %@."), elapsed,
                 (unsigned long)lines.count, NLHasWords(lines) ? NLL(@"word by word") : NLL(@"lines only")]];
    if (first.count) [self nlSay:[first componentsJoinedByString:@"\n"]];
}

- (void)nlEndTest {
    _test++;
    _alert = nil;
    _requestID = nil;
    [_timeout invalidate];
    _timeout = nil;
    [self nlStopListening];
}

@end

static void NLAppleMusicAnswered(CFNotificationCenterRef center, void *observer, CFStringRef name,
                                 const void *object, CFDictionaryRef userInfo) {
    NLAppleMusicController *controller = (__bridge NLAppleMusicController *)observer;
    dispatch_async(dispatch_get_main_queue(), ^{ [controller nlAnswered]; });
}
