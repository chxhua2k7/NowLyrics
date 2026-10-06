# Changelog

## 1.2.4

### Features

- Lyrics Island also works on devices given the Dynamic Island by a tweak or a MobileGestalt edit, iPads included

### Fixes

- iPad: with the Settings sidebar showing, the player at the top of the settings pages fills the page again, and the island preview sits in the middle
- Clearer notes in Settings on what Quit app on change does and which lyrics light up word by word
- Added more bugs to fix later D:

## 1.2.3

### Features

- Your Apple Music subscription is checked only when something changes, instead of once a day; signing out of Media & Purchases locks Apple Music lyrics, and unlocking then asks you to sign in first
- Now Playing shows the whole story of where the lyrics came from; when none were found, each source's reason gets its own line
- Smaller and lighter

### Fixes

- Quit app on change no longer quits the music app when you just open NowLyrics' settings or change something it does not use
- Lyrics in the island wait for the iOS 26 island to finish opening before they appear
- With Album color, a song without a cover goes back to white
- A long line keeps its faded edges as it leaves
- Picking another source while lyrics are still being searched no longer brings back the old result
- Apple Music lyrics in Spotify and other apps: a search that fails is tried again later instead of giving up on the song
- Musixmatch: a User Token field with nothing in it no longer counts as a token, and its lyrics look the same the first time as when played again
- LRCLIB finds lyrics even when the app does not say how long the song is
- Music: Hide explicit badge no longer acts while NowLyrics is off for Music
- Island preview in Settings: a new cover always shows, the open preview closes properly when the music stops, and the page colors match the preview
- Settings: the waveform stops while its page is covered, the Apple Music test stops when you tap OK, and a song's offset is no longer cut off at ±3 s
- Lyrics Library: song details wrap instead of being cut off, files whose names start with a dot are listed, lyrics added as ".LRC" are used, every word-by-word file is marked, and a search of only spaces shows the right note
- Simplified Chinese and Japanese: the notes use the rows' actual names
- Added more bugs to fix later D:

## 1.2.2

### Features

- Transparency for Player over its cover (Advanced): let the wallpaper show through on the Lock Screen and in Control Center
- Choose Apps lists music apps only (the default) or all apps
- Preview island option: Compact, Expanded, or Auto compact (opens, then closes after 5 s)
- Other pages too (Advanced): the other settings pages show the same player or island preview as the main page
- Supported Tweaks (Advanced): turn Crescendo's volume slider and NextUp 3's Up Next row in Settings on or off
- The player in Settings sits on a background, as on the Lock Screen
- iOS 17 and later: the player in Settings shows the volume slider when Always Show Volume Control is on

### Fixes

- iOS 26: Player over its cover is hidden, as the Lock Screen and Control Center keep their own look there
- iOS 26: the open island preview no longer touches the row below it
- Apple Music: if you have not agreed to Apple Music's privacy notice yet, unlocking asks you to do it in Music first instead of Apple's sheet popping up
- Source order sits in its own group on Lyrics Sources
- Added more bugs to fix later D:

## 1.2.1

### Features

- The main page's island preview follows your lyrics color, font size and line change
- Less battery use, and faster settings pages

### Fixes

- Island preview: swiping back halfway no longer leaves the open player over the closed island
- Island preview: NextUp 3's Up Next row and Crescendo's volume slider respond to taps and drags again
- Now Playing: Remove added lyrics removes the song you confirmed, not whatever is playing when you tap
- Now Playing no longer keeps redrawing when nothing is playing, and uses less memory
- The waveform animation stops when its page closes, when nothing plays, or when the page is covered
- Added more bugs to fix later D:

## 1.2.0

### Features

- Apple Music lyrics (subscription needed): Apple's own lyrics, word by word where Apple has them, in Music and also in Spotify and other apps
- Word by word in the island: lines light up as they are sung, and long lines glide along with the singing
- Now Playing page: see where the song's lyrics came from, pick another source for that song, and set its own offset
- Paste lyrics or import them from Files (LRC, word-by-word LRC, TTML); lyrics you add come before every source
- Lyrics Library: browse, search, edit and delete saved lyrics by app; Clear lyrics cache lives here now and keeps lyrics you added
- The island preview shows what is playing; hold it to open it with working controls, drag it to stretch it
- Source order: drag the sources into the order they are tried
- Musixmatch has its own page and unlocks once the Musixmatch app is installed; its word-by-word lyrics are used only when they match the version playing
- Top of main page (Advanced): the player, the island preview, or nothing
- Player over its cover: the player on the Lock Screen, in Control Center and in Settings sits on its cover, blurred and darkened
- Crescendo and NextUp 3: their volume slider and Up Next row also show in the Settings player and island preview
- Settings reorganized: the player at the top, Now Playing, Lyrics Sources and Advanced pages
- On iOS 15, Apple Music lyrics stay hidden (they need iOS 16)

### Fixes

- Added more bugs to fix later D:

## 1.1.2

### Features

- Works with iOS 18 and later: the settings page is under Settings › General (needs PreferenceLoader 2.2.8)
- Musixmatch picks the lyrics that match the version you are playing (single, album or radio edit)
- On iPhones without the Dynamic Island, the island settings explain that Lyrics in the island needs one (iPhones given the island by a tweak count as having it)

### Fixes

- Lyrics in the island no longer shake sideways as they appear (iOS 17 and later)
- Lyrics in the island make way when Face ID or something else uses the island
- Long lines no longer lose their first and last letters at the faded edges
- Lyrics in Spotify and other apps change on time instead of half a second late
- Lyrics no longer jump back now and then
- The real song title no longer flashes up in place of the lyrics in some apps
- Fixed a rare crash in music apps when changing a setting
- Settings icons no longer go missing on older iOS
- Added more bugs to fix later D:

## 1.1.1

### Features

- Island preview on the island settings page: tap or hold it like the real island

### Fixes

- Long lines stay at the end instead of scrolling back while still being sung
- The previous line no longer flashes up when the line changes
- More NetEase credit lines are filtered out
- Added more bugs to fix later D:

## 1.1.0

### Features

- Lyrics Island: the current line at the bottom of the Dynamic Island (optional)
- Hide explicit badge option
- An Apply button restarts SpringBoard, and options only show when their switch is on

### Fixes

- Turning NowLyrics off brings the real title back right away
- NetEase credits no longer show up as lyrics
- Less battery use
- Added more bugs to fix later D:

## 1.0.0

Initial release.

### Features

- Lyrics in place of the track title on the Lock Screen, in Control Center, the Dynamic Island and CarPlay
- Spotify, Apple Music and any other app that shows what it plays; choose them per app
- Musixmatch, LRCLIB and NetEase Cloud Music, with a preferred source
- An offset slider (or type a value), artist field options, your own .lrc files, and lyrics cached per app
- Settings in English, Traditional Chinese, Simplified Chinese and Japanese
- Added more bugs to fix later D:
