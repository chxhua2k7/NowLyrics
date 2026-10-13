//
//  NLHistory.m
//  See NLHistory.h.
//

#import "NLHistory.h"
#import <ImageIO/ImageIO.h>

static const NSInteger kNLHistoryVersion = 1;
static const CGFloat kNLHistoryArtworkSide = 180;   // pixels: a 60 pt cover at 3×

static dispatch_queue_t NLHistoryQueue(void) {
    return NL_ONCE(dispatch_queue_create("com.c3x14n.nowlyrics.history", DISPATCH_QUEUE_SERIAL));
}

// yyyy-MM-dd in the current time zone, whatever the calendar and locale.
static NSDateFormatter *NLHistoryDayFormatter(void) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    formatter.dateFormat = @"yyyy-MM-dd";
    return formatter;
}

NSString *NLHistoryDayKey(NSDate *date) {
    return [NLHistoryDayFormatter() stringFromDate:date];
}

NSDate *NLHistoryDayDate(NSString *dayKey) {
    return dayKey.length == 10 ? [NLHistoryDayFormatter() dateFromString:dayKey] : nil;
}

NSString *NLHistoryDayPath(NSString *dayKey) {
    return [NL_HISTORY_DIR stringByAppendingPathComponent:[dayKey stringByAppendingPathExtension:@"json"]];
}

// yyyy-MM-dd by its shape: the folder is listed on every load, and a
// formatter for each of a year's files is not cheap.
static BOOL NLHistoryIsDayKey(NSString *name) {
    if (name.length != 10) return NO;
    for (NSUInteger i = 0; i < 10; i++) {
        unichar c = [name characterAtIndex:i];
        if ((i == 4 || i == 7) ? c != '-' : (c < '0' || c > '9')) return NO;
    }
    return YES;
}

NSArray<NSString *> *NLHistoryDays(void) {
    NSMutableArray<NSString *> *days = [NSMutableArray array];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:NL_HISTORY_DIR error:nil]) {
        if (![name.pathExtension isEqualToString:@"json"]) continue;
        NSString *day = name.stringByDeletingPathExtension;
        if (NLHistoryIsDayKey(day)) [days addObject:day];
    }
    // The names sort as the dates do.
    return [days sortedArrayUsingSelector:@selector(compare:)].reverseObjectEnumerator.allObjects;
}

NSArray<NSDictionary *> *NLHistoryReadDay(NSString *dayKey) {
    NSData *data = [NSData dataWithContentsOfFile:NLHistoryDayPath(dayKey)];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSMutableArray<NSDictionary *> *plays = [NSMutableArray array];
    for (id play in NLArray(json, @"plays")) {
        // Every entry has its id and times; anything else is not one.
        if (NLString(play, NL_HP_ID).length && NLNum(NLValue(play, NL_HP_START), 0) > 0) [plays addObject:play];
    }
    return plays;
}

NSString *NLHistoryArtworkPath(NSString *name) {
    if (![name isKindOfClass:NSString.class] || name.length == 0 || [name containsString:@"/"]) return nil;
    return [NL_HISTORY_ART_DIR stringByAppendingPathComponent:name];
}

// On the queue. Sorted by start; an empty day loses its file.
static BOOL NLHistoryWriteDay(NSString *dayKey, NSArray<NSDictionary *> *plays) {
    NSString *path = NLHistoryDayPath(dayKey);
    if (plays.count == 0) return [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
    NSArray *sorted = [plays sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        return [@(NLNum(a[NL_HP_START], 0)) compare:@(NLNum(b[NL_HP_START], 0))];
    }];
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"version": @(kNLHistoryVersion), @"plays": sorted}
                                                   options:NSJSONWritingSortedKeys error:nil];
    if (!data) return NO;
    [[NSFileManager defaultManager] createDirectoryAtPath:NL_HISTORY_DIR withIntermediateDirectories:YES attributes:nil error:nil];
    return [data writeToFile:path atomically:YES];
}

static NSString *NLHistoryEntryDay(NSDictionary *entry) {
    return NLHistoryDayKey([NSDate dateWithTimeIntervalSince1970:NLNum(entry[NL_HP_START], 0)]);
}

void NLHistorySavePlay(NSDictionary *entry) {
    NSString *identifier = NLString(entry, NL_HP_ID);
    if (!identifier.length || NLNum(entry[NL_HP_START], 0) <= 0) return;
    entry = [entry copy];
    dispatch_async(NLHistoryQueue(), ^{
        NSString *day = NLHistoryEntryDay(entry);
        NSMutableArray<NSDictionary *> *plays = [NLHistoryReadDay(day) mutableCopy];
        NSUInteger at = [plays indexOfObjectPassingTest:^BOOL(NSDictionary *play, NSUInteger i, BOOL *stop) {
            return [play[NL_HP_ID] isEqual:identifier];
        }];
        if (at == NSNotFound) [plays addObject:entry];
        else plays[at] = entry;
        if (NLHistoryWriteDay(day, plays)) NLPostDarwin(NL_HISTORY_WRITTEN_NOTIFICATION);
    });
}

