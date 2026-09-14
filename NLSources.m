//
//  NLSources.m
//  HTTP, the three lyrics providers, and the order they are tried in.
//
//  Everything here runs on the engine's serial fetch queue and blocks, which
//  keeps each provider linear instead of a nest of completion handlers.
//

#import "NowLyrics.h"
#import <sys/sysctl.h>

const NSTimeInterval kNLDurationTolerance = 8.0;
static const NSUInteger kNLDiskCacheLimit = 300;   // cached tracks per app; the oldest go first
static const NSTimeInterval kNLNeteaseTolerance = 10.0;   // its search is looser, so is the check

// Scratch state for one resolution: how the most recent request went, and what
// each provider had to say, so the diagnostics readout can tell "not in the
// catalogue" apart from "found something but our own matching rejected it".
@interface NLFetch : NSObject
@property (nonatomic, strong) NLSettings *settings;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *artist;
@property (nonatomic, copy) NSString *album;
@property (nonatomic, assign) NSTimeInterval duration;
@property (nonatomic, assign) NSInteger lastStatus;   // HTTP status of the most recent request, 0 if none
@property (nonatomic, assign) BOOL lastFailed;        // timeout, DNS, connection refused, etc.
@property (nonatomic, assign) BOOL transient;         // some request never got an answer
@property (nonatomic, strong) NSMutableArray<NSString *> *notes;   // per provider, in the order tried
@end

@implementation NLFetch
- (instancetype)init {
    if ((self = [super init])) _notes = [NSMutableArray array];
    return self;
}
@end

#pragma mark - JSON helpers

// Tolerant accessors: any wrong type on the way down yields nil instead of an
// exception, and every provider gets to be sloppy with its response shape.
static id NLValue(id container, NSString *key) {
    return [container isKindOfClass:[NSDictionary class]] ? ((NSDictionary *)container)[key] : nil;
}

static NSString *NLString(id container, NSString *key) {
    id v = NLValue(container, key);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

static NSArray *NLArray(id container, NSString *key) {
    id v = NLValue(container, key);
    return [v isKindOfClass:[NSArray class]] ? v : nil;
}

#pragma mark - HTTP

static NSURLSession *NLSession(void) {
    static NSURLSession *session = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURLSessionConfiguration *cfg = [NSURLSessionConfiguration ephemeralSessionConfiguration];
        cfg.timeoutIntervalForRequest = 12;
        cfg.timeoutIntervalForResource = 20;
        session = [NSURLSession sessionWithConfiguration:cfg];
    });
    return session;
}

static NSString *NLEscape(NSString *s) {
    static NSCharacterSet *allowed = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        allowed = [NSCharacterSet characterSetWithCharactersInString:
                   @"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"];
    });
    return [(s ?: @"") stringByAddingPercentEncodingWithAllowedCharacters:allowed] ?: @"";
}

// Blocking GET. Records how it went on the fetch so callers can tell "the
// server said no" apart from "the server never answered", which must not be
// memoised as a miss.
static NSData *NLGet(NLFetch *f, NSString *urlString, NSDictionary<NSString *, NSString *> *headers) {
    f.lastStatus = 0;
    f.lastFailed = NO;
    NSURL *url = [NSURL URLWithString:urlString];
    if (!url) return nil;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    [req setValue:kNLUserAgent forHTTPHeaderField:@"Lrclib-Client"];
    [req setValue:kNLUserAgent forHTTPHeaderField:@"User-Agent"];
    [headers enumerateKeysAndObjectsUsingBlock:^(NSString *k, NSString *v, BOOL *stop) {
        [req setValue:v forHTTPHeaderField:k];
    }];

    __block NSData *result = nil;
    __block NSInteger status = 0;
    __block BOOL failed = NO;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    [[NLSession() dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        status = [resp isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)resp).statusCode : 0;
        failed = (err != nil) || status == 0;
        if (!err && status >= 200 && status < 300) result = data;
        dispatch_semaphore_signal(sem);
    }] resume];
    if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC))) != 0) {
        failed = YES;   // gave up waiting
    }
    f.lastStatus = status;
    f.lastFailed = failed;
    return result;
}

