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
- **Spotify 的時間**(`NowLyrics.xm`,只在 Spotify):引擎用聽到的位置(`NLHeardPosition`),
  也就是 App 自己數的時間減掉輸出延遲和超前量。Spotify 回報的是交給音訊單元的位置,所以延遲是
  `AVAudioSession.outputLatency` + 0.04 秒,只算手機自己的輸出和藍牙(AirPlay、CarPlay、USB 和 Connect 不算),
  換輸出時重算。它播放中的時間是自己另外數的,有兩種情況會跑在聲音前面,直到它下次從音訊讀回位置
  (暫停、繼續、拖動)為止。一首歌自己接到下一首時,下一首在聲音出來前約一秒就從 0 開始數
  (量了 15 首:0.91–1.43 秒,中位數 0.98),所以最後 3.5 秒內回到 0 的歌,以及之後 1 秒內換上的新曲名,
  超前量記 0.98 秒。換輸出時音訊會停 0.1–0.85 秒,時間照數:Spotify 的 RemoteIO 單元(從
  `AudioOutputUnitStart` 找到)掛 render notification 量出停頓,在下一次回報、以及換輸出後 1.5 秒和 4 秒
  加進超前量。回報接著同一個時間數下去時超前量保留,換歌、改速率或拖動時歸零。

- **歌詞上島**(`NowLyricsIsland.x`,只注入 SpringBoard,預設關閉):透過
  `-[SBSystemApertureSceneElement preferredEdgeOutsetsForLayoutMode:…]` 讓播放元件的 compact 外框
  往下長,剛好停在頂部安全區的線上(以固定的感測區量測)。歌詞列用
  `-[SBSystemApertureContainerView addContentSubview:]` 放進內容層,讓 SpringBoard 跟封面、聲波一起縮放、
  淡化、裁切;只在容器的 `layoutSubviews` 排版,置中於鏡頭下方。文字、explicit 旗標與封面(專輯顏色)
  來自 `MRMediaRemoteGetNowPlayingInfo`。常駐顯示(`islandAlwaysShow`):App 或它的場景在畫面上時,
  SpringBoard 會依元件關聯的 App 把元件收起(`-shouldSuppressElementWhilePresentingAppWithBundleId:` 與
  `…SceneWithIdentifier:`);播放元件改回答不收,切換設定時呼叫
  `-[SBSystemApertureViewController _reevaluateElementSuppression]` 立刻重新判斷(16.5.1、18.5、26.1 相同)。
- **Apple Music 歌詞**(有獨立開關):以歌曲的 adam ID 呼叫 `MPStoreLyricsMusicKitRequestOperation`,
  拿到 Music 歌詞頁同一份 TTML(店面語系、逐字時間)。在「音樂」App 裡 ID 來自 content item 的
  `lyricsAdamID`/`storeID`;其他 App(Spotify)沒有 ID 也沒有 Apple Music 權限,改由 SpringBoard 代勞
  (`NLAppleMusicSB.x`):App 在自己的 Library/NowLyrics 寫 `am-request.plist` 並發 Darwin 通知,
  SpringBoard 用 Apple 公開搜尋依歌名、歌手、長度找到這首(`NLAppleMusicFind.m`),要到歌詞後寫回
  `am-response.plist`。確認有訂閱前 Apple Music 相關的設定全部隱藏:按「解鎖」時由 SpringBoard
  問 iTunesCloud 的 `ICMusicSubscriptionStatusController`,再問 StoreKit,最後實際要一首歌的歌詞;
  之後在 iTunesCloud 通知訂閱狀態改變、SpringBoard 啟動、Apple Music 歌詞請求失敗時由 SpringBoard
  重新確認,訂閱過期或「媒體與購買項目」沒登入 Apple ID 就再鎖起來。還沒同意 Apple Music 的隱私權說明時(`AMSAcknowledgePrivacyTask`、
  `com.apple.onboarding.applemusic`)只問 iTunesCloud、也不抓歌詞,因為 StoreKit 會把同意畫面蓋在當下的畫面上;
  設定頁會請你到「音樂」裡同意。
- **逐字歌詞**:Apple Music、Musixmatch(有 token 時的 `track.richsync.get`)、網易雲(`/api/song/lyric/v1` 的 `yrc`)
  與匯入的 TTML 或逐字 LRC 有逐字時間,存成 enhanced LRC(`<mm:ss.xx>`)。鎖定畫面照舊一行;島從 App 的
  `nowplaying.plist` 找到歌詞檔,用 MediaRemote 的進度和 App 一樣的方式對到這一行,遮罩照時間推進
  (柔邊、長句跟著唱到的位置平滑捲動)。Musixmatch 一首歌只有一份 richsync,對的是某一個版本,
  不一定是正在播的:逐行字幕用歌曲長度挑(`q_duration`),richsync 的 `richsync_length` 差超過 3 秒、
  各行和逐行字幕越差越遠,或快到人唱不出來(任何來源都檢查)時就改用逐行。MediaRemote 的進度就是
  App 推的:`MPNowPlayingInfoCenter` 對第三方 App 距上次不到 0.5 秒的更新會延後 0.5 秒(`_pushDate`),
  所以每次推歌詞前先在它的佇列上清掉。
