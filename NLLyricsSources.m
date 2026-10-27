//
//  NLLyricsSources.m
//  See NLLyricsSources.h.
//

#import "NLLyricsSources.h"
#import "NowLyrics.h"

NSDictionary *NLReadPrefsNow(void) {
    CFStringRef domain = (__bridge CFStringRef)NL_PREFS_DOMAIN;
    CFPreferencesAppSynchronize(domain);
    return CFBridgingRelease(CFPreferencesCopyMultiple(NULL, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)) ?: @{};
}

void NLWritePrefQuietly(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, (__bridge CFStringRef)NL_PREFS_DOMAIN);
    CFPreferencesAppSynchronize((__bridge CFStringRef)NL_PREFS_DOMAIN);
}

static BOOL NLSourceOn(NSDictionary *prefs, NSString *name, NSString *bundleID) {
    if ([name isEqualToString:@"applemusic"]) {
        if (@available(iOS 16.0, *)) {
            return NLLooseBool(prefs[@"appleMusicVerified"], NO) && NLLooseBool(prefs[@"useAppleMusic"], NO) &&
                   ([bundleID isEqualToString:@"com.apple.Music"] || NLLooseBool(prefs[@"appleMusicOtherApps"], YES));
        }
        return NO;
    }
    if ([name isEqualToString:@"musixmatch"]) {
        return NLLooseBool(prefs[@"useMusixmatch"], NO) && NLMusixmatchHasCredentials(prefs[@"musixmatchToken"], prefs[@"musixmatchKey"]);
    }
    if ([name isEqualToString:@"lrclib"]) return NLLooseBool(prefs[@"useLRCLIB"], YES);
    if ([name isEqualToString:@"netease"]) return NLLooseBool(prefs[@"useNetease"], YES);
    return NO;
}

NSArray<NSString *> *NLOfferedSources(NSDictionary *prefs, NSString *bundleID, NSDictionary *np) {
    if (NLString(np, NL_NP_KEY).length == 0) return @[];
    NSMutableArray<NSString *> *sources = [NSMutableArray arrayWithObject:@""];
    for (NSString *name in NLSourceNamesInOrder()) {
        if (NLSourceOn(prefs, name, bundleID)) [sources addObject:name];
    }
    [sources addObject:NL_TRACK_SOURCE_OFF];   // last: none for this song
    return sources;
}

NSString *NLPickedSource(NSDictionary *prefs, NSDictionary *np) {
    return NLString(NLValue(prefs, NL_TRACK_SOURCES_KEY), NLString(np, NL_NP_KEY) ?: @"") ?: @"";
}

NSString *NLSourceTitleKey(NSString *name) {
    NSDictionary *titles = NL_ONCE((@{@"": @"Automatic", @"applemusic": @"Apple Music", @"musixmatch": @"Musixmatch",
                                      @"lrclib": @"LRCLIB", @"netease": @"NetEase Music", NL_TRACK_SOURCE_OFF: @"Off for This Song"}));
    return titles[name] ?: name;
}

NSString *NLSourceSymbolName(NSString *name) {
    NSDictionary *symbols = NL_ONCE((@{@"": @"list.number", @"applemusic": @"music.note", @"musixmatch": @"sparkles",
                                       @"lrclib": @"globe", @"netease": @"cloud", NL_TRACK_SOURCE_OFF: @"nosign"}));
    return symbols[name];
}

NSString *NLLyricsStatusText(NSDictionary *np, BOOL asked, NSString *(^localized)(NSString *key)) {
    NSString *status = NLString(np, NL_NP_STATUS);
    NSString *path = NLString(np, NL_NP_PATH);
    NSString *text;
    if (NLIsManualLyricsPath(path)) {
        text = localized(@"Added by you");
    } else if (asked || !status) {
        return localized(@"Searching…");
    } else if ([status isEqualToString:NL_STATUS_OFF]) {
        return localized(@"Off for This Song");
    } else if (path) {
        NSString *from = NLStatusSource(status);
        text = [status hasPrefix:NL_STATUS_CACHE]
            ? ([from isEqualToString:NL_STATUS_CACHE] ? localized(@"Saved") : [NSString stringWithFormat:@"%@ · %@", localized(@"Saved"), from])
            : from;
    } else {
        text = localized(@"No lyrics found");
    }
    if (NLPrefBool(np, NL_NP_WORDS, NO)) text = [text stringByAppendingFormat:@" · %@", localized(@"Word by word")];
    return text;
}

