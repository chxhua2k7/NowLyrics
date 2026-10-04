//
//  NLSources.m
//  HTTP, the three lyrics providers, and the order they are tried in.
//
//  Everything here runs on the engine's serial fetch queue and blocks, which
//  keeps each provider linear instead of a nest of completion handlers.
//

#import "NowLyrics.h"
#import <objc/runtime.h>
#import <sys/sysctl.h>

static const NSTimeInterval kNLDurationTolerance = 8.0;   // max track-length mismatch when matching
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
@property (nonatomic, assign) NLSource picked;        // chosen for this song on the settings page, tried first
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
    if (failed) f.transient = YES;
    return result;
}

static id NLGetJSON(NLFetch *f, NSString *urlString, NSDictionary *headers) {
    NSData *data = NLGet(f, urlString, headers);
    return data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
}

static NSString *NLNoAnswer(NLFetch *f) {
    return f.lastFailed ? @"no response" : [NSString stringWithFormat:@"HTTP %ld", (long)f.lastStatus];
}

// What a request that did not return the expected JSON shape comes down to.
static NSString *NLBadReply(NLFetch *f) {
    return f.lastFailed ? @"no response" : @"bad reply";
}

// Musixmatch wraps every answer as {"message": {"header": {"status_code": N}, "body": ...}}.
static NSInteger NLMxmStatus(id message) {
    return (NSInteger)NLNum(NLValue(NLValue(message, @"header"), @"status_code"), 0);
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

// Word by word, for a matched track that has it ("richsync"): a second call.
// The body is [{"ts": lineStart, "te": lineEnd, "x": line, "l": [{"c": piece,
// "o": offset from ts}]}], a space being a piece of its own whose offset is
// where the word before it stops. `outLength` gets the length of the cut it
// was timed to (richsync_length, seconds), 0 if not said.
static NSArray<NLLyricLine *> *NLFetchMusixmatchRichsync(NLFetch *f, id track, double *outLength) {
    *outLength = 0;
    long long trackID = (long long)NLNum(NLValue(track, @"track_id"), 0);
    if (NLNum(NLValue(track, @"has_richsync"), 0) == 0 || trackID <= 0) return nil;

    NSString *url = [NSString stringWithFormat:
        @"https://apic.musixmatch.com/ws/1.1/track.richsync.get?usertoken=%@&app_id=%@&track_id=%lld",
        NLEscape(f.settings.musixmatchToken), NLEscape(NLMusixmatchAppId()), trackID];
    id message = NLValue(NLGetJSON(f, url, nil), @"message");
    id richsync = NLValue(NLValue(message, @"body"), @"richsync");
    if (NLMxmStatus(message) != 200 || NLNum(NLValue(richsync, @"restricted"), 0) != 0) return nil;
    *outLength = NLNum(NLValue(richsync, @"richsync_length"), 0);
    NSString *body = NLString(richsync, @"richsync_body");
    id parsed = body.length ? [NSJSONSerialization JSONObjectWithData:[body dataUsingEncoding:NSUTF8StringEncoding]
                                                              options:0 error:nil] : nil;
    if (![parsed isKindOfClass:[NSArray class]]) return nil;

    NSMutableArray<NLLyricLine *> *lines = [NSMutableArray array];
    for (id entry in (NSArray *)parsed) {
        double ts = NLNum(NLValue(entry, @"ts"), -1), te = NLNum(NLValue(entry, @"te"), 0);
        NSArray *pieces = NLArray(entry, @"l");
        if (ts < 0 || pieces.count == 0) continue;
        NSMutableArray<NLLyricWord *> *words = [NSMutableArray arrayWithCapacity:pieces.count];
        for (id piece in pieces) {
            NSString *c = NLString(piece, @"c");
            double at = ts + NLNum(NLValue(piece, @"o"), 0);
            if (c.length == 0) continue;
            NLLyricWord *last = words.lastObject;
            if (last && last.end <= 0) last.end = at;   // whatever comes next ends the word before
            if ([c stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].length == 0) {
                if (last) last.text = [last.text stringByAppendingString:c];
                continue;
            }
            NLLyricWord *word = [NLLyricWord new];
            word.start = at;
            word.text = c;
            [words addObject:word];
        }
        if (words.lastObject.end <= 0) words.lastObject.end = te;
        NLLyricLine *line = NLLineFromWords(words, ts, te);
        if (line) [lines addObject:line];
    }
    return NLFinishWordLines(lines);
}

// The line-timed subtitle out of macro.subtitles.get's answer. nil, with the
// reason in `note`, when there is none to use. `outLength` as for the richsync.
static NSArray<NLLyricLine *> *NLMusixmatchSubtitleLines(id macroCalls, NSString **note, double *outLength) {
    *outLength = 0;
    id subtitleMessage = NLValue(NLValue(macroCalls, @"track.subtitles.get"), @"message");
    NSArray *subtitleList = NLArray(NLValue(subtitleMessage, @"body"), @"subtitle_list");
    if (subtitleList.count == 0) {
        // track.lyrics.get may still hold plain, untimed lyrics, which are of no use here.
        NLLog(@"Musixmatch has no timed subtitle (status %ld)",
              (long)NLMxmStatus(subtitleMessage));
        *note = @"no timed subtitle";
        return nil;
    }

    id subtitle = NLValue(subtitleList.firstObject, @"subtitle");
    if (NLNum(NLValue(subtitle, @"restricted"), 0) != 0) {
        *note = @"restricted track";
        NLLog(@"Musixmatch subtitle is restricted for this track");
        return nil;
    }
    *outLength = NLNum(NLValue(subtitle, @"subtitle_length"), 0);

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
    return lines.count ? [lines copy] : nil;
}

// Lengths Musixmatch gives in whole seconds; within this, the same cut.
static const double kNLCutSlack = 3;

static NSArray<NLLyricLine *> *NLFetchMusixmatchToken(NLFetch *f, NSString **note) {
    NSString *token = f.settings.musixmatchToken;
    if (token.length == 0) return nil;
    *note = @"no result";

    NSMutableString *url = [NSMutableString stringWithFormat:
        @"https://apic.musixmatch.com/ws/1.1/macro.subtitles.get"
        @"?usertoken=%@&app_id=%@&subtitle_format=mxm&q_track=%@&q_artist=%@",
        NLEscape(token), NLEscape(NLMusixmatchAppId()),
        NLEscape(NLCleanTitle(f.title)), NLEscape(NLPrimaryArtist(f.artist))];
    // A track has subtitles timed to several cuts (single, album, radio edit);
    // the length picks the one for the cut playing.
    if (f.duration > 0) [url appendFormat:@"&q_duration=%.0f", f.duration];

    id json = NLGetJSON(f, url, nil);
    if (!json) {
        *note = NLNoAnswer(f);
        return nil;
    }
    id message = NLValue(json, @"message");
    if (!message) return nil;

    NSInteger status = NLMxmStatus(message);
    if (status == 401) {
        *note = @"token rejected (401)";
        NLLog(@"Musixmatch token rejected (401), re-copy the debug info");
        return nil;
    }

    id macroCalls = NLValue(NLValue(message, @"body"), @"macro_calls");
    NSString *timedNote = nil;
    double timedLength = 0, wordsLength = 0;
    NSArray<NLLyricLine *> *timed = NLMusixmatchSubtitleLines(macroCalls, &timedNote, &timedLength);

    // Word by word when the track has it and its times hold up. A track has
    // one richsync, timed to one cut, and it may not be the cut playing: a
    // longer intro had every word lit seconds late (So High: richsync timed
    // to 214 s, the song is 200 s), a shorter one early. Some are squeezed
    // into a fraction of the song outright, which the subtitle of the same
    // answer gives away. The subtitle otherwise.
    id track = NLValue(NLValue(NLValue(NLValue(macroCalls, @"matcher.track.get"), @"message"), @"body"), @"track");
    NSArray<NLLyricLine *> *words = NLFetchMusixmatchRichsync(f, track, &wordsLength);
    if (NLHasContent(words)) {
        BOOL plausible = NLWordTimesPlausible(words);
        BOOL agrees = timed.count == 0 || NLWordLinesAgree(words, timed);
        BOOL otherCut = f.duration > 0 && wordsLength > 0 && fabs(wordsLength - f.duration) > kNLCutSlack &&
                        timed.count && timedLength > 0 && fabs(timedLength - f.duration) <= kNLCutSlack;
        if (plausible && agrees && !otherCut) {
            *note = nil;
            return words;
        }
        NLLog(@"Musixmatch richsync dropped: %@", !plausible ? @"faster than singing"
              : otherCut ? [NSString stringWithFormat:@"timed to %.0f s, the song is %.0f s", wordsLength, f.duration]
              : @"its lines are not where the subtitle has them");
    }
    if (timed.count) {
        *note = nil;
        return timed;
    }
    if (NLHasContent(words)) *note = @"word times off";
    else if (timedNote) *note = timedNote;
    return nil;
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
        *note = [@"key " stringByAppendingString:NLNoAnswer(f)];
        return nil;
    }

    id message = NLValue(json, @"message");
    NSInteger status = NLMxmStatus(message);
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

    // Fall back to search, keeping the closest duration that has a timed transcript.
    NSString *searchURL = [NSString stringWithFormat:
        @"https://lrclib.net/api/search?track_name=%@&artist_name=%@",
        NLEscape(NLCleanTitle(f.title)), NLEscape(NLPrimaryArtist(f.artist))];

    id json = NLGetJSON(f, searchURL, nil);
    if (![json isKindOfClass:[NSArray class]]) {
        *note = NLBadReply(f);
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
        *note = NLBadReply(f);
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

    // The v1 endpoint with yv=-1 also hands out "yrc", word-by-word timing, for
    // the tracks NetEase has it for; the rest only get "lrc", as before.
    NSString *lyricURL = [NSString stringWithFormat:
        @"https://music.163.com/api/song/lyric/v1?id=%lld&lv=-1&kv=-1&tv=-1&yv=-1&rv=-1&cp=false", bestID];
    json = NLGetJSON(f, lyricURL, NLNeteaseHeaders());
    if (![json isKindOfClass:[NSDictionary class]]) {
        *note = NLBadReply(f);
        return nil;
    }

    NSArray<NLLyricLine *> *words = NLParseYRC(NLString(NLValue(json, @"yrc"), @"lyric"));
    if (NLHasContent(words)) return words;

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
        case NLSourceAppleMusic: return @"AM";
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
    NSString *label = nil, *note = nil;

    switch (source) {
        case NLSourceMusixmatch: {
            if (!s.useMusixmatch) return nil;
            NSString *tokenNote = nil, *keyNote = nil;
            lines = NLFetchMusixmatchToken(f, &tokenNote);
            label = @"Musixmatch token";
            if (!NLHasContent(lines)) {
                lines = NLParseLRC(NLFetchMusixmatchKey(f, &keyNote));
                label = @"Musixmatch key";
                note = NLJoinNotes(tokenNote, keyNote);
            }
            break;
        }
        case NLSourceAppleMusic: {
            // Music asks by its own item; another app through SpringBoard,
            // which finds the song on Apple Music first.
            if (!s.useAppleMusic) return nil;
            // The request is iOS 16 and later; without it SpringBoard can only
            // answer "no" after a search.
            if (!objc_getClass("MPStoreLyricsMusicKitRequestOperation")) return nil;
            NSString *raw = nil;
            if (NLProcessUsesContentItems()) {
                raw = NLAppleMusicLyrics(f.title, 10);
            } else {
                if (!s.useAppleMusicElsewhere) return nil;
                raw = NLAppleMusicLyricsFromSpringBoard(f.title, f.artist, f.duration, 10, &note);
            }
            label = @"Apple Music";
            if (raw.length == 0) { if (!note.length) note = @"no lyrics"; }
            else {
                lines = [raw rangeOfString:@"<tt" options:NSCaseInsensitiveSearch].location != NSNotFound
                    ? NLParseTTML(raw) : NLParseLRC(raw);
                if (lines.count == 0) note = @"lyrics untimed";
            }
            NLLog(@"Apple Music lyrics: %lu chars, %lu lines, words %d: %@", (unsigned long)raw.length,
                  (unsigned long)lines.count, NLHasWords(lines), raw.length > 160 ? [raw substringToIndex:160] : raw);
            break;
        }
        case NLSourceLRCLIB:
            if (!s.useLRCLIB) return nil;
            lines = NLParseLRC(NLFetchLRCLIB(f, &note));
            label = @"LRCLIB";
            break;
        case NLSourceNetease:
            if (!s.useNetease) return nil;
            lines = NLFetchNetease(f, &note);
            label = @"NetEase";
            break;
        default:
            return nil;
    }

    // Squeezed word times light every word early; the next source instead.
    if (NLHasWords(lines) && !NLWordTimesPlausible(lines)) {
        NLLog(@"%@ word times faster than singing, skipped", label);
        lines = nil;
        note = @"word times off";
    }

    if (NLHasContent(lines)) {
        *outSource = label;
        // With the track and the source on top, so the settings page can list
        // the file by name and say where it came from.
        NSMutableDictionary<NSString *, NSString *> *header = [NSMutableDictionary dictionary];
        header[NL_LRC_TITLE] = f.title;
        header[NL_LRC_ARTIST] = f.artist;
        header[NL_LRC_ALBUM] = f.album;
        header[NL_LRC_SOURCE] = label;
        header[NL_LRC_CHECKED] = @"1";
        [NLLinesToLRCWithHeader(lines, header) writeToFile:cachePath atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NLPruneCache(kNLDiskCacheLimit);
        return lines;
    }
    if (lines.count && note.length == 0) note = @"found, but nothing sung";
    if (note.length) [f.notes addObject:[NSString stringWithFormat:@"%@ %@", NLSourceLabel(source), note]];
    return nil;
}

// The source picked for this song goes first, then the user's order (by
// default Apple Music in Music, Musixmatch for its timing, LRCLIB, free and
// broad, then NetEase for Chinese tracks). A source switched off is skipped
// when its turn comes.
static int NLSourceOrder(NLSettings *settings, NLSource picked, NLSource order[NLSourceCount]) {
    int n = 0;
    BOOL used[NLSourceCount] = {NO};
    NSMutableArray<NSNumber *> *wanted = [NSMutableArray arrayWithObject:@(picked)];
    [wanted addObjectsFromArray:settings.sourceOrder];
    for (NSNumber *number in wanted) {
        NLSource s = (NLSource)number.integerValue;
        if (s == NLSourceNone || s < 0 || s >= NLSourceCount || used[s]) continue;
        used[s] = YES;
        order[n++] = s;
    }
    return n;
}

NSArray<NLLyricLine *> *NLResolveLyrics(NLSettings *settings, NSString *key,
                                        NSString *title, NSString *artist, NSString *album,
                                        NSTimeInterval duration,
                                        NSString **source, NSString **outPath, BOOL *transient) {
    *transient = NO;
    *outPath = nil;

    NSArray<NLLyricLine *> *manual = NLManualLyrics(title, artist, outPath);
    if (manual.count) { *source = @"manual file"; return manual; }

    NSString *path = NLCachePath(key);
    NSString *disk = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    NSArray<NLLyricLine *> *suspect = nil;   // cached with word times not to be trusted
    NSString *suspectSource = nil;
    if (disk.length) {
        NSArray<NLLyricLine *> *cached = NLParseLRC(disk);
        // Word times cached before they were checked (squeezed ones, and
        // Musixmatch's, which may be timed to another cut): looked up again,
        // and kept only should nothing better come back.
        NSDictionary<NSString *, NSString *> *head = NLHasWords(cached) ? NLParseLRCHeader(disk) : nil;
        BOOL unchecked = [head[NL_LRC_SOURCE] hasPrefix:@"Musixmatch"] && !head[NL_LRC_CHECKED];
        if (head && (unchecked || !NLWordTimesPlausible(cached))) {
            suspect = cached;
            NSString *from = head[NL_LRC_SOURCE];
            suspectSource = from.length ? [@"cache · " stringByAppendingString:from] : @"cache";
            cached = nil;
        }
        if (cached.count) {
            NSDictionary<NSString *, NSString *> *tags = NLParseLRCHeader(disk);
            // Cached before 1.2.0: no tags, and the file name cannot be split
            // back into title and artist. Name it now, so the settings page's
            // library can list it properly.
            if (!tags[NL_LRC_TITLE] && title.length) {
                NSMutableDictionary<NSString *, NSString *> *header = [NSMutableDictionary dictionary];
                header[NL_LRC_TITLE] = title;
                header[NL_LRC_ARTIST] = artist;
                header[NL_LRC_ALBUM] = album;
                [[NLLinesToLRCWithHeader(@[], header) stringByAppendingString:disk]
                    writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            NSString *from = tags[NL_LRC_SOURCE];
            *source = from.length ? [@"cache · " stringByAppendingString:from] : @"cache";
            *outPath = path;
            return cached;
        }
    }

    NLFetch *f = [NLFetch new];
    f.settings = settings;
    f.title = title;
    f.artist = artist;
    f.album = album;
    f.duration = duration;
    f.picked = [settings sourceForTrack:key];

    NLSource order[NLSourceCount];
    int count = NLSourceOrder(settings, f.picked, order);
    for (int i = 0; i < count; i++) {
        NSArray<NLLyricLine *> *lines = NLFetchSource(f, order[i], path, source);
        if (lines.count) {
            *outPath = path;
            return lines;
        }
    }

    if (suspect) {
        *source = suspectSource;
        *outPath = path;
        return suspect;
    }

    // Nothing worked. Say what each provider said, in the order they were tried,
    // so the readout shows whether the track is absent or merely unmatched.
    *source = f.notes.count ? [f.notes componentsJoinedByString:@" · "] : @"no sources enabled";
    *transient = f.transient;
    return nil;
}
