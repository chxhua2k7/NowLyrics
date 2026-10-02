//
//  NLEngine.m
//  Track state, the virtual playback clock, line lookup, the flip timer and the
//  fetch queue. Knows nothing about how the app publishes: it hands the
//  composed strings to NLPublish() in NowLyrics.xm.
//

#import "NowLyrics.h"
#import <QuartzCore/QuartzCore.h>
#import <pthread.h>

static const NSTimeInterval kNLMargin = 0.15;        // how early a line may switch
static const NSTimeInterval kNLMaxFlipDelay = 8.0;   // cap on timer sleep
static const NSUInteger kNLMemoryCacheLimit = 64;    // parsed tracks kept in memory; the disk has the rest
static const NSTimeInterval kNLCueWindow = 1.5;      // how late a chorus start may still be announced

// Lyrics cache. Touched from both the fetch queue and the main queue.
static NSMutableDictionary<NSString *, NSArray<NLLyricLine *> *> *gCache = nil;
static NSMutableArray<NSString *> *gCacheOrder = nil;                 // insertion order, for eviction
static NSMutableSet<NSString *> *gPending = nil;
static NSMutableSet<NSString *> *gMissing = nil;                      // known misses, so we stop asking
static NSMutableDictionary<NSString *, NSString *> *gStatus = nil;    // which source answered, for diagnostics
static pthread_mutex_t gCacheMutex = PTHREAD_MUTEX_INITIALIZER;
static dispatch_queue_t gFetchQueue = nil;

// Playback state. Main queue only, no locking.
static NSString *gTrackKey = nil;
static NSString *gTrackTitle = nil;
static NSString *gTrackArtist = nil;
static BOOL gTrackRequested = NO;           // lyrics were asked for, which needs the duration
static NSTimeInterval gAnchorElapsed = 0;   // virtual clock anchor
static CFTimeInterval gAnchorHost = 0;
static double gRate = 0;
static uint64_t gFlipGeneration = 0;        // invalidates superseded timers
static __weak NLLyricLine *gLastCue = nil;  // the chorus start last announced

void NLEngineStart(void) {
    gCache = [NSMutableDictionary dictionary];
    gCacheOrder = [NSMutableArray array];
    gPending = [NSMutableSet set];
    gMissing = [NSMutableSet set];
    gStatus = [NSMutableDictionary dictionary];
    gFetchQueue = dispatch_queue_create("app.nowlyrics.fetch", DISPATCH_QUEUE_SERIAL);
}

NSString *NLEngineTrackTitle(void) { return gTrackTitle; }
NSString *NLEngineTrackArtist(void) { return gTrackArtist; }

#pragma mark - Cache

static NSArray<NLLyricLine *> *NLCachedLines(NSString *key) {
    if (key.length == 0) return nil;
    pthread_mutex_lock(&gCacheMutex);
    NSArray<NLLyricLine *> *lines = gCache[key];
    pthread_mutex_unlock(&gCacheMutex);
    return lines;
}

static NSString *NLStatusForKey(NSString *key) {
    if (key.length == 0) return nil;
    pthread_mutex_lock(&gCacheMutex);
    NSString *status = gStatus[key];
    pthread_mutex_unlock(&gCacheMutex);
    return status;
}

// A miss is only remembered when every source actually answered. If a request
// timed out, the next play of the same track gets another attempt instead of
// being written off for the rest of the session.
static void NLStoreResult(NSString *key, NSArray<NLLyricLine *> *lines, NSString *status, BOOL transient) {
    pthread_mutex_lock(&gCacheMutex);
    gStatus[key] = status;
    if (lines.count) {
        if (!gCache[key]) [gCacheOrder addObject:key];
        gCache[key] = lines;
        // Bounded: a long session otherwise keeps every track it ever parsed.
        // Anything evicted is still on disk and comes back in a few milliseconds.
        while (gCacheOrder.count > kNLMemoryCacheLimit) {
            NSString *oldest = gCacheOrder.firstObject;
            [gCacheOrder removeObjectAtIndex:0];
            [gCache removeObjectForKey:oldest];
            [gStatus removeObjectForKey:oldest];
        }
    } else if (!transient) {
        [gMissing addObject:key];
    }
    [gPending removeObject:key];
    pthread_mutex_unlock(&gCacheMutex);
}

void NLEngineForgetLyrics(void) {
    pthread_mutex_lock(&gCacheMutex);
    [gCache removeAllObjects];
    [gCacheOrder removeAllObjects];
    [gMissing removeAllObjects];   // a previous miss no longer means anything
    [gStatus removeAllObjects];
    pthread_mutex_unlock(&gCacheMutex);
    gTrackKey = nil;   // force the next ingest to look everything up again
}

