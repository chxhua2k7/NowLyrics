//
//  NLLyrics.m
//  LRC parsing and serialisation, title cleaning, and the files on disk (the
//  cache and manual overrides). No networking and no playback state.
//

#import "NowLyrics.h"

@implementation NLLyricLine
@end

#pragma mark - Value helpers

// JSON null decodes to NSNull, which does not respond to doubleValue. Sending it
// anyway raises an unrecognised-selector exception, and on a background queue
// that takes the whole host app down.
double NLNum(id value, double fallback) {
    return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
}

#pragma mark - Paths

// Library/NowLyrics, without creating it.
static NSString *NLCacheDir(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dir = [NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES).firstObject
               stringByAppendingPathComponent:@"NowLyrics"];
    });
    return dir;
}

// The same, created on first use together with manual/, so that folder is
// discoverable without having to guess its name.
static NSString *NLRootPath(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [[NSFileManager defaultManager] createDirectoryAtPath:[NLCacheDir() stringByAppendingPathComponent:@"manual"]
                                  withIntermediateDirectories:YES attributes:nil error:nil];
    });
    return NLCacheDir();
}

static NSString *NLSanitizeFilename(NSString *name) {
    static NSCharacterSet *illegal = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\:?*\"<>|"];
    });
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

static NSDate *NLModificationDate(NSURL *url) {
    NSDate *date = nil;
    [url getResourceValue:&date forKey:NSURLContentModificationDateKey error:nil];
    return date ?: [NSDate distantPast];
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

#pragma mark - Titles

// Strips "- 2011 Remaster", "(feat. X)", "(Live)" and friends, which otherwise
// prevent a match against the catalogue entry.
NSString *NLCleanTitle(NSString *title) {
    if (title.length == 0) return @"";
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
              @"\\s*(?:[-–—]\\s*(?:\\d{4}\\s*)?(?:remaster|remastered|live|single|radio|mono|stereo|version)[^\\n]*$"
              @"|[\\(（\\[][^\\)）\\]]*(?:feat\\.|ft\\.|remaster|live|version|edit|mix|deluxe|bonus)[^\\)）\\]]*[\\)）\\]])"
                                                       options:NSRegularExpressionCaseInsensitive
                                                         error:nil];
    });
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
    static NSRegularExpression *device = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        device = [NSRegularExpression regularExpressionWithPattern:@"^(?:playing on|listening on|正在.*播放|正在.*播放中|再生中)"
                                                           options:NSRegularExpressionCaseInsensitive error:nil];
    });
    if (![device firstMatchInString:artist options:0 range:NSMakeRange(0, artist.length)]) return NO;
    if (outTitle) *outTitle = [title substringToIndex:dot.location];
    if (outArtist) *outArtist = [title substringFromIndex:NSMaxRange(dot)];
    return YES;
}