static id NLGetJSON(NLFetch *f, NSString *urlString, NSDictionary *headers) {
    NSData *data = NLGet(f, urlString, headers);
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}

static void NLNoteTransient(NLFetch *f) {
    if (f.lastFailed) f.transient = YES;
}

static NSString *NLNoAnswer(NLFetch *f) {
    return f.lastFailed ? @"no response" : [NSString stringWithFormat:@"HTTP %ld", (long)f.lastStatus];
}

#pragma mark - Musixmatch via app user token

// The token endpoint is what the Musixmatch app itself talks to, and it is not
// the documented developer API: different host, `usertoken` instead of `apikey`,
// and a response that nests the payload several levels deep. Modelled on
// EeveeSpotify's MusixmatchLyricsRepository.
//
// EeveeSpotify also passes track_spotify_id, which it can read out of Spotify's
// private SPTPlayerTrack. Deliberately not done here: reaching into the host
// app's obfuscated classes is exactly what this tweak avoids, and it would only
// ever work for Spotify. Matching therefore relies on q_track and q_artist alone,
// which is weaker for obscure or same-titled tracks.
static NSString *NLMusixmatchAppId(void) {
    static NSString *appId = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        char model[64] = {0};
        size_t len = sizeof(model);
        appId = (sysctlbyname("hw.machine", model, &len, NULL, 0) == 0 &&
                 strncmp(model, "iPad", 4) == 0)
            ? @"mac-ios-ipad-v1.0"
            : @"mac-ios-v2.0";
    });
    return appId;
}

static NSArray<NLLyricLine *> *NLFetchMusixmatchToken(NLFetch *f, NSString **note) {
    NSString *token = f.settings.musixmatchToken;
    if (token.length == 0) return nil;
    *note = @"no result";

    NSString *url = [NSString stringWithFormat:
        @"https://apic.musixmatch.com/ws/1.1/macro.subtitles.get"
        @"?usertoken=%@&app_id=%@&subtitle_format=mxm&q_track=%@&q_artist=%@",
        NLEscape(token), NLEscape(NLMusixmatchAppId()),
        NLEscape(NLCleanTitle(f.title)), NLEscape(NLPrimaryArtist(f.artist))];

    id json = NLGetJSON(f, url, nil);
    if (!json) {
        NLNoteTransient(f);
        *note = NLNoAnswer(f);
        return nil;
    }
    id message = NLValue(json, @"message");
    if (!message) return nil;

    NSInteger status = (NSInteger)NLNum(NLValue(NLValue(message, @"header"), @"status_code"), 0);
    if (status == 401) {
        *note = @"token rejected (401)";
        NLLog(@"Musixmatch token rejected (401), re-copy the debug info");
        return nil;
    }

    id macroCalls = NLValue(NLValue(message, @"body"), @"macro_calls");
    id subtitleMessage = NLValue(NLValue(macroCalls, @"track.subtitles.get"), @"message");
    NSArray *subtitleList = NLArray(NLValue(subtitleMessage, @"body"), @"subtitle_list");
    if (subtitleList.count == 0) {
        // track.lyrics.get may still hold plain, untimed lyrics, which are of no use here.
        NLLog(@"Musixmatch has no timed subtitle (status %ld)",
              (long)NLNum(NLValue(NLValue(subtitleMessage, @"header"), @"status_code"), 0));
        *note = @"no timed subtitle";
        return nil;
    }

    id subtitle = NLValue(subtitleList.firstObject, @"subtitle");
    if (NLNum(NLValue(subtitle, @"restricted"), 0) != 0) {
        *note = @"restricted track";
        NLLog(@"Musixmatch subtitle is restricted for this track");
        return nil;
    }

    // subtitle_body is itself a JSON string: [{"text": ..., "time": {"total": seconds}}]
    NSString *body = NLString(subtitle, @"subtitle_body");
    if (body.length == 0) return nil;
    id parsed = [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding]
                                                options:0
                                                  error:nil];
    if (![parsed isKindOfClass:[NSArray class]]) return nil;

    NSArray *entries = parsed;
    NSMutableArray<NLLyricLine *> *lines = [NSMutableArray arrayWithCapacity:entries.count];
    for (NSUInteger i = 0; i < entries.count; i++) {
        id entry = entries[i];
        NSTimeInterval start = NLNum(NLValue(NLValue(entry, @"time"), @"total"), -1);
        if (start < 0) continue;

        NLLyricLine *line = [NLLyricLine new];
        line.start = start;
        // The final entry is an end marker; blanking it makes the title reappear
        // once the song finishes, which is what the empty-line path already does.
        line.text = (i + 1 == entries.count) ? @"" : (NLString(entry, @"text") ?: @"");
        [lines addObject:line];
    }

    if (lines.count) *note = nil;
    return lines.count ? [lines copy] : nil;
}

