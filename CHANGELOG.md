# Changelog

## 1.2.4

- Settings: the notes under Advanced and Lyrics Island now say how Quit app on change works (it quits the music app only when a setting it uses changes) and where word-by-word lyrics come from (Apple Music, Musixmatch or NetEase where they have them, or TTML and word-by-word LRC you add)
- Added more bugs to fix later

## 1.2.3

- **Apple Music subscription** is checked only when something changes, not once a day: when Apple Music reports a change, after a respring, and when Apple Music lyrics are refused. Signing out of Media & Purchases locks Apple Music like a lapsed subscription, and unlocking then asks you to sign in first
- **Quit app on change** quits the music app only for a change it uses: opening Settings, the island's options or the pages' layout no longer quit what is playing, and an automatic Apple Music lock looks the song up again instead
- **Now Playing** shows the whole status; when no lyrics were found, each source's reason is on its own line. The lyrics library's details wrap instead of being cut off
- Lyrics in the island: the line no longer fades in while the iOS 26 island is still springing open; with Album color, a song without a cover goes back to white; a long line leaving keeps its faded edges
- Picking another source while a search is still running no longer brings back the old answer
- Spotify and other apps: a busy or failing Apple Music search is tried again later instead of being taken as "not on Apple Music"
- Musixmatch: a User Token field holding only spaces, or a pasted debug block without a token, counts as no token everywhere, so Now Playing no longer offers Musixmatch then; lyrics found with the User Token look the same the first time as when played again
- LRCLIB: lyrics are found when the app does not report the song's length
- Music: Hide "E" no longer acts while NowLyrics is switched off for Music
- Island preview in Settings: a new cover is noticed even when it is the same size as the last one; the open preview closes properly when music stops; without a live preview, the pages' color matches what the preview shows
- Settings: the waveform stops while its page is covered; the Apple Music test stops when you tap OK; a song's offset is no longer clipped to ±3 s when the default offset is set too
- Lyrics library: files whose names start with a dot are listed; lyrics you added as ".LRC" are used; every word-timed file is marked Word by word; a search of only spaces shows the right note
- Simplified Chinese and Japanese: notes name the rows as the rows are labeled
- Smaller and lighter: shared code instead of copies across the tweak, SpringBoard and Settings
- Added more bugs to fix later

## 1.2.2

- **Transparency** for Player over its cover (Advanced, default 50 %): the cover and the system's material under it thin together, so the wallpaper shows through on the lock screen and in Control Center
- **Choose Apps** filter: music apps only (the default: the App Store's Music category, Music, Podcasts and apps already chosen) or all apps, from the button at the top right
- **Preview island** option on the Lyrics Island page: Compact, Expanded, or Auto compact (opens, then closes after 5 s left alone)
- **Other pages too** (Advanced, on by default): the other pages show what the top of the main page shows, the player, the island preview or nothing; Lyrics Island keeps its own preview and Now Playing its player
- **Supported Tweaks** (Advanced): a switch each for Crescendo and NextUp 3, with their own icons, for their volume slider and Up Next row in the player and the island preview on these pages
- The player in Settings sits on a background as it does on the lock screen: glass on iOS 26, the system's material on earlier iOS; Player over its cover lies over it
- iOS 17 and later: the player in Settings shows the volume slider when Always Show Volume Control is on, as the lock screen does
- iOS 26: Player over its cover and its transparency are hidden, as the lock screen and Control Center keep the system's look there; the open island preview no longer touches the row below it
- Apple Music: when its privacy notice has not been agreed to on this iPhone, unlocking asks you to agree in Music first instead of Apple's sheet appearing over the screen, and no Apple Music lyrics are fetched until then
- Lyrics Sources: Source order sits in a group of its own
- Added more bugs to fix later

## 1.2.1

- Island preview: a swipe back let go halfway no longer leaves the open player over the closed island, and the preview still on the page takes the island back
- The main page's island preview follows the Lyrics Island page's lyrics color, font size and line change
- Island preview: NextUp 3's Up Next row and Crescendo's volume slider take taps and drags again, with more room between the slider and the row
- Now Playing: "Remove added lyrics" removes the song you confirmed, not whichever plays when you tap
- Now Playing no longer rebuilds itself every 0.75 s with nothing playing, and no longer leaks with each visit
- Settings: the waveform animation no longer keeps running after its page closed, while nothing plays, or while the page is covered
- Less battery use: SpringBoard asks for the now-playing info (cover included) once per change for the island and the player, reads the settings file once per change, and refetches the cover only when Player over its cover is switched; faster lyrics parsing; the settings pages no longer decode the same cover again, scan every app's container or reload the library twice
- Added more bugs to fix later

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
