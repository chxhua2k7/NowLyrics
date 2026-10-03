//
//  NLPreviewLines.m
//  What the island preview sings: puns, the day of the week, the hour (and a
//  few special minutes), the month, the start and end of a month, today's
//  holiday (Gregorian, or lunar from the Chinese calendar), how much of the
//  year is gone and the battery. All original; no real lyrics.
//
//  Written per language, since puns do not translate: Chinese is the full set
//  (in Traditional characters for everyone reading Chinese), English and
//  Japanese have their own.
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, NLJokeLanguage) { NLJokeChinese, NLJokeEnglish, NLJokeJapanese };

static NLJokeLanguage NLPreviewLanguage(NSBundle *bundle) {
    NSString *lang = bundle.preferredLocalizations.firstObject ?: @"en";
    if ([lang hasPrefix:@"zh"]) return NLJokeChinese;
    if ([lang hasPrefix:@"ja"]) return NLJokeJapanese;
    return NLJokeEnglish;
}

// Everything about "now" the lines can use.
typedef struct {
    NSInteger month, day, weekday, hour, minute;   // weekday: 1 = Sunday
    NSInteger lunarMonth, lunarDay;                // 0 in a leap lunar month
    BOOL lunarNewYearsEve;
    NSInteger dayOfYear, yearPercent, daysToNewYear, daysLeftInMonth, daysToSaturday;
    NSInteger battery;                             // percent, -1 unknown
    BOOL charging;
} NLNow;

#pragma mark - Chinese

static NSArray<NSString *> *NLChineseGeneric(void) {
    return @[
        // The island
        @"這行字是用『島』具做的，請勿模仿",
        @"歌詞來了，請勿『島』退",
        @"這首歌很『島』地，有台灣味",
        @"島主，你的歌詞到了，請簽收",
        @"本島今日天氣晴，歌詞降雨機率 100%",
        @"上島不用船票，只要一首歌",
        @"動態島：我不胖，我只是比較會撐",
        @"這座島沒有沙灘，只有金曲",
        @"別擔心，這座島不會沉，除非你沒電",
        @"動態島今天也有好好上班，島主辛苦了",
        @"島歉，這句歌詞比較長，要慢慢從頭捲到尾，請耐心看完謝謝",
        @"歌詞背不起來沒關係，動態島幫你背",
        @"這句不是歌詞，是 NowLyrics 在偷偷講話",
        // Notes and singing
        @"Fa 財了！今天也要 Fa 大財",
        @"Do Re Mi Fa So，我的錢包只剩 La（啦）",
        @"對這首歌死心塌地，Si 心塌地",
        @"好想 Mi 一下（瞇一下），歌詞先幫我看著",
        @"副歌來了，富哥也來了，可惜不是我",
        @"我唱歌不走音，是音自己走掉的",
        @"高音上不去，就用氣音假裝很有感情",
        @"前奏三秒猜歌名，這是我唯一的才藝",
        @"副歌一來，方向盤都變成鼓",
        @"歌手換氣的時候，我也趕快換氣",
        @"單曲循環第 99 次，連隔壁鄰居都會唱了",
        @"跟著唱可以，但請不要在捷運上",
        @"節奏感很好，就是每一拍都跟不上",
        @"耳機一戴，誰都不愛",
        @"隨機播放，播來播去都是那三首",
        @"我的歌單：一半是回憶，一半是廣告",
        @"年度回顧還沒出來，先別檢討我聽了什麼",
        @"藍牙耳機只剩一邊有電，人生就是這麼不平衡",
        @"AirPods 又找不到了，這句歌詞先陪你",
        @"這首歌的 BPM 跟我的心跳一樣快，因為咖啡喝太多",
        @"聽歌不用錢，耳機要錢，心碎也要錢",
        @"我的歌單跟我的房間一樣，很亂，但我知道東西在哪",
        @"音樂開大聲一點，煩惱就聽不到了",
        @"單曲循環一百次，這首歌已經認識你了",
        @"人生就像跑馬燈，繞了一圈又回到原點，但這次你看清楚每個字了",
        // Fruit and food
        @"『梨』不開這首歌",
        @"你『芋』見了這句歌詞",
        @"我們『柚』緣，這句被你看到了",
        @"『莓』有你的日子，只好聽歌",
        @"『桃』不出這首歌的手掌心",
        @"再『芒』也要聽首歌",
        @"『蕉』個朋友吧，一起聽歌",
        @"鳳梨酥說：旺來！歌詞也旺來",
        @"『蔥』明的人都在聽歌",
        @"『醬』子聽歌最對味",
        @"雞排要切嗎？不用，歌詞也不用切",
        @"珍奶不能沒有珍珠，歌不能沒有歌詞",
        // Animals
        @"『鴨』力山大？聽首歌放鬆一下",
        @"『鹿』過的人都聽到了",
        @"『熊』心壯志，先聽完這首再說",
        @"『象』你這麼會聽歌的人不多了",
        @"『貓』病又犯了，又單曲循環",
        @"『魚』你一起聽歌",
        @"『鯨』喜！這句是彩蛋",
        @"好了好了，『狗』了，下一首",
    ];
}