#pragma mark - Musixmatch via developer API key

static NSString *NLFetchMusixmatchKey(NLFetch *f, NSString **note) {
    NSString *key = f.settings.musixmatchKey;
    if (key.length == 0) return nil;

    NSMutableString *url = [NSMutableString stringWithFormat:
        @"https://api.musixmatch.com/ws/1.1/matcher.subtitle.get?format=json&q_track=%@&q_artist=%@&apikey=%@",
        NLEscape(NLCleanTitle(f.title)), NLEscape(NLPrimaryArtist(f.artist)), NLEscape(key)];
    if (f.duration > 0) {
        [url appendFormat:@"&f_subtitle_length=%.0f&f_subtitle_length_max_deviation=%.0f",
                          floor(f.duration), kNLDurationTolerance];
    }

    id json = NLGetJSON(f, url, nil);
    if (!json) {
        NLNoteTransient(f);
        *note = [@"key " stringByAppendingString:NLNoAnswer(f)];
        return nil;
    }

    id message = NLValue(json, @"message");
    NSInteger status = (NSInteger)NLNum(NLValue(NLValue(message, @"header"), @"status_code"), 0);
    if (status != 200) {
        // 401 bad key, 402 quota exceeded, 403 plan excludes this endpoint, 404 no match
        NLLog(@"Musixmatch status_code=%ld", (long)status);
        *note = [NSString stringWithFormat:@"key status %ld", (long)status];
        return nil;
    }

    NSString *lrc = NLString(NLValue(NLValue(message, @"body"), @"subtitle"), @"subtitle_body");
    return lrc.length ? lrc : nil;
}

#pragma mark - LRCLIB (no key required)

static NSString *NLFetchLRCLIB(NLFetch *f, NSString **note) {
    // Exact lookup first: with all four fields LRCLIB matches on duration too.
    NSString *getURL = [NSString stringWithFormat:
        @"https://lrclib.net/api/get?track_name=%@&artist_name=%@&album_name=%@&duration=%.0f",
        NLEscape(f.title), NLEscape(f.artist), NLEscape(f.album), floor(f.duration)];

    NSString *synced = NLString(NLGetJSON(f, getURL, nil), @"syncedLyrics");
    if (synced.length) return synced;
    NLNoteTransient(f);

    // Fall back to search, keeping the closest duration that has a timed transcript.
    NSString *searchURL = [NSString stringWithFormat:
        @"https://lrclib.net/api/search?track_name=%@&artist_name=%@",
        NLEscape(NLCleanTitle(f.title)), NLEscape(NLPrimaryArtist(f.artist))];

    id json = NLGetJSON(f, searchURL, nil);
    if (![json isKindOfClass:[NSArray class]]) {
        NLNoteTransient(f);
        *note = f.lastFailed ? @"no response" : @"bad reply";
        return nil;
    }

    NSString *best = nil;
    double bestDelta = INFINITY;
    NSUInteger candidates = 0, timed = 0;
    for (id item in (NSArray *)json) {
        if (![item isKindOfClass:[NSDictionary class]]) continue;
        candidates++;
        NSString *lrc = NLString(item, @"syncedLyrics");
        if (lrc.length == 0) continue;
        timed++;

        // duration can be JSON null here, which really does occur in search results
        double itemDuration = NLNum(NLValue(item, @"duration"), -1);
        double delta = (itemDuration < 0) ? INFINITY : fabs(itemDuration - f.duration);
        if (delta < bestDelta) { bestDelta = delta; best = lrc; }
    }
    // A large mismatch usually means a cover or a live take; no lyrics beats wrong ones.
    if (best && (f.duration <= 0 || bestDelta <= kNLDurationTolerance)) return best;

    if (candidates == 0)  *note = @"nothing under this title";
    else if (timed == 0)  *note = [NSString stringWithFormat:@"%lu found, none timed", (unsigned long)candidates];
    else                  *note = [NSString stringWithFormat:@"%lu timed, duration off by %.0fs", (unsigned long)timed, bestDelta];
    return nil;
}