#pragma mark - Virtual playback clock

// Players only report progress on play, pause and seek, so the position in
// between has to be extrapolated.
NSTimeInterval NLEnginePosition(void) {
    if (gRate <= 0) return gAnchorElapsed;
    return gAnchorElapsed + (CACurrentMediaTime() - gAnchorHost) * gRate;
}

#pragma mark - Composing

static void NLScheduleFlip(NSTimeInterval delay) {
    uint64_t generation = ++gFlipGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(MAX(delay, 0.05) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (generation != gFlipGeneration) return;   // superseded by a newer schedule
        NLEnginePushUpdate();
    });
}

void NLEngineCancelFlip(void) {
    gFlipGeneration++;
}

// Lines are sorted, so binary search for the last one at or before the position.
static NLLyricLine *NLLineAt(NSArray<NLLyricLine *> *lines, NSTimeInterval position,
                             NSTimeInterval *nextStart, NSString **nextText) {
    NSTimeInterval cutoff = position + kNLMargin;
    NSUInteger lo = 0, hi = lines.count;
    while (lo < hi) {
        NSUInteger mid = lo + (hi - lo) / 2;
        if (lines[mid].start <= cutoff) lo = mid + 1;
        else hi = mid;
    }
    // lo is now the first line after the cutoff.
    *nextStart = (lo < lines.count) ? lines[lo].start : -1;

    // Skip the blank entries that mark interludes; the next thing actually
    // sung is what is worth previewing.
    *nextText = nil;
    for (NSUInteger i = lo; i < lines.count; i++) {
        if (lines[i].text.length) { *nextText = lines[i].text; break; }
    }
    return (lo > 0) ? lines[lo - 1] : nil;
}

typedef NS_ENUM(NSInteger, NLShow) {
    NLShowNothing = 0,   // no lyrics and nothing to report: leave the app alone
    NLShowStatus,        // no lyrics, but a diagnostics readout for the artist field
    NLShowLyrics,        // a line, or the track title during a gap
};

// Works out what the title and artist fields should say right now; nil means
// "whatever the player set". The lookup position, the line being sung and the
// start of the next one come back too, so the caller can schedule the flip.
static NLShow NLCompose(NLSettings *s, NSString **outTitle, NSString **outArtist,
                        NSTimeInterval *outLookup, NSTimeInterval *outNextStart,
                        NLLyricLine **outLine) {
    *outTitle = nil;
    *outArtist = nil;
    *outNextStart = -1;
    *outLine = nil;

    // The offset only changes which line is shown. Adding it to the reported
    // elapsed time would skew the lock screen progress bar.
    *outLookup = MAX(NLEnginePosition(), 0) + s.offset;

    NSArray<NLLyricLine *> *lines = NLCachedLines(gTrackKey);

    // Diagnostics turn the artist field into a readout of which source answered,
    // so "did the API connect" is visible on the lock screen without log tools.
    // With no lyrics at all it is the only thing we have to say, so say it.
    if (lines.count == 0) {
        NSString *status = s.diagnostics ? NLStatusForKey(gTrackKey) : nil;
        if (status.length == 0) return NLShowNothing;
        *outArtist = [NSString stringWithFormat:@"NowLyrics: %@", status];
        return NLShowStatus;
    }

    NSString *nextText = nil;
    NLLyricLine *current = NLLineAt(lines, *outLookup, outNextStart, &nextText);
    NSString *line = current.text;
    *outLine = current;

    // Intros and instrumental breaks are empty lines; show the track title there.
    NSString *display = line.length ? line : gTrackTitle;
    if (display.length == 0) return NLShowLyrics;
    *outTitle = display;

    NSString *trackCredit = gTrackArtist.length
        ? [NSString stringWithFormat:@"%@ — %@", gTrackTitle ?: @"", gTrackArtist]
        : (gTrackTitle ?: @"");

    NSString *credit = nil;
    if (line.length) {
        if (s.artistMode == NLArtistModeNextLine) {
            // Falls back to the track credit at the end of the song, so the
            // field never just goes blank.
            credit = nextText.length ? nextText : trackCredit;
        } else if (s.artistMode == NLArtistModeTitle) {
            credit = trackCredit;
        }
    }

    if (s.diagnostics) {
        NSString *status = NLStatusForKey(gTrackKey);
        // Where the chorus detection thinks we are; ▶ marks the moment a chorus begins.
        if (current.chorus) {
            NSString *mark = current.chorusStart ? @"♪ chorus ▶" : @"♪ chorus";
            status = status.length ? [status stringByAppendingFormat:@"  ·  %@", mark] : mark;
        }
        if (status.length) {
            credit = credit.length ? [credit stringByAppendingFormat:@"  ·  %@", status] : status;
        }
    }

    if (credit.length) *outArtist = credit;
    return NLShowLyrics;
}

