# NowLyrics

English: [README.md](README.md)

在鎖定畫面、控制中心、動態島與 CarPlay 上顯示逐行同步歌詞,支援 Spotify、
Apple Music 以及其他播放器。

概念來自 [Lessica/AMLyrics](https://github.com/Lessica/AMLyrics),但實作路線不同。

## 與 AMLyrics 的差異

| | AMLyrics | NowLyrics |
|---|---|---|
| 歌詞來源 | Apple 官方的 `syllable-lyrics`(TTML) | Musixmatch → LRCLIB → 網易雲,可自選 |
| 取得方式 | 掛 `ICURLSession` 借用 MusicKit 已驗證的連線 | 不需驗證,一般 HTTPS |
| 曲目識別 | `iTunesStoreIdentifier` / `lyricsAdamID` | 曲名 + 演出者 + 時長比對 |
| 解析 | 私有的 `MSVLyricsTTMLParser` | 內建 LRC 解析器 |
| 掛鉤對象 | `MRNowPlayingPlayerClient`、`MPNowPlayingContentItem` | 第三方播放器:`MPNowPlayingInfoCenter`;Music:`MPNowPlayingContentItem` |
| 精細度 | 逐字 | 逐行 |

關鍵在掛鉤對象。Apple Music 是系統 App,類別名稱穩定;Spotify 的播放器類別經過
混淆,每隔幾週就會變。NowLyrics 完全不碰宿主 App 自己的程式碼,只掛
`-[MPNowPlayingInfoCenter setNowPlayingInfo:]` —— 這是公開 API,任何要在鎖定畫面
顯示資訊的播放器都一定會呼叫。副作用是任何播放器都能用,不限於 Spotify。

唯一不呼叫這個方法的播放器就是 Apple Music:它把一個 content item 交給 MediaPlayer,
MediaRemote 直接從那個物件讀 metadata。所以在 Music 裡同一套引擎改成直接編輯
content item,做法和 [AMLyrics](https://github.com/Lessica/AMLyrics) 一樣,見「運作方式」。

## 運作方式

1. `setNowPlayingInfo:` 被呼叫時先原封不動放行,再到主佇列讀出曲名、演出者、
   專輯、時長、已播放時間和播放速率。
2. 曲目變了(曲名 + 演出者不同;時長只拿來檢查比對結果,因為播放器每次回報的時長常差個一兩秒)
   就解析歌詞:手動檔 → 磁碟快取 → Musixmatch → LRCLIB → 網易雲。若設定了偏好來源,
   該來源會排到最前面。播放器還沒回報時長的曲目會先等。
3. 播放器只在播放、暫停、拖曳時回報進度,中間的位置要自己推算:
   `elapsed + (CACurrentMediaTime() - anchor) * rate`。
4. 每到下一行的時間點用 `dispatch_after` 觸發一次更新,把該行寫進
   `MPMediaItemPropertyTitle`,演出者欄位則依「Artist field」設定放原曲名或下一句。
   同時更新 `elapsedPlaybackTime`,否則進度條會被打回舊值。

在 Music(`com.apple.Music`)裡第 1 步和第 4 步不同,其餘共用:

- Music 的播放引擎持有一個 `MPNowPlayingContentItem`,並持續更新它的已播放時間,所以掛的是
  這個 item 的 setter(`setElapsedTime:playbackRate:`、`setTitle:`、`setTrackArtistName:`、
  `setDuration:`)。App 寫進去的就是真正的曲名和演出者;收到進度更新的那個 item 就是正在播的。
- 發布的方式是把當前歌詞行寫進 item 自己的 `title`、把 credit 寫進 `trackArtistName`,再把
  已播放時間重新定錨一次,MediaPlayer 就會重新發布。item 已經顯示正確內容時什麼都不寫,
  所以這些變更通知不會繞成迴圈。
- 在 App 選擇器裡把 Music 關掉時會把真正的曲名放回去,因為和字典路徑不同,沒有別人會幫忙還原。

一個行程走哪條路徑在 `%ctor` 依 bundle identifier 決定(`kNLContentItemBundles`),
兩組 hook 絕不會同時裝。

## 編譯

```bash
git clone <this repo> && cd NowLyrics
make package && sudo make install
```

`Makefile` 裡 `THEOS_PACKAGE_SCHEME = rootless` 預設是開著的。rootful 越獄要把它註解掉。

`make package` 編的是 DEBUG 版,每一步都寫 log;日常使用請編正式版,安靜而且體積只有一半:

```bash
make package FINALPACKAGE=1
```

編出來的是 `arm64 arm64e`。arm64e slice 是 Apple Music 能用的關鍵(Music.app 是 arm64e 行程),
而且必須用 Mac 上 Xcode 的工具鏈編。在裝置上編要用 `make package ARCHS=arm64`,
等於放棄 Apple Music,見下方「arm64e 必須用 Xcode 編」。

執行期需要 [AltList](https://github.com/opa334/AltList)(`com.opa334.altlist`),
它提供 App 選擇器,設定 bundle 會 dlopen 它。

套件識別碼是 `com.c3x14n.nowlyrics`。control 對 `com.82flex.amlyrics` 同時宣告 `Conflicts` 和
`Replaces`:兩者會改同一個 Music 項目,所以裝 NowLyrics 時會把 AMLyrics 移除。偏好設定的 domain 和重載通知仍叫
`app.nowlyrics`,所以設定不會因為改名而遺失。

在裝置上打包時若出現 `exec of gzip -c1 failed`,是因為 `dm.pl` 對 `control.tar`
硬編碼用 gzip(不管 `-Z` 選什麼),而裝置上沒裝 gzip。裝一個就好:

```bash
sudo apt install gzip
```

## 設定

裝好後「設定」App 裡會出現 NowLyrics。設定頁會跟著系統語言切換(英文、繁體中文、簡體中文、日文),
頁面上的說明刻意寫得很短,細節都在這份文件裡。

- **Enabled** —— 總開關。
- **Apps** —— 由 AltList 提供的完整 App 清單,有搜尋列。**即時生效,不用重開 App。**
  在第一次用選擇器之前,套用的是內建預設清單:Apple Music、Spotify、YouTube Music、KKBOX、
  SoundCloud、TIDAL、Deezer、Amazon Music。2.11 之前存過的清單不會自動多出 Music,要自己勾。
- **Display** —— 「演出者欄位」:歌詞占用曲名欄位時,演出者欄位要放什麼(原曲名加演出者
  `曲名 — 演出者`、下一句歌詞,或維持播放器原本的值)。「偏移」:全域歌詞偏移,−3 s 到 +3 s,
  拖拉桿(0.1 s 一格,邊拖邊套用)或點數值直接輸入,例如 `0.25` 或 `-300ms`,正值 = 提早出現。
  只想調某一首,改該首快取 `.lrc` 開頭的 `[offset:±毫秒]` 標籤,兩者會疊加。
- **Lyrics Sources** —— Musixmatch / LRCLIB / 網易雲各自獨立開關,另外可以指定一個偏好來源
  排到第一順位,其餘維持 Musixmatch → LRCLIB → 網易雲 的順序。LRCLIB 和網易雲預設開,
  Musixmatch 預設關,需要 User Token(把 Musixmatch App 的「Copy debug info」整段貼進去,
  它等同帳號憑證,請當密碼看待)或開發者 API key,後者只在沒填 token 時使用。
- **Advanced** —— 「Diagnostics」把實際回應的來源附在演出者欄位後面,完全找不到時改顯示
  每個來源各自的結果(例如 `LRCLIB 3 timed, duration off by 41s · NetEase nothing under this title`;
  nothing under this title 是資料庫沒有條目、duration off 是時長對不上、will retry 是網路沒回應)。
  「Quit app on change」在每次改設定時直接結束宿主 App,平常用不到,因為所有設定本來就即時生效。
  「Clear lyrics cache」把所有 App 下載過的歌詞刪掉。「Spotify Connect 曲名修正」(預設開)把 Spotify 在其他裝置播放時
  回報的「曲名 • 演出者」加「正在用某裝置播放」拆回真正的曲名和演出者,查詢和快取檔名才會正常。
- **About** —— 目前安裝的版本。
- **套用**(右上角)—— 把有開 NowLyrics 的播放器結束,讓它們用目前設定重新啟動。平常用不到,
  因為設定本來就即時生效;它是「改設定時結束 App」的手動版。

改動設定會發 Darwin 通知 `app.nowlyrics/ReloadPrefs`,tweak 收到後即時重載,不必重開 App。
改了來源會順便清掉記憶體快取,磁碟快取保留。

## 自備歌詞

對歌靠字串比對,現場版、重製版和冷門曲目會對不上 —— 資料庫裡根本沒有那個條目,
怎麼調都沒用。這時把 `.lrc` 放進目標 App 沙盒裡的:

```
Library/NowLyrics/manual/
```

檔名用 `曲名 - 演出者.lrc` 或 `曲名.lrc`(兩種都會試,不看時長)。手動歌詞優先於
所有線上來源,也不會被快取覆蓋。

線上抓到的歌詞會以 `.lrc` 存在上一層的 `Library/NowLyrics/`,檔名以曲目命名,
找得到也能直接手改。在檔案開頭加 `[offset:±毫秒]` 標籤就能單獨調整那一首。每個 App 最多
留 300 個檔,超過就淘汰最舊的。設定頁的「清除歌詞快取」會記下按下的時間,各 App 把比那時間
早的檔案刪掉:正在執行的立刻做,沒在執行的下次開啟時補做。

## 設定頁

`NowLyricsPrefs.bundle` 是真的 preference bundle,和 tweak 一樣編 arm64 + arm64e,
裡面有兩個類別(原始碼在 `prefsbundle/`)。`NLRootListController` 是這一頁的控制器,
繼承 libprefs 的 `PLLocalizedListController`,補上 plist 寫不出來的兩件事:每一列的圖示
(執行期直接用 SF Symbols 畫)和「清除歌詞快取」的動作。`NLOffsetCell` 是偏移那一列
(邊拖邊套用的拉桿,加上可以直接輸入數值的欄位)。頁面上其他東西都是 plist 驅動的內建
Preferences cell,App 選擇器則是 AltList 的。這個 bundle 在建構子裡 dlopen AltList 的框架,
plist 裡寫到 `ATLApplicationListMultiSelectionController` 時才找得到。`#import <libprefs/prefs.h>`
會透過 Theos 的 module map 自動連結 libprefs,rootless 的 rpath 在 `/var/jb/usr/lib` 找到它。

```
/Library/PreferenceBundles/NowLyricsPrefs.bundle/
├── Info.plist                (CFBundleExecutable = NowLyricsPrefs、NSPrincipalClass = NLRootListController)
├── NowLyricsPrefs            (NLRootListController、NLOffsetCell、AltList 的 dlopen)
└── NowLyrics.png / @2x / @3x (entry 的圖示)
```

entry 指向它:

```
bundle = NowLyricsPrefs        → 我們的 bundle:entry 圖示和兩個類別都從這裡來
isController = 1               → 載入 bundle,再建立它的 NSPrincipalClass
pl_alt_plist_name = NowLyrics  → 項目從 entry 旁邊的 plist 讀
```

2.13 之前這個 bundle 沒有自己的程式碼:執行檔是指向 AltList 二進位檔的軟連結,AltList 因此
順便被載入,也就不需要編 arm64e。現在 arm64e 由 Xcode 編,這個手法就不需要了。

「關於」顯示的版本就是 Makefile 的 `PACKAGE_VERSION`,版本號只寫在那一個地方:編譯時以 `NL_VERSION`
傳進來(User-Agent 也用它),bundle 的 `Info.plist` 則在 stage 時填入。

設定項目和翻譯放在 entry 旁邊的資料夾,而不是 bundle 裡(原始檔在 `prefs/`):

```
/Library/PreferenceLoader/Preferences/NowLyrics/
├── NowLyrics.plist                              (entry + items)
└── en.lproj、zh-Hant.lproj、zh-Hans.lproj、ja.lproj
    └── Localizable.strings                      (label、footer、選項標題、placeholder)
```

PreferenceLoader 會遞迴掃描 `Preferences/`,plist 所在的資料夾就是那個 entry 的來源 bundle。
`PLLocalizedListController` 用 plist 裡的英文字串當 key,到該 bundle 的 `Localizable.strings`
查 label、footer、選項標題和 placeholder;沒有翻譯的 key 就顯示英文。列的圖示不是檔案:每一列
寫 `iconSymbol` 和 `iconColor`,`NLRootListController` 在載入項目時畫成設定 App 那種 29 pt 的
色塊圖示。entry 自己的圖示是唯一留下的 PNG,在 `NowLyricsPrefs.bundle` 裡。

兩條走不通的路(軟連結時期的),記下來:

- **在 entry 上寫 `bundle = AltList`** —— AltList 會載入,但 `prefBundle` 變成
  AltList.bundle,`icon` 跑去那裡找,圖示就不見了。
- **改在子項目上寫 `bundle = AltList`** —— 圖示回來了,但子項目載不進來。
  PreferenceLoader 只對頂層 entry 做 `/Library/PreferenceBundles` 的路徑搜尋;
  子項目走 Preferences.framework,它只認 `/System/Library/PreferenceBundles`。

## arm64e 必須用 Xcode 編

裝置端 Theos/Procursus 工具鏈產生的 arm64e slice 載入 arm64e 行程時會過不了指標驗證:
libobjc 在 `readClass()` 崩潰,`ESR` EC 0x1C,也就是 PAC 失敗。preference bundle(弄掛
Preferences.app)和 tweak 本體(弄掛 SpringBoard)都確認過。

`-Wl,-no_fixup_chains` 沒用,還會更糟:dyld 是在處理 auth 類型的 chained fixups
時簽這些指標的,把 chains 拿掉等於保證指標沒簽。

Mach-O 中繼資料和能正常運作的第三方二進位檔完全一樣 —— 同樣的 `cpusubtype`、
同樣的 `DYLD_CHAINED_PTR_ARM64E_USERLAND24` 指標格式 —— 所以差別在簽章本身,
不在標頭。目前唯一已知的解法是在有 Xcode 的 Mac 上編,發布的版本就是這樣編的。

實際影響:

- 裝置上編的版本(`ARCHS=arm64`)載不進 Apple Music,因為它是 arm64e 行程。
  那種情況請用 AMLyrics,它的官方逐字歌詞本來就更好。
- 有了 arm64e slice 之後,dylib 也會被載進 SpringBoard 和 Preferences,因為過濾器比對的
  類別它們也有。`%ctor` 在那裡什麼都不做就返回(`NLProcessIsEligible()`),但 slice 本身
  載入失敗是擋不住的:各 App 的開關擋不住載入時的崩潰,那發生在 dlopen 初始化階段,
  比 `%ctor` 還早。裝新版之前先確認自己越獄的安全模式怎麼進。

## 過濾器只有三種 key

ellekit 的 `injector/injector.c` 只認 `Bundles`、`Classes` 和 `Executables`。
**MobileSubstrate 的 `Frameworks` 沒有實作** —— 用了不會報錯,只是什麼都對不上,
dylib 永遠不會被注入到任何地方,也沒有任何訊息說明為什麼。

```
Filter = { Classes = ( "MPNowPlayingInfoCenter" ); };
```

只要 `objc_getClass("MPNowPlayingInfoCenter")` 找得到,MediaPlayer 就已載入。
靜態連結 MediaPlayer 的 App 在 injector 跑的時候類別已經註冊好了。事後才 dlopen
MediaPlayer 的 App 會漏掉,但會發布 now-playing 資訊的播放器都是靜態連結的。

## 程式碼結構

| 檔案 | 內容 |
|---|---|
| `NowLyrics.xm` | hook 與兩種發布方式:第三方播放器走字典路徑,Music 走 content item 路徑 |
| `NLEngine.m` | 曲目狀態、虛擬時鐘、行查找、換行計時器、抓取佇列 |
| `NLSources.m` | HTTP 與三個歌詞來源,以及嘗試順序 |
| `NLLyrics.m` | LRC 解析與序列化、曲名清理、快取與手動檔 |
| `NLSettings.m` | 讀設定檔、各 App 開關、行程檢查 |
| `NowLyrics.h` | 共用宣告,各檔案之間需要的東西都在這 |
| `prefs/` | 設定頁:PreferenceLoader 的 plist 和每種語言一份 `Localizable.strings` |
| `prefsbundle/NLRootListController.m` | 設定頁的控制器:執行期用 SF Symbols 畫的列圖示、清除快取的動作、版本列 |
| `prefsbundle/NLOffsetCell.m` | 偏移那一列的拉桿加輸入欄,以及 AltList 的 `dlopen` |

資料單向流動:hook 讀到播放器發布的內容後呼叫 `NLEngineIngest()`;引擎解析並計時歌詞,
再呼叫 `NLPublish()`,由 hook 檔依這個行程用的路徑實作。設定是不可變的快照(`NLSettings`),
每次重載整個換掉,所以進行中的抓取看到的設定始終一致。

## 改程式碼時的注意事項

- **`NowLyrics.xm` 是當 Objective-C++ 編譯的**(`.m` 檔是純 Objective-C),所以在那個檔案裡
  C++ 關鍵字不能當識別字。`explicit`、`class`、`new`、`template`、`using`、`namespace`
  都會失敗,而錯誤訊息(`expected unqualified-id`)不會告訴你原因。`NowLyrics.h` 裡的共用函式
  包在 `extern "C"` 區塊裡也是同一個原因。
- **`%orig` 必須獨占一行。** 寫成 `if (x) { %orig; return; }` 的話,logos 會把那一行
  `%orig` 後面的東西全部吃掉 —— 包括右大括號 —— 括號就對不起來了。
- **`%init(GroupName)` 必須出現在 `%group GroupName` 之後。** logos 是循序處理的。
  先前置宣告函式,在 group 後面再定義。

## 已知限制

- LRCLIB 對華語歌的涵蓋率明顯比英文差,所以網易雲預設開著當備援。那個端點是
  非官方的,可能失效,或封鎖中國大陸以外的位址。
- **網易雲的歌詞是簡體中文。** 沒有做轉換。華語流行歌的原生繁體條目,Musixmatch 比較多。
  網易雲放在開頭的作詞 / 作曲 / 編曲和版權聲明會被解析器丟掉,不會再當歌詞閃一下。
  網易雲也會在段落之間塞空白的時間戳行;只有下一句在五秒以上才算間奏(這時會顯示曲名),
  更短的空行直接略過,上一句就繼續留著。
- Musixmatch 有兩條路。從 Musixmatch App 拿到的 **User Token** 打的是
  `apic.musixmatch.com/ws/1.1/macro.subtitles.get`,也就是 App 自己用的端點 ——
  非官方,隨時可能失效,而且 token 等同帳號憑證。**開發者 API key** 打的是有文件的
  API,但帶時間軸的 `matcher.subtitle.get` 端點通常不在免費方案內,所以會拿到 403。
  先試 token 那條路。
- 和 EeveeSpotify 不同,這裡不送 `track_spotify_id`:要讀它得掛 Spotify 私有的
  `SPTPlayerTrack`,等於放棄整個「只碰系統框架」的設計,而且只對 Spotify 有幫助。
  所以冷門或同名曲目的比對會比較弱。
- 對歌靠字串。`NLCleanTitle()` 會去掉 `- 2011 Remaster`、`(feat. X)` 這類後綴,
  但不完美。時長差超過 8 秒(網易雲是 10 秒)就寧可不顯示,錯的歌詞比沒有更糟。
- **只有逐行,沒有逐字。** AMLyrics 能逐字是因為 Apple 的 TTML 帶有那種標記;LRC 沒有。
- 注入 App Store 的 App 會改掉它的簽章,可能導致被登出或 Spotify Connect 失效。
  這是注入本身的性質,不是這份程式碼的問題。
- 設定檔會依序從 App 沙盒的 `Library/Preferences/`、`/var/mobile/Library/Preferences/`
  和 `/var/jb` 底下的同一路徑讀取。三個都讀不到時全部退回預設值:內建的 App 清單、
  LRCLIB 加網易雲。用 TrollFools 注入時沒有設定頁,就是靠沙盒內那個路徑來設定。
- Apple Music 的支援建立在 AMLyrics 用的同一組掛鉤點(`MPNowPlayingContentItem`)上,
  但那是私有 API,iOS 更新可能會動到。不要在 Music 裡同時裝 AMLyrics 和 NowLyrics,
  兩者都會改 item 的曲名。因為改的是 item 本身,Music 自己的播放畫面也可能看到歌詞行。
  給 Music 用的手動 `.lrc` 要放在 Music 自己的沙盒裡。

## 搭配 Letterpress

可以。Letterpress 讀的是 MediaRemote 的 now-playing 標題,正好是我們改的地方。

## License

© 2026 chxhua2k7。保留所有權利。NowLyrics 透過 Havoc 販售,原始碼不以開源授權釋出。