- **歌詞管理**(設定頁「正在播放」「歌詞庫」):Preferences 沒有沙盒,直接讀寫各 App 容器裡的歌詞檔
  (`NLLocate.m` 用容器的 metadata plist 找 bundle ID),改完發 `com.c3x14n.nowlyrics/LyricsChanged`,
  App 先重讀設定再清掉記憶體快取、找一次。每首偏移和每首指定的來源存在設定檔的 `trackOffsets`、
  `trackSources`(曲目 key → 秒 / 來源名;來源是 `off` 就是「這首不顯示歌詞」,這首歌在哪裡都不顯示歌詞);
  頁面上只顯示一個偏移(「進階」的預設偏移加上這首的)。
  主頁和「正在播放」頁最上面嵌入鎖定畫面的播放器
  (MediaControls 的 `+[MRPlatterViewController coverSheetPlatterViewController]`,`NLPlayerHeader`);
  主頁可在「進階 › 主頁頂端」(`pageHeader`)換成島預覽或隱藏;「進階 › 其他頁也一樣」
  (`topOnEveryPage`,預設開,`NLPageTop`)讓其他頁面頂端跟主頁一樣(島預覽放在表格的 header),
  「歌詞上島」頁(有自己的預覽島)、「正在播放」頁(有自己的播放器)和歌詞編輯頁除外。播放器離開鎖定畫面
  就沒有自己的背景(它的材質在別處什麼都不顯示),所以墊一層:iOS 26 是玻璃(`UIGlassEffect`),以下是系統材質;
  「播放器用封面背景」蓋在上面。「歌詞來源」頁照嘗試順序列出來源
  (plist 列上的 `source`)。Musixmatch 跟 Apple Music 一樣要先解鎖:有安裝 Musixmatch App
  (`musixmatchVerified`);App 刪掉後,有存 User Token 或 API Key 就繼續用。
- **控制中心的媒體播放器**(`NLSystemPlayerSB.x`,在 NowLyricsIsland 裡;iOS 16 和 26,17 到 25 維持原樣):
  輸出列表下面列出「正在播放」頁提供的來源,這首指定的打勾、下面寫歌詞狀態,還有「這首不顯示歌詞」和「NowLyrics 設定⋯」
  (iOS 16:`MRURoutingView` 輸出表格的 footer;iOS 26:路由選擇器的 collection view 下面,列的樣子照輸出列量出來)。
  iOS 16 在那裡或設定頁選的大小(`systemPlayerSize`:1×4、2×2、2×4、3×4 或系統預設)會放進控制中心的格子
  (`-[CCUIModuleCollectionViewController _sizesForModuleIdentifiers:…]`,有模組超過兩格寬時改用整格檢查的排列),
  收合的播放器用它自己的元件照大小排:1×4 一列,2×2 封面在歌曲上面,2×4 大封面加歌曲和三行歌詞,
  3×4 封面、歌詞、時間條和按鈕(MediaControls 把超過 200 pt 寬的卡片當成展開,所以把它的狀態固定在收合)。
  展開時歌詞像 Apple Music:直向在大封面和歌曲下面,橫向在時間條和按鈕之間,iOS 26 並排輸出列表時也有;
  正在唱的那行逐字亮起,其他行變暗模糊,長間奏有圓點,長句隨著唱往上捲,上面顯示歌曲本身的曲名,輸出名稱拿掉。
  iOS 26 的 MediaControls 是 Swift:元件的欄位照名稱讀(`class_getInstanceVariable`);2×4、4×4、直向、橫向有歌詞,
  小尺寸的標題保持跑馬燈。設定頁「控制中心」:大小(iOS 16)、收合時顯示歌詞、展開時顯示歌詞、輸出列表顯示歌詞來源
  (`ccClosedLyrics`、`ccOpenLyrics`、`ccSourcesInOutputs`),以及從「進階」搬來的「播放器用封面背景」。
  控制中心收起時只是把視窗藏起來,元件都還在裡面,MediaControls 每次正在播放的資訊一變就把每個播放器重排:
  NowLyrics 自己的讀取和逐格更新在視窗隱藏時停下,視窗再出現時恢復(`UIWindowDidBecomeVisibleNotification`)。
