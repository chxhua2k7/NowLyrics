# NowLyrics

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

## Building

```bash
git clone <this repo> && cd NowLyrics
make package && sudo make install
```

The Makefile sets `THEOS_PACKAGE_SCHEME = rootless`. Comment it out for a
rootful jailbreak.

`make package` is a debug build that logs every step; for daily use build the
release one, which is silent and half the size:

```bash
make package FINALPACKAGE=1
```

It builds `arm64 arm64e`. The arm64e slice is what makes Apple Music work
(Music.app is an arm64e process) and it has to come from Xcode's toolchain on a
Mac. Building on the device means `make package ARCHS=arm64`, which drops Apple
Music; see "arm64e must come from Xcode" below.

Requires [AltList](https://github.com/opa334/AltList) (`com.opa334.altlist`) at
runtime — it provides the app picker; the settings bundle `dlopen`s it.

The package is `com.c3x14n.nowlyrics`. The control file declares `Conflicts`
and `Replaces` on `com.82flex.amlyrics`: both tweaks rewrite the same Music
item, so installing NowLyrics removes AMLyrics. The preference domain and the reload
notification keep the `app.nowlyrics` name, so settings survive the rename.

Packaging on-device may fail with `exec of gzip -c1 failed`: `dm.pl` hard-codes
gzip for `control.tar` regardless of `-Z`, and the device may not have it
installed. Installing it is enough:

```bash
sudo apt install gzip
```

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
  *Clear lyrics cache* deletes the downloaded lyrics in every app. *Fix Spotify
  Connect titles* (on by default) splits the `Title • Artist` / `Playing on <device>`
  pair Spotify reports while playing on another device back into a real title
  and artist, so lookups and cache names stay clean.
- **About** — the installed version.
- **Apply** (top right) — quits the players that have NowLyrics enabled so they
  relaunch with the current settings. Not normally needed, since everything
  applies live; it is the manual form of *Quit app on change*.

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

## The settings page

`NowLyricsPrefs.bundle` is a real preference bundle, built arm64 + arm64e like
the tweak, and it holds two classes (source in `prefsbundle/`).
`NLRootListController`, the page's controller, is libprefs'
`PLLocalizedListController` plus the two things a plist cannot express: the row
icons, drawn from SF Symbols at runtime, and the action behind *Clear lyrics
cache*. `NLOffsetCell` is the offset row (a slider that applies as you drag,
plus a field the value can be typed into). Everything else on the page is stock
Preferences cells driven by a plist, and the app picker is AltList's. The bundle
`dlopen`s AltList's framework in a constructor, which is what makes
`ATLApplicationListMultiSelectionController` resolve when the plist names it.
Importing `<libprefs/prefs.h>` links libprefs through Theos' module map, and
the rootless rpath finds it in `/var/jb/usr/lib`.

```
/Library/PreferenceBundles/NowLyricsPrefs.bundle/
├── Info.plist                (CFBundleExecutable = NowLyricsPrefs, NSPrincipalClass = NLRootListController)
├── NowLyricsPrefs            (NLRootListController, NLOffsetCell, the AltList dlopen)
└── NowLyrics.png / @2x / @3x (the entry's icon)
```

The entry points at it:

```
bundle = NowLyricsPrefs        → our bundle: the entry icon and the classes come from here
isController = 1               → load the bundle, then instantiate its NSPrincipalClass
pl_alt_plist_name = NowLyrics  → read the items from the plist next to the entry
```

Until 2.13 the bundle had no code of its own: its executable was a symlink to
AltList's binary, so AltList got loaded as a side effect and nothing needed an
arm64e build. With arm64e now coming from Xcode that trick is gone.

The version *About* shows is `PACKAGE_VERSION` from the Makefile, the only
place it is written: the build passes it in as `NL_VERSION` (the User-Agent
carries it too) and fills the bundle's `Info.plist` in at stage time.

The items and their translations live next to the entry, in a folder rather
than in the bundle (source: `prefs/`):

```
/Library/PreferenceLoader/Preferences/NowLyrics/
├── NowLyrics.plist                              (entry + items)
└── en.lproj, zh-Hant.lproj, zh-Hans.lproj, ja.lproj
    └── Localizable.strings                      (labels, footers, option titles, placeholders)
```

PreferenceLoader scans `Preferences/` recursively and treats the folder a plist
sits in as that entry's source bundle. `PLLocalizedListController` looks every
label, footer, option title and placeholder up in that bundle's
`Localizable.strings`, with the English text in the plist as the key; keys
without a translation fall back to English. Row icons are not files: a row
names an SF Symbol and a colour (`iconSymbol`, `iconColor`) and
`NLRootListController` paints the 29 pt tile Settings uses as the specifiers
load. The entry's own icon is the one PNG left, in `NowLyricsPrefs.bundle`.

Two dead ends worth recording, from the symlink era:

- **`bundle = AltList` on the entry** — AltList loads, but `prefBundle` becomes
  AltList.bundle and `icon` is looked up there, so the icon disappears.
- **`bundle = AltList` on the sub-item instead** — the icon comes back but the
  sub-item fails to load. PreferenceLoader only performs its
  `/Library/PreferenceBundles` path search for the top-level entry; sub-items go
  through Preferences.framework, which only knows
  `/System/Library/PreferenceBundles`.

## arm64e must come from Xcode

The on-device Theos/Procursus toolchain produces arm64e slices that fail pointer
authentication when loaded into an arm64e process. libobjc crashes in
`readClass()` with `ESR` EC 0x1C, a PAC failure. Confirmed for both a preference
bundle (crashing Preferences.app) and the tweak itself (crashing SpringBoard).

`-Wl,-no_fixup_chains` does not fix it and makes things worse: dyld signs those
pointers while processing auth-type chained fixups, so removing the chains
guarantees unsigned pointers.

The Mach-O metadata is identical to a working third-party binary — same
`cpusubtype`, same `DYLD_CHAINED_PTR_ARM64E_USERLAND24` pointer format — so the
difference lies in the signing, not the headers. Building on a Mac with Xcode is
the only known fix, and that is how the packaged build is made.

Practical consequences:

- An on-device build (`ARCHS=arm64`) cannot load into Apple Music, which is an
  arm64e process. Use AMLyrics there; its official per-syllable lyrics are
  better anyway.
- With the arm64e slice present the dylib is also loaded into SpringBoard and
  Preferences, since the filter matches a class they have too. `%ctor` returns
  before doing anything there (`NLProcessIsEligible()`), but a slice that fails
  to load at all cannot be caught that way: per-app switches cannot prevent a
  load-time crash, which happens during the dlopen initializer, before `%ctor`.
  Know how to enter your jailbreak's safe mode before installing a new build.

## Only three filter keys exist

ellekit's `injector/injector.c` recognises `Bundles`, `Classes` and
`Executables`. **MobileSubstrate's `Frameworks` is not implemented** — using it
raises no error, it simply matches nothing, so the dylib is never injected
anywhere and nothing indicates why.

```
Filter = { Classes = ( "MPNowPlayingInfoCenter" ); };
```

If `objc_getClass("MPNowPlayingInfoCenter")` resolves, MediaPlayer is loaded.
Apps that link MediaPlayer statically have the class registered by the time the
injector runs. An app that dlopens MediaPlayer later would be missed, but players
that publish now-playing info link it statically.

## Code layout

| File | What it holds |
|---|---|
| `NowLyrics.xm` | The hooks and the two publishers: the dictionary path for third-party players, the content-item path for Music |
| `NLEngine.m` | Track state, the virtual clock, line lookup, the flip timer and the fetch queue |
| `NLSources.m` | HTTP and the three providers, and the order they are tried in |
| `NLLyrics.m` | LRC parsing and serialisation, title cleaning, the cache and manual files |
| `NLSettings.m` | Reading the preference file, the per-app switch, the process checks |
| `NowLyrics.h` | Shared declarations, everything the files need from each other |
| `prefs/` | The settings page: the PreferenceLoader plist and one `Localizable.strings` per language |
| `prefsbundle/NLRootListController.m` | The settings page's controller: row icons drawn from SF Symbols at runtime, the clear-cache action, the version row |
| `prefsbundle/NLOffsetCell.m` | The offset slider-and-field row, and the AltList `dlopen` |

Data flows one way. A hook reads what the player published and calls
`NLEngineIngest()`; the engine resolves and times the lyrics and calls
`NLPublish()`, which the hook file implements for whichever path the process
uses. Settings are an immutable snapshot (`NLSettings`) replaced on every
reload, so a fetch already running keeps a consistent view.

## Notes for editing the code

- **`NowLyrics.xm` is compiled as Objective-C++** (the `.m` files are plain
  Objective-C), so in that file C++ keywords cannot be used as identifiers.
  `explicit`, `class`, `new`, `template`, `using` and `namespace` all fail, and
  the error (`expected unqualified-id`) does not mention why. The shared
  functions in `NowLyrics.h` sit inside an `extern "C"` block for the same
  reason.
- **`%orig` must be alone on its line.** Written as `if (x) { %orig; return; }`,
  logos swallows everything after `%orig` on that line — closing brace included —
  and the braces stop balancing.
- **`%init(GroupName)` must appear after `%group GroupName`.** logos processes
  sequentially. Forward-declare the function and define it after the group.

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

## License

© 2026 chxhua2k7. All rights reserved. NowLyrics is sold through Havoc; this source is not offered under an open-source license.
