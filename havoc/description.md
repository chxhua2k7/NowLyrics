While a song plays, NowLyrics puts the line being sung **in place of the track title** on the Lock Screen — and in Control Center, the Dynamic Island and CarPlay — so the words follow the music without opening or swiping anything.

## Features

- **Lyrics Island** — optional: a strip with the current line at the bottom of the compact Dynamic Island, which grows down to the status bar's edge. White or album color, fade or scroll-up line changes, adjustable size; long lines scroll, and lyrics with word timing light up word by word as they are sung. A live preview on its settings page shows every change at once.
- **Hide explicit badge** — drops the "E" that would follow the lyric line on explicit tracks.
- **Artist field** — keep the credit (`Track — Artist`), show the next lyric line, or leave it alone.
- **Offset slider** — −3 s to +3 s, applied as you drag; or type an exact value such as `0.25` or `-300ms`.
- **Your own lyrics** — drop an `.lrc` into the app's `Library/NowLyrics/manual/` folder and it wins over every online source.
- **Cached per app** — a song fetched once is served from the cache from then on; a Clear lyrics cache button empties it.
- **Diagnostics** — shows which source answered, right in the artist field.
- **Localized settings** — English, 繁體中文, 简体中文 and 日本語.

## Supported apps

- **Spotify** — full support; Spotify Connect titles ("Playing on …") are turned back into the real title and artist
- **Apple Music** — full support
- **YouTube Music, KKBOX, SoundCloud, TIDAL, Deezer, Amazon Music** — via the system now-playing info
- **Other players** — any app that publishes now-playing info; pick them from a searchable list

## Lyrics sources

- **LRCLIB** — works out of the box, no account needed.
- **NetEase Cloud Music** — works out of the box, no account needed; lyrics are Simplified Chinese, no conversion applied.
- **Musixmatch** — the largest catalogue; needs the Musixmatch app installed, then your own token from it (Settings → Get help → Copy debug info) or an API key.
- **Apple Music** — Apple's own lyrics, many timed word by word, in Music and also in Spotify and other apps; needs an Apple Music subscription (iOS 16 and later).

Drag the sources into the order they are tried (Source order); when one has nothing, the next fills in.

## Compatibility

**iOS 15.0 – 26.1.** This listing covers the **rootless** package only (Dopamine, palera1n), built for arm64 and arm64e. AltList is installed automatically for the app picker. Settings page verified on iOS 16.5.1, and on 18.6.2 and 26.1 virtual devices with PreferenceLoader 2.2.8, which iOS 18 and later need (dhinakg's repo, https://dhinakg.github.io/repo/); the page is at the bottom of Settings › General.

Cannot be installed alongside **AMLyrics** — both rewrite the same Apple Music item.

## Known issues

- The Lock Screen, Control Center and CarPlay change line by line; word by word shows only in Lyrics Island, for lyrics with word timing (Apple Music, Musixmatch, NetEase, imported TTML or word-by-word LRC).
- Inside Apple Music the lyric line also appears in Music's own now-playing views.
- Lyrics Island needs an iPhone with the Dynamic Island; verified on iOS 16.5.1, 18.6.2 and 26.1.

Only the track title, artist, album and duration are sent to the lyrics services (Apple Music lyrics are asked of Apple by the song's Apple Music ID, through your Apple ID); your Musixmatch token is stored on the device and sent only to Musixmatch. No accounts, no analytics.

## 中文

NowLyrics 把正在唱的那句歌詞放到曲名的位置：鎖定畫面、控制中心、動態島與 CarPlay 都會顯示，不用打開任何 App。

支援 Spotify、Apple Music、YouTube Music、KKBOX 等所有會發布播放資訊的播放器，可從完整 App 清單勾選。

歌詞來源：LRCLIB 與網易雲音樂免設定即用（網易雲為簡體）；Musixmatch 曲庫最大，需安裝 Musixmatch App 再貼上自己的 token，或用 API key；Apple Music 歌詞需要 Apple Music 訂閱（iOS 16 起），「音樂」和 Spotify 等其他 App 都能用。可拖動調整來源順序，前面的找不到就由後面的補上。

「歌詞上島」可在縮小的動態島底部多一列顯示當前歌詞（白色或專輯顏色、淡入或向上捲動，長句自動捲動）；有逐字時間的歌詞（Apple Music、Musixmatch、網易雲、匯入的 TTML 或逐字 LRC）在島上會逐字亮起；也能隱藏 explicit 歌曲的「E」標記。偏移拉桿 ±3 秒，邊拖邊套用；演出者欄位可顯示原曲名與演出者、下一句歌詞或維持原樣；把自己的 `.lrc` 放進 App 的 `Library/NowLyrics/manual/` 即優先採用。

iOS 15.0 – 26.1，僅支援 rootless 越獄（Dopamine、palera1n），不能與 AMLyrics 同時安裝。iOS 18 以上的設定頁需要 PreferenceLoader 2.2.8（dhinakg 的軟體源），位置在「設定 › 一般」最下面。只會把曲名、演出者、專輯與長度送給歌詞服務（Apple Music 歌詞是以歌曲的 Apple Music ID 透過你的 Apple ID 向 Apple 取得），不需帳號、沒有追蹤。