static NSArray<NSString *> *NLChineseWeekday(NSInteger weekday) {
    switch (weekday) {
        case 1: return @[@"Sunday 唸快一點就是『散 day』，週末要散場了",
                         @"星期天晚上的憂鬱，學名叫『明天要上班』",
                         @"星期天：鬧鐘說它也要休假",
                         @"『粥』末最後一天，好好喝粥"];
        case 2: return @[@"Monday 根本是『悶 day』",
                         @"星期一的電量，跟這首歌的低音一樣低",
                         @"星期一症候群，症狀：一直想按跳過",
                         @"星期一，連歌詞都不想上班"];
        case 3: return @[@"Tuesday 唸快一點就是『吐死 day』，撐住",
                         @"星期二：一週最沒存在感的一天，跟第二段主歌一樣",
                         @"星期二，離週末還有好幾首歌的距離"];
        case 4: return @[@"星期三是一週的三明治，夾在中間最難熬",
                         @"小週末！今天可以偷偷多聽一首",
                         @"Wednesday 唸起來像『溫死 day』，記得多喝水"];
        case 5: return @[@"Thursday 聽起來像『受死 day』，明天就星期五了",
                         @"瘋狂星期四，V 我 50 買耳機",
                         @"星期四：週末的前奏已經響起"];
        case 6: return @[@"Friday 是『福來 day』，福氣跟週末一起來",
                         @"TGIF：Thank God It's 副歌",
                         @"星期五下班的腳步，比這首歌的 BPM 還快"];
        default: return @[@"星期六，鬧鐘請假，我也請假",
                          @"Saturday 是『殺』時間 day，最適合聽歌",
                          @"週六沒有早上，只有中午"];
    }
}

