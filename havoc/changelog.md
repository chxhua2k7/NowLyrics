## 1.2.0

- **Apple Music lyrics** (optional, subscription needed): Apple's own text and word timing, in the Music app and also in **Spotify and other apps**, where the song is found on Apple Music by title, artist and length and its lyrics fetched through SpringBoard. Unlocked once your subscription is confirmed; without one, nothing Apple Music shows
- **Word by word in the island**: lines light up as they are sung, with a soft edge, and long lines glide along with the singing (Apple Music, Musixmatch, NetEase, imported TTML and word-by-word LRC)
- **Now Playing** page in Settings: the lock screen's player, the song with where its lyrics came from, a **source picked for this song** (tried first, then the others), and its own **offset**
- **Paste** lyrics or **import** them from Files (LRC, word-by-word LRC, Apple Music / AMLL TTML); added lyrics come before every source
- **Lyrics library**: every saved song by app, searchable; view, edit and delete. Clear lyrics cache moved into it; lyrics you added are kept
- **Island preview** shows what is playing: the real cover, waveform and line; long-press to open it with working controls, drag it to stretch it
- **Source order**: drag the sources into the order they are tried (replaces Preferred); Lyrics Sources lists them in that order
- **Musixmatch** gets its own page, like Apple Music: unlocked once the Musixmatch app is installed, and kept while a User Token or API key is saved. Musixmatch's word-by-word lyrics are used only when they fit the version playing
- **Top of main page** (Advanced): the player, the island preview, or nothing
- **Player over its cover** on the lock screen, in Control Center and in Settings (optional): the cover, blurred and darkened so the text stays readable; with nothing playing, the system's own look. Also in iOS 18's Control Center and on iOS 15's lock screen
- **Crescendo** and **NextUp 3** supported: the volume slider and the Up Next row also show in the player and the island preview in Settings; on iOS 17 and later the volume slider follows the system's Always Show Volume Control
- Settings reorganized: the player at the top, a Now Playing page, Lyrics Sources and Advanced pages, choices picked in place, the tweak's size under About
- iOS 15: Apple Music lyrics need iOS 16 and stay hidden
- Lyrics saved by older versions are deleted once, so songs you played before are looked up again with the new sources
- Added more bugs to fix later

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
- Added more bugs to fix later

## 1.1.0

- **Lyrics Island** — the current line at the bottom of the compact Dynamic Island (optional)
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
