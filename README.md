# NowLyrics

<img src="logo/NowLyrics-1024.png" width="128" alt="NowLyrics">

Synced lyrics on the lock screen, Control Center, Dynamic Island and CarPlay,
for Spotify, Apple Music and other players.

Inspired by [Lessica/AMLyrics](https://github.com/Lessica/AMLyrics), but built
on a different foundation.

繁體中文說明:[README.zh-Hant.md](README.zh-Hant.md)

## How it differs from AMLyrics

| | AMLyrics | NowLyrics |
|---|---|---|
| Lyrics source | Apple's official `syllable-lyrics` (TTML) | Musixmatch → LRCLIB → NetEase, selectable |
| How it is fetched | Hooks `ICURLSession` to reuse MusicKit's authenticated session | No auth needed, plain HTTPS |
| Track identity | `iTunesStoreIdentifier` / `lyricsAdamID` | Title + artist + duration matching |
| Parsing | Private `MSVLyricsTTMLParser` | Built-in LRC parser |
| Hook target | `MRNowPlayingPlayerClient`, `MPNowPlayingContentItem` | `MPNowPlayingInfoCenter` (third-party players), `MPNowPlayingContentItem` (Music) |
| Granularity | Per syllable | Per line |

The hook target is the important difference. Apple Music is a system app with
stable class names; Spotify's player classes are obfuscated and change every few
weeks. NowLyrics never touches the host app's own code — it hooks
`-[MPNowPlayingInfoCenter setNowPlayingInfo:]`, a public API that any player
displaying lock screen information must call. As a side effect it works with any
player, not just Spotify.

Apple Music is the one player that never calls that method: it hands MediaPlayer
a content item and MediaRemote reads the metadata out of that object. Inside
Music the same engine therefore edits the content item instead, the way
[AMLyrics](https://github.com/Lessica/AMLyrics) does; see "How it works".

## How it works

1. When `setNowPlayingInfo:` is called, the original call passes through
   untouched; the title, artist, album, duration, elapsed time and playback rate
   are then read on the main queue.
2. On a track change (a new title + artist; the duration is used only to
   check catalogue hits, since players report it a second or two apart from
   one play to the next), lyrics are resolved: manual override → on-disk cache
   → Musixmatch → LRCLIB → NetEase. A preferred source, if one is set, moves to
   the front of that order. A track published without a duration yet is waited
   for.
3. Players only report progress on play, pause and seek, so the position in
   between is extrapolated: `elapsed + (CACurrentMediaTime() - anchor) * rate`.
4. At each line boundary a `dispatch_after` fires, writes that line into
   `MPMediaItemPropertyTitle` and, depending on the Artist field setting, puts
   the track credit or the next line into the artist field.
   `elapsedPlaybackTime` is refreshed at the same time, otherwise the scrubber
   would jump back.

Inside Music (`com.apple.Music`) steps 1 and 4 look different, the rest is
shared:

- Music's playback engine owns an `MPNowPlayingContentItem` and keeps its
  elapsed time current, so the item's setters (`setElapsedTime:playbackRate:`,
  `setTitle:`, `setTrackArtistName:`, `setDuration:`) are hooked. Whatever the
  app writes there is the real title and artist; the item that receives
  progress updates is the one being played.
- Publishing means writing the current line into the item's own `title` and the
  credit into `trackArtistName`, then re-anchoring its elapsed time, which is
  what makes MediaPlayer republish. Nothing is written when the item already
  shows what it should, so the change notifications this raises cannot loop.
- Switching Music off in the app picker puts the real title back, since unlike
  the dictionary path nothing else will.

Which path a process gets is decided in `%ctor` from the bundle identifier
(`kNLContentItemBundles`); the two hook groups are never installed together.

## Settings

A NowLyrics entry appears in Settings. The page follows the device language
(English, Traditional Chinese, Simplified Chinese, Japanese); the footers are
deliberately short, this file has the details.

- **Enabled** — master switch.
- **Apps** — a full app list from AltList with a search bar. Applies live.
  Until the picker has been used once, a built-in default list applies: Apple
  Music, Spotify, YouTube Music, KKBOX, SoundCloud, TIDAL, Deezer and Amazon
  Music. A list saved before 2.11 does not gain Music by itself; tick it.
- **Display** — *Artist field*: what goes in the artist field while a lyric
  line occupies the title (the track credit `Track — Artist`, the next lyric
  line, or whatever the player set). *Offset*: global lyrics offset from −3 s
  to +3 s; drag the slider (0.1 s steps, applied as you drag) or tap the value
  and type one, e.g. `0.25` or `-300ms`. Positive means earlier. To nudge a
  single track instead, edit the `[offset:±ms]` tag at the top of its cached
  `.lrc`; the two add up.
- **Lyrics Sources** — Musixmatch / LRCLIB / NetEase, each independently
  switchable, plus a preferred source that is tried first; the rest keep the
  order Musixmatch → LRCLIB → NetEase. LRCLIB and NetEase are on by default,
  Musixmatch is off and needs either a User Token (paste the Musixmatch app's
  "Copy debug info" block; it identifies your account, so treat it like a
  password) or a developer API key, which is only used without a token.
- **Advanced** — *Diagnostics* appends the source that answered to the artist
  field, or, when nothing was found, what each source said (e.g. `LRCLIB 3
  timed, duration off by 41s · NetEase nothing under this title`; "nothing under
  this title" means no catalogue entry, "duration off" a length mismatch, "will
  retry" a timed-out request). *Quit app on change* terminates the host app on
  every settings change, which is rarely needed since everything applies live.
  *Clear lyrics cache* deletes the downloaded lyrics in every app.
- **About** — the installed version.

Changes post a Darwin notification (`app.nowlyrics/ReloadPrefs`), so they take
effect without relaunching anything. Changing the sources also clears the
in-memory cache; the on-disk cache is kept.

## Supplying your own lyrics

Matching is string-based, so live takes, remasters and obscure tracks will fail —
the entry simply is not in the catalogue and no tuning changes that. Drop a `.lrc`
into the target app's container instead:

```
Library/NowLyrics/manual/
```

Name it `Title - Artist.lrc` or `Title.lrc` (both cases are tried, duration is
ignored). Manual lyrics take priority over every online source and are never
overwritten by the cache.

Fetched lyrics are cached one level up, in `Library/NowLyrics/`, as `.lrc`
files named after the track, so they can be found and hand-edited. An
`[offset:±ms]` tag at the top of such a file shifts that one track. The folder
keeps at most 300 files per app, oldest out first. *Clear lyrics cache* in the
settings records the time of the tap; each app deletes the files older than
that, at once if it is running and otherwise when it is next launched.

## Known limitations

- LRCLIB's coverage of Chinese tracks is noticeably weaker than English, which is
  why NetEase is enabled as a fallback. That endpoint is unofficial and may break
  or block non-mainland addresses.
- **NetEase lyrics are Simplified Chinese.** There is no conversion. Musixmatch
  has more native Traditional entries for Mandopop. The credit lines (作词 /
  作曲 / 编曲) and the copyright notice NetEase puts at the start of a transcript
  are dropped by the parser, so they no longer flash up as lyrics. NetEase also
  puts blank timestamped lines between verses; a blank is only treated as a gap
  (where the track title is shown) when the next line is five seconds or more
  away, otherwise the previous line simply stays up.
- Musixmatch has two paths. A **User Token** taken from the Musixmatch app hits
  `apic.musixmatch.com/ws/1.1/macro.subtitles.get`, the endpoint the app itself
  uses — unofficial, may break at any time, and the token is effectively an
  account credential. A **developer API key** hits the documented API, but its
  timed `matcher.subtitle.get` endpoint is usually not part of the free plan, so
  expect 403. The token path is tried first.
- Unlike EeveeSpotify, no `track_spotify_id` is sent: reading it requires hooking
  Spotify's private `SPTPlayerTrack`, which would forfeit the whole
  system-frameworks-only design and only ever help Spotify. Matching is therefore
  weaker for obscure or same-titled tracks.
- Matching relies on strings. `NLCleanTitle()` strips `- 2011 Remaster` and
  `(feat. X)` style suffixes, but it is not perfect. A duration mismatch over 8
  seconds (10 for NetEase) is rejected rather than shown, since wrong lyrics are
  worse than none.
- Preferences are read from the app's own `Library/Preferences/`, then
  `/var/mobile/Library/Preferences/`, then the same path under `/var/jb`. If
  none is readable, everything falls back to the defaults: the built-in app
  list, LRCLIB and NetEase. The in-container path is also how it can be
  configured when injected with TrollFools, where there is no Settings panel.
- Apple Music support is built on the same hook points AMLyrics uses
  (`MPNowPlayingContentItem`), which are private API, so an iOS update can
  change them. Do not run AMLyrics and NowLyrics inside Music at the same time:
  both write the item's title. Because the title is changed on the item itself,
  Music's own now-playing views may show the lyric line too. Manual `.lrc`
  files for Music go into Music's own container.
- **Per line, not per syllable.** AMLyrics can do syllables because Apple's TTML
  carries that markup; LRC does not.
- Injecting into an App Store app changes its signature, which may sign you out
  or break Spotify Connect. That is a property of the injection, not this code.

## Install

NowLyrics is sold on [Havoc](https://havoc.app). Add the Havoc repo in Sileo, buy it, install. Requires iOS 15 or 16 on a rootless jailbreak (Dopamine, palera1n) and [AltList](https://github.com/opa334/AltList), which Sileo pulls in automatically.

## Privacy

To look up lyrics, NowLyrics sends the track title, artist, album and duration to the lyrics services you have enabled: Musixmatch, LRCLIB and NetEase Cloud Music. Nothing else leaves the device. If you paste a Musixmatch token, it is stored only in the tweak's preference file on your device and sent only to Musixmatch. There are no analytics, no accounts and no tracking.

## License

© 2026 chxhua2k7. All rights reserved. This repository holds the documentation for NowLyrics; the software is proprietary and distributed through Havoc.
