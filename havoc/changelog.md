## 1.1.2

- Lyrics in the island: on iOS 17 and later the line waits until the island has settled (no more sideways shake on iOS 26)
- Lyrics in the island: the line steps aside while another element, such as Face ID, uses the island
- Long lines: the first and last characters are no longer eaten by the faded edges
- Lyrics in Spotify and other apps no longer change half a second late
- The lyrics clock no longer jumps back when an app publishes NowLyrics' own update again
- An app updating its now-playing info from another thread is no longer let through with its raw title
- Fixed a rare crash in music apps when the settings changed while the lyrics updated
- Musixmatch: the lyrics timed to the version playing (single, album, radio edit) are picked
- iPhones without the Dynamic Island get a note that Lyrics in the island needs one (iOS 16 iPhones given the island through MobileGestalt count as having it)
- Settings icons missing on older iOS show a stand-in
- On iOS 18 and later the settings page needs PreferenceLoader 2.2.8 and is under Settings › General
- Added more bugs to fix later

## 1.1.1

- **Island preview** on the island settings page; tap or hold it like the real island
- Long lines stay at the end instead of scrolling back while still being sung
- Fixed the previous line flashing up at a line change
- More NetEase credits filtered (lines such as "歌手 Artist：…" no longer stop the filter)

## 1.1.0

- **Lyrics in the island** — the current line at the bottom of the compact Dynamic Island (optional)
- **Hide explicit badge** option
- Settings: Apply restarts SpringBoard; options show only when their switch is on
- Switching off restores the real title at once
- Fixed NetEase credits showing as lyrics; less battery use

## 1.0.0

Initial release.

- Lyrics in place of the track title on the lock screen, Control Center, Dynamic Island and CarPlay
- Spotify, Apple Music and any other now-playing app, selectable per app
- Musixmatch, LRCLIB and NetEase Cloud Music, with a preferred source
- Offset slider with typed values, artist-field options, manual `.lrc` override, per-app cache
- Settings in English, Traditional Chinese, Simplified Chinese and Japanese