static NSArray<NSString *> *NLChineseHour(NSInteger hour, NSInteger minute) {
    NSMutableArray *lines = [NSMutableArray array];
    if (hour == 11 && minute == 11) [lines addObject:@"11:11，快許願：歌詞永遠對拍"];
    if (hour == 12 && minute == 34) [lines addObject:@"12:34，連時間都在數拍子"];
    if (hour == 13 && minute == 14) [lines addObject:@"13:14，一生一世，這首歌也是"];
    if (hour == 5 && minute == 20) [lines addObject:@"5:20 我愛你，這個時間還醒著也是蠻愛的"];
    if (hour == 22 && minute == 22) [lines addObject:@"22:22，四個 2，今天 2 到底"];
    if (hour < 5) {
        [lines addObjectsFromArray:@[[NSString stringWithFormat:@"凌晨 %ld 點還在聽歌？黑眼圈也跟著打拍子", (long)hour],
                                     @"熬夜聽歌，肝在唱 R&B：Really Bad",
                                     @"這麼晚了，連歌詞都想睡了 zzz",
                                     @"深夜的歌特別好聽，因為沒人跟你搶耳機",
                                     @"這個時間還醒著的，只有你、我和外送員",
                                     @"再聽一首就睡（今晚第 8 次說）"]];
    } else if (hour < 9) {
        [lines addObjectsFromArray:@[@"『棗』安！早起的鳥兒有歌聽",
                                     @"早安！今天第一首歌是鬧鐘的高音",
                                     @"通勤時間到，耳機是你的結界"]];
    } else if (hour < 12) {
        [lines addObjectsFromArray:@[@"早餐吃了沒？歌詞已經先吃飽了",
                                     @"上班偷聽歌，老闆看不到動態島"]];
    } else if (hour < 14) {
        [lines addObjectsFromArray:@[@"午餐吃什麼？這是比歌詞還難的問題",
                                     @"吃飽了好想 Mi 一下"]];
    } else if (hour < 18) {
        [lines addObjectsFromArray:@[[NSString stringWithFormat:@"下午 %ld 點，『睏』境中的你需要一首快歌", (long)(hour - 12)],
                                     @"下午茶：手搖飲微糖少冰，歌詞全糖"]];
    } else if (hour < 21) {
        [lines addObjectsFromArray:@[@"下班了！耳機一戴，世界與我無關",
                                     @"晚餐時間，配一首歌下飯"]];
    } else {
        [lines addObjectsFromArray:@[@"晚上好，今天辛苦了，這句歌詞送你",
                                     @"洗澡時間到，浴室演唱會即將開始",
                                     @"該睡了，但是，再一首"]];
    }
    return lines;
}

static NSString *NLChineseMonth(NSInteger month) {
    switch (month) {
        case 1: return @"一月：新年新希望，舊年舊歌單";
        case 2: return @"二月天數最少，歌單一樣長";
        case 3: return @"三月，春天來了，過敏也來了，鼻音最適合唱情歌";
        case 4: return @"四月的天氣，跟隨機播放一樣難猜";
        case 5: return @"五月天？不是，是五月的天";
        case 6: return @"六月梅雨季，連歌詞都濕濕的";
        case 7: return @"七月，熱到耳機都在流汗";
        case 8: return @"八月颱風多，颱風假請在家聽歌";
        case 9: return @"九月開學，學生的歌單突然變得很勵志";
        case 10: return @"十月秋天到，情歌的季節來了";
        case 11: return @"十一月：購物車滿了，錢包空了，歌單還在";
        default: return @"十二月，聖誕歌開始無限循環，誰都逃不掉";
    }
}

static NSString *NLChineseHoliday(NLNow n) {
    if (n.lunarNewYearsEve) return @"除夕快樂！今晚的歌單：圍爐、紅包、倒數";
    if (n.lunarMonth == 1 && n.lunarDay == 1) return @"新年快樂！Fa 財 Fa 財，紅包拿來";
    if (n.lunarMonth == 1 && n.lunarDay == 15) return @"元宵節快樂，湯圓圓，歌詞也要圓滿";
    if (n.lunarMonth == 5 && n.lunarDay == 5) return @"端午節快樂，『粽』有一句歌詞適合你";
    if (n.lunarMonth == 7 && n.lunarDay == 7) return @"七夕快樂，牛郎織女遠距離，你跟耳機零距離";
    if (n.lunarMonth == 7 && n.lunarDay == 15) return @"中元節，好兄弟也在聽，音量小聲一點";
    if (n.lunarMonth == 8 && n.lunarDay == 15) return @"中秋節快樂，月餅吃太多，肚子『柚』點撐";
    if (n.month == 5 && n.weekday == 1 && n.day >= 8 && n.day <= 14) return @"母親節快樂！媽媽的手機鈴聲十年沒換過";
    if (n.month == 1 && n.day == 1) return @"元旦快樂！今年也要『元』氣滿滿";
    if (n.month == 2 && n.day == 14) return @"情人節快樂，單身的請自動切換成單曲循環";
    if (n.month == 2 && n.day == 29) return @"2/29，四年一次，跟我認真聽完一張專輯的頻率一樣";
    if (n.month == 3 && n.day == 14) return @"3.14 圓周率日，這句歌詞無限不循環";
    if (n.month == 4 && n.day == 1) return @"愚人節快樂！這句歌詞是假的（嗎？）";
    if (n.month == 4 && n.day == 4) return @"兒童節快樂，今天大家都可以假裝自己是小孩";
    if (n.month == 5 && n.day == 1) return @"勞動節快樂，今天耳朵也放假，只聽喜歡的";
    if (n.month == 5 && n.day == 20) return @"520 我愛你，但歌詞比較愛你";
    if (n.month == 5 && n.day == 21) return @"521，我餓了";
    if (n.month == 8 && n.day == 8) return @"88 節快樂，爸爸的歌單永遠停在 1998";
    if (n.month == 9 && n.day == 28) return @"教師節快樂，老師說這句歌詞要背起來";
    if (n.month == 10 && n.day == 10) return @"雙十節快樂！今天的歌詞十全十美";
    if (n.month == 10 && n.day == 31) return @"Trick or Treat！不給歌詞就『島』蛋";
    if (n.month == 11 && n.day == 11) return @"11/11 光棍節，四根光棍陪你聽歌";
    if (n.month == 12 && (n.day == 24 || n.day == 25)) return @"聖誕快樂！麋鹿說牠也想上島";
    if (n.month == 12 && n.day == 31) return @"今年最後一天，今年的歌詞到此為止";
    if (n.day == 13 && n.weekday == 6) return @"13 號星期五，這句歌詞有點毛";
    return nil;
}

