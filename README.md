# NowLyrics

<img src="logo/NowLyrics-1024.png" width="128" alt="NowLyrics">

While a song plays, NowLyrics puts the line being sung **in place of the track
title** on the lock screen, in Control Center, the Dynamic Island and CarPlay,
so the words follow the music without opening anything. Optionally it adds a
strip with the current line under the Dynamic Island, lit up word by word.

Works with Spotify, Apple Music and any player that shows what it plays on the
lock screen. Lyrics come from Apple Music (with a subscription), Musixmatch,
LRCLIB and NetEase Cloud Music.

Current version: **1.2.4** · [Changelog](CHANGELOG.md) · 繁體中文說明:[README.zh-Hant.md](README.zh-Hant.md)

## Features

- **Lyrics in place of the title**: lock screen, Control Center, Dynamic
  Island and CarPlay. The artist field can keep the track and artist, show the
  next line, or stay as the player set it.
- **Lyrics Island**: the current line at the bottom of the compact Dynamic
  Island, which grows down to the status bar's edge. White or album color, a
  fade or scroll-up line change, adjustable font size and scroll speed. Long
  lines scroll, and lyrics with word times light up word by word as they are
  sung. A live preview on its settings page shows every change at once.
- **Four lyrics sources**, tried in the order you drag them into: Apple Music,
  Musixmatch, LRCLIB and NetEase. When one has nothing, the next fills in.
- **Now Playing page** in Settings: the lock screen's player, where the song's
  lyrics came from (or why each source found none), a source picked for this
  song, and this song's own offset.
- **Your own lyrics**: paste them or import them from Files (LRC, word-by-word
  LRC, Apple Music / AMLL TTML); lyrics you add win over every source.
- **Lyrics Library**: every saved song by app, searchable; view, edit and
  delete, or clear the cache (lyrics you added are kept).
- **Player over its cover**: the player on the lock screen, in Control Center
  and in Settings sits on its cover, blurred and darkened, with adjustable
  transparency (iOS 15–18).
- **Offset**: a default for every song and one per song, −3 s to +3 s, applied
  as you drag; or type an exact value such as `0.25` or `-300ms`.
- **Hide explicit badge**: drops the "E" that would follow the lyric line.
- **Spotify Connect**: "Track • Artist / Playing on …" is turned back into the
  real title and artist.
- **Other tweaks**: Crescendo's volume slider and NextUp 3's Up Next row also
  show in the player and the island preview in Settings. Tweaks that show the
  now-playing title, such as Letterpress, show the lyric line too.
- **Settings in four languages**: English, 繁體中文, 简体中文 and 日本語.

## Supported apps

- **Spotify** and **Apple Music**: full support.
- **YouTube Music, KKBOX, SoundCloud, TIDAL, Deezer, Amazon Music**: on by
  default, through the system's now-playing info.
- **Any other player** that shows what it plays on the lock screen: pick it
  under Choose Apps, which lists music apps (or, with its filter, all apps).

## Lyrics sources

| Source | Needs | Notes |
|---|---|---|
| **Apple Music** | An Apple Music subscription, iOS 16 or later | Apple's own lyrics in your region's store text (Traditional Chinese in Taiwan), word by word where Apple has it. Works in Music and, through SpringBoard, in Spotify and other apps |
| **Musixmatch** | The Musixmatch app, then its User Token or your own API key | The largest catalogue, much of it word by word |
| **LRCLIB** | Nothing | On by default |
| **NetEase Cloud Music** | Nothing | On by default; lyrics are Simplified Chinese |

**Apple Music lyrics** stay hidden until you unlock them: Lyrics Sources ›
Unlock Apple Music lyrics checks your subscription. Agree to Apple Music's
privacy notice in the Music app first, and be signed in under Settings › your
name › Media & Purchases. The subscription is checked again only when
something changes: when Apple Music reports a change, after a respring, and
when Apple Music refuses a lyrics request. A lapsed subscription, or signing
out of Media & Purchases, locks Apple Music again and NowLyrics carries on with
the other sources. In other apps the song is found on Apple Music by title,
artist and length; Test with the song playing shows each step.

**Musixmatch** is unlocked once the Musixmatch app is installed. Paste its
debug info into User Token (in the Musixmatch app: Settings → Get help → Copy
debug info), or enter an API key of your own. The User Token identifies your
Musixmatch account, so treat it like a password.

## Settings

NowLyrics has its own page in Settings (on iOS 18 and later at the bottom of
Settings › General). **Apply** at the top right restarts SpringBoard; it is
needed once after installing, for what runs there: Lyrics Island, Player over
its cover and Apple Music lyrics in other apps. Everything else applies at
once.

