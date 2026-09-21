# NowLyrics

**Synced lyrics on the lock screen, in Control Center, the Dynamic Island and CarPlay — for Spotify, Apple Music and more.**

NowLyrics shows the current lyric line in place of the track title wherever iOS shows now-playing info. Nothing to open, nothing to swipe: the lyrics follow the song on the lock screen, in Control Center, in the Dynamic Island and on CarPlay.

## Works with the players you already use

Spotify, Apple Music, YouTube Music, KKBOX, SoundCloud, TIDAL, Deezer, Amazon Music — and any other app that publishes now-playing info. Pick which apps get lyrics from a full app list with search.

## Three lyrics sources

- **LRCLIB** and **NetEase Cloud Music** work out of the box, no account needed.
- **Musixmatch** for the largest catalogue: paste the token from the Musixmatch app (Settings → Get help → Copy debug info) or use your own API key.

Set a preferred source; the others fill in when it has nothing. Lyrics are cached per app, so a song fetched once never needs the network again.

## Made to be tuned

- **Offset slider** from −3 s to +3 s that applies as you drag, or type an exact value such as `0.25` or `-300ms`.
- **Artist field**: keep the credit (`Track — Artist`), show the next lyric line, or leave it alone.
- **Your own lyrics**: drop an `.lrc` into the app's `Library/NowLyrics/manual/` folder and it wins over every online source.
- **Diagnostics** mode shows which source answered, right in the artist field.
- Settings page in English, 繁體中文, 简体中文 and 日本語.

## Good to know

- Requires iOS 15 or 16 on a rootless jailbreak (Dopamine, palera1n). Built for arm64 and arm64e.
- Installs AltList automatically for the app picker.
- Lyrics are line-synced (LRC). Word-by-word lyrics are not available from these sources.
- NetEase lyrics are Simplified Chinese; no conversion is applied.
- Cannot be installed alongside AMLyrics: both rewrite the same Apple Music item.
- Only the track title, artist, album and duration are sent to the lyrics services. No accounts, no analytics.

---

## 中文

NowLyrics 把當前歌詞行放到曲名的位置：鎖定畫面、控制中心、動態島、CarPlay 都會顯示，不用打開任何 App。

支援 Spotify、Apple Music、YouTube Music、KKBOX、SoundCloud、TIDAL、Deezer、Amazon Music，以及任何會發布 now-playing 資訊的播放器，可從完整 App 清單勾選。

歌詞來源有三個：LRCLIB 和網易雲音樂免設定即可使用；Musixmatch 的曲庫最大，貼上其 App 的 token 或填自己的 API key 即可。可設定優先來源，其他來源自動補位；歌詞會依 App 快取。

偏移拉桿 ±3 秒、邊拖邊套用，也能直接輸入數值；演出者欄位可選顯示原曲名與演出者、下一句歌詞或維持原樣；把 `.lrc` 放進 App 的 `Library/NowLyrics/manual/` 就以你的檔案為準。設定頁有英文、繁中、簡中、日文。

需要 iOS 15 或 16 的 rootless 越獄（Dopamine、palera1n）。不能與 AMLyrics 同時安裝。網易雲歌詞為簡體。