- **NowLyrics 的控制中心模組**(`cc/`,CCSupport 的 module provider,在 `/Library/ControlCenter/CCSupport_Providers`):
  「設定 › 控制中心」的控制項裡有「NowLyrics 1×1」到「NowLyrics 3×4」,每個是一種大小(`-moduleSizeForOrientation:`;
  iOS 17 起只有兩個小方塊),可以加好幾個。每個模組是一份照媒體模組方式建立的播放器
  (`[MRUControlCenterViewController new]` 和它的關閉、Home 手勢、角落按鈕三個 block),交給島(`NLSPOwnModule`)
  照媒體模組的方式依那個大小排版。輸出按鈕換成歌詞圖示(`quote.bubble`),輸出列表只有歌詞來源:
  輸出表格藏在下面(MediaControls 用批次更新改它,所以不動它的資料來源)。1×1(封面和 App 圖示)
  與 1×2(封面、用 MediaControls 的 `MRUMarqueeLabel` 跑馬燈的曲名和演出者、播放/暫停)是模組自己的小方塊,
  蓋在卡片上,展開時淡出。
- **播放器用封面背景**(`NLPlayerTint`,開關 `playerTint`):控制中心蓋在
  `-[MRUControlCenterView materialView]` 上;鎖定畫面蓋在播放器 `PLPlatterView` 的毛玻璃上,
  靠通知列表的群組 `com.apple.MediaRemoteUI` 和即時動態(同樣是 ActivityUIServices 的 scene)分開。
  把封面模糊、依最亮的一成加深(不管歌詞是什麼顏色);換歌時封面還沒到就維持原本的樣子。
  「進階 › 透明度」(`playerTintClear`,預設 50%)把封面和底下系統的毛玻璃(`MTMaterialView` 的 `weighting`)
  一起調淡,透出桌布;調淡的毛玻璃先換到自己的 backdrop 群組(`groupNameBase`),因為同一群組的毛玻璃共用濾鏡。
- **Crescendo**(有裝時):開關從它的 notify state(`com.yves.crescendo.state`)讀;設定頁播放器裡
  休眠的音量列強制打開(`-[MRUNowPlayingView setShowVolumeControlsView:]`),歌詞上島的預覽另外放一條
  `MRUNowPlayingVolumeControlsView`,展開時高 40 pt。
- **NextUp 3**(有裝時):在 MediaControls 之後把它的 dylib 載入設定 App,設定頁播放器就和鎖定畫面一樣
  有「接著播放」列。它給 iOS 17 島的 hook 在 16.5 也會碰到預覽的 view,所以預覽把那個 view 收回來
  (`NLNextUpKeepOut`),自己照真正的島放一條 `NUNextUpRowView`。
- **進階 › 支援的插件**(`Tweaks.plist`):Crescendo(`tweakCrescendo`,iOS 17 以下;17 起改由系統的
  「永遠顯示音量控制」)和 NextUp 3(`tweakNextUp`,iOS 16 起)各一個開關,預設開,圖示用插件自己的(它的偏好設定
  bundle 裡的),沒裝的會變灰。關掉 NextUp 就不載入它的 dylib;已經載入的,只在設定 App 裡讓它以為沒有下一首
  (`-[NUNextUpManager isActive]`),播放器的列馬上消失。iOS 17 起設定頁播放器照「永遠顯示音量控制」
  (`-[MRUserSettings alwaysShowVolumeControls]`)顯示音量列,和鎖定畫面一樣;展開的島兩種情況都沒有。
- **歌詞上島頁的預覽**:有音樂時用 MediaControls 的 `MRUActivityNowPlayingViewController`(MediaRemoteUI
  畫島的同一個),封面、聲波是它的 leading/trailing view,展開是它的展開版面;設定 App 沒有島的宿主,
  所以 `-[UIView SBUISA_layoutMode]` 與鏡頭的 layout guide 由預覽代答(只限膠囊裡的 view)。聲波的
  音量需要音訊 tap 權限,這裡餵模擬值(`NLWaveformDriver`)。可拖動拉長、長按展開。
  展開版面的 `-layoutSubviews` 每次排版都用自己的座標設定封面和聲波的 frame,不管它們現在在哪裡;
  預覽包住這個方法,在同一次排版裡放回原位。「預覽島」(`islandPreviewOpen`)決定它出現時的樣子:
  縮小、展開,或自動縮小(展開後放著不動 5 秒就縮回)。
- **隱藏 E 標記**:在系統看到之前清掉 `MPMediaItemPropertyIsExplicit`(Apple Music 為 `explicitItem`),
  歌詞後面就不會出現「E」。
