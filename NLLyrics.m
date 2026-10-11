//
//  NLLyrics.m
//  LRC parsing and serialisation, title cleaning, and the files on disk (the
//  cache and manual overrides). No networking and no playback state.
//

#import "NowLyrics.h"
@implementation NLLyricWord
+ (instancetype)wordAt:(NSTimeInterval)start end:(NSTimeInterval)end text:(NSString *)text {
    NLLyricWord *word = [self new];
    word.start = start;
    word.end = end;
    word.text = text;
    return word;
}
@end

@implementation NLLyricLine
+ (instancetype)lineAt:(NSTimeInterval)start text:(NSString *)text {
    NLLyricLine *line = [self new];
    line.start = start;
    line.text = text;
    return line;
}
@end

#pragma mark - Paths

// Library/NowLyrics, without creating it.
NSString *NLCacheDir(void) {
    return NL_ONCE([NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject
                    stringByAppendingPathComponent:NL_FOLDER_NAME]);
}

// The same, created on first use together with manual/, so that folder is
// discoverable without having to guess its name.
static NSString *NLRootPath(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:[NLCacheDir() stringByAppendingPathComponent:NL_MANUAL_FOLDER]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return NLCacheDir();
}

static NSString *NLSanitizeFilename(NSString *name) {
    NSCharacterSet *illegal = NL_ONCE([NSCharacterSet characterSetWithCharactersInString:@"/\\:?*\"<>|"]);
    return [[name componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@""];
}

// Title and artist only. Players report the length of the same track a second
// or two apart from one play to the next, and Spotify sometimes reports 0 for a
// moment; keying on it made those look like new tracks. The length still
// decides whether a catalogue hit is accepted, it just no longer names the track.
NSString *NLTrackKey(NSString *title, NSString *artist) {
    return [NSString stringWithFormat:@"%@|%@", title ?: @"", artist ?: @""];
}

// Readable name plus a djb2 suffix, so cached files can be found and hand-edited.
NSString *NLCachePath(NSString *key) {
    unsigned long long h = 5381;
    const char *c = key.UTF8String;
    while (*c) { h = ((h << 5) + h) ^ (unsigned char)(*c); c++; }

    NSString *safe = NLSanitizeFilename(key);
    if (safe.length > 80) safe = [safe substringToIndex:80];

    return [NLRootPath() stringByAppendingPathComponent:
            [NSString stringWithFormat:@"%@_%llx.lrc", safe, h]];
}

NSString *NLNowPlayingPath(void) {
    return [NLRootPath() stringByAppendingPathComponent:NL_NOWPLAYING_FILE];
}

#pragma mark - Housekeeping

// The cached .lrc files with their modification dates, read in the same
// directory listing rather than one file at a time. manual/ is a directory and
// never matches.
static NSArray<NSURL *> *NLCachedFiles(NSString *root) {
    NSArray<NSURL *> *all = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:[NSURL fileURLWithPath:root isDirectory:YES]
                                                          includingPropertiesForKeys:@[NSURLContentModificationDateKey]
                                                                             options:0
                                                                               error:nil];
    return [all filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSURL *url, NSDictionary *bindings) {
        return [url.pathExtension isEqualToString:@"lrc"];
    }]];
}

// "Clear lyrics cache" on the settings page records the time of the tap in the
// preference file. Comparing that with each file's date, rather than keeping a
// marker, means an app that was not running at the time still clears the right
// files when it is next launched, and never touches anything cached afterwards.
BOOL NLClearCacheIfRequested(NSTimeInterval requestedAt) {
    if (requestedAt <= 0) return NO;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSince1970:requestedAt];
    NSUInteger removed = 0;
    for (NSURL *url in NLCachedFiles(NLCacheDir())) {   // not NLRootPath(): nothing to create here
        if ([NLModificationDate(url) compare:cutoff] == NSOrderedAscending &&
            [[NSFileManager defaultManager] removeItemAtURL:url error:nil]) removed++;
    }
    if (removed) NLLog(@"lyrics cache cleared, %lu files", (unsigned long)removed);
    return removed > 0;
}

// Keeps the cache folder from growing forever: once there are more than
// `limit` files the oldest go. Fetch queue, after a new file was written.
void NLPruneCache(NSUInteger limit) {
    NSArray<NSURL *> *files = NLCachedFiles(NLRootPath());
    if (files.count <= limit) return;
    NSArray<NSURL *> *oldestFirst = [files sortedArrayUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [NLModificationDate(a) compare:NLModificationDate(b)];
    }];
    NSUInteger excess = files.count - limit;
    for (NSUInteger i = 0; i < excess; i++) {
        [[NSFileManager defaultManager] removeItemAtURL:oldestFirst[i] error:nil];
    }
    NLLog(@"pruned %lu cached lyrics", (unsigned long)excess);
}

// Lyrics cached before 1.2.0 never went through Apple Music or the checks on
// word times, and the cache is asked before any source, so a song played back
// then would keep them for good. Everything 1.2.0 caches names its source
// (NL_LRC_SOURCE); a file without one is from before and goes, once per
// folder: the marker left behind means nothing cached or edited after that is
// looked at again. No folder, nothing cached yet.
void NLClearOldCache(NSString *folder) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *marker = [folder stringByAppendingPathComponent:NL_OLD_CACHE_CLEARED];
    if ([fm fileExistsAtPath:marker]) return;
    NSArray<NSURL *> *files = NLCachedFiles(folder);
    if (!files) return;
    for (NSURL *url in files) {
        NSString *text = [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil];
        if (text && !NLParseLRCHeader(text)[NL_LRC_SOURCE]) [fm removeItemAtURL:url error:nil];
    }
    [fm createFileAtPath:marker contents:nil attributes:nil];
}

