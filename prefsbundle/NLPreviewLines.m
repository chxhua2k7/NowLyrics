//
//  NLPreviewLines.m
//  What the island preview sings: puns, the day of the week, the hour, today's
//  holiday (Gregorian, or lunar from the Chinese calendar), how much of the
//  year is gone and the battery level. All original; no real lyrics.
//
//  Written per language, since puns do not translate: Traditional Chinese is
//  the full set, Simplified Chinese is the same set run through ICU's
//  Hant-Hans transform, English and Japanese have their own.
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, NLJokeLanguage) { NLJokeHant, NLJokeHans, NLJokeEnglish, NLJokeJapanese };

static NLJokeLanguage NLPreviewLanguage(NSBundle *bundle) {
    NSString *lang = bundle.preferredLocalizations.firstObject ?: @"en";
    if ([lang hasPrefix:@"zh-Hant"] || [lang hasPrefix:@"zh-TW"] || [lang hasPrefix:@"zh-HK"]) return NLJokeHant;
    if ([lang hasPrefix:@"zh"]) return NLJokeHans;
    if ([lang hasPrefix:@"ja"]) return NLJokeJapanese;
    return NLJokeEnglish;
}

#pragma mark - Traditional Chinese

static NSArray<NSString *> *NLHantGeneric(void) {
    return @[
        @"Fa 財了！今天也要 Fa 大財",
        @"Do Re Mi Fa So，我的錢包只剩 La（啦）",
        @"對這首歌死心塌地，Si 心塌地",
        @"島歉，這句歌詞比較長，要慢慢從頭捲到尾，請耐心看完謝謝",
        @"這行字是用『島』具做的，請勿模仿",
        @"歌詞來了，請勿『島』退",
        @"這首歌很『島』地，有台灣味",
        @"動態島今天也有好好上班，島主辛苦了",
        @"高音上不去沒關係，動態島幫你撐著",
        @"聽歌不用錢，耳機要錢，心碎也要錢",
        @"我的歌單跟我的房間一樣，很亂，但我知道東西在哪",
        @"這不是歌詞，是動態島的內心戲",
        @"音樂開大聲一點，煩惱就聽不到了",
        @"沒有歌詞的時候，我就自己編，例如這句",
        @"單曲循環一百次，這首歌已經認識你了",
        @"人生就像跑馬燈，繞了一圈又回到原點，但這次你看清楚每個字了",
    ];
}

static NSArray<NSString *> *NLHantWeekday(NSInteger weekday) {   // 1 = Sunday
    switch (weekday) {
        case 1: return @[@"Sunday 唸快一點就是『散 day』，週末要散場了",
                         @"星期天晚上的憂鬱，學名叫『明天要上班』"];
        case 2: return @[@"Monday 根本是『悶 day』",
                         @"星期一的電量，跟這首歌的低音一樣低"];
        case 3: return @[@"Tuesday 唸快一點就是『吐死 day』，撐住"];
        case 4: return @[@"星期三是一週的三明治，夾在中間最難熬"];
        case 5: return @[@"Thursday 聽起來好像『受死 day』，明天就星期五了",
                         @"瘋狂星期四，V 我 50 買耳機"];
        case 6: return @[@"Friday 是『福來 day』，福氣跟週末一起來"];
        default: return @[@"星期六，鬧鐘請假，我也請假",
                          @"Saturday 是『殺』時間 day，最適合聽歌"];
    }
}

static NSArray<NSString *> *NLHantHour(NSInteger hour) {
    if (hour < 5) return @[[NSString stringWithFormat:@"凌晨 %ld 點還在聽歌？黑眼圈也跟著打拍子", (long)hour],
                           @"熬夜聽歌，肝在唱 R&B：Really Bad",
                           @"這麼晚了，連歌詞都想睡了 zzz",
                           @"深夜的歌特別好聽，因為沒人跟你搶耳機"];
    if (hour < 11) return @[@"早安！今天第一首歌是鬧鐘的高音",
                            @"早餐吃了沒？歌詞已經先吃飽了"];
    if (hour < 14) return @[@"午餐吃什麼？這是比歌詞還難的問題"];
    if (hour < 18) return @[[NSString stringWithFormat:@"下午 %ld 點，『睏』境中的你需要一首快歌", (long)(hour - 12)]];
    return @[@"下班了！耳機一戴，世界與我無關",
             @"晚上好，今天辛苦了，這句歌詞送你"];
}