#pragma mark - NetEase (fallback, best coverage for Chinese tracks)

static NSDictionary *NLNeteaseHeaders(void) {
    return @{
        @"Referer": @"https://music.163.com/",
        @"Cookie": @"appver=8.7.01; os=iOS",
        @"User-Agent": @"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15",
    };
}

static NSArray<NLLyricLine *> *NLFetchNetease(NLFetch *f, NSString **note) {
    NSString *keyword = [NSString stringWithFormat:@"%@ %@", NLCleanTitle(f.title), NLPrimaryArtist(f.artist)];
    NSString *searchURL = [NSString stringWithFormat:
        @"https://music.163.com/api/search/get/web?csrf_token=&type=1&offset=0&limit=8&s=%@",
        NLEscape(keyword)];

    id json = NLGetJSON(f, searchURL, NLNeteaseHeaders());
    if (![json isKindOfClass:[NSDictionary class]]) {
        NLNoteTransient(f);
        *note = f.lastFailed ? @"no response" : @"bad reply";
        return nil;
    }
    NSArray *songs = NLArray(NLValue(json, @"result"), @"songs");
    if (songs.count == 0) {
        *note = @"nothing under this title";
        return nil;
    }

    long long bestID = 0;
    double bestDelta = INFINITY;
    for (id song in songs) {
        if (![song isKindOfClass:[NSDictionary class]]) continue;
        double songDuration = NLNum(NLValue(song, @"duration"), -1) / 1000.0;   // NetEase reports milliseconds
        double delta = (f.duration > 0 && songDuration > 0) ? fabs(songDuration - f.duration) : 0;
        if (delta < bestDelta) { bestDelta = delta; bestID = (long long)NLNum(NLValue(song, @"id"), 0); }
    }
    if (bestID <= 0 || (f.duration > 0 && bestDelta > kNLNeteaseTolerance)) {
        *note = (bestID <= 0) ? @"no usable hit"
                              : [NSString stringWithFormat:@"duration off by %.0fs", bestDelta];
        return nil;
    }

    NSString *lyricURL = [NSString stringWithFormat:
        @"https://music.163.com/api/song/lyric?id=%lld&lv=1&kv=1&tv=0", bestID];
    json = NLGetJSON(f, lyricURL, NLNeteaseHeaders());
    if (![json isKindOfClass:[NSDictionary class]]) {
        NLNoteTransient(f);
        *note = f.lastFailed ? @"no response" : @"bad reply";
        return nil;
    }

    NSString *lrc = NLString(NLValue(json, @"lrc"), @"lyric");
    if (lrc.length == 0) {
        *note = @"matched, but no lyrics";
        return nil;
    }

    NSArray<NLLyricLine *> *lines = NLParseLRC(lrc);
    if (lines.count == 0) *note = @"matched, lyrics untimed";
    return lines;
}

#pragma mark - Resolution

static NSString *NLSourceLabel(NLSource source) {
    switch (source) {
        case NLSourceMusixmatch: return @"MXM";
        case NLSourceLRCLIB:     return @"LRCLIB";
        case NLSourceNetease:    return @"NetEase";
        default:                 return @"?";
    }
}

static NSString *NLJoinNotes(NSString *a, NSString *b) {
    if (a.length && b.length) return [NSString stringWithFormat:@"%@, %@", a, b];
    return a.length ? a : b;
}

