# NowLyrics

<img src="logo/NowLyrics-1024.png" width="96" alt="NowLyrics">

把同步歌詞放到曲名的位置:鎖定畫面、控制中心、動態島、CarPlay 都會顯示。支援 Spotify、
Apple Music 和任何會發布 now-playing 資訊的播放器。歌詞來自 Musixmatch、LRCLIB 和網易雲音樂。

這是原始碼 repo(私人)。公開頁面在 [github.com/chxhua2k7/NowLyrics](https://github.com/chxhua2k7/NowLyrics),
套件以 `com.c3x14n.nowlyrics` 在 Havoc 販售,上架用的素材在 `havoc/`。

English: [README.md](README.md)

## 功能

- 在 iOS 顯示 now-playing 資訊的每個地方,用當前歌詞行取代曲名;演出者欄位顯示「曲名 — 演出者」、
  下一句歌詞,或維持原樣。
- 任何播放器都能用:掛的是 MediaPlayer 的公開 API,不是 App 自己的類別,Spotify 改版也不會壞。
  Apple Music 走另一條路徑(見下)。要對哪些 App 生效從完整 App 清單勾選。
- 三個來源、可指定優先來源;每個 App 各自的磁碟快取;手動 `.lrc` 覆蓋;全域偏移拉桿加單曲偏移標籤。
- 設定頁有英文、繁中、簡中、日文,圖示執行期用 SF Symbols 畫,有版本列。

和啟發它的 [AMLyrics](https://github.com/Lessica/AMLyrics) 相比:AMLyrics 透過 MusicKit 的 session
讀 Apple 官方的逐字 TTML,只能在 Apple Music 裡用;NowLyrics 是逐行、不需要認證、每個播放器都能用。
兩者在 Music 裡會改同一個項目,不能共存,所以套件對 `com.82flex.amlyrics` 宣告衝突。

## 運作方式

兩條發布路徑共用一個引擎。行程走哪一條在 `%ctor` 依 bundle ID 決定(`kNLContentItemBundles`),
兩組 hook 不會同時裝。

**第三方播放器(字典路徑)。** 會在鎖定畫面顯示資訊的播放器都會呼叫
`-[MPNowPlayingInfoCenter setNowPlayingInfo:]`。hook 讓原呼叫通過,再到主佇列讀曲名、演出者、
專輯、時長、已播放時間和速率。每到一行的邊界,引擎把播放器的字典複製一份、換掉曲名(依設定也換演出者)、
重新定錨已播放時間讓進度條不跳,推回去。若 App 把自己的資訊讀回來再推一次,回音防護會把真實值放回去。

Spotify 在別的裝置播放時(Spotify Connect),手機收到的是「曲名 • 演出者」加演出者欄位「正在用某裝置播放」。
「Spotify Connect 曲名修正」開著時,hook 在系統看到之前就把這一對改回真正的曲名和演出者,
查詢、快取檔名、鎖定畫面都用正確的值,切歌時也不會閃一下原字串。

**Apple Music(content item 路徑)。** Music 從不呼叫 `setNowPlayingInfo:`。它的播放引擎持有一個
`MPNowPlayingContentItem`,MediaRemote 直接從那個物件讀 metadata,所以掛的是它的 setter
(`setElapsedTime:playbackRate:`、`setTitle:`、`setTrackArtistName:`、`setDuration:`)。App 寫進去的
就是真實曲名和演出者;收到進度更新的那個 item 就是正在播的。發布時把歌詞行寫進 item 的 `title`、
把署名寫進 `trackArtistName`,再重新定錨已播放時間,MediaPlayer 就會重新發布。item 已經是該顯示的內容時
什麼都不寫,所以觸發的變更通知不會迴圈。把 Music 關掉時會把真實曲名放回去,因為沒別人會做。

**引擎。** 曲目以曲名和演出者辨識(時長只拿來核對目錄命中,因為播放器每次回報的時長會差一兩秒;
還沒回報時長的曲目先等)。歌詞依序解析:手動檔 → 磁碟快取 → 依優先順序的來源。播放器只在播放、暫停、
拖曳時回報進度,中間的位置用上一個錨點和速率外推;每一行的邊界用 `dispatch_after` 觸發。設定是不可變的
快照,每次重載整個換掉,進行中的抓取看到的仍是一致的設定。

**解析。** LRC 解析器處理 offset 標籤、多時間戳的行、排序;會丟掉網易雲放在開頭的作詞 / 作曲等署名行和
版權聲明。空的帶時間戳的行只有在下一行 5 秒以上才算空檔(顯示曲名),否則上一行繼續留著。

## 自備歌詞與快取

比對靠字串,現場版、重製版、冷門曲目可能找不到。把 `.lrc` 放進目標 App 的容器:

```
Library/NowLyrics/manual/曲名 - 演出者.lrc      (或 曲名.lrc)
```

手動歌詞優先於所有線上來源,也不會被覆蓋。抓到的歌詞快取在上一層 `Library/NowLyrics/`,以曲目命名,
找得到也能手改;檔案開頭的 `[offset:±毫秒]` 只調那一首(和全域偏移相加)。每個 App 最多留 300 個檔,
最舊的先淘汰。Music 的檔在 Music 自己的容器裡。

## 編譯與發布

Mac 上的 Theos 加 Xcode。`THEOS` 要指到 Theos 目錄。

```bash
make package                 # DEBUG:每一步都 NSLog
make package FINALPACKAGE=1  # 正式版:安靜、體積一半,發布用這個
```

- rootless(`THEOS_PACKAGE_SCHEME = rootless`);rootful 把它註解掉。
- `ARCHS = arm64 arm64e`。arm64e slice 是 Apple Music 能用的關鍵,必須用 Xcode 的工具鏈編;
  在裝置上編(`ARCHS=arm64`)就沒有 Music:那種 slice 載入 arm64e 行程會過不了指標驗證
  (libobjc 在 `readClass()` 崩潰),Mach-O metadata 相同,差在簽章。
- **版本號只寫在一個地方**:Makefile 的 `PACKAGE_VERSION`。它是套件版本、`NL_VERSION` 定義
  (User-Agent 和「關於」的版本列),stage 時也填進 `bundle/Info.plist` 的 `__VERSION__`。
  `control` 的 `Version:` 會被 Theos 覆蓋。
- `control`:套件 `com.c3x14n.nowlyrics`;對 `com.82flex.amlyrics` 宣告 `Conflicts`/`Replaces`;
  `Icon:` 指向 bundle 裡 87 px 的圖示,Sileo 才會顯示。偏好設定 domain 和通知名稱維持 `app.nowlyrics`。
- 執行期相依:[AltList](https://github.com/opa334/AltList) 提供 App 選擇器(設定 bundle dlopen 它),以及 PreferenceLoader。
- Logo 是 16×16 的像素風音符盒(`logo/NowLyrics.svg`);PNG 直接從格子填實心像素再切 iOS 圓角,
  不要用 SVG 縮圖(會留下半透明的接縫)。

裝到裝置:把 .deb 傳過去 `sudo dpkg -i`。不用 respring:播放器重開就載入新版,設定頁 `killall Preferences` 即可。

## 程式碼結構

| 檔案 | 內容 |
|---|---|
| `NowLyrics.xm` | hook 與兩個發布器(字典路徑、content item 路徑)、Spotify Connect 改寫、重載與套用的通知觀察 |
| `NLEngine.m` | 曲目狀態、虛擬時鐘、找行、翻行計時器、抓取佇列 |
| `NLSources.m` | HTTP 和三個來源,以及嘗試順序 |
| `NLLyrics.m` | LRC 解析與輸出、曲名清理、Connect 拆解、快取與手動檔 |
| `NLSettings.m` | 設定快照、各 App 的開關、行程檢查 |
| `NowLyrics.h` | 共用宣告 |
| `prefs/` | 設定頁:PreferenceLoader 的 plist 和每種語言一份 `Localizable.strings` |
| `prefsbundle/NLRootListController.m` | 設定頁控制器:執行期圖示(`iconSymbol`/`iconColor`,或 `iconApp` 用已裝 App 的圖示)、套用按鈕、清除快取、版本列 |
| `prefsbundle/NLOffsetCell.m` | 偏移那一列的拉桿加輸入欄,以及 AltList 的 `dlopen` |
| `prefsbundle/NLEditTextCell.m` | 文字列:按 Return 存值並收鍵盤 |
| `docs/` | vPhone 測試手冊 |
| `havoc/` | 上架描述、changelog、相容性、乾淨重裝檢查表 |

資料單向流動:hook 讀播放器發布的內容呼叫 `NLEngineIngest()`;引擎解析並計時後呼叫 `NLPublish()`,
由 `NowLyrics.xm` 依行程的路徑實作。

## 測試

- 真機:iPhone 14 Pro、iOS 16.5.1、Dopamine。所有東西包括設定頁和 AltList 選擇器都在這裡驗證。
- vphone-cli 的 VM(iOS 26.1、18.6.2)驗證新版 iOS 上的注入和 Spotify 路徑;PreferenceLoader 在 VM
  裡永遠掛不出設定頁。手冊:`docs/vphone-testing.md`。
- 發布前:`havoc/clean-install-check.md`(移除、重裝、預設值、不填 Musixmatch token 也要有歌詞)。

## 已知限制

- LRCLIB 的中文曲目很少,所以網易雲當備援;那個端點非官方,可能封鎖非中國大陸位址。
- 網易雲歌詞是簡體,沒有轉換。華語流行歌的原生繁體條目 Musixmatch 比較多。
- Musixmatch:token 路徑打的是 App 自己的端點(`macro.subtitles.get`),非官方且綁帳號;API key
  路徑走公開 API,但有時間軸的 `matcher.subtitle.get` 通常不在免費方案裡(會 403)。token 優先。
- 不送 Spotify 曲目 ID(要掛 Spotify 私有類別才拿得到),冷門或同名曲目比對較弱。`NLCleanTitle()`
  會去掉 `- 2011 Remaster`、`(feat. X)` 這類字尾但不完美。時長差超過 8 秒(網易雲 10 秒)直接拒絕。
- 偏好設定依序讀 App 自己的 `Library/Preferences/`、`/var/mobile/Library/Preferences/`、
  `/var/jb` 下的同路徑;都讀不到就用預設值。容器內的路徑也是用 TrollFools 注入、沒有設定面板時的設定方式。
- Apple Music 的支援建立在私有的 `MPNowPlayingContentItem` API 上,iOS 更新可能會動到。因為改的是
  item 本身,Music 自己的播放畫面也會看到歌詞行。
- 只有逐行,沒有逐字:LRC 沒有逐字時間。
- 注入 App Store 的 App 會改變它的簽章,可能被登出或讓 Spotify Connect 出問題。這是注入本身的性質,不是這份程式碼。

## 授權

© 2026 chxhua2k7。保留所有權利。NowLyrics 透過 Havoc 販售,原始碼不以開源授權釋出。
