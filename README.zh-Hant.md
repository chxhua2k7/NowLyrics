# NowLyrics

<img src="logo/NowLyrics-1024.png" width="128" alt="NowLyrics">

播放音樂時，NowLyrics 把正在唱的那句歌詞**放到曲名的位置**：鎖定畫面、控制中心、
動態島和 CarPlay 都看得到，不用打開任何 App。也可以在動態島底下多一列當前歌詞，
有逐字時間的歌詞會跟著演唱一個字一個字亮起來。

支援 Spotify、Apple Music，以及任何會在鎖定畫面顯示播放資訊的播放器。歌詞來源有
Apple Music（需訂閱）、Musixmatch、LRCLIB 和網易雲音樂。

目前版本：**1.2.3** · [更新紀錄](CHANGELOG.md) · English: [README.md](README.md)

## 功能

- **歌詞取代曲名**：鎖定畫面、控制中心、動態島和 CarPlay。演出者欄位可以顯示
  曲名與演出者、下一句歌詞，或維持播放器原本的內容。
- **歌詞上島**：在縮小的動態島底部顯示當前歌詞，動態島會往下長到剛好貼齊狀態列。
  白色或專輯顏色、淡入淡出或向上捲動的換行動畫，字體大小和捲動速度都能調。太長的
  句子會捲動；有逐字時間的歌詞會照著演唱逐字亮起。開啟「常駐顯示」後，在正在播放的 App
  裡島也不會收起來。設定頁上的即時預覽會馬上反映每個改動。
- **四個歌詞來源**，照你拖曳排好的順序嘗試：Apple Music、Musixmatch、LRCLIB 和
  網易雲。前一個找不到，就由下一個補上。
- **「正在播放」頁**：鎖定畫面的播放器、這首歌的歌詞從哪裡來（找不到時每個來源各自
  的原因）、替這首歌指定來源，以及這首歌自己的偏移。
- **自己加歌詞**：直接貼上，或從「檔案」匯入（LRC、逐字 LRC、Apple Music / AMLL
  TTML）；你加的歌詞優先於所有來源。
- **歌詞庫**：依 App 列出所有存過的歌詞，可搜尋、查看、編輯、刪除，也能清除快取
  （你手動加的歌詞會保留）。
- **播放器用封面背景**：鎖定畫面、控制中心和設定頁的播放器背景換成模糊並加深的封面，
  透明度可調（iOS 15–18）。
- **偏移**：所有歌的預設偏移，加上每首歌各自的偏移，−3 秒到 +3 秒，邊拖邊套用；
  也可以直接輸入，例如 `0.25` 或 `-300ms`。
- **隱藏「E」標記**：不讓歌詞後面跟著 explicit 的「E」。
- **Spotify Connect**：把「曲名 • 演出者 / 正在用某裝置播放」還原成真正的曲名和演出者。
- **其他插件**：設定頁的播放器和預覽島也會顯示 Crescendo 的音量條和 NextUp 3 的
  「接著播放」列。Letterpress 這類顯示播放標題的插件，也會跟著顯示歌詞。
- **四種語言的設定頁**：English、繁體中文、简体中文、日本語。

## 支援的 App

- **Spotify** 和 **Apple Music**：完整支援。
- **YouTube Music、KKBOX、SoundCloud、TIDAL、Deezer、Amazon Music**：預設開啟，
  透過系統的播放資訊運作。
- **其他播放器**：只要會在鎖定畫面顯示播放資訊都可以，在「選擇 App」勾選即可。清單
  預設只列音樂 App，用「篩選」可以改成列出所有 App。

## 歌詞來源

| 來源 | 需要 | 說明 |
|---|---|---|
| **Apple Music** | Apple Music 訂閱、iOS 16 以上 | Apple 自己的歌詞，依你所在地區商店的文字（台灣為繁體中文），有的歌還有逐字時間。Music 裡可用，Spotify 等其他 App 也能透過 SpringBoard 使用 |
| **Musixmatch** | Musixmatch App，再貼上它的 User Token，或用你自己的 API Key | 曲庫最大，很多有逐字時間 |
| **LRCLIB** | 不用 | 預設開啟 |
| **網易雲音樂** | 不用 | 預設開啟；歌詞為簡體中文 |

**Apple Music 歌詞**要先解鎖才會出現：「歌詞來源 › 解鎖 Apple Music 歌詞」會確認你的
訂閱。請先在 Music App 同意 Apple Music 的隱私權說明，並在「設定 › 你的名稱 › 媒體與
購買項目」登入 Apple ID。之後只有狀態可能改變時才會重新確認：Apple Music 通知訂閱有
變動、重新整理（respring）之後，以及 Apple Music 拒絕歌詞請求時。訂閱過期或登出「媒體
與購買項目」，Apple Music 就會再鎖起來，NowLyrics 改用其他來源。在其他 App 裡，會先用
歌名、歌手和長度在 Apple Music 找到這首歌；「用正在播放的歌測試」會把每一步的結果顯示出來。

**Musixmatch** 只要裝了 Musixmatch App 就能解鎖。把它的 debug info 貼到 User Token
（在 Musixmatch App：設定 → Get help → Copy debug info），或填你自己的 API Key。
User Token 等同你的 Musixmatch 帳號憑證，請當密碼保管。

## 設定

NowLyrics 在「設定」App 有自己的頁面（iOS 18 以上在「設定 › 一般」最下面）。每一頁右上角的
**套用**會重新啟動 SpringBoard；安裝後要按一次，給在 SpringBoard 裡運作的部分用：
歌詞上島、播放器用封面背景，以及其他 App 的 Apple Music 歌詞。其他設定都會立即生效。

