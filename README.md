# NowLyrics

<img src="logo/NowLyrics-1024.png" width="96" alt="NowLyrics">

Synced lyrics in place of the track title on the lock screen, in Control Center,
the Dynamic Island and CarPlay. Works with Spotify, Apple Music and any other
player that publishes now-playing info. Lyrics come from Musixmatch, LRCLIB and
NetEase Cloud Music.

This is the source repository (private). The public page is
[github.com/chxhua2k7/NowLyrics](https://github.com/chxhua2k7/NowLyrics); the
package is sold on Havoc as `com.c3x14n.nowlyrics`. Havoc listing material lives
in `havoc/`.

繁體中文說明:[README.zh-Hant.md](README.zh-Hant.md)

## What it does

- Replaces the track title with the current lyric line everywhere iOS shows
  now-playing info; the artist field shows the credit (`Track — Artist`), the
  next line, or is left alone.
- Any player: the hook is on a public MediaPlayer API, not on the app's own
  classes, so Spotify updates cannot break it. Apple Music gets its own path
  (see below). Which apps get lyrics is chosen from a full app list.
- Three sources with a preferred one; per-app disk cache; manual `.lrc`
  override; global offset slider plus per-track offset tags.
- Settings page in English, Traditional Chinese, Simplified Chinese and
  Japanese, with runtime-drawn SF Symbol icons and a version row.

Compared with [AMLyrics](https://github.com/Lessica/AMLyrics), which inspired
it: AMLyrics reads Apple's official per-syllable TTML through MusicKit's
session and only works inside Apple Music; NowLyrics is per line, needs no
authentication, and works in every player. The two cannot coexist inside
Music (both rewrite the same item), so the package conflicts with
`com.82flex.amlyrics`.

## How it works

Two publish paths share one engine. Which one a process gets is decided in
`%ctor` from the bundle identifier (`kNLContentItemBundles`); the hook groups
are never installed together.

**Third-party players (dictionary path).** Every player that shows lock-screen
info calls `-[MPNowPlayingInfoCenter setNowPlayingInfo:]`. The hook lets the
call through, then reads title, artist, album, duration, elapsed time and rate
on the main queue. At each line boundary the engine pushes a copy of the
player's dictionary with the title (and, per setting, the artist) replaced and
the elapsed time re-anchored so the scrubber does not jump. An echo guard puts
the real values back if the app reads its own info and pushes it again.

While Spotify plays on another device (Spotify Connect) the phone reports
`Title • Artist` with `Playing on <device>` as the artist. With *Fix Spotify
Connect titles* on, the hook rewrites that pair before the system sees it, so
lookups, cache names and the lock screen use the real title and artist and
nothing flashes at a track change.

**Apple Music (content-item path).** Music never calls `setNowPlayingInfo:`.
Its engine owns an `MPNowPlayingContentItem` and MediaRemote reads the metadata
out of it, so the item's setters are hooked (`setElapsedTime:playbackRate:`,
`setTitle:`, `setTrackArtistName:`, `setDuration:`). Whatever the app writes is
the real title and artist; the item that receives progress is the one playing.
Publishing writes the line into the item's `title` and the credit into
`trackArtistName`, then re-anchors its elapsed time, which makes MediaPlayer
republish. Nothing is written when the item already shows what it should, so
the change notifications cannot loop. Turning Music off puts the real title
back, since nothing else would.

**The engine.** A track is identified by title and artist (duration is only
used to check catalogue hits, because players report it a second or two apart
from one play to the next; a track published without a duration is waited
for). Lyrics resolve in this order: manual file → disk cache → the sources in
preferred order. Players only report progress on play, pause and seek, so the
position in between is extrapolated from the last anchor and the playback
rate; a `dispatch_after` fires at every line boundary. Settings are an
immutable snapshot replaced on every reload, so a fetch in flight keeps a
consistent view.

**Parsing.** The LRC parser handles offset tags, multi-timestamp lines and
sorts; it drops the credit lines (作词 / 作曲 / …) and copyright notices NetEase
prepends. A blank timestamped line only counts as a gap (title shown) when the
next line is 5 s or more away; otherwise the previous line stays up.

## Your own lyrics and the cache

Matching is string-based, so live takes, remasters and obscure tracks may miss.
Drop a `.lrc` into the target app's container:

```
Library/NowLyrics/manual/Title - Artist.lrc      (or Title.lrc)
```

Manual lyrics win over every online source and are never overwritten. Fetched
lyrics are cached one level up, in `Library/NowLyrics/`, named after the track,
so they can be found and hand-edited; an `[offset:±ms]` tag at the top shifts
that one track (it adds to the global offset). At most 300 files per app are
kept, oldest out first. Music's files go into Music's own container.

## Building and releasing

Theos on a Mac with Xcode. `THEOS` must point at the Theos checkout.

```bash
make package                 # debug: NSLog on every step
make package FINALPACKAGE=1  # release: silent, half the size — what ships
```

- Rootless (`THEOS_PACKAGE_SCHEME = rootless`); comment it out for rootful.
- `ARCHS = arm64 arm64e`. The arm64e slice is what makes Apple Music work and
  it must come from Xcode's toolchain; an on-device build (`ARCHS=arm64`)
  drops Music: those slices fail pointer authentication (libobjc crashes in
  `readClass()`, a PAC failure), and the Mach-O metadata is identical, so the
  signing is the difference.
- **The version is written in one place**, `PACKAGE_VERSION` in the Makefile.
  It becomes the package version, the `NL_VERSION` define (User-Agent and the
  About row), and fills the `__VERSION__` placeholders of `bundle/Info.plist`
  at stage time. `control`'s `Version:` line is overwritten by Theos.
- `control`: package `com.c3x14n.nowlyrics`; `Conflicts`/`Replaces` on
  `com.82flex.amlyrics`; `Icon:` points at the bundle's 87 px icon so Sileo
  shows it. The preference domain and notifications keep the `app.nowlyrics`
  name.
- Runtime dependency: [AltList](https://github.com/opa334/AltList) for the app
  picker (`dlopen`ed by the settings bundle), plus PreferenceLoader.
- The logo is a 16×16 pixel-art note block (`logo/NowLyrics.svg`); the PNGs are
  rendered straight from the grid with solid pixels and iOS-style rounded
  corners, never by scaling the SVG (that leaves semi-transparent seams).

Installing on the device: copy the `.deb` over and `sudo dpkg -i` it. No
respring is needed: players pick the dylib up on relaunch, the settings page
after `killall Preferences`.

## Code layout

| File | What it holds |
|---|---|
| `NowLyrics.xm` | The hooks and the two publishers (dictionary path, content-item path), the Spotify Connect rewrite, the reload and Apply observers |
| `NLEngine.m` | Track state, the virtual clock, line lookup, the flip timer, the fetch queue |
| `NLSources.m` | HTTP and the three providers, in the order they are tried |
| `NLLyrics.m` | LRC parsing and serialisation, title cleaning, the Connect split, the cache and manual files |
| `NLSettings.m` | The preference snapshot, the per-app switch, the process checks |
| `NowLyrics.h` | Shared declarations |
| `prefs/` | The settings page: the PreferenceLoader plist and one `Localizable.strings` per language |
| `prefsbundle/NLRootListController.m` | The page's controller: runtime icons (`iconSymbol`/`iconColor`, or `iconApp` for an installed app's icon), the Apply button, the clear-cache action, the version row |
| `prefsbundle/NLOffsetCell.m` | The offset slider-and-field row, and the AltList `dlopen` |
| `prefsbundle/NLEditTextCell.m` | The text rows: Return commits and dismisses the keyboard |
| `docs/` | The vPhone testing runbook |
| `havoc/` | Listing description, changelog, compatibility, clean-install checklist |

Data flows one way: a hook reads what the player published and calls
`NLEngineIngest()`; the engine resolves and times the lyrics and calls
`NLPublish()`, which `NowLyrics.xm` implements for whichever path the process
uses.

## Testing

- Real device: iPhone 14 Pro, iOS 16.5.1, Dopamine. Everything, including the
  settings page and the AltList picker, is verified there.
- vphone-cli VMs on iOS 26.1 and 18.6.2 verify injection and the Spotify path
  on newer iOS; PreferenceLoader never shows the settings page inside the VMs.
  Runbook: `docs/vphone-testing.md`.
- Before a release: `havoc/clean-install-check.md` (purge, reinstall, defaults,
  lyrics without a Musixmatch token).

## Known limitations

- LRCLIB's coverage of Chinese tracks is thin, hence NetEase as a fallback; that
  endpoint is unofficial and may block non-mainland addresses.
- NetEase lyrics are Simplified Chinese; there is no conversion. Musixmatch has
  more native Traditional entries for Mandopop.
- Musixmatch: the token path hits the app's own endpoint
  (`macro.subtitles.get`), unofficial and tied to the account; the API-key path
  uses the documented API, whose timed `matcher.subtitle.get` is usually not in
  the free plan (expect 403). Token first.
- No Spotify track IDs are sent (that would need hooking Spotify's private
  classes), so matching is weaker for obscure or same-titled tracks.
  `NLCleanTitle()` strips `- 2011 Remaster` / `(feat. X)` style suffixes but is
  not perfect. A duration mismatch over 8 s (10 for NetEase) is rejected.
- Preferences are read from the app's own `Library/Preferences/`, then
  `/var/mobile/Library/Preferences/`, then the same under `/var/jb`; with none
  readable the defaults apply. The in-container path is how it is configured
  when injected with TrollFools, where there is no Settings panel.
- Apple Music support rests on private `MPNowPlayingContentItem` API that an
  iOS update can change. Because the item itself is edited, Music's own
  now-playing views show the lyric line too.
- Per line, not per syllable: LRC has no syllable timing.
- Injecting into an App Store app changes its signature, which may sign you out
  or break Spotify Connect. That is a property of injection, not of this code.

## License

© 2026 chxhua2k7. All rights reserved. NowLyrics is sold through Havoc; this
source is not offered under an open-source license.