// Tries one provider and caches a hit. Kept separate so the order can be
// permuted by preference rather than hard-coded into a chain of ifs.
static NSArray<NLLyricLine *> *NLFetchSource(NLFetch *f, NLSource source, NSString *cachePath, NSString **outSource) {
    NLSettings *s = f.settings;
    NSArray<NLLyricLine *> *lines = nil;
    NSString *note = nil;

    switch (source) {
        case NLSourceMusixmatch: {
            if (!s.useMusixmatch) return nil;
            NSString *tokenNote = nil, *keyNote = nil;
            lines = NLFetchMusixmatchToken(f, &tokenNote);
            if (NLHasContent(lines)) { *outSource = @"Musixmatch token"; break; }
            lines = NLParseLRC(NLFetchMusixmatchKey(f, &keyNote));
            if (NLHasContent(lines)) { *outSource = @"Musixmatch key"; break; }
            note = NLJoinNotes(tokenNote, keyNote);
            break;
        }
        case NLSourceLRCLIB: {
            if (!s.useLRCLIB) return nil;
            lines = NLParseLRC(NLFetchLRCLIB(f, &note));
            if (NLHasContent(lines)) { *outSource = @"LRCLIB"; break; }
            break;
        }
        case NLSourceNetease: {
            if (!s.useNetease) return nil;
            lines = NLFetchNetease(f, &note);
            if (NLHasContent(lines)) { *outSource = @"NetEase"; break; }
            break;
        }
        default:
            return nil;
    }

    if (NLHasContent(lines)) {
        [NLLinesToLRC(lines) writeToFile:cachePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NLPruneCache(kNLDiskCacheLimit);
        return lines;
    }
    if (lines.count && note.length == 0) note = @"found, but nothing sung";
    if (note.length) [f.notes addObject:[NSString stringWithFormat:@"%@ %@", NLSourceLabel(source), note]];
    return nil;
}

// The preferred source goes first; the rest keep their default relative order:
// Musixmatch (best timing) -> LRCLIB (free, broad) -> NetEase (Chinese tracks).
static void NLSourceOrder(NLSource preferred, NLSource order[NLSourceCount]) {
    int n = 0;
    if (preferred != NLSourceNone) order[n++] = preferred;
    for (int i = 0; i < (int)NLSourceCount; i++) {
        if ((NLSource)i != preferred) order[n++] = (NLSource)i;
    }
}

NSArray<NLLyricLine *> *NLResolveLyrics(NLSettings *settings, NSString *key,
                                        NSString *title, NSString *artist, NSString *album,
                                        NSTimeInterval duration,
                                        NSString **source, BOOL *transient) {
    *transient = NO;

    NSArray<NLLyricLine *> *manual = NLManualLyrics(title, artist);
    if (manual.count) { *source = @"manual file"; return manual; }

    NSString *path = NLCachePath(key);
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:path] && duration > 0) {
        // Caches from before 2.19 were named with the duration as well; adopt one.
        NSString *legacy = NLCachePath(NLLegacyTrackKey(title, artist, duration));
        if ([fm fileExistsAtPath:legacy]) [fm moveItemAtPath:legacy toPath:path error:nil];
    }
    NSString *disk = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    if (disk.length) {
        NSArray<NLLyricLine *> *cached = NLParseLRC(disk);
        if (cached.count) { *source = @"cache"; return cached; }
    }

    NLFetch *f = [NLFetch new];
    f.settings = settings;
    f.title = title;
    f.artist = artist;
    f.album = album;
    f.duration = duration;

    NLSource order[NLSourceCount];
    NLSourceOrder(settings.preferredSource, order);
    for (int i = 0; i < (int)NLSourceCount; i++) {
        NSArray<NLLyricLine *> *lines = NLFetchSource(f, order[i], path, source);
        if (lines.count) return lines;
    }

    // Nothing worked. Say what each provider said, in the order they were tried,
    // so the readout shows whether the track is absent or merely unmatched.
    *source = f.notes.count ? [f.notes componentsJoinedByString:@" · "] : @"no sources enabled";
    *transient = f.transient;
    return nil;
}