- **啟用**、**選擇 App**：總開關，以及要在哪些 App 裡運作。
- **正在播放**：目前播放的歌。演出者欄位、隱藏「E」標記、這首歌的偏移；「自動」或
  替這首歌指定來源；貼上歌詞、從檔案匯入、移除手動歌詞，以及查看與編輯正在用的歌詞。
- **歌詞上島**：啟用、常駐顯示、預覽正在播放、預覽島（縮小、展開、自動縮小）、歌詞顏色（白色、
  專輯顏色）、換行動畫（淡入淡出、向上捲動）、逐字歌詞、字體大小、捲動速度。頁面頂端的
  預覽島和真的一樣，可以點也可以長按。
- **歌詞來源**：歌詞庫、來源順序、Apple Music 歌詞（含「用在其他 App」和測試）、
  Musixmatch、LRCLIB、網易雲音樂。
- **進階**：
  - 預設偏移；
  - 主頁頂端（播放器、動態島、隱藏），以及讓其他頁面頂端也一樣的「其他頁也一樣」；
  - 播放器用封面背景、透明度；
  - 支援的插件（Crescendo、NextUp 3）；
  - 診斷（在演出者欄位顯示是哪個來源回應的）；
  - 改設定時結束 App（App 用到的設定改變時把音樂 App 關掉）；
  - Spotify Connect 曲名修正。

## 自己加歌詞

最簡單的方法是在播放時打開「設定 › NowLyrics › 正在播放」：**貼上歌詞**（先複製 LRC
或 TTML）或**從檔案匯入**。你加的歌詞會優先於所有來源，直到你移除為止。

手動放檔案也可以：把 `曲名 - 演出者.lrc`（或 `曲名.lrc`）放進該 App 容器裡的
`Library/NowLyrics/manual/`。檔案開頭加 `[offset:±毫秒]` 可以單獨調整那一首。線上抓到
的歌詞依 App 存在 `Library/NowLyrics/`（每個 App 最多 300 首），可以在歌詞庫編輯。

## 系統需求與安裝

- **iOS 15.0 – 26.1**，rootless 越獄（Dopamine、palera1n），arm64 和 arm64e。
- **AltList**，安裝 NowLyrics 時會自動一起裝。
- **iOS 18 以上**：設定頁需要 PreferenceLoader 2.2.8（[dhinakg 的軟體源](https://dhinakg.github.io/repo/)）。
- 不能和 **AMLyrics** 同時安裝：兩者都會改寫同一個 Apple Music 項目。

NowLyrics 在 [Havoc](https://havoc.app) 販售：在套件管理器加入 Havoc 軟體源，購買並安裝，
再到它的設定頁按一次**套用**。

## 疑難排解

- **某首歌沒有歌詞**：打開「設定 › NowLyrics › 正在播放」，那裡會列出每個來源的結果；
  可以替這首歌換一個來源，或自己加歌詞。
- **歌詞早一點或晚一點**：在「正在播放」調「偏移」（只影響這首），或在「進階」調
  「預設偏移」（所有歌）。
- **動態島底下沒有歌詞**：歌詞上島需要動態島（本身有動態島的 iPhone，或用改 MobileGestalt、插件等方式開出動態島的機型，iPad 也可以），安裝後也要重新整理一次（套用）。
- **沒有 Apple Music 歌詞**：確認「歌詞來源」裡的 Apple Music 歌詞已解鎖並開啟；解鎖時
  會告訴你缺了什麼。

## 已知限制

- 鎖定畫面、控制中心和 CarPlay 顯示整句；只有歌詞上島會逐字亮起，而且只限有逐字時間的歌詞。
- 在 Apple Music 裡，Music 自己的播放畫面也會看到歌詞行。
- 靠歌名、歌手和長度對歌，現場版、重製版和冷門歌可能對不上；這些請自己加歌詞。
- 網易雲的歌詞是簡體中文，沒有轉換。網易雲和 Musixmatch User Token 用的是非官方服務，
  隨時可能失效；Musixmatch 免費方案的 API Key 通常拿不到帶時間的歌詞。
- Apple Music 歌詞和歌詞上島依賴 iOS 內部機制，已在 iOS 16.5.1、18.6.2 和 26.1 確認過；
  其他版本可能需要更新。
- iOS 26 上「播放器用封面背景」會隱藏：那裡鎖定畫面的播放器是玻璃材質，控制中心也已經
  自己用封面的顏色。

## 隱私

為了找歌詞，NowLyrics 會把曲名、演出者、專輯和長度送給你開啟的歌詞來源。Apple Music
歌詞是先用 Apple 的公開搜尋找到這首歌，再透過你自己的 Apple ID 向 Apple 取得；確認訂閱時
也只問 Apple。Musixmatch 的 User Token 或 API Key 只存在你裝置上 NowLyrics 的設定裡，也只會
送給 Musixmatch。不需要帳號，沒有分析，沒有追蹤。

## 致謝

概念來自 [Lessica/AMLyrics](https://github.com/Lessica/AMLyrics)。App 選擇器使用
[AltList](https://github.com/opa334/AltList)。歌詞來自 Apple Music、
[Musixmatch](https://www.musixmatch.com)、[LRCLIB](https://lrclib.net) 和網易雲音樂。

## 授權

© 2026 chxhua2k7。保留所有權利。這個 repo 只放 NowLyrics 的說明文件；軟體本身為專有軟體，
透過 Havoc 發行。
