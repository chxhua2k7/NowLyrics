//
//  NLEngine.m
//  Track state, the virtual playback clock, line lookup, the flip timer and the
//  fetch queue. Knows nothing about how the app publishes: it hands the
//  composed strings to NLPublish() in NowLyrics.xm.
//

#import "NowLyrics.h"
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <pthread.h>

static const NSTimeInterval kNLMaxFlipDelay = 8.0;   // cap on timer sleep
static const NSTimeInterval kNLMaxLead = 3.0;        // cap on how far ahead of its sound an app's count is taken to be
static const NSUInteger kNLMemoryCacheLimit = 64;    // parsed tracks kept in memory; the disk has the rest

// Lyrics cache. Touched from both the fetch queue and the main queue.
static NSMutableDictionary<NSString *, NSArray<NLLyricLine *> *> *gCache = nil;
static NSMutableArray<NSString *> *gCacheOrder = nil;                 // insertion order, for eviction
static NSMutableSet<NSString *> *gPending = nil;
static NSMutableSet<NSString *> *gMissing = nil;                      // known misses, so we stop asking
static NSMutableDictionary<NSString *, NSString *> *gStatus = nil;    // which source answered, for diagnostics
static NSMutableDictionary<NSString *, NSString *> *gPaths = nil;     // the file each track's lyrics are in
// Moved on by NLEngineForgetLyrics. A fetch queued before then looked its
// track up with settings or files that no longer hold, so what it finds is
// thrown away instead of landing on the state cleared for the fetch queued
// after it.
static NSUInteger gGeneration = 0;
static pthread_mutex_t gCacheMutex = PTHREAD_MUTEX_INITIALIZER;
static dispatch_queue_t gFetchQueue = nil;

// Playback state. Main queue only, no locking.
static NSString *gTrackKey = nil;
static NSString *gTrackTitle = nil;
static NSString *gTrackArtist = nil;
static NSString *gTrackAlbum = nil;
static NSTimeInterval gTrackDuration = 0;   // 0 until the player reports it
static CFAbsoluteTime gTrackStarted = 0;     // when the player first reported the current track
static BOOL gTrackRequested = NO;           // lyrics were asked for, which needs the duration
static NSTimeInterval gAnchorElapsed = 0;   // virtual clock anchor
static CFTimeInterval gAnchorHost = 0;
static double gRate = 0;
static NSTimeInterval gOutputDelay = 0;     // the app's audio is heard this long after the position it reports
static NSTimeInterval gLead = 0;            // the app's count is this far ahead of its audio, until it reads it off again
static dispatch_source_t gFlipTimer = nil;  // one timer, re-armed for every line
static dispatch_queue_t gWriteQueue = nil;  // nowplaying.plist, kept off the fetch queue, which can be busy for seconds
static NSDictionary *gWrittenNowPlaying = nil;   // what was last written, without its date

void NLEngineStart(void) {
    gCache = [NSMutableDictionary dictionary];
    gCacheOrder = [NSMutableArray array];
    gPending = [NSMutableSet set];
    gMissing = [NSMutableSet set];
    gStatus = [NSMutableDictionary dictionary];
    gPaths = [NSMutableDictionary dictionary];
    gWriteQueue = dispatch_queue_create("app.nowlyrics.nowplaying", DISPATCH_QUEUE_SERIAL);
    gFetchQueue = dispatch_queue_create("app.nowlyrics.fetch", DISPATCH_QUEUE_SERIAL);
    dispatch_async(gFetchQueue, ^{ NLClearOldCache(NLCacheDir()); });   // first: no fetch reads the cache before it
    gFlipTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(gFlipTimer, ^{ NLEnginePushUpdate(); });
    NLEngineCancelFlip();   // armed per line by NLScheduleFlip
    dispatch_resume(gFlipTimer);
}