#pragma mark - Titles

// Strips "- 2011 Remaster", "(feat. X)", "(Live)" and friends, which otherwise
// prevent a match against the catalogue entry.
NSString *NLCleanTitle(NSString *title) {
    if (title.length == 0) return @"";
    NSRegularExpression *re = NL_ONCE([NSRegularExpression regularExpressionWithPattern:
        @"\\s*(?:[-–—]\\s*(?:\\d{4}\\s*)?(?:remaster|live|single|radio|mono|stereo|version)[^\\n]*$"
        @"|[\\(（\\[][^\\)）\\]]*(?:feat\\.|ft\\.|remaster|live|version|edit|mix|deluxe|bonus)[^\\)）\\]]*[\\)）\\]])"
                                                                             options:NSRegularExpressionCaseInsensitive
                                                                               error:nil]);
    NSString *out = [re stringByReplacingMatchesInString:title
                                                options:0
                                                  range:NSMakeRange(0, title.length)
                                           withTemplate:@""];
    out = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    return out.length ? out : title;
}

// While Spotify plays on another device (Spotify Connect) the phone reports the
// track as "Title • Artist" and puts "Playing on <device>" in the artist field.
// Returns YES and the real title and artist when that is what was reported.
BOOL NLSplitConnectInfo(NSString *title, NSString *artist, NSString **outTitle, NSString **outArtist) {
    if (title.length == 0 || artist.length == 0) return NO;
    NSRange dot = [title rangeOfString:@" • "];
    if (dot.location == NSNotFound || dot.location == 0 || NSMaxRange(dot) >= title.length) return NO;
    NSRegularExpression *device = NL_ONCE([NSRegularExpression regularExpressionWithPattern:@"^(?:playing on|listening on|正在.*播放|再生中)"
                                                                                    options:NSRegularExpressionCaseInsensitive error:nil]);
    if (![device firstMatchInString:artist options:0 range:NSMakeRange(0, artist.length)]) return NO;
    if (outTitle) *outTitle = [title substringToIndex:dot.location];
    if (outArtist) *outArtist = [title substringFromIndex:NSMaxRange(dot)];
    return YES;
}

// Players often report "A, B, C"; catalogues index by the primary artist.
NSString *NLPrimaryArtist(NSString *artist) {
    NSString *a = artist ?: @"";
    for (NSString *sep in NL_ONCE((@[@",", @"、", @";", @" & ", @" feat.", @" ft.", @" / "]))) {
        NSRange r = [a rangeOfString:sep options:NSCaseInsensitiveSearch];
        if (r.location != NSNotFound) a = [a substringToIndex:r.location];
    }
    return [a stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}

#pragma mark - LRC

static const NSTimeInterval kNLMinimumGap = 5.0;   // a blank shorter than this is not a gap worth announcing

// NetEase in particular prefixes the credits and a copyright notice as timed
// lines a few hundredths of a second apart. Nobody sings "作曲 : X", so those
// are dropped here, which also covers files already in the cache.
static BOOL NLIsMetadataLine(NSString *text) {
    NSRegularExpression *credits = NL_ONCE([NSRegularExpression regularExpressionWithPattern:
        @"^\\s*(?:作词|作詞|作曲|编曲|編曲|制作人|製作人|监制|監製|混音|母带|母帶|录音|錄音|词|曲"
        @"|lyrics?\\s+by|composed\\s+by|arranged\\s+by|produced\\s+by|written\\s+by)\\s*[:：]"
                                                                                  options:NSRegularExpressionCaseInsensitive
                                                                                    error:nil]);
    if (text.length == 0) return NO;
    if ([credits firstMatchInString:text options:0 range:NSMakeRange(0, text.length)]) return YES;

    // 【本作品声明,著作权权利保留…】 style notices.
    if ([text hasPrefix:@"【"]) {
        for (NSString *word in NL_ONCE((@[@"声明", @"聲明", @"版权", @"版權", @"著作", @"着作"]))) {
            if ([text containsString:word]) return YES;
        }
    }
    return NO;
}

// The credits block NetEase puts before the first sung line also has entries
// the list above cannot know: "木箱鼓 Cajon：X", "母带工程师 Mastering Engineer：X",
// "杜比全景声混音室 Dolby Atmos Studio：X". Recognised by shape (a label, often
// in two languages, a colon, a value) plus a production word in the label, so
// a duet's "男：…" or "周杰倫：…" is never taken for one. Only used before the
// first sung line.
static BOOL NLIsCreditLine(NSString *text) {
    static NSArray<NSString *> *roles, *words;
    static NSSet<NSString *> *whole;
    static NSCharacterSet *colons, *nonLetters;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        roles = @[@"作词", @"作詞", @"作曲", @"编曲", @"編曲", @"制作", @"製作", @"监制", @"監製", @"统筹", @"統籌",
                  @"企划", @"企劃", @"出品", @"发行", @"發行", @"版权", @"版權", @"录音", @"錄音", @"混音", @"母带", @"母帶",
                  @"工程师", @"工程師", @"编辑", @"編輯", @"人声", @"人聲", @"和声", @"和聲", @"和音", @"配唱",
                  @"吉他", @"贝斯", @"貝斯", @"鼓", @"键盘", @"鍵盤", @"钢琴", @"鋼琴", @"提琴", @"弦乐", @"弦樂",
                  @"管乐", @"管樂", @"打击乐", @"打擊樂", @"合成器", @"采样", @"採樣", @"演奏", @"乐手", @"樂手",
                  @"乐队", @"樂隊", @"工作室", @"助理", @"总监", @"總監",
                  @"设计", @"設計", @"摄影", @"攝影", @"视觉", @"視覺", @"宣传", @"宣傳", @"营销", @"營銷",
                  @"歌手", @"演唱", @"主唱", @"原唱", @"翻唱", @"经纪", @"經紀", @"公司"];
        words = @[@"produc", @"engineer", @"mix", @"master", @"record", @"vocal", @"guitar", @"bass", @"drum",
                  @"keyboard", @"piano", @"string", @"arrang", @"compos", @"lyric", @"studio", @"edit", @"program",
                  @"synth", @"percussion", @"director", @"supervis", @"coordinat", @"assistant", @"design",
                  @"publish", @"cajon", @"violin", @"cello", @"sax", @"trumpet", @"horn", @"dolby", @"atmos",
                  @"artist", @"singer", @"perform", @"featur", @"executive", @"manag", @"company", @"label"];
        whole = [NSSet setWithArray:@[@"词", @"詞", @"曲", @"op", @"sp", @"isrc"]];
        colons = [NSCharacterSet characterSetWithCharactersInString:@":："];
        nonLetters = NSCharacterSet.letterCharacterSet.invertedSet;
    });
    NSRange colon = [text rangeOfCharacterFromSet:colons];
    if (colon.location == NSNotFound) return NO;
    NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
    NSString *label = [[text substringToIndex:colon.location] stringByTrimmingCharactersInSet:space].lowercaseString;
    NSString *value = [[text substringFromIndex:NSMaxRange(colon)] stringByTrimmingCharactersInSet:space];
    if (label.length == 0 || label.length > 60 || value.length == 0 || value.length > 80) return NO;

    for (NSString *role in roles) {
        if ([label containsString:role]) return YES;
    }
    for (NSString *word in [label componentsSeparatedByCharactersInSet:nonLetters]) {
        if ([whole containsObject:word]) return YES;
        for (NSString *stem in words) {
            if ([word hasPrefix:stem]) return YES;
        }
    }
    return NO;
}

