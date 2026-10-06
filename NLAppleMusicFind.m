//
//  NLAppleMusicFind.m
//  See NLAppleMusicFind.h.
//

#import "NLAppleMusicFind.h"
#import "NLShared.h"

// For comparing titles and artists: one script (Traditional as Simplified),
// no case, accents or widths, no bracketed parts ("(feat. …)", "[Live]") or
// " - Remastered" tails, letters and digits only.
static NSString *NLFold(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return @"";
    NSString *s = [text stringByApplyingTransform:@"Hant-Hans" reverse:NO] ?: text;
    s = [s stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch | NSWidthInsensitiveSearch
                               locale:nil];
    NSRegularExpression *brackets = NL_ONCE([NSRegularExpression regularExpressionWithPattern:@"[\\(\\[（【].*?[\\)\\]）】]" options:0 error:nil]);
    s = [brackets stringByReplacingMatchesInString:s options:0 range:NSMakeRange(0, s.length) withTemplate:@""];
    NSRange dash = [s rangeOfString:@" - "];
    if (dash.location != NSNotFound && dash.location > 0) s = [s substringToIndex:dash.location];
    NSMutableString *out = [NSMutableString string];
    NSCharacterSet *keep = NSCharacterSet.alphanumericCharacterSet;
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length) options:NSStringEnumerationByComposedCharacterSequences
                       usingBlock:^(NSString *piece, NSRange r, NSRange e, BOOL *stop) {
        if ([piece rangeOfCharacterFromSet:keep].location != NSNotFound) [out appendString:piece];
    }];
    return out;
}

// The asked-for artist's parts ("A & B", "A, B") folded, those of two letters
// or more: the same for every search result.
static NSArray<NSString *> *NLArtistParts(NSString *artist) {
    NSCharacterSet *separators = NL_ONCE([NSCharacterSet characterSetWithCharactersInString:@"&,/、，;＆"]);
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [artist componentsSeparatedByCharactersInSet:separators]) {
        NSString *folded = NLFold(part);
        if (folded.length >= 2) [parts addObject:folded];
    }
    return parts;
}

// Whether a result's artist field shares an artist with the asked-for one
// ("A & B", "A, B", "A feat. B"): `wanted` is that one folded, `parts` its
// NLArtistParts.
static BOOL NLArtistsMeet(NSString *wanted, NSArray<NSString *> *parts, NSString *other) {
    if (!wanted.length) return NO;
    NSString *b = NLFold(other);
    if (!b.length) return NO;
    if ([wanted containsString:b] || [b containsString:wanted]) return YES;
    for (NSString *folded in parts) {
        if ([b containsString:folded]) return YES;
    }
    return NO;
}

// The best of the search results for the song, or nil. A result must have the
// title, and either the artist or the length to within 2 s; one more than 5 s
// longer or shorter is another version.
static NSDictionary *NLBestMatch(NSArray *results, NSString *title, NSString *artist, NSTimeInterval duration) {
    NSString *wanted = NLFold(title);
    NSString *wantedArtist = NLFold(artist);
    NSArray<NSString *> *artistParts = wantedArtist.length ? NLArtistParts(artist) : @[];
    NSDictionary *best = nil;
    double bestScore = -1;
    for (NSDictionary *result in results) {
        if (![result isKindOfClass:NSDictionary.class]) continue;
        NSNumber *trackID = result[@"trackId"];
        if (![trackID respondsToSelector:@selector(longLongValue)]) continue;
        NSString *name = NLFold(result[@"trackName"]);
        int titleScore = [name isEqualToString:wanted] ? 3
                       : (name.length && wanted.length && ([name containsString:wanted] || [wanted containsString:name])) ? 2 : 0;
        if (titleScore == 0) continue;
        double length = NLLooseNum(result[@"trackTimeMillis"], 0) / 1000;
        double apart = (duration > 0 && length > 0) ? fabs(duration - length) : -1;
        if (apart > 5) continue;
        BOOL artistMeets = NLArtistsMeet(wantedArtist, artistParts, result[@"artistName"]);
        if (!artistMeets && !(apart >= 0 && apart <= 2)) continue;
        double score = titleScore * 10 + (artistMeets ? 5 : 0) + (apart >= 0 ? 5 - apart : 0);
        if (score > bestScore) {
            bestScore = score;
            best = @{@"id": trackID, @"title": result[@"trackName"] ?: @"", @"artist": result[@"artistName"] ?: @""};
        }
    }
    return best;
}

// Apple's public catalog search (no account), in the device's region: the
// terms one after another until one finds the song. Calls back on the main
// queue with the match, or nil and what went wrong (nil: not there).
static void NLSearchAppleMusic(NSArray<NSString *> *terms, NSUInteger index, NSString *title, NSString *artist,
                               NSTimeInterval duration, void (^done)(NSDictionary *match, NSString *problem)) {
    if (index >= terms.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ done(nil, nil); });
        return;
    }
    NSString *country = [NSLocale.currentLocale.countryCode lowercaseString] ?: @"us";
    NSURLComponents *url = [NSURLComponents componentsWithString:@"https://itunes.apple.com/search"];
    url.queryItems = @[
        [NSURLQueryItem queryItemWithName:@"term" value:terms[index]],
        [NSURLQueryItem queryItemWithName:@"entity" value:@"song"],
        [NSURLQueryItem queryItemWithName:@"limit" value:@"25"],
        [NSURLQueryItem queryItemWithName:@"country" value:country],
    ];
    [[NSURLSession.sharedSession dataTaskWithURL:url.URL completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        // Only a list of results is an answer. A refusal (rate limited, a
        // server error) or a body that is not one is a failed search, which
        // must not be taken, and remembered, as "not on Apple Music".
        NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse *)response).statusCode : 200;
        NSArray *results = nil;
        NSString *problem = nil;
        if (error || !data) {
            problem = error.localizedDescription ?: @"no data";
        } else if (status < 200 || status > 299) {
            problem = [NSString stringWithFormat:@"HTTP %ld", (long)status];
        } else {
            results = NLArray([NSJSONSerialization JSONObjectWithData:data options:0 error:nil], @"results");
            if (!results) problem = @"unreadable answer";
        }
        if (problem) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(nil, problem); });
            return;
        }
        NSDictionary *match = NLBestMatch(results, title, artist, duration);
        if (match) {
            dispatch_async(dispatch_get_main_queue(), ^{ done(match, nil); });
            return;
        }
        NLSearchAppleMusic(terms, index + 1, title, artist, duration, done);
    }] resume];
}

// By title and artist first, then by title alone.
void NLFindOnAppleMusic(NSString *title, NSString *artist, NSTimeInterval duration,
                        void (^done)(NSDictionary *match, NSString *problem)) {
    NSArray<NSString *> *terms = artist.length ? @[[NSString stringWithFormat:@"%@ %@", title, artist], title] : @[title];
    NLSearchAppleMusic(terms, 0, title, artist, duration, done);
}