static NSString *NLHantHoliday(NSInteger month, NSInteger day, NSInteger lunarMonth, NSInteger lunarDay) {
    if (lunarMonth == 1 && lunarDay == 1) return @"新年快樂！Fa 財 Fa 財，紅包拿來";
    if (lunarMonth == 1 && lunarDay == 15) return @"元宵節快樂，湯圓圓，歌詞也要圓滿";
    if (lunarMonth == 5 && lunarDay == 5) return @"端午節快樂，『粽』有一句歌詞適合你";
    if (lunarMonth == 7 && lunarDay == 7) return @"七夕快樂，牛郎織女遠距離，你跟耳機零距離";
    if (lunarMonth == 8 && lunarDay == 15) return @"中秋節快樂，月餅吃太多，肚子『柚』點撐";
    if (month == 1 && day == 1) return @"元旦快樂！今年也要『元』氣滿滿";
    if (month == 2 && day == 14) return @"情人節快樂，單身的請自動切換成單曲循環";
    if (month == 3 && day == 14) return @"3.14 圓周率日，這句歌詞無限不循環";
    if (month == 4 && day == 1) return @"愚人節快樂！這句歌詞是假的（嗎？）";
    if (month == 4 && day == 4) return @"兒童節快樂，今天大家都可以假裝自己是小孩";
    if (month == 5 && day == 20) return @"520 我愛你，但歌詞比較愛你";
    if (month == 5 && day == 21) return @"521，我餓了";
    if (month == 8 && day == 8) return @"88 節快樂，爸爸的歌單永遠停在 1998";
    if (month == 9 && day == 28) return @"教師節快樂，老師說這句歌詞要背起來";
    if (month == 10 && day == 10) return @"雙十節快樂！今天的歌詞十全十美";
    if (month == 10 && day == 31) return @"Trick or Treat！不給歌詞就『島』蛋";
    if (month == 11 && day == 11) return @"11/11 光棍節，四根光棍陪你聽歌";
    if (month == 12 && (day == 24 || day == 25)) return @"聖誕快樂！麋鹿說它也想上島";
    if (month == 12 && day == 31) return @"今年最後一天，今年的歌詞到此為止";
    return nil;
}

static NSArray<NSString *> *NLHantFacts(NSInteger yearPercent, NSInteger daysToNewYear, NSInteger battery) {
    NSMutableArray *lines = [NSMutableArray arrayWithObjects:
        [NSString stringWithFormat:@"今年已經過了 %ld%%，新年新希望的進度呢？", (long)yearPercent],
        [NSString stringWithFormat:@"距離跨年還有 %ld 天，跨年歌單可以開始排了", (long)daysToNewYear], nil];
    if (battery >= 0 && battery <= 20) [lines addObject:[NSString stringWithFormat:@"電量剩 %ld%%，跟星期一的我一樣", (long)battery]];
    else if (battery >= 80) [lines addObject:[NSString stringWithFormat:@"電量 %ld%%，比你的社交電量還滿", (long)battery]];
    return lines;
}

#pragma mark - English

static NSArray<NSString *> *NLEnglishGeneric(void) {
    return @[
        @"Treble is my middle name",
        @"Sorry, I'm Haydn from my responsibilities",
        @"I'd tell you a pitch joke, but it might fall flat",
        @"Why did the singer bring a ladder? For the high notes",
        @"Bach to back bangers, coming up",
        @"This island has no beach, only bangers",
        @"Not a lyric, just the island thinking out loud",
        @"A longer line like this one scrolls slowly from start to end, so you never miss a word",
    ];
}