CFAbsoluteTime NLPickSourceForSong(NSDictionary **prefs, NSString *bundleID, NSDictionary *np, NSString *name) {
    NSString *key = NLString(np, NL_NP_KEY);
    if (key.length == 0) return 0;
    NSDictionary *sources = NLTrackEntries(NLValue(*prefs, NL_TRACK_SOURCES_KEY), key, name.length ? name : nil);
    NLWritePrefQuietly(NL_TRACK_SOURCES_KEY, sources);
    NSMutableDictionary *now = [*prefs mutableCopy] ?: [NSMutableDictionary dictionary];
    now[NL_TRACK_SOURCES_KEY] = sources;
    *prefs = now;
    return NLLookUpAgain(bundleID, np, name);
}

@implementation NLSungLines
@end

NLSungLines *NLSungLinesNow(NSDictionary *np, NSDictionary *info, NSDictionary *prefs, NSUInteger nextCount) {
    NSString *path = NLString(np, NL_NP_PATH);
    NSString *shown = NLInfoTitle(info);
    if (!path || !shown.length) return nil;
    BOOL between = [shown isEqualToString:NLString(np, NL_NP_TITLE)];
    NLSungLines *sung = [NLSungLines new];
    sung.line = between ? nil : shown;
    sung.index = -1;
    NSArray<NLLyricLine *> *lines = NLParseLRCFile(path);
    sung.lines = lines;
    if (!lines.count) return sung;
    double rate = NLPrefNum(info, NL_MR_RATE, 0);
    NSDate *stamp = info[NL_MR_TIMESTAMP];
    double position = NLPrefNum(info, NL_MR_ELAPSED, 0) + ([stamp isKindOfClass:NSDate.class] ? -stamp.timeIntervalSinceNow * rate : 0) +
                      NLOffsetForTrack(prefs, NLString(np, NL_NP_KEY));
    NSInteger at = (NSInteger)NLLinesStartedBy(lines, position) - 1, found = NSNotFound;
    sung.position = position;
    sung.rate = rate;
    if (between) {
        NSInteger last = MIN(at, (NSInteger)lines.count - 1);
        sung.index = last;
        for (NSInteger i = last; i >= 0 && !sung.previous; i--) {
            if (lines[i].text.length) sung.previous = lines[i].text;
        }
        NSMutableArray<NSString *> *next = [NSMutableArray array];
        for (NSInteger i = MAX(last + 1, 0); i < (NSInteger)lines.count && next.count < nextCount; i++) {
            if (lines[i].text.length) [next addObject:lines[i].text];
        }
        sung.next = next;
        return sung;
    }
    NSInteger candidates[] = {at, at - 1, at + 1};
    for (int k = 0; k < 3 && found == NSNotFound; k++) {
        NSInteger i = candidates[k];
        if (i >= 0 && i < (NSInteger)lines.count && [lines[i].text isEqualToString:shown]) found = i;
    }
    if (found == NSNotFound) {
        found = (NSInteger)[lines indexOfObjectPassingTest:^BOOL(NLLyricLine *candidate, NSUInteger i, BOOL *stop) {
            return [candidate.text isEqualToString:shown];
        }];
    }
    if (found == NSNotFound) return sung;
    sung.index = found;
    NSArray<NLLyricWord *> *timed = lines[found].words;
    if (timed.count) {
        NSMutableArray *texts = [NSMutableArray array], *starts = [NSMutableArray array], *ends = [NSMutableArray array];
        for (NLLyricWord *word in timed) {
            [texts addObject:word.text];
            [starts addObject:@(word.start)];
            [ends addObject:@(word.end)];
        }
        NLShownWords *words = [NLShownWords new];
        words.texts = texts;
        words.starts = starts;
        words.ends = ends;
        words.position = position;
        words.rate = rate;
        sung.words = words;
    }
    for (NSInteger i = found - 1; i >= 0; i--) {
        if (lines[i].text.length) {
            sung.previous = lines[i].text;
            break;
        }
    }
    NSMutableArray<NSString *> *next = [NSMutableArray array];
    for (NSInteger i = found + 1; i < (NSInteger)lines.count && next.count < nextCount; i++) {
        if (lines[i].text.length) [next addObject:lines[i].text];
    }
    sung.next = next;
    return sung;
}
