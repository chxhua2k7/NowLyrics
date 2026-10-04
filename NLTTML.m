//
//  NLTTML.m
//  TTML, what Apple Music and AMLL use: <p begin end> per line and, for
//  word-by-word lyrics, <span begin end> per word. Backing vocals and the
//  translation/romanisation spans are left out; the lock screen has room for
//  the line only. Used for Apple Music's own lyrics (in Music) and for TTML
//  imported on the settings page.
//

#import "NowLyrics.h"

// "1:23.456", "00:01:23.456", "83.456", "83.456s", "83456ms" → seconds; -1 if none.
static NSTimeInterval NLTTMLTime(NSString *value) {
    NSString *v = [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
    if (v.length == 0) return -1;
    if ([v hasSuffix:@"ms"]) return [[v substringToIndex:v.length - 2] doubleValue] / 1000.0;
    if ([v hasSuffix:@"s"]) v = [v substringToIndex:v.length - 1];
    NSTimeInterval total = 0;
    for (NSString *part in [v componentsSeparatedByString:@":"]) total = total * 60 + part.doubleValue;
    return total;
}

@interface NLTTMLReader : NSObject <NSXMLParserDelegate>
@property (nonatomic, strong) NSMutableArray<NLLyricLine *> *lines;
@end

@implementation NLTTMLReader {
    NLLyricLine *_line;                        // the <p> being read
    NSMutableString *_lineText;                // its text, for lines without word times
    NSMutableArray<NLLyricWord *> *_words;
    NLLyricWord *_word;                        // the timed <span> being read
    NSInteger _depth;                          // element depth inside the <p>
    NSInteger _skipDepth;                      // inside a span left out (backing vocals, translation), its depth; 0 if not
}

- (instancetype)init {
    if ((self = [super init])) _lines = [NSMutableArray array];
    return self;
}

static NSString *NLAttr(NSDictionary *attributes, NSString *name) {
    for (NSString *key in attributes) {
        // Prefixes differ between files (ttm:role, role); compare the local name.
        NSString *local = [key componentsSeparatedByString:@":"].lastObject;
        if ([local isEqualToString:name]) return attributes[key];
    }
    return nil;
}

- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)element namespaceURI:(NSString *)ns
 qualifiedName:(NSString *)qName attributes:(NSDictionary *)attributes {
    NSString *name = [element componentsSeparatedByString:@":"].lastObject;
    if (!_line) {
        if (![name isEqualToString:@"p"]) return;
        NSTimeInterval begin = NLTTMLTime(NLAttr(attributes, @"begin"));
        if (begin < 0) return;
        _line = [NLLyricLine new];
        _line.start = begin;
        _line.end = MAX(NLTTMLTime(NLAttr(attributes, @"end")), 0);
        _lineText = [NSMutableString string];
        _words = [NSMutableArray array];
        _depth = 0;
        _skipDepth = 0;
        return;
    }
    _depth++;
    if (_skipDepth) return;
    NSString *role = NLAttr(attributes, @"role");
    if ([role hasPrefix:@"x-bg"] || [role hasPrefix:@"x-translation"] || [role hasPrefix:@"x-roman"]) {
        _skipDepth = _depth;
        return;
    }
    if ([name isEqualToString:@"span"]) {
        NSTimeInterval begin = NLTTMLTime(NLAttr(attributes, @"begin"));
        if (begin >= 0) {
            _word = [NLLyricWord new];
            _word.start = begin;
            _word.end = MAX(NLTTMLTime(NLAttr(attributes, @"end")), 0);
            _word.text = @"";
        }
    }
}

- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string {
    if (!_line || _skipDepth) return;
    [_lineText appendString:string];
    if (_word) {
        _word.text = [_word.text stringByAppendingString:string];
    } else if (_words.count) {
        // Spacing between spans belongs to the word before it.
        NLLyricWord *last = _words.lastObject;
        last.text = [last.text stringByAppendingString:string];
    }
}

- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)element namespaceURI:(NSString *)ns qualifiedName:(NSString *)qName {
    if (!_line) return;
    if (_depth == 0) {   // the </p>
        [self finishLine];
        return;
    }
    if (_skipDepth == _depth) _skipDepth = 0;
    else if (!_skipDepth && _word) {
        if (_word.text.length) [_words addObject:_word];
        _word = nil;
    }
    _depth--;
}

- (void)finishLine {
    NSCharacterSet *space = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    // Collapse the XML's line breaks and indentation into single spaces.
    for (NLLyricWord *word in _words) {
        word.text = [word.text stringByReplacingOccurrencesOfString:@"\\s+" withString:@" "
                                                            options:NSRegularExpressionSearch
                                                              range:NSMakeRange(0, word.text.length)];
    }
    NSString *plain = [[[_lineText componentsSeparatedByCharactersInSet:space]
                        filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]] componentsJoinedByString:@" "];
    if (_words.count) {
        // The words' own text decides the line, as NLParseLRC does.
        NLLyricLine *line = NLLineFromWords(_words, _line.start, _line.end);
        if (line) [_lines addObject:line];
    } else {
        _line.text = plain;
        if (_line.text.length) [_lines addObject:_line];
    }
    _line = nil;
    _words = nil;
    _word = nil;
}

@end

NSArray<NLLyricLine *> *NLParseTTML(NSString *ttml) {
    NSData *data = [ttml dataUsingEncoding:NSUTF8StringEncoding];
    if (!data) return nil;
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:data];
    NLTTMLReader *reader = [NLTTMLReader new];
    parser.delegate = reader;
    parser.shouldProcessNamespaces = NO;
    if (![parser parse] && reader.lines.count == 0) return nil;
    return NLFinishWordLines(reader.lines);   // sorted, with breaks where lines end long before the next
}

