## 1.2.0

- **Apple Music lyrics** (optional, subscription needed): Apple's own text and word timing, in the Music app and also in **Spotify and other apps**, where the song is found on Apple Music by title, artist and length and its lyrics fetched through SpringBoard. Unlocked once your subscription is confirmed; without one, nothing Apple Music shows
- **Now Playing** page in Settings: the lock screen's player, the song with where its lyrics came from, a **source picked for this song**, and its own **offset**
- **Search again** for one song, **paste** lyrics or **import** them from Files (LRC, word-by-word LRC, Apple Music / AMLL TTML)
- **Lyrics library**: every saved song by app, searchable; view, edit and delete
- **Word by word in the island**: lines light up as they are sung, with a soft edge, and long lines glide along with the singing (Apple Music, Musixmatch, NetEase, imported TTML)
- **Island preview** shows what is playing: the real cover, waveform and line; long-press to open it with working controls, drag it to stretch it
- Clear lyrics cache moved into the library; lyrics you added are kept
- **Source order**: drag the sources into the order they are tried (replaces Preferred); only sources switched on are listed, and Lyrics Sources shows them in that order too
- **Musixmatch** gets its own page, like Apple Music: unlocked once the Musixmatch app is installed, and kept while a User Token or API key is saved
- **Top of main page** (Advanced): the player, the island preview, or nothing
- **Player over its cover** on the lock screen, in Control Center and in Settings (optional): the cover, blurred and darkened so the text stays readable; with nothing playing, the system's own look
- **Crescendo** and **NextUp 3** supported: the volume slider and the Up Next row also show in the player and the island preview in Settings
- **Word timing**: Musixmatch's word-by-word lyrics are checked against the song (some were timed to a version with a longer or shorter intro and lit seconds late or early, some were squeezed into the first minute); when they do not fit, the line-by-line lyrics timed to the version playing are used. A half-second system delay on line changes in Spotify and other apps is gone
- The island line stays out of the way while Face ID uses the island
- **iOS 18 and 26** checked: the island line waits until the island has settled (no more sideways shake on 26), Player over its cover also in iOS 18's Control Center, and on iOS 17 and later the volume slider follows the system's Always Show Volume Control. On iOS 18 and later the settings page needs PreferenceLoader 2.2.8 and is under Settings › General
- iPhones without the Dynamic Island get a note on the settings page that Lyrics Island needs one (iOS 16 iPhones given the island through MobileGestalt count as having it)
- Now Playing: picking a source searches again at once and shows what it found
- Settings reorganized: the player at the top, colors after the island preview, display options on the Now Playing page, one offset per song there with the default offset under Advanced, choices picked in place, the tweak's size under About
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