- **Enabled** and **Choose Apps**: the main switch and the apps NowLyrics
  works in.
- **Now Playing**: the song playing now. Artist field, Hide explicit badge and
  this song's Offset; Auto or a source picked for this song; Paste lyrics,
  Import from Files, Remove added lyrics, and View and edit for the lyrics in
  use.
- **Lyrics Island**: Enabled, Preview what's playing, Preview island (Compact,
  Expanded or Auto compact), Lyrics color (White or Album color), Line change
  (Fade or Scroll up), Word by word, Font size, Scroll speed. The preview at
  the top works like the real island: tap or hold it.
- **Lyrics Sources**: Lyrics Library, Source order, Apple Music lyrics (with
  Use in other apps and a test), Musixmatch, LRCLIB and NetEase Music.
- **Advanced**:
  - Default offset;
  - Top of main page (Player, Island or Hidden), and Other pages too to put
    the same at the top of the other pages;
  - Player over its cover and Transparency;
  - Supported Tweaks (Crescendo, NextUp 3);
  - Diagnostics (the source that answered, in the artist field);
  - Quit app on change (quits the music app when a setting it uses changes);
  - Fix Spotify Connect titles.

## Adding your own lyrics

The easiest way is Settings › NowLyrics › Now Playing while the song plays:
**Paste lyrics** (copy LRC or TTML first) or **Import from Files**. Lyrics you
add are used before every source until you remove them.

By hand: put an `.lrc` file named `Title - Artist.lrc` (or `Title.lrc`) into
the app's container, under `Library/NowLyrics/manual/`. An `[offset:±ms]` tag
at the top shifts that one song. Lyrics fetched online are kept per app in
`Library/NowLyrics/` (at most 300 songs per app) and can be edited in the
Lyrics Library.

## Requirements and install

- **iOS 15.0 – 26.1**, rootless jailbreak (Dopamine, palera1n), arm64 and arm64e.
- **AltList**, installed automatically with NowLyrics.
- **iOS 18 and later**: PreferenceLoader 2.2.8 from
  [dhinakg's repo](https://dhinakg.github.io/repo/), which the settings page
  needs there.
- Cannot be installed alongside **AMLyrics**: both rewrite the same Apple Music
  item.

NowLyrics is sold on [Havoc](https://havoc.app): add the Havoc repo in your
package manager, buy NowLyrics and install it, then tap **Apply** on its
settings page once.

## Troubleshooting

- **No lyrics for a song**: open Settings › NowLyrics › Now Playing. It shows
  what each source answered; pick another source for the song, or add the
  lyrics yourself.
- **Lyrics a little early or late**: drag Offset on Now Playing (this song) or
  Default offset under Advanced (every song).
- **Nothing under the Dynamic Island**: Lyrics Island needs an iPhone with the
  Dynamic Island and one respring (Apply) after installing.
- **Apple Music lyrics missing**: make sure Apple Music lyrics is unlocked and
  on under Lyrics Sources; the unlock tells you what is missing.

## Known limitations

- The lock screen, Control Center and CarPlay show the whole line; only Lyrics
  Island goes word by word, and only with lyrics that have word times.
- Inside Apple Music the lyric line also appears in Music's own now-playing
  views.
- Songs are matched by title, artist and length, so live versions, remasters
  and rare tracks can be missed; add those lyrics yourself.
- NetEase lyrics are Simplified Chinese, with no conversion. The NetEase and
  Musixmatch User Token services are unofficial and may stop working; a free
  Musixmatch API key usually has no timed lyrics.
- Apple Music lyrics and Lyrics Island rely on iOS internals, checked on iOS
  16.5.1, 18.6.2 and 26.1; another iOS version may need an update.
- On iOS 26, Player over its cover is hidden: the lock screen's player is
  glass there and Control Center already takes the cover's colors.

## Privacy

To find lyrics, NowLyrics sends the track's title, artist, album and length to
the lyrics sources you have on. Apple Music lyrics are asked of Apple through
your own Apple ID, after the song is found with Apple's public search; the
subscription check also asks Apple. A Musixmatch User Token or API key is
stored only in NowLyrics' settings on your device and sent only to Musixmatch.
No accounts, no analytics, no tracking.

## Credits

Inspired by [Lessica/AMLyrics](https://github.com/Lessica/AMLyrics). App
picker by [AltList](https://github.com/opa334/AltList). Lyrics from Apple
Music, [Musixmatch](https://www.musixmatch.com), [LRCLIB](https://lrclib.net)
and NetEase Cloud Music.

## License

© 2026 chxhua2k7. All rights reserved. This repository holds the
documentation for NowLyrics; the software is proprietary and distributed
through Havoc.
