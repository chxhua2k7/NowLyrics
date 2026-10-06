While a song plays, NowLyrics puts the line being sung **in place of the track title** on the Lock Screen — and in Control Center, the Dynamic Island and CarPlay — so the words follow the music without opening or swiping anything.

## Features

- **Lyrics in the island** — optional: the current line in a strip at the bottom of the compact Dynamic Island, which grows down to the status bar's edge. White or album color, fade or scroll-up line changes, adjustable font size and scroll speed; long lines scroll. A preview on its settings page shows every change at once; tap or hold it like the real island.
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
- **YouTube Music, KKBOX, SoundCloud, TIDAL, Deezer, Amazon Music** — on by default, through the system's now-playing info
- **Other players** — any app that publishes now-playing info; pick them from a searchable list

## Lyrics sources

- **LRCLIB** — works out of the box, no account needed.
- **NetEase Cloud Music** — works out of the box, no account needed; lyrics are Simplified Chinese, no conversion applied.
- **Musixmatch** — the largest catalogue; needs your own token from the Musixmatch app (Settings → Get help → Copy debug info) or an API key. The lyrics timed to the version you play (single, album or radio edit) are picked.

Set a preferred source; the others fill in when it has nothing.

## Compatibility

**iOS 15.0 – 26.1.** This listing covers the **rootless** package only (Dopamine, palera1n), built for arm64 and arm64e. AltList is installed automatically for the app picker. On iOS 18 and later the settings page needs PreferenceLoader 2.2.8 (dhinakg's repo, https://dhinakg.github.io/repo/) and is at the bottom of Settings › General. After installing, tap **Apply** on the settings page once for Lyrics in the island. Verified on an iPhone 14 Pro (iOS 16.5.1); newer iOS versions verified with Spotify on virtual devices.

Cannot be installed alongside **AMLyrics** — both rewrite the same Apple Music item.

## Known issues

- Lyrics are line-synced (LRC); word-by-word lyrics are not available from these sources.
- Inside Apple Music the lyric line also appears in Music's own now-playing views.
- Lyrics in the island needs an iPhone with the Dynamic Island (iOS 16 iPhones given the island through MobileGestalt count); verified on iOS 16.5.1, 18.6.2 and 26.1.
- Songs are matched by title, artist and length, so live versions, remasters and rare tracks can be missed; add those lyrics yourself.
- The NetEase and Musixmatch token services are unofficial and may stop working.

Only the track title, artist, album and duration are sent to the lyrics services; your Musixmatch token is stored on the device and sent only to Musixmatch. No accounts, no analytics.

## 中文

NowLyrics 把正在唱的那句歌詞放到曲名的位置：鎖定畫面、控制中心、動態島與 CarPlay 都會顯示，不用打開任何 App。

支援 Spotify、Apple Music，YouTube Music、KKBOX、SoundCloud、TIDAL、Deezer、Amazon Music 預設開啟；其他會發布播放資訊的播放器可從完整 App 清單勾選。Spotify Connect 的曲名會還原成真正的曲名和演出者。

歌詞來源：LRCLIB 與網易雲音樂免設定即用（網易雲為簡體）；Musixmatch 曲庫最大，需貼上自己的 token 或 API key，會挑跟你播放的版本對得上的歌詞。可設定優先來源，其他來源自動補位。

「歌詞上島」可在縮小的動態島底部多一列顯示當前歌詞（白色或專輯顏色、淡入或向上捲動、字體大小與捲動速度可調，長句自動捲動），設定頁有預覽，可以像真的動態島一樣點按或長按。也能隱藏 explicit 歌曲的「E」標記。偏移拉桿 ±3 秒，邊拖邊套用；演出者欄位可顯示原曲名與演出者、下一句歌詞或維持原樣；把自己的 `.lrc` 放進 App 的 `Library/NowLyrics/manual/` 即優先採用。

iOS 15.0 – 26.1，僅支援 rootless 越獄（Dopamine、palera1n），不能與 AMLyrics 同時安裝。iOS 18 以上的設定頁需要 PreferenceLoader 2.2.8（dhinakg 的軟體源），位置在「設定 › 一般」最下面；安裝後到設定頁按一次「套用」。只會把曲名、演出者、專輯與長度送給歌詞服務，不需帳號、沒有追蹤。