// The moment a chorus begins, tell SpringBoard so the Dynamic Island can bounce;
// whether it does is NowLyricsIsland's call. Pauses, seeks and redraws land on
// the same line again, so each start is announced once, and only while it is
// actually being sung, not when playback is dropped into the middle of it.
static void NLCueChorus(NLLyricLine *line, NSTimeInterval lookup) {
    if (!line.chorusStart || line == gLastCue) return;
    if (lookup - line.start > kNLCueWindow) return;
    gLastCue = line;
    NLLog(@"chorus cue @ %.1f", line.start);
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kNLChorusNotification, NULL, NULL, true);
}

void NLEnginePushUpdate(void) {
    NLSettings *s = NLSettingsCurrent();
    if (!s.enabled) {
        NLPublishRestore();
        return;
    }

    NSString *title = nil, *artist = nil;
    NSTimeInterval lookup = 0, nextStart = -1;
    NLLyricLine *current = nil;
    NLShow show = NLCompose(s, &title, &artist, &lookup, &nextStart, &current);
    if (show == NLShowNothing) return;

    NLPublish(title, artist);

    if (show == NLShowLyrics && gRate > 0) {
        NLCueChorus(current, lookup);
        NSTimeInterval delay = (nextStart > lookup) ? (nextStart - lookup) / gRate : 1.0;
        NLScheduleFlip(MIN(delay, kNLMaxFlipDelay));
    }
}

#pragma mark - Fetching

static void NLRequestLyrics(NSString *key, NSString *title, NSString *artist,
                            NSString *album, NSTimeInterval duration) {
    if (key.length == 0 || title.length == 0) return;

    pthread_mutex_lock(&gCacheMutex);
    BOOL skip = (gCache[key] != nil) || [gPending containsObject:key] || [gMissing containsObject:key];
    if (!skip) [gPending addObject:key];
    pthread_mutex_unlock(&gCacheMutex);
    if (skip) {
        dispatch_async(dispatch_get_main_queue(), ^{ NLEnginePushUpdate(); });
        return;
    }

    // Taken here, on the main queue: a reload swaps the settings object rather
    // than mutating it, so the fetch keeps a consistent view.
    NLSettings *settings = NLSettingsCurrent();

    dispatch_async(gFetchQueue, ^{
        NSArray<NLLyricLine *> *lines = nil;
        NSString *source = @"error";
        BOOL transient = NO;
        // An exception on this queue has no handler and terminates the host app.
        // Missing lyrics is a small problem; taking the player down is not.
        @try {
            lines = NLResolveLyrics(settings, key, title, artist, album, duration, &source, &transient);
        } @catch (NSException *e) {
            NLLog(@"exception while resolving lyrics: %@ — %@", e.name, e.reason);
            lines = nil;
        }
        NLLog(@"%@ → %lu lines (%@)", key, (unsigned long)lines.count, source);

        // Before the lines go into the shared cache, while nothing else can see them.
        NLMarkChorus(lines);
        for (NLLyricLine *line in lines) {
            if (line.chorusStart) NLLog(@"chorus start @ %.1f: %@", line.start, line.text);
        }

        NSString *status = transient ? [source stringByAppendingString:@" (will retry)"] : (source ?: @"unknown");
        NLStoreResult(key, lines, status, transient);

        // Even a total miss needs a push when diagnostics are on, so the reason
        // can be shown instead of silently doing nothing.
        dispatch_async(dispatch_get_main_queue(), ^{ NLEnginePushUpdate(); });
    });
}

#pragma mark - Ingest

void NLEngineIngest(NSString *title, NSString *artist, NSString *album,
                    NSTimeInterval duration, NSNumber *elapsed, NSNumber *rate) {
    // Advance the clock with the old rate before adopting the new anchor.
    NSTimeInterval carried = NLEnginePosition();
    gAnchorElapsed = elapsed ? elapsed.doubleValue : carried;
    if (rate) gRate = rate.doubleValue;
    gAnchorHost = CACurrentMediaTime();

    NSString *key = NLTrackKey(title, artist);
    if (![key isEqualToString:gTrackKey]) {
        gTrackKey = key;
        gTrackTitle = title;
        gTrackArtist = artist;
        gTrackRequested = NO;
        gFlipGeneration++;   // cancel any flip still queued for the previous track
    }

    // Players sometimes publish a track before they know its length, and the
    // length is what keeps a cover or a live take from being accepted. Wait for it.
    if (!gTrackRequested && duration > 0) {
        gTrackRequested = YES;
        NLRequestLyrics(key, title, artist, album, duration);
        return;
    }

    NLEnginePushUpdate();
}