void NLEngineClearCacheLater(NSTimeInterval requestedAt) {
    if (requestedAt <= 0) return;
    // Serial queue: done before any fetch queued after it reads the disk cache.
    dispatch_async(gFetchQueue, ^{ NLClearCacheIfRequested(requestedAt); });
}

NSString *NLEngineTrackTitle(void) { return gTrackTitle; }
NSString *NLEngineTrackArtist(void) { return gTrackArtist; }

#pragma mark - Cache

static id NLLockedGet(NSDictionary *dict, NSString *key) {
    if (key.length == 0) return nil;
    pthread_mutex_lock(&gCacheMutex);
    id value = dict[key];
    pthread_mutex_unlock(&gCacheMutex);
    return value;
}

static NSArray<NLLyricLine *> *NLCachedLines(NSString *key) { return NLLockedGet(gCache, key); }
static NSString *NLStatusForKey(NSString *key) { return NLLockedGet(gStatus, key); }

static BOOL NLGenerationIsCurrent(NSUInteger generation) {
    pthread_mutex_lock(&gCacheMutex);
    BOOL current = (generation == gGeneration);
    pthread_mutex_unlock(&gCacheMutex);
    return current;
}

// A miss is only remembered when every source actually answered. If a request
// timed out, the next play of the same track gets another attempt instead of
// being written off for the rest of the session. A fetch from an earlier
// generation stores nothing, its key's pending mark included (that belongs to
// the fetch queued after it), and gets NO.
static BOOL NLStoreResult(NSString *key, NSArray<NLLyricLine *> *lines, NSString *status, NSString *path, BOOL transient,
                          NSUInteger generation) {
    pthread_mutex_lock(&gCacheMutex);
    if (generation != gGeneration) {
        pthread_mutex_unlock(&gCacheMutex);
        return NO;
    }
    gStatus[key] = status;
    gPaths[key] = path;   // nil removes it
    if (lines.count) {
        [gMissing removeObject:key];   // found after all: no longer a miss
        if (!gCache[key]) [gCacheOrder addObject:key];
        gCache[key] = lines;
        // Bounded: a long session otherwise keeps every track it ever parsed.
        // Anything evicted is still on disk and comes back in a few milliseconds.
        while (gCacheOrder.count > kNLMemoryCacheLimit) {
            NSString *oldest = gCacheOrder.firstObject;
            [gCacheOrder removeObjectAtIndex:0];
            [gCache removeObjectForKey:oldest];
            [gStatus removeObjectForKey:oldest];
            [gPaths removeObjectForKey:oldest];
        }
    } else if (!transient) {
        [gMissing addObject:key];
    }
    [gPending removeObject:key];
    pthread_mutex_unlock(&gCacheMutex);
    return YES;
}

#pragma mark - Virtual playback clock

// Players only report progress on play, pause and seek, so the position in
// between has to be extrapolated. This is the position as the app counts it.
static NSTimeInterval NLClockPosition(void) {
    if (gRate <= 0) return gAnchorElapsed;
    return gAnchorElapsed + (CACurrentMediaTime() - gAnchorHost) * gRate;
}
// What is heard now: the app's count less how far it has run ahead of its
// audio, as it stood gOutputDelay ago. Below 0 while a track announced early is
// not sounding yet, which is what the next line's timing has to go by.
static NSTimeInterval NLHeardPosition(void) { return NLClockPosition() - gLead - gOutputDelay * MAX(gRate, 0); }
// What everyone outside the clock reads. Lines, word timing (through what is
// pushed to the system) and the scrubber all go by it.
NSTimeInterval NLEnginePosition(void) { return MAX(NLHeardPosition(), 0); }

void NLEngineSetOutputDelay(NSTimeInterval delay) { gOutputDelay = delay; }

void NLEngineAddLead(NSTimeInterval seconds) {
    if (gRate > 0) gLead = MIN(MAX(gLead + seconds, 0), kNLMaxLead);
}