// "mm:ss.xx" (also "mm:ss:xx" and "mm:ss"): groups 1-3 are minutes, seconds
// and the fraction, as NLMatchTime reads them.
#define NL_LRC_TIME @"(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?"

// A line's "[mm:ss.xx]" and a word's "<mm:ss.xx>", as NLParseLRC reads them.
static NSRegularExpression *NLLineTimeTags(void) {
    return NL_ONCE([NSRegularExpression regularExpressionWithPattern:@"\\[" NL_LRC_TIME @"\\]" options:0 error:nil]);
}
static NSRegularExpression *NLWordTimeTags(void) {
    return NL_ONCE([NSRegularExpression regularExpressionWithPattern:@"<" NL_LRC_TIME @">" options:0 error:nil]);
}

// The time in a match of the patterns below, which wrap NL_LRC_TIME, in seconds.
static NSTimeInterval NLMatchTime(NSString *s, NSTextCheckingResult *m) {
    double minutes = [[s substringWithRange:[m rangeAtIndex:1]] doubleValue];
    double seconds = [[s substringWithRange:[m rangeAtIndex:2]] doubleValue];
    double frac = 0;
    if ([m rangeAtIndex:3].location != NSNotFound) {
        NSString *f = [s substringWithRange:[m rangeAtIndex:3]];
        frac = [f doubleValue] / pow(10, (double)f.length);
    }
    return minutes * 60 + seconds + frac;
}

// Group `index` of a YRC match, milliseconds, in seconds.
static NSTimeInterval NLMatchMs(NSString *s, NSTextCheckingResult *m, NSUInteger index) {
    return [[s substringWithRange:[m rangeAtIndex:index]] doubleValue] / 1000.0;
}

// The words' texts joined, with the line's outer whitespace trimmed off the
// first and last word so the join is exactly the line as shown. Empty pieces go.
static NSString *NLTidyWords(NSMutableArray<NLLyricWord *> *words) {
    NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
    while (words.count) {
        NLLyricWord *first = words.firstObject;
        NSUInteger lead = 0;
        while (lead < first.text.length && [space characterIsMember:[first.text characterAtIndex:lead]]) lead++;
        first.text = [first.text substringFromIndex:lead];
        if (first.text.length) break;
        [words removeObjectAtIndex:0];
    }
    while (words.count) {
        NLLyricWord *last = words.lastObject;
        NSUInteger end = last.text.length;
        while (end > 0 && [space characterIsMember:[last.text characterAtIndex:end - 1]]) end--;
        last.text = [last.text substringToIndex:end];
        if (last.text.length) break;
        [words removeLastObject];
    }
    NSMutableString *text = [NSMutableString string];
    for (NLLyricWord *word in words) [text appendString:word.text];
    return text;
}