- **選擇 App**(`NLAppListController`):AltList 的 App 清單,右上角可篩選(`appListFilter`):預設只列音樂 App
  (App Store 音樂類別 6011、「音樂」、「Podcast」和已勾選的),或列出全部。篩選是 AltList 區段的 predicate;
  AltList 是 dlopen 載入而不是連結,所以子類別在執行期才建立。

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
- 執行期相依:PreferenceLoader、AltList;NowLyrics 的控制中心模組要 CCSupport(不列為相依:沒裝就只是不載入那個 provider)。`sudo dpkg -i` 安裝後 respring 一次(設定頁的「套用」),SpringBoard 才會載入 NowLyricsIsland;歌詞本身只要播放器重開。
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
| `NLSystemPlayerSB.x` | SpringBoard:控制中心的媒體播放器(iOS 16、26)和 NowLyrics 模組裡的副本:輸出下的來源、大小、歌詞 |
| `NLLyricsSources.m` | 提供和指定的來源、歌詞狀態:「正在播放」頁與控制中心共用 |
| `cc/` | 控制中心模組:provider 和模組(`NLCCModule.m`)、1×1 與 1×2 的小方塊(`NLCCViews.m`) |
| `prefs/`、`prefsbundle/`、`bundle/Island.plist` | 設定頁:plist 加四種語言;控制器(執行期圖示、套用、版本、歌詞上島頁)、拉桿列、文字列 |
| `docs/`、`havoc/` | vPhone 手冊;上架文案、changelog、乾淨重裝檢查表 |

## 測試

iPhone 14 Pro / iOS 16.5.1 測全部;vphone-cli VM(iOS 26.1、18.6.2)測 Spotify 路徑、島、鎖定畫面、控制中心,
裝 PreferenceLoader 2.2.8 後也測設定頁(VM 沒有 Apple Music;舊的 2.2.6 掛不出設定頁)。歌詞上島在 14 Pro(16.5.1)
與 18.6.2、26.1 的 VM 上驗證過,動畫是用螢幕錄影逐格檢查的。
iOS 17 以上改掛在元件自己的 view:那裡容器的內容 view 規定只能有一個子 view,`addContentSubview:` 會把元件換掉。
17 以上島變大小是一步步重排那個 view(26 會先回彈,過一下再變寬),所以歌詞等它在螢幕上停住才淡入。
18.5 與 26.1 用到的私有 API 逐一對過該版的符號。控制中心在 14 Pro(16.5.1、CCSupport 1.3.13)上確認過,
iOS 26 在 ios26 和 ipados26 VM(26.6.2)上確認過。

## 限制

鎖定畫面一次一行;只有島會逐字,而且要歌詞有逐字時間。網易雲是簡體。Musixmatch 要 App 的 token(非官方)或 API key(帶時間軸的端點通常要付費)。
比對靠字串;Apple Music 依賴私有 API。歌詞上島需要 SpringBoard 裡有動態島(SpringBoard 啟動完成後問 SpringBoardServices 的
`SBSIsSystemApertureAvailable`,以 notify state `com.c3x14n.nowlyrics.island` 發布,所以用其他方式開出動態島的機型也算,
例如改 MobileGestalt 或 SpringBoard 裡的插件,iPad 也一樣;其他機型設定頁會說明),
依賴在 16.5.1、18.6.2、26.1(以及開了動態島的 iPadOS 26.6.2)確認過的 SpringBoard 內部實作,其他版本可能需要調整。
iPadOS 26 的「設定」側邊欄浮在頁面上,所以播放器和預覽島依表格的邊距與安全區域排版,而不是表格寬度。播放器用封面背景:16 與 18 的
鎖定畫面和控制中心;26 的鎖定畫面播放器是玻璃,會把背後的畫面蓋在顏色上,控制中心的媒體模組本來就取封面顏色,
所以維持系統原樣;26 上這個設定會隱藏,設定頁的播放器也維持系統外觀,跟鎖定畫面一致。
Spotify 的時間依據的是 16.5.1 上的量測:宣告後比平常更久才出聲的歌(看過最長 1.43 秒)歌詞最多早 0.45 秒,
在一首歌最後 3.5 秒內切歌或回到開頭,之後的歌詞會晚約 1 秒,兩者都到下次暫停為止;交叉淡化和 Automix
沒有處理,Spotify Connect 裝置的延遲也沒有。控制中心的媒體播放器只在 iOS 16 和 26 排版;NowLyrics 自己的模組要 CCSupport,
裡面是 iOS 16 的播放器。每個模組都是一整份 MediaControls 播放器,控制中心收起時 MediaControls 也會在每次正在播放的資訊
變動(每句歌詞)時更新它們,所以模組加越多越耗資源。

## 授權

© 2026 chxhua2k7。保留所有權利,不開源。
