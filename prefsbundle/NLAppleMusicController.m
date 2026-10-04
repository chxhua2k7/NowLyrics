//
//  NLAppleMusicController.m
//  The Apple Music page under Lyrics Sources: its switches, and a test that
//  asks SpringBoard (NLAppleMusicSB.x) for the lyrics of the song playing
//  exactly as an app does (title, artist, length; SpringBoard finds it on
//  Apple Music and asks for its lyrics), then shows each step: the song it was
//  found as, and what came back, parsed as the apps would.
//

#import "NLLyricsPages.h"
#import <Preferences/PSSpecifier.h>

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
    BOOL _listening;
}

- (void)dealloc {
    [self nlStopListening];
    [_timeout invalidate];
}

// The song on screen, from its app's nowplaying.plist (the now-playing title
// MediaRemote has is a lyric line): the app MediaRemote names, else whichever
// wrote last.
static void NLPlayingSong(void (^done)(NSString *bundleID, NSDictionary *np)) {
    NLNowPlayingBundleID(^(NSString *playing) {
        NSDictionary *np = NLReadNowPlaying(playing);
        NSString *bundleID = playing;
        if (!np) {
            NSDate *latest = nil;
            for (NSString *candidate in NLLyricsFolders()) {
                NSDictionary *info = NLReadNowPlaying(candidate);
                NSDate *updated = info[NL_NP_UPDATED];
                if ([updated isKindOfClass:NSDate.class] && (!latest || [updated compare:latest] == NSOrderedDescending)) {
                    latest = updated;
                    bundleID = candidate;
                    np = info;
                }
            }
        }
        done(bundleID, np);
    });
}

- (void)nlSay:(NSString *)line {
    [_report addObject:line];
    _alert.message = [_report componentsJoinedByString:@"\n\n"];
}

- (void)nlTestAppleMusic:(PSSpecifier *)specifier {
    if (_alert) return;
    _report = [NSMutableArray array];
    _alert = [UIAlertController alertControllerWithTitle:NLL(@"Apple Music test") message:@"" preferredStyle:UIAlertControllerStyleAlert];
    __weak typeof(self) weakSelf = self;
    [_alert addAction:[UIAlertAction actionWithTitle:NLL(@"OK") style:UIAlertActionStyleCancel
                                             handler:^(UIAlertAction *action) { [weakSelf nlEndTest]; }]];
    [self presentViewController:_alert animated:YES completion:nil];
    [self nlSay:NLL(@"Looking at what is playing…")];

    NLPlayingSong(^(NSString *bundleID, NSDictionary *np) {
        NSString *title = [np[NL_NP_TITLE] isKindOfClass:NSString.class] ? np[NL_NP_TITLE] : nil;
        NSString *artist = [np[NL_NP_ARTIST] isKindOfClass:NSString.class] ? np[NL_NP_ARTIST] : @"";
        double duration = [np[NL_NP_DURATION] respondsToSelector:@selector(doubleValue)] ? [np[NL_NP_DURATION] doubleValue] : 0;
        if (!title.length) {
            [weakSelf nlSay:NLL(@"Nothing is playing in an app NowLyrics is on for.")];
            return;
        }
        [weakSelf nlSay:[NSString stringWithFormat:NLL(@"Playing in %@: %@ — %@"), NLAppName(bundleID), title, artist]];
        [weakSelf nlAskSpringBoard:@{@"title": title, @"artist": artist, @"duration": @(duration)}];
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
    [[NSFileManager defaultManager] createDirectoryAtPath:NL_AM_DIR withIntermediateDirectories:YES attributes:nil error:nil];
    [request writeToFile:NL_AM_REQUEST_FILE atomically:YES];
    [self nlStartListening];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)NL_AM_REQUEST_NOTIFICATION, NULL, NULL, YES);
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
    NSString *ttml = [answer[@"ttml"] isKindOfClass:NSString.class] ? answer[@"ttml"] : nil;
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
    NSMutableArray<NSString *> *first = [NSMutableArray array];
    for (NLLyricLine *line in lines) {
        if (line.text.length) [first addObject:line.text];
        if (first.count == 2) break;
    }
    [self nlSay:[NSString stringWithFormat:NLL(@"SpringBoard got the lyrics in %.1f s: %lu lines, %@."), elapsed,
                 (unsigned long)lines.count, NLHasWords(lines) ? NLL(@"word by word") : NLL(@"lines only")]];
    if (first.count) [self nlSay:[first componentsJoinedByString:@"\n"]];
}

- (void)nlEndTest {
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