static NSArray<NSString *> *NLEnglishWeekday(NSInteger weekday) {
    switch (weekday) {
        case 1: return @[@"Sunday scaries are warming up their vocals"];
        case 2: return @[@"Monday: the bass is low, and so is my energy"];
        case 3: return @[@"Tuesday: the only weekday named after tacos (probably)"];
        case 4: return @[@"Wednesday: the sandwich filling of the week"];
        case 5: return @[@"Thursday: not Friday, but emotionally Friday"];
        case 6: return @[@"Friday? More like Fri-YAY"];
        default: return @[@"Saturday: alarm clock on mute, volume on max"];
    }
}

static NSArray<NSString *> *NLEnglishHour(NSInteger hour) {
    NSInteger h12 = hour % 12 ?: 12;
    if (hour < 5) return @[[NSString stringWithFormat:@"It's %ld AM. Even your playlist is yawning", (long)h12]];
    if (hour < 11) return @[@"Good morning! Your alarm already hit the high note"];
    if (hour < 14) return @[@"Lunch break: the hardest lyric is \"what do we eat\""];
    if (hour < 18) return @[[NSString stringWithFormat:@"%ld PM slump detected. Deploying bangers", (long)h12]];
    return @[@"Off work. Headphones on, world off"];
}

static NSString *NLEnglishHoliday(NSInteger month, NSInteger day) {
    if (month == 1 && day == 1) return @"New year, same playlist";
    if (month == 2 && day == 14) return @"Happy Valentine's! Single? Put yourself on repeat";
    if (month == 3 && day == 14) return @"Pi Day: this line is irrational and never repeats";
    if (month == 4 && day == 1) return @"April Fools'! This lyric is fake. Or is it?";
    if (month == 10 && day == 31) return @"Trick or treble!";
    if (month == 12 && (day == 24 || day == 25)) return @"Fa la la la la, island la la la";
    if (month == 12 && day == 31) return @"Last day of the year. Skip intro?";
    return nil;
}

static NSArray<NSString *> *NLEnglishFacts(NSInteger yearPercent, NSInteger daysToNewYear, NSInteger battery) {
    NSMutableArray *lines = [NSMutableArray arrayWithObjects:
        [NSString stringWithFormat:@"The year is %ld%% done. How are those resolutions?", (long)yearPercent],
        [NSString stringWithFormat:@"%ld days to New Year's Eve. Countdown playlist, anyone?", (long)daysToNewYear], nil];
    if (battery >= 0 && battery <= 20) [lines addObject:[NSString stringWithFormat:@"Battery at %ld%%. Same, honestly", (long)battery]];
    else if (battery >= 80) [lines addObject:[NSString stringWithFormat:@"Battery %ld%%, more than your social battery", (long)battery]];
    return lines;
}

#pragma mark - Japanese

static NSArray<NSString *> *NLJapaneseGeneric(void) {
    return @[
        @"島で歌詞を……しまった！",
        @"ドレミファソラシド、財布はソラ（空）",
        @"布団が吹っ飛んだ、歌詞も飛んできた",
        @"アルミ缶の上にあるミカン、島の上にある歌詞",
        @"高い音が出なくても大丈夫、島が支えてる",
        @"長い行はこんなふうに、最初から最後までゆっくり流れるので一文字も逃しません",
    ];
}

static NSArray<NSString *> *NLJapaneseWeekday(NSInteger weekday) {
    switch (weekday) {
        case 1: return @[@"日曜の夜は、明日が月曜という事実と戦う"];
        case 2: return @[@"月曜日、ゲッソリ曜日"];
        case 6: return @[@"金曜日は、お金より休みがほしい"];
        default: return @[@"今日もイヤホンが相棒"];
    }
}

static NSArray<NSString *> *NLJapaneseHour(NSInteger hour) {
    if (hour < 5) return @[[NSString stringWithFormat:@"%ld時まだ起きてる？夜更かしはお肌も歌詞も荒れる", (long)hour]];
    if (hour < 11) return @[@"おはよう！今日の一曲目は目覚ましの高音"];
    if (hour >= 18) return @[@"おつかれさま、この一行をどうぞ"];
    return @[@"お昼何食べる？歌詞より難しい問題"];
}