// Enhanced LRC: "<mm:ss.xx>word <mm:ss.xx>word <mm:ss.xx>", each time starting
// the piece after it and a trailing one ending the last. Text before the first
// time starts with the line. Returns the line's plain text; `outWords` gets the
// timed pieces, or nil when the line has no word times.
static NSString *NLSplitWords(NSString *body, NSTimeInterval lineStart, NSArray<NLLyricWord *> **outWords) {
    *outWords = nil;
    NSArray<NSTextCheckingResult *> *tags = [NLWordTimeTags() matchesInString:body options:0 range:NSMakeRange(0, body.length)];
    if (tags.count == 0) return [body stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

    NSMutableArray<NLLyricWord *> *words = [NSMutableArray array];
    NSTimeInterval start = lineStart;
    NSUInteger cursor = 0;
    for (NSUInteger i = 0; i <= tags.count; i++) {
        NSUInteger until = (i < tags.count) ? tags[i].range.location : body.length;
        NSString *piece = [body substringWithRange:NSMakeRange(cursor, until - cursor)];
        if (piece.length) [words addObject:[NLLyricWord wordAt:start end:0 text:piece]];
        if (i == tags.count) break;
        start = NLMatchTime(body, tags[i]);
        if (words.lastObject.end <= 0) words.lastObject.end = start;   // a time also ends the piece before it
        cursor = NSMaxRange(tags[i].range);
    }
    NSString *text = NLTidyWords(words);
    if (words.count) *outWords = [words copy];
    return text;
}

// The same pieces moved by `delta` seconds, for a line sung again at another time.
static NSArray<NLLyricWord *> *NLShiftWords(NSArray<NLLyricWord *> *words, NSTimeInterval delta) {
    if (delta == 0 || words.count == 0) return words;
    NSMutableArray<NLLyricWord *> *out = [NSMutableArray arrayWithCapacity:words.count];
    for (NLLyricWord *w in words) {
        [out addObject:[NLLyricWord wordAt:w.start + delta end:(w.end > 0 ? w.end + delta : 0) text:w.text]];
    }
    return out;
}

// By start time, ties kept in their order.
static void NLSortByStart(NSMutableArray<NLLyricLine *> *lines) {
    [lines sortUsingComparator:^NSComparisonResult(NLLyricLine *a, NLLyricLine *b) {
        return a.start < b.start ? NSOrderedAscending : (a.start > b.start ? NSOrderedDescending : NSOrderedSame);
    }];
}

// What every format goes through once its lines are read and sorted: the
// credits before the first sung line dropped, and blanks kept only where they
// announce a real break.
static NSArray<NLLyricLine *> *NLFinishLines(NSMutableArray<NLLyricLine *> *out) {
    if (out.count == 0) return nil;

    // The rest of the credits block, up to the first sung line.
    for (NSUInteger i = 0; i < out.count; ) {
        NSString *text = out[i].text;
        if (text.length == 0) { i++; continue; }
        if (!NLIsCreditLine(text)) break;
        [out removeObjectAtIndex:i];
    }
    if (out.count == 0) return nil;

    // A blank timestamped line announces a gap, and the engine shows the track
    // title there. Musixmatch uses one as an end marker; NetEase also sprinkles
    // them between verses, a second or two before the next line, which made the
    // title flash. Keep a blank only when the silence it announces is long
    // enough to be worth showing the title for, or when nothing follows it.
    NSMutableArray<NLLyricLine *> *kept = [NSMutableArray arrayWithCapacity:out.count];
    for (NSUInteger i = 0; i < out.count; i++) {
        NLLyricLine *line = out[i];
        if (line.text.length == 0) {
            NSUInteger next = i + 1;
            while (next < out.count && out[next].text.length == 0) next++;
            if (next < out.count && out[next].start - line.start < kNLMinimumGap) continue;
        }
        [kept addObject:line];
    }
    return [kept copy];
}

NSArray<NLLyricLine *> *NLParseLRC(NSString *lrc) {
    if (lrc.length == 0) return nil;

    // Part of the LRC format itself, in milliseconds. Handy for nudging one song.
    NSTimeInterval tagOffset = 0;
    NSRange offsetTag = [lrc rangeOfString:@"[offset:" options:NSCaseInsensitiveSearch];
    if (offsetTag.location != NSNotFound) {
        NSString *tail = [lrc substringFromIndex:NSMaxRange(offsetTag)];
        NSRange close = [tail rangeOfString:@"]"];
        if (close.location != NSNotFound && close.location <= 12) {
            tagOffset = [[tail substringToIndex:close.location] doubleValue] / 1000.0;
        }
    }

    NSRegularExpression *re = NLLineTimeTags();

    NSMutableArray<NLLyricLine *> *out = [NSMutableArray array];

    for (NSString *raw in [lrc componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSArray<NSTextCheckingResult *> *matches =
            [re matchesInString:raw options:0 range:NSMakeRange(0, raw.length)];
        if (matches.count == 0) continue;   // metadata lines such as [ar:] and [ti:]

        NSTimeInterval first = NLMatchTime(raw, matches.firstObject);
        NSArray<NLLyricWord *> *words = nil;
        NSString *text = NLSplitWords([raw substringFromIndex:NSMaxRange(matches.lastObject.range)], first, &words);
        if (NLIsMetadataLine(text)) continue;

        // One line may carry several timestamps when a chorus repeats. Word
        // times are written for the first; the others get them moved along.
        for (NSTextCheckingResult *m in matches) {
            NSTimeInterval start = NLMatchTime(raw, m);
            NLLyricLine *line = [NLLyricLine lineAt:start - tagOffset text:text];
            if (words) {
                line.words = NLShiftWords(words, start - first - tagOffset);
                line.end = line.words.lastObject.end;
            }
            [out addObject:line];
        }
    }
    NLSortByStart(out);
    return NLFinishLines(out);
}

// Most files have no word tag anywhere, which one search tells. Otherwise the
// lines are read the way NLParseLRC reads them, up to the first with words.
// The one difference: a word-timed credit before the first sung line, which
// NLParseLRC's finishing drops, still counts here.
BOOL NLLRCHasWordTimes(NSString *lrc) {
    if (lrc.length == 0 || [NLWordTimeTags() rangeOfFirstMatchInString:lrc options:0 range:NSMakeRange(0, lrc.length)].location == NSNotFound) return NO;
    for (NSString *raw in [lrc componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        if ([raw rangeOfString:@"<"].location == NSNotFound) continue;   // no word tag on this line
        NSTextCheckingResult *last = [NLLineTimeTags() matchesInString:raw options:0 range:NSMakeRange(0, raw.length)].lastObject;
        if (!last) continue;   // not a timed line
        NSArray<NLLyricWord *> *words = nil;
        NSString *text = NLSplitWords([raw substringFromIndex:NSMaxRange(last.range)], 0, &words);
        if (words && !NLIsMetadataLine(text)) return YES;
    }
    return NO;
}

// Lines a source hands over already timed rather than as LRC (Musixmatch's
// subtitle). Their cached copy is read back through NLParseLRC, so they get
// what it does to a file's lines, and the first play shows what every later
// one does: each text trimmed (in place), credits and notices dropped, then
// sorted and finished.
NSArray<NLLyricLine *> *NLFinishTimedLines(NSArray<NLLyricLine *> *lines) {
    NSMutableArray<NLLyricLine *> *out = [NSMutableArray arrayWithCapacity:lines.count];
    NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
    for (NLLyricLine *line in lines) {
        NSString *text = [line.text ?: @"" stringByTrimmingCharactersInSet:space];
        if (NLIsMetadataLine(text)) continue;
        line.text = text;
        [out addObject:line];
    }
    NLSortByStart(out);
    return NLFinishLines(out);
}

// NetEase's word-by-word lyrics: "[lineMs,durMs](wordMs,durMs,0)word(…)word",
// with the credits as JSON lines ({"t":…,"c":[…]}) mixed in. Times are absolute
// milliseconds. Pieces are kept as timed, a CJK character or a word with its space.
NSArray<NLLyricLine *> *NLParseYRC(NSString *yrc) {
    if (yrc.length == 0) return nil;
    NSRegularExpression *lineRe = NL_ONCE([NSRegularExpression regularExpressionWithPattern:@"^\\[(\\d+),(\\d+)\\]" options:0 error:nil]);
    NSRegularExpression *wordRe = NL_ONCE([NSRegularExpression regularExpressionWithPattern:@"\\((\\d+),(\\d+),-?\\d+\\)" options:0 error:nil]);

    NSMutableArray<NLLyricLine *> *out = [NSMutableArray array];
    for (NSString *raw in [yrc componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSTextCheckingResult *head = [lineRe firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)];
        if (!head) continue;   // the JSON credit lines and blanks
        NSString *rest = [raw substringFromIndex:NSMaxRange(head.range)];
        NSArray<NSTextCheckingResult *> *tags = [wordRe matchesInString:rest options:0 range:NSMakeRange(0, rest.length)];

        NSMutableArray<NLLyricWord *> *words = [NSMutableArray arrayWithCapacity:tags.count];
        for (NSUInteger i = 0; i < tags.count; i++) {
            NSUInteger textFrom = NSMaxRange(tags[i].range);
            NSUInteger until = (i + 1 < tags.count) ? tags[i + 1].range.location : rest.length;
            if (until <= textFrom) continue;
            NSTimeInterval start = NLMatchMs(rest, tags[i], 1);
            [words addObject:[NLLyricWord wordAt:start end:start + NLMatchMs(rest, tags[i], 2)
                                            text:[rest substringWithRange:NSMakeRange(textFrom, until - textFrom)]]];
        }
        double start = NLMatchMs(raw, head, 1);
        double length = NLMatchMs(raw, head, 2);
        NLLyricLine *line = NLLineFromWords(words, start, start + length);
        if (line) [out addObject:line];
    }
    return NLFinishWordLines(out);
}

NLLyricLine *NLLineFromWords(NSMutableArray<NLLyricWord *> *words, NSTimeInterval start, NSTimeInterval end) {
    NSString *text = NLTidyWords(words);
    if (text.length == 0 || NLIsMetadataLine(text)) return nil;
    NLLyricLine *line = [NLLyricLine lineAt:start text:text];
    line.end = end > start ? end : words.lastObject.end;
    line.words = words;
    return line;
}

// Word-timed formats have no blank lines, but every line says when it ends: a
// long silence after one gets the blank that shows the track title, the way
// the timed-line sources mark breaks, and so does the end of the song.
NSArray<NLLyricLine *> *NLFinishWordLines(NSMutableArray<NLLyricLine *> *out) {
    NLSortByStart(out);
    // In order as built: a blank starts after its line and well before the next.
    NSMutableArray<NLLyricLine *> *withGaps = [NSMutableArray arrayWithCapacity:out.count + 4];
    for (NSUInteger i = 0; i < out.count; i++) {
        NLLyricLine *line = out[i];
        [withGaps addObject:line];
        NSTimeInterval next = (i + 1 < out.count) ? out[i + 1].start : INFINITY;
        if (line.end > line.start && next - line.end >= kNLMinimumGap) {
            [withGaps addObject:[NLLyricLine lineAt:line.end text:@""]];
        }
    }
    return NLFinishLines(withGaps);
}

// One format on disk for everything: hand-editable, and [offset:] keeps working
// on results that did not arrive as LRC.
static NSString *NLFormatTime(NSTimeInterval t) {
    t = MAX(t, 0);
    int total = (int)floor(t);
    int cs = (int)round((t - total) * 100);
    if (cs >= 100) { cs = 0; total += 1; }
    return [NSString stringWithFormat:@"%02d:%02d.%02d", total / 60, total % 60, cs];
}

// Word-timed lines go out as enhanced LRC, which NLParseLRC reads back.
static NSString *NLLinesToLRC(NSArray<NLLyricLine *> *lines) {
    NSMutableString *out = [NSMutableString string];
    for (NLLyricLine *line in lines) {
        [out appendFormat:@"[%@]", NLFormatTime(line.start)];
        if (line.words.count) {
            // A word that ends before the next one starts gets its own end time
            // (a time followed by nothing); otherwise the next start ends it.
            NSUInteger count = line.words.count;
            for (NSUInteger i = 0; i < count; i++) {
                NLLyricWord *word = line.words[i];
                [out appendFormat:@"<%@>%@", NLFormatTime(word.start), word.text];
                BOOL last = (i + 1 == count);
                if (word.end > word.start && (last || line.words[i + 1].start - word.end > 0.005)) {
                    [out appendFormat:@"<%@>", NLFormatTime(word.end)];
                }
            }
        } else {
            [out appendString:line.text ?: @""];
        }
        [out appendString:@"\n"];
    }
    return out;
}

// Header tags first, in a fixed order; a value cannot end its tag early or
// start a new line.
NSString *NLLinesToLRCWithHeader(NSArray<NLLyricLine *> *lines, NSDictionary<NSString *, NSString *> *header) {
    NSMutableString *out = [NSMutableString string];
    for (NSString *tag in NL_ONCE((@[NL_LRC_TITLE, NL_LRC_ARTIST, NL_LRC_ALBUM, NL_LRC_SOURCE, NL_LRC_CHECKED]))) {
        NSString *value = NLString(header, tag);
        if (!value) continue;
        value = [[[value componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]
                  componentsJoinedByString:@" "] stringByReplacingOccurrencesOfString:@"]" withString:@")"];
        value = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (value.length) [out appendFormat:@"[%@:%@]\n", tag, value];
    }
    [out appendString:NLLinesToLRC(lines)];
    return out;
}

// The tags at the top of a file, up to the first timed line. Keys are lowercased.
NSDictionary<NSString *, NSString *> *NLParseLRCHeader(NSString *lrc) {
    NSRegularExpression *tag = NL_ONCE([NSRegularExpression regularExpressionWithPattern:@"^\\s*\\[([A-Za-z][A-Za-z-]*):(.*)\\]\\s*$" options:0 error:nil]);
    NSMutableDictionary<NSString *, NSString *> *out = [NSMutableDictionary dictionary];
    // Cut one line at a time where componentsSeparatedByCharactersInSet: would
    // (at every newline character), so the lyrics below the header are never split.
    NSCharacterSet *newlines = [NSCharacterSet newlineCharacterSet];
    NSUInteger length = lrc.length;
    for (NSUInteger from = 0; from < length; ) {
        NSRange newline = [lrc rangeOfCharacterFromSet:newlines options:0 range:NSMakeRange(from, length - from)];
        NSUInteger end = (newline.location == NSNotFound) ? length : newline.location;
        NSString *raw = [lrc substringWithRange:NSMakeRange(from, end - from)];
        from = (newline.location == NSNotFound) ? length : NSMaxRange(newline);
        if (raw.length == 0) continue;
        NSTextCheckingResult *m = [tag firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)];
        if (!m) break;   // the lyrics have started
        NSString *value = [[raw substringWithRange:[m rangeAtIndex:2]]
                           stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (value.length) out[[raw substringWithRange:[m rangeAtIndex:1]].lowercaseString] = value;
    }
    return out;
}

BOOL NLHasWords(NSArray<NLLyricLine *> *lines) {
    for (NLLyricLine *line in lines) {
        if (line.words.count) return YES;
    }
    return NO;
}

// Letters and digits: what takes time to sing, and what makes two lines the same.
static NSCharacterSet *NLSungCharacters(void) {
    static NSCharacterSet *sung;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableCharacterSet *set = [NSMutableCharacterSet letterCharacterSet];
        [set formUnionWithCharacterSet:NSCharacterSet.decimalDigitCharacterSet];
        sung = [set copy];
    });
    return sung;
}
static NSCharacterSet *NLUnsungCharacters(void) { return NL_ONCE(NLSungCharacters().invertedSet); }

// How many of text's characters take time to sing; spaces and punctuation do not.
static NSUInteger NLSungLength(NSString *text) {
    NSCharacterSet *sung = NLSungCharacters();
    NSUInteger n = 0;
    for (NSUInteger i = 0; i < text.length; i++) {
        if ([sung characterIsMember:[text characterAtIndex:i]]) n++;
    }
    return n;
}

// Word times now and then come squeezed: Musixmatch has richsyncs whose lines
// last a quarter of a second, the whole song over in under a minute, the words
// lit long before they are sung. Faster than anyone sings (the quickest rap is
// some 30 letters a second) on more than a few lines means the times are wrong.
static const double kNLFastestSinging = 40;   // letters a second

BOOL NLWordTimesPlausible(NSArray<NLLyricLine *> *lines) {
    NSUInteger measured = 0, tooFast = 0;
    for (NLLyricLine *line in lines) {
        if (line.words.count == 0) continue;
        NSUInteger letters = NLSungLength(line.text);
        double length = MAX(line.words.lastObject.end, line.words.lastObject.start) - line.words.firstObject.start;
        if (letters < 6 || length <= 0) continue;
        measured++;
        if (letters / length > kNLFastestSinging) tooFast++;
    }
    return measured < 4 || tooFast * 5 < measured;   // under a fifth
}

static NSString *NLComparableText(NSString *text) {
    NSMutableString *out = [NSMutableString string];
    NSString *lower = text.lowercaseString;
    NSCharacterSet *keep = NSCharacterSet.alphanumericCharacterSet;
    for (NSUInteger i = 0; i < lower.length; i++) {
        unichar c = [lower characterAtIndex:i];
        if ([keep characterIsMember:c]) CFStringAppendCharacters((__bridge CFMutableStringRef)out, &c, 1);
    }
    return out;
}

// Whether word-timed lines keep in step with a line-timed version of the same
// lyrics (Musixmatch hands out both, made apart): the same lines found in
// order, each about as far from its counterpart as the typical one. A constant
// difference is allowed, since the two can be timed to cuts with intros of
// different lengths and either may be the one playing; times that drift apart
// (a squeezed richsync) are not. Too few lines in common to tell counts as
// agreeing.
BOOL NLWordLinesAgree(NSArray<NLLyricLine *> *words, NSArray<NLLyricLine *> *timed) {
    NSMutableArray<NSString *> *timedTexts = [NSMutableArray arrayWithCapacity:timed.count];
    for (NLLyricLine *line in timed) [timedTexts addObject:NLComparableText(line.text)];
    NSMutableArray<NSNumber *> *gaps = [NSMutableArray array];
    NSUInteger from = 0, sung = 0;
    for (NLLyricLine *line in words) {
        NSString *text = NLComparableText(line.text);
        if (text.length == 0) continue;
        sung++;
        // A few lines ahead at most, so one line's repeat later in the song is
        // not taken for it.
        for (NSUInteger i = from; i < timed.count && i < from + 4; i++) {
            if (![timedTexts[i] isEqualToString:text]) continue;
            [gaps addObject:@(line.start - timed[i].start)];
            from = i + 1;
            break;
        }
    }
    if (gaps.count < 3 || gaps.count * 3 < sung) return YES;
    [gaps sortUsingSelector:@selector(compare:)];
    double typical = gaps[gaps.count / 2].doubleValue;
    NSMutableArray<NSNumber *> *spread = [NSMutableArray arrayWithCapacity:gaps.count];
    for (NSNumber *gap in gaps) [spread addObject:@(fabs(gap.doubleValue - typical))];
    [spread sortUsingSelector:@selector(compare:)];
    return spread[spread.count / 2].doubleValue <= 1.5;
}

// A result with fewer than two sung lines is almost certainly an end marker or
// an "[Instrumental]" placeholder. Accepting it would cache a blank and block
// every other source, so treat it as a miss instead.
BOOL NLHasContent(NSArray<NLLyricLine *> *lines) {
    NSUInteger sung = 0;
    for (NLLyricLine *line in lines) {
        if (line.text.length && ++sung >= 2) return YES;
    }
    return NO;
}

#pragma mark - Chorus

static const NSUInteger kNLChorusMaxLines = 400;   // beyond this it is not a song, skip the O(n²) table
static const NSUInteger kNLChorusMinLines = 2;
static const NSUInteger kNLChorusMinChars = 12;    // after normalising; keeps "oh / yeah" pairs out
static const NSUInteger kNLChorusMaxBridge = 2;    // lines between two occurrences that still make them one chorus...
static const NSTimeInterval kNLChorusMaxBridgeTime = 10.0;   // ...as long as they are a tag, not a short verse

// What makes two lines "the same": case, punctuation, spacing and bracketed
// backing vocals ("(yeah)", "（合）") do not count.
static NSString *NLChorusNormalize(NSString *text) {
    NSRegularExpression *brackets = NL_ONCE([NSRegularExpression regularExpressionWithPattern:@"[\\(（\\[【][^\\)）\\]】]*[\\)）\\]】]"
                                                                                       options:0
                                                                                         error:nil]);
    if (text.length == 0) return @"";
    NSString *s = [brackets stringByReplacingMatchesInString:text options:0
                                                       range:NSMakeRange(0, text.length) withTemplate:@""];
    return [[[s lowercaseString] componentsSeparatedByCharactersInSet:NLUnsungCharacters()] componentsJoinedByString:@""];
}

// The chorus is taken to be the run of consecutive lines that repeats the most,
// weighted by how much text it holds: a single repeated line is too easily a
// hook or an ad-lib, a block of them almost never is. The count is squared so
// that a verse plus chorus sung twice does not beat the chorus alone sung four
// times. A chorus that repeats inside itself shows up as occurrences a line or
// two apart; those are one chorus with one start.
void NLMarkChorus(NSArray<NLLyricLine *> *lines) {
    NSUInteger n = lines.count;
    for (NLLyricLine *line in lines) { line.chorus = NO; line.chorusStart = NO; }
    if (n < kNLChorusMinLines * 2 || n > kNLChorusMaxLines) return;

    // Each distinct normalised line becomes a number, so the table below
    // compares integers instead of strings. 0 is a blank line.
    NSUInteger w = n + 1;
    uint16_t *run = calloc(w * w, sizeof(uint16_t));
    NSUInteger *ids = calloc(n, sizeof(NSUInteger));
    NSUInteger *chars = calloc(n, sizeof(NSUInteger));
    if (!run || !ids || !chars) { free(run); free(ids); free(chars); return; }
    NSMutableDictionary<NSString *, NSNumber *> *idOf = [NSMutableDictionary dictionaryWithCapacity:n];
    for (NSUInteger i = 0; i < n; i++) {
        NSString *norm = NLChorusNormalize(lines[i].text);
        chars[i] = norm.length;
        if (norm.length == 0) continue;
        NSNumber *known = idOf[norm];
        if (!known) idOf[norm] = known = @(idOf.count + 1);
        ids[i] = known.unsignedIntegerValue;
    }

    // run[i*(n+1)+j]: how many lines match going forward from i and j. Blank
    // lines never match, so a block cannot span an instrumental break.
    for (NSInteger i = n - 1; i >= 0; i--) {
        if (ids[i] == 0) continue;   // row stays zero
        for (NSInteger j = n - 1; j >= 0; j--) {
            if (i == j || ids[i] != ids[j]) continue;
            run[i * w + j] = run[(i + 1) * w + (j + 1)] + 1;
        }
    }

    NSUInteger bestStart = 0, bestLen = 0, bestCount = 0, bestScore = 0;
    for (NSUInteger i = 0; i < n; i++) {
        // Longest block starting at i that appears again somewhere without overlapping itself.
        NSUInteger maxLen = 0;
        for (NSUInteger j = i + 1; j < n; j++) {
            maxLen = MAX(maxLen, MIN((NSUInteger)run[i * w + j], j - i));
        }

        NSUInteger blockChars = 0;
        for (NSUInteger len = 1; len <= maxLen; len++) {
            blockChars += chars[i + len - 1];
            if (len < kNLChorusMinLines || blockChars < kNLChorusMinChars) continue;

            NSUInteger count = 0;
            for (NSUInteger k = 0; k + len <= n; ) {
                if (k == i || run[i * w + k] >= len) { count++; k += len; }
                else k++;
            }
            NSUInteger score = count * count * blockChars;
            if (count >= 2 && (score > bestScore || (score == bestScore && count > bestCount))) {
                bestStart = i; bestLen = len; bestCount = count; bestScore = score;
            }
        }
    }

    if (bestLen) {
        NSUInteger prevEnd = NSNotFound;   // one past the last line of the previous occurrence
        for (NSUInteger k = 0; k + bestLen <= n; ) {
            if (k == bestStart || run[bestStart * w + k] >= bestLen) {
                BOOL continues = (prevEnd != NSNotFound && k - prevEnd <= kNLChorusMaxBridge &&
                                  (k == prevEnd || lines[k].start - lines[prevEnd].start <= kNLChorusMaxBridgeTime));
                for (NSUInteger m = prevEnd; continues && m < k; m++) {
                    if (lines[m].text.length == 0) continues = NO;   // a break in between: a new chorus
                }
                NSUInteger from = continues ? prevEnd : k;
                for (NSUInteger m = from; m < k + bestLen; m++) lines[m].chorus = YES;
                if (!continues) lines[k].chorusStart = YES;
                k += bestLen;
                prevEnd = k;
            } else {
                k++;
            }
        }
    }
    free(run);
    free(ids);
    free(chars);
}

#pragma mark - Manual overrides

// Matching is string-based, so live takes, remasters and obscure tracks will fail
// and no amount of tuning fixes that: the entry simply is not in the catalogue.
// Hence a manual escape hatch: drop a .lrc into Library/NowLyrics/manual/ named
// "Title - Artist.lrc" or "Title.lrc". The settings page saves what is pasted or
// imported there under the first name.
NSString *NLManualFileName(NSString *title, NSString *artist) {
    NSString *raw = artist.length ? [NSString stringWithFormat:@"%@ - %@", title ?: @"", artist] : (title ?: @"");
    return [NLSanitizeFilename(raw) stringByAppendingPathExtension:@"lrc"];
}

// `name` ("Title - Artist.lrc") as `listing` has it with the extension in
// other capitals ("Title - Artist.LRC"), nil when it has no such file. The
// library lists those as added by hand, and the volume is case-sensitive, so
// opening `name` itself never finds them.
static NSString *NLListedWithOtherExtensionCase(NSArray<NSString *> *listing, NSString *name) {
    if (![name hasSuffix:@".lrc"]) return nil;
    NSString *stem = [name substringToIndex:name.length - 4];
    for (NSString *entry in listing) {
        if (entry.length <= 4 || [entry hasSuffix:@".lrc"]) continue;   // ".lrc" itself is opened by name
        NSRange extension = NSMakeRange(entry.length - 4, 4);
        if ([entry compare:@".lrc" options:NSCaseInsensitiveSearch range:extension] == NSOrderedSame &&
            [[entry substringToIndex:extension.location] compare:stem] == NSOrderedSame) return entry;
    }
    return nil;
}

// The lines of manual/`name`, nil when it is missing or has no timed line.
static NSArray<NLLyricLine *> *NLManualFile(NSString *dir, NSString *name, NSString **outPath) {
    NSString *path = [dir stringByAppendingPathComponent:name];
    NSArray<NLLyricLine *> *lines = NLParseLRC([NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]);
    if (lines.count == 0) return nil;
    NLLog(@"using manual lyrics: %@", path);
    if (outPath) *outPath = path;
    return lines;
}

NSArray<NLLyricLine *> *NLManualLyrics(NSString *title, NSString *artist, NSString **outPath) {
    NSString *dir = [NLRootPath() stringByAppendingPathComponent:NL_MANUAL_FOLDER];
    // Almost always empty: one listing instead of a string of failed opens.
    NSArray<NSString *> *listing = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil];
    if (listing.count == 0) return nil;

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (artist.length) [names addObject:NLManualFileName(title, artist)];
    if (title.length) [names addObject:NLManualFileName(title, nil)];

    for (NSString *name in names) {
        if ([name isEqualToString:@".lrc"]) continue;
        NSString *lower = name.lowercaseString;
        for (NSString *candidate in [lower isEqualToString:name] ? @[name] : @[name, lower]) {
            NSArray<NLLyricLine *> *lines = NLManualFile(dir, candidate, outPath);
            NSString *other = lines ? nil : NLListedWithOtherExtensionCase(listing, candidate);
            if (other) lines = NLManualFile(dir, other, outPath);
            if (lines) return lines;
        }
    }
    return nil;
}