void NLHistorySaveArtwork(NSData *data, NSString *name) {
    NSString *path = NLHistoryArtworkPath(name);
    if (!path || data.length == 0) return;
    dispatch_async(NLHistoryQueue(), ^{
        if ([[NSFileManager defaultManager] fileExistsAtPath:path]) return;
        CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
        if (!source) return;
        NSDictionary *options = @{(__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
                                  (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
                                  (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(kNLHistoryArtworkSide)};
        CGImageRef thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
        CFRelease(source);
        if (!thumbnail) return;
        NSMutableData *jpeg = [NSMutableData data];
        CGImageDestinationRef destination = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, NULL);
        if (destination) {
            CGImageDestinationAddImage(destination, thumbnail, (__bridge CFDictionaryRef)@{(__bridge NSString *)kCGImageDestinationLossyCompressionQuality: @0.8});
            if (CGImageDestinationFinalize(destination)) {
                [[NSFileManager defaultManager] createDirectoryAtPath:NL_HISTORY_ART_DIR withIntermediateDirectories:YES attributes:nil error:nil];
                [jpeg writeToFile:path atomically:YES];
            }
            CFRelease(destination);
        }
        CGImageRelease(thumbnail);
    });
}

void NLHistoryPrune(NSInteger keepDays) {
    dispatch_async(NLHistoryQueue(), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        NSArray<NSString *> *days = NLHistoryDays();
        NSUInteger found = days.count;
        if (keepDays > 0) {
            NSCalendar *calendar = NSCalendar.currentCalendar;
            NSDate *today = [calendar startOfDayForDate:[NSDate date]];
            NSString *oldest = NLHistoryDayKey([calendar dateByAddingUnit:NSCalendarUnitDay value:-(keepDays - 1) toDate:today options:0]);
            NSMutableArray<NSString *> *kept = [NSMutableArray array];
            for (NSString *day in days) {
                if ([day compare:oldest] == NSOrderedAscending) [fm removeItemAtPath:NLHistoryDayPath(day) error:nil];
                else [kept addObject:day];
            }
            days = kept;
        }
        if (days.count < found) NLPostDarwin(NL_HISTORY_WRITTEN_NOTIFICATION);
        // Covers no kept play uses.
        NSMutableSet<NSString *> *used = [NSMutableSet set];
        for (NSString *day in days) {
            for (NSDictionary *play in NLHistoryReadDay(day)) {
                NSString *art = NLString(play, NL_HP_ART);
                if (art) [used addObject:art];
            }
        }
        for (NSString *name in [fm contentsOfDirectoryAtPath:NL_HISTORY_ART_DIR error:nil]) {
            if (![used containsObject:name]) [fm removeItemAtPath:[NL_HISTORY_ART_DIR stringByAppendingPathComponent:name] error:nil];
        }
    });
}

void NLHistoryContainsPlay(NSString *dayKey, NSString *identifier, void (^done)(BOOL found)) {
    dispatch_async(NLHistoryQueue(), ^{
        BOOL found = NO;
        for (NSDictionary *play in NLHistoryReadDay(dayKey)) {
            if ([play[NL_HP_ID] isEqual:identifier]) { found = YES; break; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ done(found); });
    });
}

void NLHistoryDeletePlays(NSString *dayKey, NSSet<NSString *> *identifiers, dispatch_block_t done) {
    dispatch_async(NLHistoryQueue(), ^{
        NSArray *plays = [NLHistoryReadDay(dayKey) filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSDictionary *play, NSDictionary *b) {
            return ![identifiers containsObject:play[NL_HP_ID]];
        }]];
        NLHistoryWriteDay(dayKey, plays);
        NLPostDarwin(NL_HISTORY_EDITED_NOTIFICATION);
        if (done) dispatch_async(dispatch_get_main_queue(), done);
    });
}