BOOL NLEngineNearEnd(NSTimeInterval within) {
    if (gRate <= 0 || gTrackDuration <= 0) return NO;
    NSTimeInterval left = gTrackDuration - NLClockPosition();
    return left >= -2 && left <= within;
}

#pragma mark - Composing

// Re-arming replaces whatever was scheduled, so a superseded flip never fires.
static void NLScheduleFlip(NSTimeInterval delay) {
    dispatch_source_set_timer(gFlipTimer, NLTimeIn(MAX(delay, 0.05)), DISPATCH_TIME_FOREVER, 10 * NSEC_PER_MSEC);
}

void NLEngineCancelFlip(void) {
    dispatch_source_set_timer(gFlipTimer, DISPATCH_TIME_FOREVER, DISPATCH_TIME_FOREVER, 0);
}

// Chorus marks are only ever shown in the diagnostics readout, so they are
// worked out the first time a track's lines are shown with it on.
static void NLEnsureChorus(NSArray<NLLyricLine *> *lines) {
    static char kMarked;
    if (objc_getAssociatedObject(lines, &kMarked)) return;
    objc_setAssociatedObject(lines, &kMarked, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    NLMarkChorus(lines);
#if DEBUG
    for (NLLyricLine *line in lines) {
        if (line.chorusStart) NLLog(@"chorus start @ %.1f: %@", line.start, line.text);
    }
#endif
}

// Lines are sorted: the last one at or before the position is the one before
// the first still to come (NLLinesStartedBy).
static NLLyricLine *NLLineAt(NSArray<NLLyricLine *> *lines, NSTimeInterval position,
                             NSTimeInterval *nextStart, NSString **nextText) {
    NSUInteger lo = NLLinesStartedBy(lines, position);   // the first line after the cutoff
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
// "whatever the player set". The lookup position and the start of the next
// line come back too, so the caller can schedule the flip.
static NLShow NLCompose(NLSettings *s, NSString **outTitle, NSString **outArtist,
                        NSTimeInterval *outLookup, NSTimeInterval *outNextStart) {
    *outTitle = nil;
    *outArtist = nil;
    *outNextStart = -1;

    // The offset only changes which line is shown. Adding it to the reported
    // elapsed time would skew the lock screen progress bar.
    *outLookup = NLHeardPosition() + [s offsetForTrack:gTrackKey];

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

    // Intros and instrumental breaks are empty lines; show the track title there.
    NSString *display = line.length ? line : gTrackTitle;
    if (display.length == 0) return NLShowLyrics;
    *outTitle = display;

    NSString *credit = nil;
    if (line.length && s.artistMode != NLArtistModeNone) {
        if (s.artistMode == NLArtistModeNextLine && nextText.length) {
            credit = nextText;
        } else {
            // Next-line mode falls back to this at the end of the song, so the
            // field never just goes blank.
            credit = gTrackArtist.length
                ? [NSString stringWithFormat:@"%@ — %@", gTrackTitle ?: @"", gTrackArtist]
                : (gTrackTitle ?: @"");
        }
    }

    if (s.diagnostics) {
        NLEnsureChorus(lines);
        NSString *status = NLStatusForKey(gTrackKey);
        // Where the chorus detection thinks we are; ▶ marks the moment a chorus begins.
        if (current.chorus) {
            NSString *mark = current.chorusStart ? @"♪ chorus ▶" : @"♪ chorus";
            status = NLJoinNonEmpty(status, mark, @"  ·  ");
        }
        credit = NLJoinNonEmpty(credit, status, @"  ·  ");
    }

    if (credit.length) *outArtist = credit;
    return NLShowLyrics;
}

void NLEnginePushUpdate(void) {
    NLSettings *s = NLSettingsCurrent();
    if (!s.enabled) {
        NLPublishRestore();
        return;
    }

    NSString *title = nil, *artist = nil;
    NSTimeInterval lookup = 0, nextStart = -1;
    NLShow show = NLCompose(s, &title, &artist, &lookup, &nextStart);
    if (show == NLShowNothing) return;

    NLPublish(title, artist);

    // The next line switches NL_LINE_MARGIN ahead of its start (a millisecond
    // later, so the lookup then is past it however the clock rounds). After the
    // last line nothing changes until the player reports something, which
    // comes back through an ingest.
    if (show == NLShowLyrics && gRate > 0 && nextStart > lookup) {
        NLScheduleFlip(MIN((nextStart - NL_LINE_MARGIN - lookup) / gRate + 0.001, kNLMaxFlipDelay));
    }
}

#pragma mark - nowplaying.plist

// What the settings page and the island read to learn the real track (the
// now-playing title is a lyric line) and the lyrics file behind it. Written
// when the current track's lyrics are asked for and again when they are in.
// Main queue.
static void NLWriteNowPlaying(void) {
    NSString *key = gTrackKey;
    if (key.length == 0) return;
    pthread_mutex_lock(&gCacheMutex);
    NSString *status = gStatus[key];
    NSString *path = gPaths[key];
    NSArray<NLLyricLine *> *lines = gCache[key];
    pthread_mutex_unlock(&gCacheMutex);
    BOOL words = NLHasWords(lines);   // outside the lock: cached arrays are never changed

    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[NL_NP_KEY] = key;
    info[NL_NP_TITLE] = gTrackTitle ?: @"";
    info[NL_NP_ARTIST] = gTrackArtist ?: @"";
    info[NL_NP_DURATION] = @(gTrackDuration);
    info[NL_NP_STATUS] = status;   // nil leaves it out
    info[NL_NP_PATH] = path;
    info[NL_NP_WORDS] = @(words);
    info[NL_NP_STARTED] = @(gTrackStarted);
    if ([info isEqualToDictionary:gWrittenNowPlaying]) return;
    gWrittenNowPlaying = [info copy];

    info[NL_NP_UPDATED] = [NSDate date];
    info[NL_NP_STAMP] = @(CFAbsoluteTimeGetCurrent());   // to the fraction, which the date is not once written
    dispatch_async(gWriteQueue, ^{ [info writeToFile:NLNowPlayingPath() atomically:YES]; });
}

#pragma mark - Fetching

static void NLRequestLyrics(NSString *key, NSString *title, NSString *artist,
                            NSString *album, NSTimeInterval duration) {
    if (key.length == 0 || title.length == 0) return;

    pthread_mutex_lock(&gCacheMutex);
    BOOL skip = (gCache[key] != nil) || [gPending containsObject:key] || [gMissing containsObject:key];
    if (!skip) [gPending addObject:key];
    NSUInteger generation = gGeneration;
    pthread_mutex_unlock(&gCacheMutex);
    NLWriteNowPlaying();   // searching: no status yet (or what is known already)
    if (skip) {
        NLEnginePushUpdate();
        return;
    }

    // Taken here, on the main queue: a reload swaps the settings object rather
    // than mutating it, so the fetch keeps a consistent view.
    NLSettings *settings = NLSettingsCurrent();

    dispatch_async(gFetchQueue, ^{
        NSArray<NLLyricLine *> *lines = nil;
        NSString *source = @"error";
        NSString *path = nil;
        BOOL transient = NO;
        // An exception on this queue has no handler and terminates the host app.
        // Missing lyrics is a small problem; taking the player down is not.
        @try {
            lines = NLResolveLyrics(settings, key, title, artist, album, duration, &source, &path, &transient,
                                    ^BOOL{ return !NLGenerationIsCurrent(generation); });
        } @catch (NSException *e) {
            NLLog(@"exception while resolving lyrics: %@ — %@", e.name, e.reason);
        }
        NLLog(@"%@ → %lu lines (%@)", key, (unsigned long)lines.count, source);

        NSString *status = transient ? [source stringByAppendingString:NL_STATUS_RETRY_SUFFIX] : source;
        // Thrown away: nothing changed, and the fetch that replaced it shows its own.
        if (!NLStoreResult(key, lines, status, lines.count ? path : nil, transient, generation)) return;

        // Even a total miss needs a push when diagnostics are on, so the reason
        // can be shown instead of silently doing nothing.
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([key isEqualToString:gTrackKey]) NLWriteNowPlaying();
            NLEnginePushUpdate();
        });
    });
}

