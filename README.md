# NowLyrics

<img src="logo/NowLyrics-1024.png" width="96" alt="NowLyrics">

Synced lyrics in place of the track title on the lock screen, Control Center,
the Dynamic Island and CarPlay, for Spotify, Apple Music and any player that
publishes now-playing info, plus an optional strip with the current line under
the compact Dynamic Island. Sources: Musixmatch, LRCLIB, NetEase.

Private source repo. Public page: [chxhua2k7/NowLyrics](https://github.com/chxhua2k7/NowLyrics).
Sold on Havoc as `com.c3x14n.nowlyrics`; listing material in `havoc/`.

繁體中文:[README.zh-Hant.md](README.zh-Hant.md)

## How it works

- **Third-party players** call `-[MPNowPlayingInfoCenter setNowPlayingInfo:]`.
  The hook lets it through, reads title/artist/duration/elapsed/rate, and at
  every line boundary pushes a copy of the dictionary with the title replaced
  and the elapsed time re-anchored. Spotify Connect's `Title • Artist` /
  `Playing on X` pair is rewritten before the system sees it.
- **Apple Music** never calls that; its `MPNowPlayingContentItem` setters are
  hooked instead and the line is written into the item itself (like AMLyrics,
  which is why the package conflicts with `com.82flex.amlyrics`).
- **Engine**: track = title + artist; resolve manual `.lrc` → disk cache →
  sources in the user's order (`sourceOrder`); position extrapolated from the last anchor;
  `dispatch_after` per line. Blank lines count as gaps only if the next line is
  ≥ 5 s away.

- **Lyrics in the island** (`NowLyricsIsland.x`, SpringBoard only, off by
  default): the now-playing element's compact frame is grown through
  `-[SBSystemApertureSceneElement preferredEdgeOutsetsForLayoutMode:…]` until it
  ends on the top safe-area line, measured from the fixed sensor region. The
  strip goes into the pill's content view with
  `-[SBSystemApertureContainerView addContentSubview:]`, so SpringBoard scales,
  fades and clips it with the artwork and waveform, and is laid out only from
  the pill's `layoutSubviews`, centred under the camera. Text, explicit flag and
  artwork (album color) come from `MRMediaRemoteGetNowPlayingInfo`.
- **Apple Music lyrics** (behind a switch): by the song's adam ID through
  `MPStoreLyricsMusicKitRequestOperation`, the same TTML Music's lyrics view
  gets (storefront text, word timing). In Music the ID is the content item's
  `lyricsAdamID`/`storeID`. Other apps (Spotify) have neither the ID nor Apple
  Music access, so SpringBoard does it (`NLAppleMusicSB.x`): the app writes
  `am-request.plist` in its Library/NowLyrics and posts a Darwin notification;
  SpringBoard finds the song with Apple's public search by title, artist and
  length (`NLAppleMusicFind.m`), asks for the lyrics and writes
  `am-response.plist` back. Everything Apple Music stays hidden until
  "Unlock" confirms a subscription (SpringBoard asks iTunesCloud's
  `ICMusicSubscriptionStatusController`, then StoreKit, then tries one song's
  lyrics); it is checked again daily, and a lapsed one locks it again.
- **Word by word**: Apple Music, Musixmatch (`track.richsync.get`, with a token), NetEase
  (`yrc` from `/api/song/lyric/v1`) and imported TTML carry word times, stored
  as enhanced LRC (`<mm:ss.xx>`). The lock screen still shows the line; the
  island finds the lyrics file through the app's `nowplaying.plist`, matches
  the line by MediaRemote's position the way the app does, and moves a soft
  mask along the word times (long lines glide with the singing).
  Musixmatch has one richsync per track, timed to one cut, which need not be
  the cut playing: the subtitle is asked for by the song's length
  (`q_duration`), and the richsync is dropped for it when its
  `richsync_length` is more than 3 s off, when its lines drift from the
  subtitle's, or when it runs faster than anyone sings (any source). The
  position MediaRemote reports is the app's own: `MPNowPlayingInfoCenter` holds
  a third-party app's update back 0.5 s when it comes within 0.5 s of the last
  one (`_pushDate`), so each lyric push clears that first, on the center's queue.
- **Lyrics management** (Settings: Now Playing, Lyrics Library): Preferences is
  not sandboxed, so it reads and writes the lyrics files in each app's container
  (`NLLocate.m` maps bundle IDs from the container metadata plists), then posts
  `app.nowlyrics/LyricsChanged`; the apps drop their memory cache and look again.
  The apps re-read the settings first. Per-song offsets and picked sources live
  in the prefs file as `trackOffsets` and `trackSources`; the page shows one
  offset (the default one under Advanced plus the song's own). The main page
  and the Now Playing page embed the lock screen's player (MediaControls'
  `+[MRPlatterViewController coverSheetPlatterViewController]`, `NLPlayerHeader`).
- **Player in lyrics color** (`NLPlayerTint`, switch `playerTint`): in Control
  Center over `-[MRUControlCenterView materialView]`; on the lock screen over the
  player's `PLPlatterView` material, the player told from Live Activities (same
  ActivityUIServices scene) by its notification-list group
  `com.apple.MediaRemoteUI`. The album color the lyrics use, or the cover
  blurred under a scrim sized from its brightest tenth; between songs the old
  look stays until the new cover is there.