static NSArray<NSString *> *NLChineseFacts(NLNow n) {
    NSMutableArray *lines = [NSMutableArray arrayWithObjects:
        [NSString stringWithFormat:@"今年已經過了 %ld%%，新年新希望的進度呢？", (long)n.yearPercent],
        [NSString stringWithFormat:@"距離跨年還有 %ld 天，跨年歌單可以開始排了", (long)n.daysToNewYear],
        [NSString stringWithFormat:@"今天是今年的第 %ld 天，你大概已經聽了 %ld 首歌（亂猜的）", (long)n.dayOfYear, (long)(n.dayOfYear * 23)],
        NLChineseMonth(n.month), nil];
    if (n.daysToSaturday == 0 || n.weekday == 1) [lines addObject:@"今天是週末，好好聽歌，不准想工作"];
    else [lines addObject:[NSString stringWithFormat:@"距離週末還有 %ld 天，大約 %ld 首歌", (long)n.daysToSaturday, (long)(n.daysToSaturday * 340)]];
    if (n.day <= 3) [lines addObject:@"月初，錢包還很有自信"];
    if (n.daysLeftInMonth <= 3) [lines addObject:@"月底了，錢包跟副歌前的停頓一樣安靜"];
    else [lines addObject:[NSString stringWithFormat:@"這個月還剩 %ld 天，撐住", (long)n.daysLeftInMonth]];
    if (n.charging) [lines addObject:@"正在充電中，跟我一樣需要休息"];
    if (n.battery >= 100) [lines addObject:@"電量 100%，滿到可以單曲循環一整天"];
    else if (n.battery >= 80) [lines addObject:[NSString stringWithFormat:@"電量 %ld%%，比你的社交電量還滿", (long)n.battery]];
    else if (n.battery >= 0 && n.battery <= 20) [lines addObject:[NSString stringWithFormat:@"電量剩 %ld%%，跟星期一的我一樣", (long)n.battery]];
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
        @"I don't sing off-key. The key moves away from me",
        @"Shuffle mode: the same three songs, in a new order",
        @"One AirPod left with battery. Life is unbalanced",
        @"My playlist is like my room: a mess, but I know where everything is",
        @"Can't remember the lyrics? The island has you covered",
        @"A longer line like this one scrolls slowly from start to end, so you never miss a word",
    ];
}

static NSArray<NSString *> *NLEnglishWeekday(NSInteger weekday) {
    switch (weekday) {
        case 1: return @[@"Sunday scaries are warming up their vocals"];
        case 2: return @[@"Monday: the bass is low, and so is my energy"];
        case 3: return @[@"Tuesday: the second verse of the week"];
        case 4: return @[@"Wednesday: the sandwich filling of the week"];
        case 5: return @[@"Thursday: not Friday, but emotionally Friday"];
        case 6: return @[@"Friday? More like Fri-YAY", @"TGIF: Thank God It's the chorus"];
        default: return @[@"Saturday: alarm clock on mute, volume on max"];
    }
}

