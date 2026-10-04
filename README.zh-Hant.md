# NowLyrics

<img src="logo/NowLyrics-1024.png" width="96" alt="NowLyrics">

把同步歌詞放到曲名的位置:鎖定畫面、控制中心、動態島、CarPlay。支援 Spotify、Apple Music
和任何會發布 now-playing 資訊的播放器;另可在縮小的動態島底部多一列顯示當前歌詞。
來源:Apple Music(需訂閱)、Musixmatch、LRCLIB、網易雲。

私人原始碼 repo。公開頁面:[chxhua2k7/NowLyrics](https://github.com/chxhua2k7/NowLyrics)。
以 `com.c3x14n.nowlyrics` 在 Havoc 販售,上架素材在 `havoc/`。

English: [README.md](README.md)

## 運作方式

- **第三方播放器**會呼叫 `-[MPNowPlayingInfoCenter setNowPlayingInfo:]`。hook 放它通過,
  讀曲名/演出者/時長/進度/速率,每到一行的邊界就把字典複製一份、換掉曲名、重新定錨進度後推回去。
  Spotify Connect 的「曲名 • 演出者 / 正在用某裝置播放」在系統看到之前就改回真實值。
- **Apple Music** 不呼叫那個方法,改掛它的 `MPNowPlayingContentItem` setter,直接把歌詞寫進 item
  (和 AMLyrics 同一招,所以套件對 `com.82flex.amlyrics` 宣告衝突)。
- **引擎**:曲目 = 曲名 + 演出者;依序找手動 `.lrc` → 磁碟快取 → 使用者排的來源順序(`sourceOrder`);位置從上一個錨點外推;
  每行一個 `dispatch_after`。空行只在下一行 ≥ 5 秒才算空檔。

- **歌詞上島**(`NowLyricsIsland.x`,只注入 SpringBoard,預設關閉):透過
  `-[SBSystemApertureSceneElement preferredEdgeOutsetsForLayoutMode:…]` 讓播放元件的 compact 外框
  往下長,剛好停在頂部安全區的線上(以固定的感測區量測)。歌詞列用
  `-[SBSystemApertureContainerView addContentSubview:]` 放進內容層,讓 SpringBoard 跟封面、聲波一起縮放、
  淡化、裁切;只在容器的 `layoutSubviews` 排版,置中於鏡頭下方。文字、explicit 旗標與封面(專輯顏色)
  來自 `MRMediaRemoteGetNowPlayingInfo`。
- **Apple Music 歌詞**(有獨立開關):以歌曲的 adam ID 呼叫 `MPStoreLyricsMusicKitRequestOperation`,
  拿到 Music 歌詞頁同一份 TTML(店面語系、逐字時間)。在「音樂」App 裡 ID 來自 content item 的
  `lyricsAdamID`/`storeID`;其他 App(Spotify)沒有 ID 也沒有 Apple Music 權限,改由 SpringBoard 代勞
  (`NLAppleMusicSB.x`):App 在自己的 Library/NowLyrics 寫 `am-request.plist` 並發 Darwin 通知,
  SpringBoard 用 Apple 公開搜尋依歌名、歌手、長度找到這首(`NLAppleMusicFind.m`),要到歌詞後寫回
  `am-response.plist`。確認有訂閱前 Apple Music 相關的設定全部隱藏:按「解鎖」時由 SpringBoard
  問 iTunesCloud 的 `ICMusicSubscriptionStatusController`,再問 StoreKit,最後實際要一首歌的歌詞;
  之後每天重新確認,訂閱過期就再鎖起來。
- **逐字歌詞**:Apple Music、Musixmatch(有 token 時的 `track.richsync.get`)、網易雲(`/api/song/lyric/v1` 的 `yrc`)
  與匯入的 TTML 或逐字 LRC 有逐字時間,存成 enhanced LRC(`<mm:ss.xx>`)。鎖定畫面照舊一行;島從 App 的
  `nowplaying.plist` 找到歌詞檔,用 MediaRemote 的進度和 App 一樣的方式對到這一行,遮罩照時間推進
  (柔邊、長句跟著唱到的位置平滑捲動)。Musixmatch 一首歌只有一份 richsync,對的是某一個版本,
  不一定是正在播的:逐行字幕用歌曲長度挑(`q_duration`),richsync 的 `richsync_length` 差超過 3 秒、
  各行和逐行字幕越差越遠,或快到人唱不出來(任何來源都檢查)時就改用逐行。MediaRemote 的進度就是
  App 推的:`MPNowPlayingInfoCenter` 對第三方 App 距上次不到 0.5 秒的更新會延後 0.5 秒(`_pushDate`),
  所以每次推歌詞前先在它的佇列上清掉。
- **歌詞管理**(設定頁「正在播放」「歌詞庫」):Preferences 沒有沙盒,直接讀寫各 App 容器裡的歌詞檔
  (`NLLocate.m` 用容器的 metadata plist 找 bundle ID),改完發 `app.nowlyrics/LyricsChanged`,
  App 先重讀設定再清掉記憶體快取、找一次。每首偏移和每首指定的來源存在設定檔的 `trackOffsets`、
  `trackSources`(曲目 key → 秒 / 來源名);頁面上只顯示一個偏移(「進階」的預設偏移加上這首的)。
  主頁和「正在播放」頁最上面嵌入鎖定畫面的播放器
  (MediaControls 的 `+[MRPlatterViewController coverSheetPlatterViewController]`,`NLPlayerHeader`);
  主頁可在「進階 › 主頁頂端」(`pageHeader`)換成島預覽或隱藏。「歌詞來源」頁照嘗試順序列出來源
  (plist 列上的 `source`)。Musixmatch 跟 Apple Music 一樣要先解鎖:有安裝 Musixmatch App
  (`musixmatchVerified`);App 刪掉後,有存 User Token 或 API Key 就繼續用。
- **播放器用封面背景**(`NLPlayerTint`,開關 `playerTint`):控制中心蓋在
  `-[MRUControlCenterView materialView]` 上;鎖定畫面蓋在播放器 `PLPlatterView` 的毛玻璃上,
  靠通知列表的群組 `com.apple.MediaRemoteUI` 和即時動態(同樣是 ActivityUIServices 的 scene)分開。
  把封面模糊、依最亮的一成加深(不管歌詞是什麼顏色);換歌時封面還沒到就維持原本的樣子。
- **Crescendo**(有裝時):開關從它的 notify state(`com.yves.crescendo.state`)讀;設定頁播放器裡
  休眠的音量列強制打開(`-[MRUNowPlayingView setShowVolumeControlsView:]`),歌詞上島的預覽另外放一條
  `MRUNowPlayingVolumeControlsView`,展開時高 40 pt。
- **NextUp 3**(有裝時):在 MediaControls 之後把它的 dylib 載入設定 App,設定頁播放器就和鎖定畫面一樣
  有「接著播放」列。它給 iOS 17 島的 hook 在 16.5 也會碰到預覽的 view,所以預覽把那個 view 收回來
  (`NLNextUpKeepOut`),自己照真正的島放一條 `NUNextUpRowView`。
- **歌詞上島頁的預覽**:有音樂時用 MediaControls 的 `MRUActivityNowPlayingViewController`(MediaRemoteUI
  畫島的同一個),封面、聲波是它的 leading/trailing view,展開是它的展開版面;設定 App 沒有島的宿主,
  所以 `-[UIView SBUISA_layoutMode]` 與鏡頭的 layout guide 由預覽代答(只限膠囊裡的 view)。聲波的
  音量需要音訊 tap 權限,這裡餵模擬值(`NLWaveformDriver`)。可拖動拉長、長按展開。
  展開版面的 `-layoutSubviews` 每次排版都用自己的座標設定封面和聲波的 frame,不管它們現在在哪裡;
  預覽包住這個方法,在同一次排版裡放回原位。
- **隱藏 E 標記**:在系統看到之前清掉 `MPMediaItemPropertyIsExplicit`(Apple Music 為 `explicitItem`),
  歌詞後面就不會出現「E」。

歌詞依 App 快取在 `Library/NowLyrics/`(最多 300 檔,1.2.0 起檔頭有 `[ti:]`/`[ar:]`/`[nl-source:]`,
舊檔播到時補上);手動加入的(設定頁貼上/匯入,或自己放)`Library/NowLyrics/manual/曲名 - 演出者.lrc`
優先於所有來源。App 另寫 `Library/NowLyrics/nowplaying.plist`(真正的曲名、歌詞檔、來源、有無逐字)。

## 編譯與發布

```bash
make package FINALPACKAGE=1   # 正式版;單純 `make package` 是帶 NSLog 的 DEBUG 版
make package FINALPACKAGE=1 THEOS=~/theos-roothide THEOS_PACKAGE_SCHEME=roothide   # roothide,iphoneos-arm64e
```

- Mac 上的 Theos + Xcode,rootless,`ARCHS = arm64 arm64e`。arm64e slice 是 Apple Music 能用的關鍵,
  只有 Xcode 的工具鏈編出來的能過指標驗證。
- roothide 要用 roothide 版的 Theos;套件會連結 libroothide,越獄的檔案用 `jbroot()` 找(`NLShared.h` 的 `NLJBPath()`)。
  兩種方案各自編在 `.theos/obj/<scheme>`,不會混在一起。還沒在 roothide 越獄上實際跑過。
- 版本號只在 Makefile 的 `PACKAGE_VERSION`(套件版本、`NL_VERSION` 定義、stage 時填入 `bundle/Info.plist`)。
- 執行期相依:PreferenceLoader、AltList。`sudo dpkg -i` 安裝後 respring 一次(設定頁的「套用」),SpringBoard 才會載入 NowLyricsIsland;歌詞本身只要播放器重開。
- iOS 18 起「設定」改用 Swift 重寫,PreferenceLoader 2.2.6 在那裡掛不出 tweak 頁面。裝 dhinakg 的 2.2.8
  (https://dhinakg.github.io/repo/)後,NowLyrics 在「設定 › 一般」最下面。

## 結構

| | |
|---|---|
| `NowLyrics.xm` | hook、兩個發布器、Connect 改寫、explicit 旗標、通知觀察 |
| `NowLyricsIsland.x` | SpringBoard:縮小動態島底部的歌詞列 |
| `NLEngine.m` / `NLSources.m` / `NLLyrics.m` / `NLSettings.m` | 引擎、來源、LRC(含逐字、yrc)與快取、設定快照 |
| `NLIslandStrip.m` / `NLLocate.m` | 島的歌詞列(逐字遮罩);找 App 容器與 `nowplaying.plist`(設定頁與島共用) |
| `prefsbundle/NLNowPlayingController.m`、`NLLibraryController.m`、`NLLyricsEditor.m`、`NLLyricsImport.m` | 正在播放、歌詞庫(依 App 分類)、編輯器、貼上/匯入與 TTML |
| `prefs/`、`prefsbundle/`、`bundle/Island.plist` | 設定頁:plist 加四種語言;控制器(執行期圖示、套用、版本、歌詞上島頁)、拉桿列、文字列 |
| `docs/`、`havoc/` | vPhone 手冊;上架文案、changelog、乾淨重裝檢查表 |

## 測試

iPhone 14 Pro / iOS 16.5.1 測全部;vphone-cli VM(iOS 26.1、18.6.2)測 Spotify 路徑、島、鎖定畫面、控制中心,
裝 PreferenceLoader 2.2.8 後也測設定頁(VM 沒有 Apple Music;舊的 2.2.6 掛不出設定頁)。歌詞上島在 14 Pro(16.5.1)
與 18.6.2、26.1 的 VM 上驗證過,動畫是用螢幕錄影逐格檢查的。
iOS 17 以上改掛在元件自己的 view:那裡容器的內容 view 規定只能有一個子 view,`addContentSubview:` 會把元件換掉。
17 以上島變大小是一步步重排那個 view(26 會先回彈,過一下再變寬),所以歌詞等它在螢幕上停住才淡入。
18.5 與 26.1 用到的私有 API 逐一對過該版的符號。

## 限制

逐字只在島上,且只限有逐字時間的歌詞;其他地方逐行。網易雲是簡體。Musixmatch 要 App 的 token(非官方)或 API key(帶時間軸的端點通常要付費)。
比對靠字串;Apple Music 依賴私有 API。歌詞上島需要有動態島的 iPhone(依 SpringBoardServices 的
`SBSIsSystemApertureAvailable` 判斷,所以 iOS 16 用 MobileGestalt 開出動態島的 iPhone 也算;其他機型設定頁會說明),
依賴在 16.5.1、18.6.2、26.1 確認過的 SpringBoard 內部實作,其他版本可能需要調整。播放器用封面背景:16 與 18 的
鎖定畫面和控制中心;26 的鎖定畫面播放器是玻璃,會把背後的畫面蓋在顏色上,控制中心的媒體模組本來就取封面顏色,
所以維持系統原樣。

## 授權

© 2026 chxhua2k7。保留所有權利,不開源。
