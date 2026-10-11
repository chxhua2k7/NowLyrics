While a song plays, NowLyrics puts the line being sung **in place of the track title** on the Lock Screen — and in Control Center, the Dynamic Island and CarPlay — so the words follow the music without opening or swiping anything. Optionally, Lyrics Island adds the current line under the Dynamic Island, lit up word by word as it is sung.

## Features

- **Lyrics Island** — optional: the current line in a strip at the bottom of the compact Dynamic Island, which grows down to meet the status bar. White or album color, a fade or scroll-up line change, adjustable size and scroll speed; long lines scroll, and lyrics with word times light up word by word. A preview on its settings page shows every change at once and can show what is playing; hold it to open it with working controls.
- **Four lyrics sources** — Apple Music, Musixmatch, LRCLIB and NetEase, tried in the order you drag them into; when one has nothing, the next fills in.
- **Now Playing page** — the Lock Screen's player in Settings, where the song's lyrics came from (or what each source answered), a source picked for this song alone, and this song's own offset.
- **Your own lyrics** — paste them or import them from Files (LRC, word-by-word LRC, Apple Music / AMLL TTML); lyrics you add win over every source.
- **Lyrics Library** — every saved song by app, searchable; view, edit or delete, or clear the cache (lyrics you added are kept).
- **Offset** — a default for every song and one per song, −3 s to +3 s, applied as you drag; or type an exact value such as `0.25` or `-300ms`.
- **Artist field** — keep the credit (`Track — Artist`), show the next lyric line, or leave it alone.
- **Hide explicit badge** — drops the "E" that would follow the lyric line on explicit tracks.
- **Player over its cover** — the player on the Lock Screen, in Control Center and in Settings sits on its cover, blurred and darkened (iOS 15–18).
- **Other tweaks** — Crescendo's volume slider and NextUp 3's Up Next row also show in the player and the island preview in Settings; tweaks that show the now-playing title, such as Letterpress, show the lyric line too.
- **Diagnostics** — shows which source answered, right in the artist field.
- **Localized settings** — English, 繁體中文, 简体中文 and 日本語.

## Supported apps

- **Spotify** — full support; Spotify Connect titles ("Playing on …") are turned back into the real title and artist
- **Apple Music** — full support
- **YouTube Music, KKBOX, SoundCloud, TIDAL, Deezer, Amazon Music** — on by default, through the system's now-playing info
- **Other players** — any app that publishes now-playing info; pick them under Choose Apps, a searchable list

## Lyrics sources

- **Apple Music** — optional, needs an Apple Music subscription (iOS 16 and later): Apple's own lyrics, timed word by word where Apple has them, in Music and also in Spotify and other apps. Unlocked once your subscription is confirmed, and locked again if it lapses.
- **Musixmatch** — the largest catalogue, much of it word by word; needs the Musixmatch app installed, then your User Token from it (Settings → Get help → Copy debug info) or an API key of your own.
- **LRCLIB** — works out of the box, no account needed.
- **NetEase Cloud Music** — works out of the box, no account needed; lyrics are Simplified Chinese, no conversion applied.

## Compatibility

**iOS 15.0 – 26.1.** This listing covers the **rootless** package only (Dopamine, palera1n), built for arm64 and arm64e. AltList is installed automatically for the app picker. iOS 18 and later need PreferenceLoader 2.2.8 for the settings page (dhinakg's repo, https://dhinakg.github.io/repo/); the page is at the bottom of Settings › General. After installing, tap **Apply** (top right of the main settings page) once: Lyrics Island, Player over its cover and Apple Music lyrics in other apps run in SpringBoard. Verified on an iPhone 14 Pro (iOS 16.5.1) and on iOS 18.6.2 and 26.1 virtual devices.

Cannot be installed alongside **AMLyrics** — both rewrite the same Apple Music item.

## Known issues

- Word-by-word lyrics light up word by word only in Lyrics Island; the Lock Screen, Control Center and CarPlay show the whole line.
- Inside Apple Music the lyric line also appears in Music's own now-playing views.
- Lyrics Island needs an iPhone with the Dynamic Island.
- Songs are matched by title, artist and length, so live versions, remasters and rare tracks can be missed; add those lyrics yourself.
- The NetEase and Musixmatch User Token services are unofficial and may stop working.
- On iOS 26, Player over its cover changes only the player in Settings: the Lock Screen's player is glass there and Control Center already takes the cover's colors.

Only the track title, artist, album and length are sent to the lyrics sources you have on. Apple Music lyrics are asked of Apple through your own Apple ID, after the song is found with Apple's public search. Your Musixmatch token is stored on the device and sent only to Musixmatch. No accounts, no analytics.

## 中文

NowLyrics 把正在唱的那句歌詞放到曲名的位置：鎖定畫面、控制中心、動態島與 CarPlay 都會顯示，不用打開任何 App。

支援 Spotify、Apple Music，YouTube Music、KKBOX、SoundCloud、TIDAL、Deezer、Amazon Music 預設開啟；其他會發布播放資訊的播放器可在「選擇 App」從可搜尋的清單勾選。Spotify Connect 的曲名會還原成真正的曲名和演出者。

歌詞來源：LRCLIB 與網易雲音樂免設定即用（網易雲為簡體）；Apple Music 歌詞需訂閱 Apple Music（iOS 16 以上），Spotify 等其他 App 也能用，訂閱過期會自動鎖回；Musixmatch 曲庫最大、很多有逐字時間，需安裝 Musixmatch App 再貼上自己的 User Token，或用 API key。可拖曳排列來源順序，前一個找不到就由下一個補上，也能替單首歌指定來源。

「歌詞上島」可在縮小的動態島底部多一列顯示當前歌詞（白色或專輯顏色、淡入或向上捲動、字體大小與捲動速度可調，長句自動捲動，有逐字時間的歌詞逐字亮起），設定頁有預覽，也能顯示正在播放的歌，長按可展開並直接操作。

設定裡的「正在播放」頁可看歌詞來源、替這首歌換來源或調偏移，也能貼上或從檔案匯入歌詞（LRC、逐字 LRC、TTML）；「歌詞庫」依 App 列出所有存過的歌詞，可搜尋、編輯、刪除或清除快取。偏移 ±3 秒（預設與單首各一），邊拖邊套用；演出者欄位可顯示原曲名與演出者、下一句歌詞或維持原樣；可隱藏 explicit 的「E」標記；播放器可用模糊加深的封面當背景（iOS 15–18）；支援 Crescendo 與 NextUp 3。

iOS 15.0 – 26.1，僅支援 rootless 越獄（Dopamine、palera1n），不能與 AMLyrics 同時安裝。iOS 18 以上的設定頁需要 PreferenceLoader 2.2.8（dhinakg 的軟體源），位置在「設定 › 一般」最下面；安裝後按一次設定主頁右上角的「套用」。只會把曲名、演出者、專輯與長度送給你開啟的歌詞來源（Apple Music 歌詞是透過你自己的 Apple ID 向 Apple 取得），不需帳號、沒有追蹤。