static NSArray<NSString *> *NLEnglishHour(NSInteger hour, NSInteger minute) {
    NSInteger h12 = hour % 12 ?: 12;
    NSMutableArray *lines = [NSMutableArray array];
    if (hour % 12 == 11 && minute == 11) [lines addObject:@"11:11, make a wish: lyrics always on beat"];
    if (hour < 5) [lines addObjectsFromArray:@[[NSString stringWithFormat:@"It's %ld AM. Even your playlist is yawning", (long)h12],
                                               @"Still awake: you, me and the delivery driver",
                                               @"One more song and then sleep (said for the 8th time)"]];
    else if (hour < 11) [lines addObject:@"Good morning! Your alarm already hit the high note"];
    else if (hour < 14) [lines addObject:@"Lunch break: the hardest lyric is \"what do we eat\""];
    else if (hour < 18) [lines addObject:[NSString stringWithFormat:@"%ld PM slump detected. Deploying bangers", (long)h12]];
    else [lines addObjectsFromArray:@[@"Off work. Headphones on, world off", @"Shower concert starting soon"]];
    return lines;
}

static NSString *NLEnglishHoliday(NLNow n) {
    if (n.month == 1 && n.day == 1) return @"New year, same playlist";
    if (n.month == 2 && n.day == 14) return @"Happy Valentine's! Single? Put yourself on repeat";
    if (n.month == 3 && n.day == 14) return @"Pi Day: this line is irrational and never repeats";
    if (n.month == 4 && n.day == 1) return @"April Fools'! This lyric is fake. Or is it?";
    if (n.month == 10 && n.day == 31) return @"Trick or treble!";
    if (n.month == 12 && (n.day == 24 || n.day == 25)) return @"Fa la la la la, island la la la";
    if (n.month == 12 && n.day == 31) return @"Last day of the year. Skip intro?";
    if (n.day == 13 && n.weekday == 6) return @"Friday the 13th. This lyric is a little spooky";
    return nil;
}

static NSArray<NSString *> *NLEnglishFacts(NLNow n) {
    NSMutableArray *lines = [NSMutableArray arrayWithObjects:
        [NSString stringWithFormat:@"The year is %ld%% done. How are those resolutions?", (long)n.yearPercent],
        [NSString stringWithFormat:@"%ld days to New Year's Eve. Countdown playlist, anyone?", (long)n.daysToNewYear], nil];
    if (n.charging) [lines addObject:@"Charging. Same, honestly"];
    if (n.battery >= 80) [lines addObject:[NSString stringWithFormat:@"Battery %ld%%, more than your social battery", (long)n.battery]];
    else if (n.battery >= 0 && n.battery <= 20) [lines addObject:[NSString stringWithFormat:@"Battery at %ld%%. Monday energy", (long)n.battery]];
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
        @"シャッフル再生、結局いつもの三曲",
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
    if (hour < 5) return @[[NSString stringWithFormat:@"%ld時まだ起きてる？夜更かしはお肌も歌詞も荒れる", (long)hour],
                           @"あと一曲だけ（本日8回目）"];
    if (hour < 11) return @[@"おはよう！今日の一曲目は目覚ましの高音"];
    if (hour >= 18) return @[@"おつかれさま、この一行をどうぞ"];
    return @[@"お昼何食べる？歌詞より難しい問題"];
}

static NSString *NLJapaneseHoliday(NLNow n) {
    if (n.month == 1 && n.day == 1) return @"あけおめ！今年も歌詞よろ";
    if (n.month == 10 && n.day == 31) return @"トリック・オア・トリート！歌詞くれなきゃいたずらするぞ";
    if (n.month == 12 && (n.day == 24 || n.day == 25)) return @"メリークリスマス！トナカイも島に乗りたい";
    return nil;
}

#pragma mark - Pool