// Players often report "A, B, C"; catalogues index by the primary artist.
NSString *NLPrimaryArtist(NSString *artist) {
    NSString *a = artist ?: @"";
    for (NSString *sep in @[@",", @"、", @";", @" & ", @" feat.", @" ft.", @" / "]) {
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
    static NSRegularExpression *credits = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        credits = [NSRegularExpression regularExpressionWithPattern:
                   @"^\\s*(?:作词|作詞|作曲|编曲|編曲|制作人|製作人|监制|監製|混音|母带|母帶|录音|錄音|词|曲"
                   @"|lyrics?\\s+by|composed\\s+by|arranged\\s+by|produced\\s+by|written\\s+by)\\s*[:：]"
                                                            options:NSRegularExpressionCaseInsensitive
                                                              error:nil];
    });
    if (text.length == 0) return NO;
    if ([credits firstMatchInString:text options:0 range:NSMakeRange(0, text.length)]) return YES;

    // 【本作品声明,著作权权利保留…】 style notices.
    if ([text hasPrefix:@"【"]) {
        for (NSString *word in @[@"声明", @"聲明", @"版权", @"版權", @"著作", @"着作"]) {
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
    NSRange colon = [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@":："]];
    if (colon.location == NSNotFound) return NO;
    NSCharacterSet *space = [NSCharacterSet whitespaceCharacterSet];
    NSString *label = [[text substringToIndex:colon.location] stringByTrimmingCharactersInSet:space].lowercaseString;
    NSString *value = [[text substringFromIndex:NSMaxRange(colon)] stringByTrimmingCharactersInSet:space];
    if (label.length == 0 || label.length > 60 || value.length == 0 || value.length > 80) return NO;

    static NSArray<NSString *> *roles, *words;
    static NSSet<NSString *> *whole;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        roles = @[@"作词", @"作詞", @"作曲", @"编曲", @"編曲", @"制作", @"製作", @"监制", @"監製", @"统筹", @"統籌",
                  @"企划", @"企劃", @"出品", @"发行", @"發行", @"版权", @"版權", @"录音", @"錄音", @"混音", @"母带", @"母帶",
                  @"工程师", @"工程師", @"编辑", @"編輯", @"人声", @"人聲", @"和声", @"和聲", @"和音", @"配唱",
                  @"吉他", @"贝斯", @"貝斯", @"鼓", @"键盘", @"鍵盤", @"钢琴", @"鋼琴", @"提琴", @"弦乐", @"弦樂",
                  @"管乐", @"管樂", @"打击乐", @"打擊樂", @"合成器", @"采样", @"採樣", @"演奏", @"乐手", @"樂手",
                  @"乐队", @"樂隊", @"工作室", @"录音室", @"錄音室", @"混音室", @"助理", @"总监", @"總監",
                  @"设计", @"設計", @"摄影", @"攝影", @"视觉", @"視覺", @"宣传", @"宣傳", @"营销", @"營銷",
                  @"歌手", @"演唱", @"主唱", @"原唱", @"翻唱", @"出品人", @"经纪", @"經紀", @"公司"];
        words = @[@"produc", @"engineer", @"mix", @"master", @"record", @"vocal", @"guitar", @"bass", @"drum",
                  @"keyboard", @"piano", @"string", @"arrang", @"compos", @"lyric", @"studio", @"edit", @"program",
                  @"synth", @"percussion", @"director", @"supervis", @"coordinat", @"assistant", @"design",
                  @"publish", @"cajon", @"violin", @"cello", @"sax", @"trumpet", @"horn", @"dolby", @"atmos",
                  @"artist", @"singer", @"perform", @"featur", @"executive", @"manag", @"company", @"label"];
        whole = [NSSet setWithArray:@[@"词", @"詞", @"曲", @"op", @"sp", @"isrc"]];
    });
    if ([whole containsObject:label]) return YES;
    for (NSString *role in roles) {
        if ([label containsString:role]) return YES;
    }
    for (NSString *word in [label componentsSeparatedByCharactersInSet:[NSCharacterSet letterCharacterSet].invertedSet]) {
        if ([whole containsObject:word]) return YES;
        for (NSString *stem in words) {
            if ([word hasPrefix:stem]) return YES;
        }
    }
    return NO;
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

    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:@"\\[(\\d{1,3}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]"
                                                      options:0
                                                        error:nil];
    });

    NSMutableArray<NLLyricLine *> *out = [NSMutableArray array];

    for (NSString *raw in [lrc componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSArray<NSTextCheckingResult *> *matches =
            [re matchesInString:raw options:0 range:NSMakeRange(0, raw.length)];
        if (matches.count == 0) continue;   // metadata lines such as [ar:] and [ti:]

        NSString *text = [[raw substringFromIndex:NSMaxRange(matches.lastObject.range)]
                          stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (NLIsMetadataLine(text)) continue;

        // One line may carry several timestamps when a chorus repeats.
        for (NSTextCheckingResult *m in matches) {
            double minutes = [[raw substringWithRange:[m rangeAtIndex:1]] doubleValue];
            double seconds = [[raw substringWithRange:[m rangeAtIndex:2]] doubleValue];
            double frac = 0;
            if ([m rangeAtIndex:3].location != NSNotFound) {
                NSString *f = [raw substringWithRange:[m rangeAtIndex:3]];
                frac = [f doubleValue] / pow(10, (double)f.length);
            }
            NLLyricLine *line = [NLLyricLine new];
            line.start = minutes * 60 + seconds + frac - tagOffset;
            line.text = text;
            [out addObject:line];
        }
    }

    if (out.count == 0) return nil;
    [out sortUsingComparator:^NSComparisonResult(NLLyricLine *a, NLLyricLine *b) {
        if (a.start < b.start) return NSOrderedAscending;
        if (a.start > b.start) return NSOrderedDescending;
        return NSOrderedSame;
    }];

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

// One format on disk for everything: hand-editable, and [offset:] keeps working
// on results that did not arrive as LRC.
NSString *NLLinesToLRC(NSArray<NLLyricLine *> *lines) {
    NSMutableString *out = [NSMutableString string];
    for (NLLyricLine *line in lines) {
        NSTimeInterval t = MAX(line.start, 0);
        int total = (int)floor(t);
        int cs = (int)round((t - total) * 100);
        if (cs >= 100) { cs = 0; total += 1; }
        [out appendFormat:@"[%02d:%02d.%02d]%@\n", total / 60, total % 60, cs, line.text ?: @""];
    }
    return out;
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
    static NSRegularExpression *brackets = nil;
    static NSCharacterSet *drop = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        brackets = [NSRegularExpression regularExpressionWithPattern:@"[\\(（\\[【][^\\)）\\]】]*[\\)）\\]】]"
                                                             options:0
                                                               error:nil];
        NSMutableCharacterSet *keep = [NSMutableCharacterSet letterCharacterSet];
        [keep formUnionWithCharacterSet:[NSCharacterSet decimalDigitCharacterSet]];
        drop = [keep invertedSet];
    });
    if (text.length == 0) return @"";
    NSString *s = [brackets stringByReplacingMatchesInString:text options:0
                                                       range:NSMakeRange(0, text.length) withTemplate:@""];
    return [[[s lowercaseString] componentsSeparatedByCharactersInSet:drop] componentsJoinedByString:@""];
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
// "Title - Artist.lrc" or "Title.lrc".
NSArray<NLLyricLine *> *NLManualLyrics(NSString *title, NSString *artist) {
    NSString *dir = [NLRootPath() stringByAppendingPathComponent:@"manual"];
    // Almost always empty: one listing instead of up to four failed opens.
    if ([[NSFileManager defaultManager] contentsOfDirectoryAtPath:dir error:nil].count == 0) return nil;

    NSMutableArray<NSString *> *names = [NSMutableArray array];
    if (artist.length) [names addObject:[NSString stringWithFormat:@"%@ - %@", title, artist]];
    if (title.length) [names addObject:title];

    for (NSString *raw in names) {
        NSString *name = NLSanitizeFilename(raw);
        if (name.length == 0) continue;
        for (NSString *candidate in @[name, name.lowercaseString]) {
            NSString *path = [dir stringByAppendingPathComponent:
                              [candidate stringByAppendingPathExtension:@"lrc"]];
            NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
            NSArray<NLLyricLine *> *lines = NLParseLRC(text);
            if (lines.count) {
                NLLog(@"using manual lyrics: %@", path);
                return lines;
            }
        }
    }
    return nil;
}