static NSString *NLJapaneseHoliday(NSInteger month, NSInteger day) {
    if (month == 1 && day == 1) return @"あけおめ！今年も歌詞よろ";
    if (month == 10 && day == 31) return @"トリック・オア・トリート！歌詞くれなきゃいたずらするぞ";
    if (month == 12 && (day == 24 || day == 25)) return @"メリークリスマス！トナカイも島に乗りたい";
    return nil;
}

#pragma mark - Pool

// Everything worth saying right now. Today's holiday goes in three times, so
// it comes round often.
NSArray<NSString *> *NLPreviewLinePool(NSBundle *bundle) {
    NSDate *now = [NSDate date];
    NSCalendar *greg = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSDateComponents *c = [greg components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                                           NSCalendarUnitWeekday | NSCalendarUnitHour fromDate:now];
    NSCalendar *lunar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierChinese];
    NSDateComponents *l = [lunar components:NSCalendarUnitMonth | NSCalendarUnitDay fromDate:now];
    BOOL leapLunarMonth = l.isLeapMonth;

    NSDate *yearStart = [greg dateFromComponents:({ NSDateComponents *y = [NSDateComponents new]; y.year = c.year; y.month = 1; y.day = 1; y; })];
    NSDate *nextYear = [greg dateByAddingUnit:NSCalendarUnitYear value:1 toDate:yearStart options:0];
    NSInteger yearPercent = (NSInteger)floor([now timeIntervalSinceDate:yearStart] / [nextYear timeIntervalSinceDate:yearStart] * 100);
    NSDate *today = [greg startOfDayForDate:now];
    NSInteger daysToNewYear = [greg components:NSCalendarUnitDay fromDate:today toDate:[greg dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:nextYear options:0] options:0].day;

    UIDevice *device = UIDevice.currentDevice;
    device.batteryMonitoringEnabled = YES;
    NSInteger battery = device.batteryLevel < 0 ? -1 : (NSInteger)round(device.batteryLevel * 100);

    NLJokeLanguage language = NLPreviewLanguage(bundle);
    NSMutableArray<NSString *> *pool = [NSMutableArray array];
    NSString *holiday = nil;
    switch (language) {
        case NLJokeHant:
        case NLJokeHans:
            [pool addObjectsFromArray:NLHantGeneric()];
            [pool addObjectsFromArray:NLHantWeekday(c.weekday)];
            [pool addObjectsFromArray:NLHantHour(c.hour)];
            [pool addObjectsFromArray:NLHantFacts(yearPercent, daysToNewYear, battery)];
            holiday = NLHantHoliday(c.month, c.day, leapLunarMonth ? 0 : l.month, l.day);
            break;
        case NLJokeJapanese:
            [pool addObjectsFromArray:NLJapaneseGeneric()];
            [pool addObjectsFromArray:NLJapaneseWeekday(c.weekday)];
            [pool addObjectsFromArray:NLJapaneseHour(c.hour)];
            holiday = NLJapaneseHoliday(c.month, c.day);
            break;
        case NLJokeEnglish:
            [pool addObjectsFromArray:NLEnglishGeneric()];
            [pool addObjectsFromArray:NLEnglishWeekday(c.weekday)];
            [pool addObjectsFromArray:NLEnglishHour(c.hour)];
            [pool addObjectsFromArray:NLEnglishFacts(yearPercent, daysToNewYear, battery)];
            holiday = NLEnglishHoliday(c.month, c.day);
            break;
    }
    if (holiday) [pool addObjectsFromArray:@[holiday, holiday, holiday]];

    if (language == NLJokeHans) {
        NSMutableArray *simplified = [NSMutableArray arrayWithCapacity:pool.count];
        for (NSString *line in pool) [simplified addObject:[line stringByApplyingTransform:@"Hant-Hans" reverse:NO] ?: line];
        return simplified;
    }
    return pool;
}
