# NowLyrics

<img src="logo/NowLyrics-1024.png" width="128" alt="NowLyrics">

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
  「Clear lyrics cache」把所有 App 下載過的歌詞刪掉。
- **About** —— 目前安裝的版本。

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

## 安裝

NowLyrics 在 [Havoc](https://havoc.app) 販售。在 Sileo 加入 Havoc 來源,購買後安裝即可。需要 iOS 15 或 16 的 rootless 越獄(Dopamine、palera1n)以及 [AltList](https://github.com/opa334/AltList),Sileo 會自動一起裝。

## 隱私

為了查歌詞,NowLyrics 會把曲名、演出者、專輯和時長送到你開啟的歌詞服務:Musixmatch、LRCLIB 和網易雲音樂。除此之外沒有任何資料離開裝置。貼進去的 Musixmatch token 只存在裝置上 tweak 的偏好設定檔,也只會送給 Musixmatch。沒有分析、沒有帳號、沒有追蹤。

## 授權

© 2026 chxhua2k7。保留所有權利。這個 repo 只放 NowLyrics 的說明文件;軟體本身為專有軟體,透過 Havoc 發行。
