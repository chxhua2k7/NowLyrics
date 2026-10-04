# NowLyrics

<img src="logo/NowLyrics-1024.png" width="96" alt="NowLyrics">

把同步歌詞放到曲名的位置:鎖定畫面、控制中心、動態島、CarPlay。支援 Spotify、Apple Music
和任何會發布 now-playing 資訊的播放器;另可在縮小的動態島底部多一列顯示當前歌詞。
來源:Musixmatch、LRCLIB、網易雲。

私人原始碼 repo。公開頁面:[chxhua2k7/NowLyrics](https://github.com/chxhua2k7/NowLyrics)。
以 `com.c3x14n.nowlyrics` 在 Havoc 販售,上架素材在 `havoc/`。

English: [README.md](README.md)

## 運作方式

- **第三方播放器**會呼叫 `-[MPNowPlayingInfoCenter setNowPlayingInfo:]`。hook 放它通過,
  讀曲名/演出者/時長/進度/速率,每到一行的邊界就把字典複製一份、換掉曲名、重新定錨進度後推回去。
  Spotify Connect 的「曲名 • 演出者 / 正在用某裝置播放」在系統看到之前就改回真實值。
- **Apple Music** 不呼叫那個方法,改掛它的 `MPNowPlayingContentItem` setter,直接把歌詞寫進 item
  (和 AMLyrics 同一招,所以套件對 `com.82flex.amlyrics` 宣告衝突)。
- **引擎**:曲目 = 曲名 + 演出者;依序找手動 `.lrc` → 磁碟快取 → 優先順序的來源;位置從上一個錨點外推;
  每行一個 `dispatch_after`。空行只在下一行 ≥ 5 秒才算空檔。

- **歌詞上島**(`NowLyricsIsland.x`,只注入 SpringBoard,預設關閉):透過
  `-[SBSystemApertureSceneElement preferredEdgeOutsetsForLayoutMode:…]` 讓播放元件的 compact 外框
  往下長,剛好停在頂部安全區的線上(以固定的感測區量測)。歌詞列用
  `-[SBSystemApertureContainerView addContentSubview:]` 放進內容層,讓 SpringBoard 跟封面、聲波一起縮放、
  淡化、裁切;只在容器的 `layoutSubviews` 排版,置中於鏡頭下方。文字、explicit 旗標與封面(專輯顏色)
  來自 `MRMediaRemoteGetNowPlayingInfo`。
- **隱藏 E 標記**:在系統看到之前清掉 `MPMediaItemPropertyIsExplicit`(Apple Music 為 `explicitItem`),
  歌詞後面就不會出現「E」。

歌詞依 App 快取在 `Library/NowLyrics/`(最多 300 檔);手動放的
`Library/NowLyrics/manual/曲名 - 演出者.lrc` 優先於所有來源。

## 編譯與發布

```bash
make package FINALPACKAGE=1   # 正式版;單純 `make package` 是帶 NSLog 的 DEBUG 版
```

- Mac 上的 Theos + Xcode,rootless,`ARCHS = arm64 arm64e`。arm64e slice 是 Apple Music 能用的關鍵,
  只有 Xcode 的工具鏈編出來的能過指標驗證。
- 版本號只在 Makefile 的 `PACKAGE_VERSION`(套件版本、`NL_VERSION` 定義、stage 時填入 `bundle/Info.plist`)。
- 執行期相依:PreferenceLoader、AltList。`sudo dpkg -i` 安裝後 respring 一次(設定頁的「套用」),SpringBoard 才會載入 NowLyricsIsland;歌詞本身只要播放器重開。
- iOS 18 起「設定」改用 Swift 重寫,PreferenceLoader 2.2.6 在那裡掛不出 tweak 頁面。裝 dhinakg 的 2.2.8
  (https://dhinakg.github.io/repo/)後,NowLyrics 在「設定 › 一般」最下面。

## 結構

| | |
|---|---|
| `NowLyrics.xm` | hook、兩個發布器、Connect 改寫、explicit 旗標、通知觀察 |
| `NowLyricsIsland.x` | SpringBoard:縮小動態島底部的歌詞列 |
| `NLEngine.m` / `NLSources.m` / `NLLyrics.m` / `NLSettings.m` | 引擎、來源、LRC 與快取、設定快照 |
| `prefs/`、`prefsbundle/`、`bundle/Island.plist` | 設定頁:plist 加四種語言;控制器(執行期圖示、套用、版本、歌詞上島頁)、拉桿列、文字列 |
| `docs/`、`havoc/` | vPhone 手冊;上架文案、changelog、乾淨重裝檢查表 |

## 測試

iPhone 14 Pro / iOS 16.5.1 測全部;vphone-cli VM(iOS 26.1、18.6.2)只測注入和 Spotify 路徑
(舊的 PreferenceLoader 2.2.6 在 VM 的設定 App 掛不出設定頁,2.2.8 見上)。歌詞上島在 14 Pro(16.5.1)與 18.6.2、26.1 的 VM 上驗證過,動畫是用螢幕錄影逐格檢查的。
iOS 17 以上改掛在元件自己的 view:那裡容器的內容 view 規定只能有一個子 view,`addContentSubview:` 會把元件換掉。

## 限制

逐行不逐字。網易雲是簡體。Musixmatch 要 App 的 token(非官方)或 API key(帶時間軸的端點通常要付費)。
比對靠字串;Apple Music 依賴私有 API。歌詞上島需要有動態島的 iPhone(依 SpringBoardServices 的
`SBSIsSystemApertureAvailable` 判斷,所以 iOS 16 用 MobileGestalt 開出動態島的 iPhone 也算;其他機型設定頁會說明),
依賴在 16.5.1、18.6.2、26.1 確認過的 SpringBoard 內部實作,其他版本可能需要調整。

## 授權

© 2026 chxhua2k7。保留所有權利,不開源。