void NLEngineForgetLyrics(void) {
    pthread_mutex_lock(&gCacheMutex);
    [gCache removeAllObjects];
    [gCacheOrder removeAllObjects];
    [gMissing removeAllObjects];   // a previous miss no longer means anything
    [gStatus removeAllObjects];
    [gPaths removeAllObjects];
    [gPending removeAllObjects];   // a fetch still running used the old sources...
    gGeneration++;                 // ...and its result is thrown away when it is in
    pthread_mutex_unlock(&gCacheMutex);

    // Look the current track up again now rather than at the player's next
    // update, which for some apps is the next track. Switched off, the next
    // ingest after switching on does it.
    gTrackRequested = gTrackKey && gTrackDuration > 0 && NLSettingsCurrent().enabled;
    if (gTrackRequested) NLRequestLyrics(gTrackKey, gTrackTitle, gTrackArtist, gTrackAlbum, gTrackDuration);
}

#pragma mark - Ingest

void NLEngineIngest(NSString *title, NSString *artist, NSString *album,
                    NSTimeInterval duration, NSNumber *elapsed, NSNumber *rate, NSTimeInterval lead) {
    // Advance the clock with the old rate before adopting the new anchor (gRate changes below).
    NSTimeInterval counted = NLClockPosition();
    gAnchorElapsed = elapsed ? elapsed.doubleValue : counted;
    BOOL rateChanged = rate && rate.doubleValue != gRate;
    if (rate) gRate = rate.doubleValue;
    gAnchorHost = CACurrentMediaTime();

    // Most updates are progress on the same track: compare before building a key.
    BOOL sameTrack = gTrackKey && [title ?: @"" isEqualToString:gTrackTitle ?: @""] &&
                     [artist ?: @"" isEqualToString:gTrackArtist ?: @""];

    // A lead holds while the app goes on with its own count. A pause, a resume,
    // a seek and a new track are read off its audio, so they end it; a step
    // back by part of it is the app catching up that much, and what is heard
    // does not move.
    if (gLead > 0) {
        NSTimeInterval step = elapsed ? elapsed.doubleValue - counted : 0;
        if (!sameTrack || rateChanged || step > 0.15 || step < -(gLead + 0.3)) gLead = 0;
        else if (step < -0.15) gLead = MAX(gLead + step, 0);
    }
    if (lead > 0 && gRate > 0) gLead = MIN(lead, kNLMaxLead);
    if (!sameTrack) {
        gTrackKey = NLTrackKey(title, artist);
        gTrackTitle = title;
        gTrackArtist = artist;
        gTrackAlbum = nil;
        gTrackDuration = 0;
        gTrackStarted = CFAbsoluteTimeGetCurrent();
        gTrackRequested = NO;
        NLEngineCancelFlip();   // whatever was queued belonged to the previous track
    }
    // Kept for the lookup below and for NLEngineForgetLyrics(), which has to
    // look the track up again: not every update repeats the album.
    if (album) gTrackAlbum = album;
    if (duration > 0) gTrackDuration = duration;

    // Players sometimes publish a track before they know its length, and the
    // length is what keeps a cover or a live take from being accepted. Wait for it.
    if (!gTrackRequested && duration > 0) {
        gTrackRequested = YES;
        NLRequestLyrics(gTrackKey, title, artist, gTrackAlbum, duration);
        return;
    }

    NLEnginePushUpdate();
}