void NLHistoryExport(void (^done)(NSData *data, NSUInteger plays)) {
    dispatch_async(NLHistoryQueue(), ^{
        NSMutableDictionary<NSString *, NSArray *> *days = [NSMutableDictionary dictionary];
        NSMutableDictionary<NSString *, NSString *> *artwork = [NSMutableDictionary dictionary];
        NSUInteger count = 0;
        for (NSString *day in NLHistoryDays()) {
            NSArray<NSDictionary *> *plays = NLHistoryReadDay(day);
            if (!plays.count) continue;
            days[day] = plays;
            count += plays.count;
            for (NSDictionary *play in plays) {
                NSString *art = NLString(play, NL_HP_ART);
                if (!art || artwork[art]) continue;
                NSData *jpeg = [NSData dataWithContentsOfFile:NLHistoryArtworkPath(art)];
                if (jpeg) artwork[art] = [jpeg base64EncodedStringWithOptions:0];
            }
        }
        NSDictionary *file = @{@"format": NL_HISTORY_EXPORT_FORMAT, @"version": @(kNLHistoryVersion),
                               @"exported": @(round(NSDate.date.timeIntervalSince1970)), @"days": days, @"artwork": artwork};
        NSData *data = count ? [NSJSONSerialization dataWithJSONObject:file options:NSJSONWritingSortedKeys error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ done(data, count); });
    });
}

NSDictionary *NLHistoryReadExport(NSData *data) {
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    id inDays = NLValue(json, @"days");
    if (![NLString(json, @"format") isEqualToString:NL_HISTORY_EXPORT_FORMAT] || ![inDays isKindOfClass:NSDictionary.class]) return nil;
    NSMutableDictionary<NSString *, NSArray *> *days = [NSMutableDictionary dictionary];
    for (NSString *day in inDays) {
        if (![day isKindOfClass:NSString.class] || !NLHistoryIsDayKey(day)) continue;
        NSMutableArray<NSDictionary *> *plays = [NSMutableArray array];
        for (id play in NLArray(inDays, day)) {
            if (NLString(play, NL_HP_ID).length && NLNum(NLValue(play, NL_HP_START), 0) > 0) [plays addObject:play];
        }
        if (plays.count) days[day] = plays;
    }
    NSMutableDictionary<NSString *, NSData *> *artwork = [NSMutableDictionary dictionary];
    id inArtwork = NLValue(json, @"artwork");
    if ([inArtwork isKindOfClass:NSDictionary.class]) {
        for (NSString *name in inArtwork) {
            NSString *base64 = NLString(inArtwork, name);
            NSData *jpeg = base64 ? [[NSData alloc] initWithBase64EncodedString:base64 options:0] : nil;
            if (jpeg.length && NLHistoryArtworkPath(name)) artwork[name] = jpeg;
        }
    }
    return @{@"days": days, @"artwork": artwork};
}

void NLHistoryImport(NSDictionary *export, BOOL replace, void (^done)(NSUInteger added)) {
    dispatch_async(NLHistoryQueue(), ^{
        NSFileManager *fm = [NSFileManager defaultManager];
        if (replace) {
            for (NSString *day in NLHistoryDays()) [fm removeItemAtPath:NLHistoryDayPath(day) error:nil];
        }
        // By the day each play started on here: another time zone files them otherwise.
        NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *byDay = [NSMutableDictionary dictionary];
        for (NSArray<NSDictionary *> *plays in [export[@"days"] allValues]) {
            for (NSDictionary *play in plays) {
                NSString *day = NLHistoryEntryDay(play);
                if (!byDay[day]) byDay[day] = [NSMutableArray array];
                [byDay[day] addObject:play];
            }
        }
        NSUInteger added = 0;
        for (NSString *day in byDay) {
            NSMutableArray<NSDictionary *> *plays = [NLHistoryReadDay(day) mutableCopy];
            NSMutableSet *identifiers = [NSMutableSet setWithArray:[plays valueForKey:NL_HP_ID]];
            for (NSDictionary *play in byDay[day]) {
                if ([identifiers containsObject:play[NL_HP_ID]]) continue;
                [identifiers addObject:play[NL_HP_ID]];
                [plays addObject:play];
                added++;
            }
            NLHistoryWriteDay(day, plays);
        }
        NSDictionary<NSString *, NSData *> *artwork = export[@"artwork"];
        if (artwork.count) [fm createDirectoryAtPath:NL_HISTORY_ART_DIR withIntermediateDirectories:YES attributes:nil error:nil];
        for (NSString *name in artwork) {
            NSString *path = NLHistoryArtworkPath(name);
            if (path && ![fm fileExistsAtPath:path]) [artwork[name] writeToFile:path atomically:YES];
        }
        // SpringBoard checks the play it is on; the pages load again.
        NLPostDarwin(NL_HISTORY_EDITED_NOTIFICATION);
        NLPostDarwin(NL_HISTORY_WRITTEN_NOTIFICATION);
        dispatch_async(dispatch_get_main_queue(), ^{ done(added); });
    });
}

void NLHistoryDeleteAll(dispatch_block_t done) {
    dispatch_async(NLHistoryQueue(), ^{
        [[NSFileManager defaultManager] removeItemAtPath:NL_HISTORY_DIR error:nil];
        NLPostDarwin(NL_HISTORY_EDITED_NOTIFICATION);
        if (done) dispatch_async(dispatch_get_main_queue(), done);
    });
}