static NLNow NLCurrentNow(void) {
    NLNow n = {0};
    NSDate *now = [NSDate date];
    NSCalendar *greg = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    NSDateComponents *c = [greg components:NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay |
                                           NSCalendarUnitWeekday | NSCalendarUnitHour | NSCalendarUnitMinute fromDate:now];
    n.month = c.month; n.day = c.day; n.weekday = c.weekday; n.hour = c.hour; n.minute = c.minute;

    NSCalendar *lunar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierChinese];
    NSDateComponents *l = [lunar components:NSCalendarUnitMonth | NSCalendarUnitDay fromDate:now];
    n.lunarMonth = l.isLeapMonth ? 0 : l.month;
    n.lunarDay = l.day;
    NSDateComponents *tomorrow = [lunar components:NSCalendarUnitMonth | NSCalendarUnitDay
                                          fromDate:[greg dateByAddingUnit:NSCalendarUnitDay value:1 toDate:now options:0]];
    n.lunarNewYearsEve = !tomorrow.isLeapMonth && tomorrow.month == 1 && tomorrow.day == 1;

    NSDateComponents *jan1 = [NSDateComponents new];
    jan1.year = c.year; jan1.month = 1; jan1.day = 1;
    NSDate *yearStart = [greg dateFromComponents:jan1];
    NSDate *nextYear = [greg dateByAddingUnit:NSCalendarUnitYear value:1 toDate:yearStart options:0];
    NSDate *today = [greg startOfDayForDate:now];
    n.dayOfYear = [greg ordinalityOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitYear forDate:now];
    n.yearPercent = (NSInteger)floor([now timeIntervalSinceDate:yearStart] / [nextYear timeIntervalSinceDate:yearStart] * 100);
    NSDate *newYearsEve = [greg dateByAddingUnit:NSCalendarUnitDay value:-1 toDate:nextYear options:0];
    n.daysToNewYear = [greg components:NSCalendarUnitDay fromDate:today toDate:newYearsEve options:0].day;
    n.daysLeftInMonth = [greg rangeOfUnit:NSCalendarUnitDay inUnit:NSCalendarUnitMonth forDate:now].length - c.day;
    n.daysToSaturday = (7 - c.weekday) % 7;   // Saturday is 7

    UIDevice *device = UIDevice.currentDevice;
    device.batteryMonitoringEnabled = YES;
    n.battery = device.batteryLevel < 0 ? -1 : (NSInteger)round(device.batteryLevel * 100);
    n.charging = device.batteryState == UIDeviceBatteryStateCharging;
    return n;
}

// Everything worth saying right now. Today's holiday goes in three times, so
// it comes round often.
NSArray<NSString *> *NLPreviewLinePool(NSBundle *bundle) {
    NLNow n = NLCurrentNow();
    NSMutableArray<NSString *> *pool = [NSMutableArray array];
    NSString *holiday = nil;
    switch (NLPreviewLanguage(bundle)) {
        case NLJokeChinese:
            [pool addObjectsFromArray:NLChineseGeneric()];
            [pool addObjectsFromArray:NLChineseWeekday(n.weekday)];
            [pool addObjectsFromArray:NLChineseHour(n.hour, n.minute)];
            [pool addObjectsFromArray:NLChineseFacts(n)];
            holiday = NLChineseHoliday(n);
            break;
        case NLJokeJapanese:
            [pool addObjectsFromArray:NLJapaneseGeneric()];
            [pool addObjectsFromArray:NLJapaneseWeekday(n.weekday)];
            [pool addObjectsFromArray:NLJapaneseHour(n.hour)];
            holiday = NLJapaneseHoliday(n);
            break;
        case NLJokeEnglish:
            [pool addObjectsFromArray:NLEnglishGeneric()];
            [pool addObjectsFromArray:NLEnglishWeekday(n.weekday)];
            [pool addObjectsFromArray:NLEnglishHour(n.hour, n.minute)];
            [pool addObjectsFromArray:NLEnglishFacts(n)];
            holiday = NLEnglishHoliday(n);
            break;
    }
    if (holiday) [pool addObjectsFromArray:@[holiday, holiday, holiday]];
    return pool;
}