- **Crescendo** (if installed): its switches come from its notify state
  (`com.yves.crescendo.state`); the settings player's dormant volume row is
  forced on (`-[MRUNowPlayingView setShowVolumeControlsView:]`) and the island
  preview gets a `MRUNowPlayingVolumeControlsView` of its own, 40 pt taller.
- **NextUp 3** (if installed): its library is loaded into Settings after
  MediaControls, so the settings player gets its Up Next row as the lock
  screen does. Its iOS 17 island hooks also reach the preview's view on 16.5,
  so the preview takes that view back (`NLNextUpKeepOut`) and places a
  `NUNextUpRowView` of its own, as on the real island.
- **Island preview** (island settings page): with music, MediaControls'
  `MRUActivityNowPlayingViewController` (what MediaRemoteUI draws the island
  with): its leading/trailing views as cover and waveform, its open layout when
  opened. Preferences has no island host, so the preview answers
  `-[UIView SBUISA_layoutMode]` and the camera layout guide for views in its
  pill. Waveform levels need an audio tap, so they are made up
  (`NLWaveformDriver`). It stretches when dragged and opens on a long press.
  The open view's `-layoutSubviews` sets the cover's and waveform's frames in
  its own coordinates on every pass, wherever they now live; the preview wraps
  it and puts them back in the same pass.
- **Hide explicit badge** clears `MPMediaItemPropertyIsExplicit` (and Music's
  `explicitItem`) before the system sees it, so no "E" follows the lyric line.

Lyrics are cached per app in `Library/NowLyrics/` (max 300 files; since 1.2.0
with `[ti:]`/`[ar:]`/`[nl-source:]` tags on top, added to older files when they
are next played); added lyrics (pasted or imported in Settings, or dropped in by
hand) in `Library/NowLyrics/manual/Title - Artist.lrc` win over every source.
Each app also writes `Library/NowLyrics/nowplaying.plist`: the real title, the
lyrics file, its source and whether it has word times.

## Build and release

```bash
make package FINALPACKAGE=1   # release; plain `make package` = debug with NSLog
```

- Theos + Xcode on a Mac, rootless, `ARCHS = arm64 arm64e`. The arm64e slice
  makes Apple Music work and only Xcode's toolchain produces one that passes
  pointer authentication.
- Version lives only in the Makefile's `PACKAGE_VERSION` (package, `NL_VERSION`
  define, `bundle/Info.plist` filled at stage time).
- Runtime deps: PreferenceLoader, AltList. Install with `sudo dpkg -i`, then
  respring once (Apply on the settings page) so SpringBoard loads
  NowLyricsIsland; the lyrics themselves only need the player relaunched.

## Layout

| | |
|---|---|
| `NowLyrics.xm` | hooks, both publishers, Connect rewrite, explicit flag, notification observers |
| `NowLyricsIsland.x` | SpringBoard: lyrics strip under the compact Dynamic Island |
| `NLEngine.m` / `NLSources.m` / `NLLyrics.m` / `NLSettings.m` | engine, providers, LRC (word times, yrc) + cache, settings snapshot |
| `NLIslandStrip.m` / `NLLocate.m` | the island's line strip (word mask); app containers and `nowplaying.plist` (Settings and the island) |
| `prefsbundle/NLNowPlayingController.m`, `NLLibraryController.m`, `NLLyricsEditor.m`, `NLLyricsImport.m` | Now Playing, the library (by app), the editor, paste/import and TTML |
| `prefs/`, `prefsbundle/`, `bundle/Island.plist` | settings page: plist + 4 languages; controller (runtime icons, Apply, version, island page), slider rows, text rows |
| `docs/`, `havoc/` | vPhone runbook; listing text, changelog, clean-install checklist |

## Testing

iPhone 14 Pro / iOS 16.5.1 for everything; vphone-cli VMs (iOS 26.1, 18.6.2)
for injection and the Spotify path only (their Settings never shows the page).
The island strip is verified on the 14 Pro (16.5.1) and in the 18.6.2 and 26.1
VMs; its animation work was checked frame by frame on screen recordings. On
iOS 17+ it hangs in the element's own view: there the container's content views
assert a single subview, so `addContentSubview:` would replace the element.

## Limitations

Per line, not per syllable. NetEase is Simplified Chinese. Musixmatch needs the
app's token (unofficial) or an API key whose timed endpoint is usually paid.
Matching is by strings; Apple Music relies on private API. Lyrics in the island
needs a Dynamic Island iPhone and rests on SpringBoard internals checked on
16.5.1, 18.6.2 and 26.1; other versions may need adjusting.

## License

© 2026 chxhua2k7. All rights reserved. Not open source.
