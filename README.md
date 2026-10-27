# NowLyrics

<img src="logo/NowLyrics-1024.png" width="96" alt="NowLyrics">

Synced lyrics in place of the track title on the lock screen, Control Center,
the Dynamic Island and CarPlay, for Spotify, Apple Music and any player that
publishes now-playing info, plus an optional strip with the current line under
the compact Dynamic Island. Sources: Apple Music (with a subscription),
Musixmatch, LRCLIB, NetEase.

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
- **Spotify timing** (`NowLyrics.xm`, Spotify only): the engine goes by the
  position heard (`NLHeardPosition`): the app's count less an output delay and
  a lead. Spotify reports what it hands its audio unit, so the delay is
  `AVAudioSession.outputLatency` + 0.04 s on the phone's own outputs and
  Bluetooth (none for AirPlay, CarPlay, USB or Connect), worked out again on
  route changes. Its running count is a clock of its own that gets ahead of the
  sound in two ways, until it next reads its position off the audio (pause,
  resume, seek). A track it plays into the next is announced from 0 about a
  second before it sounds (15 tracks measured: 0.91–1.43 s, median 0.98), so a
  track going back to 0 in its last 3.5 s, and a new title within 1 s of that,
  gets a lead of 0.98 s. A route change stops the output for 0.1–0.85 s while
  the count runs on: a render notification on Spotify's RemoteIO unit (found
  through `AudioOutputUnitStart`) times the stall, which goes into the lead at
  the next report and 1.5 s and 4 s after the change. A lead holds while the
  reports go on with the count and ends with a new track, a rate change or a
  seek.

- **Lyrics Island** (`NowLyricsIsland.x`, SpringBoard only, off by
  default): the now-playing element's compact frame is grown through
  `-[SBSystemApertureSceneElement preferredEdgeOutsetsForLayoutMode:…]` until it
  ends on the top safe-area line, measured from the fixed sensor region. The
  strip goes into the pill's content view with
  `-[SBSystemApertureContainerView addContentSubview:]`, so SpringBoard scales,
  fades and clips it with the artwork and waveform, and is laid out only from
  the pill's `layoutSubviews`, centred under the camera. Text, explicit flag and
  artwork (album color) come from `MRMediaRemoteGetNowPlayingInfo`. Always show
  (`islandAlwaysShow`): SpringBoard puts an element away while its app or scene
  is on screen (`-shouldSuppressElementWhilePresentingAppWithBundleId:` and
  `…SceneWithIdentifier:`, by the element's associated app); the now-playing
  element answers no, and a switch of the setting has
  `-[SBSystemApertureViewController _reevaluateElementSuppression]` ask again at
  once (16.5.1, 18.5 and 26.1 alike).
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
  lyrics). SpringBoard checks again when iTunesCloud says the subscription
  changed, when SpringBoard starts, and when an Apple Music lyrics request
  fails; a lapsed one, or no Apple ID signed in for Media & Purchases, locks
  it again. While Apple Music's privacy notice waits to be agreed to
  (`AMSAcknowledgePrivacyTask`, `com.apple.onboarding.applemusic`), nothing
  past iTunesCloud is asked and no lyrics are fetched: StoreKit would put the
  notice up over whatever is on screen. The settings page sends you to Music
  to agree to it.
- **Word by word**: Apple Music, Musixmatch (`track.richsync.get`, with a token), NetEase
  (`yrc` from `/api/song/lyric/v1`) and imported TTML or word-by-word LRC carry
  word times, stored as enhanced LRC (`<mm:ss.xx>`). The lock screen still shows
  the line; the island finds the lyrics file through the app's `nowplaying.plist`, matches
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
  `com.c3x14n.nowlyrics/LyricsChanged`; the apps drop their memory cache and look again.
  The apps re-read the settings first. Per-song offsets and picked sources live
  in the prefs file as `trackOffsets` and `trackSources` (a pick of `off`, Off
  for This Song, shows that song no lyrics anywhere); the page shows one
  offset (the default one under Advanced plus the song's own). The main page
  and the Now Playing page embed the lock screen's player (MediaControls'
  `+[MRPlatterViewController coverSheetPlatterViewController]`, `NLPlayerHeader`);
  on the main page Advanced › Top of main page (`pageHeader`) swaps it for the
  island preview or nothing, and Advanced › Other pages too (`topOnEveryPage`,
  on by default, `NLPageTop`) gives the other pages the same top (the island
  preview as their table's header), but for Lyrics Island (its own island
  preview), Now Playing (its own player) and the lyrics editor. Outside the
  lock screen the player has no background of its own (its material shows
  nothing there), so it sits on one: glass (`UIGlassEffect`) on iOS 26, a
  system material below; Player over its cover lies over it. Lyrics Sources
  lists the sources in the order they
  are tried (`source` on their plist rows). Musixmatch, like Apple Music, sits
  behind an unlock: the Musixmatch app installed (`musixmatchVerified`); with
  the app gone it stays while a User Token or API key is saved.
- **Control Center's media player** (`NLSystemPlayerSB.x`, in NowLyricsIsland;
  iOS 16 and 26, 17 to 25 left as they are): under its outputs the sources the
  Now Playing page offers, the song's pick ticked with the lyrics' status, Off
  for This Song, and NowLyrics Settings… (iOS 16: the outputs table's footer in
  `MRURoutingView`; iOS 26: under the route picker's collection view, the rows
  measured off the outputs' own). On iOS 16 a size picked there or on the
  settings page (`systemPlayerSize`: 1×4, 2×2, 2×4, 3×4 or the system's) goes
  into the grid (`-[CCUIModuleCollectionViewController
  _sizesForModuleIdentifiers:…]`, with a full-cell first-fit packing once a
  module is wider than two cells), and the closed player's own views are laid
  out for it: 1×4 a row, 2×2 the cover over the song, 2×4 a big cover with the
  song and three lines of lyrics, 3×4 the cover, the lyrics, the time bar and
  the buttons (MediaControls takes a card over 200 pt wide for the open one,
  so its state is held closed). Open, the lyrics are Apple Music's: upright
  under a big cover and the song, on its side between the time bar and the
  buttons, on iOS 26 beside the outputs too; the sung line lit word by word,
  the others dim and blurred, dots in a long pause, a long line moving up as
  it is sung, the song's own title over them and the output's name away. iOS
  26's MediaControls is Swift: its views' fields are read by name
  (`class_getInstanceVariable`); 2×4, 4×4, tall and wide get the lyrics, and
  the small sizes' titles keep their marquee running. Settings › Control
  Center: the size (iOS 16), Lyrics When Closed, Lyrics When Open, Lyrics
  Sources in Outputs (`ccClosedLyrics`, `ccOpenLyrics`, `ccSourcesInOutputs`)
  and Player over its cover (moved there from Advanced). Closed, Control
  Center hides its window but keeps its views in it, and MediaControls lays
  every player out at each now-playing change: NowLyrics' own readings and
  display links stop while the window is hidden and start again as it shows
  (`UIWindowDidBecomeVisibleNotification`).
- **NowLyrics' Control Center modules** (`cc/`, a CCSupport module provider in
  `/Library/ControlCenter/CCSupport_Providers`): "NowLyrics 1×1" to
  "NowLyrics 3×4" among Settings › Control Center's controls, each its own
  size (`-moduleSizeForOrientation:`; from iOS 17 on only the two tiles), as
  many as wanted. Each is a copy of the media player made as the media module
  makes its own (`[MRUControlCenterViewController new]` and its dismissal,
  home-gesture and corner-tap blocks) and handed to the island
  (`NLSPOwnModule`), which lays it out as the media module's at that size. Its
  output buttons show a lyrics glyph (`quote.bubble`) and its outputs' list
  holds the sources alone: the outputs' table stays hidden under them (its
  data source is left alone, as MediaControls applies batch updates to it).
  1×1 (the cover and the app's icon) and 1×2 (the cover, the title and the
  artist scrolling as MediaControls' `MRUMarqueeLabel`, play or pause) are the
  module's own tile over the card, fading out as it opens.
- **Player over its cover** (`NLPlayerTint`, switch `playerTint`): in Control
  Center over `-[MRUControlCenterView materialView]`; on the lock screen over the
  player's `PLPlatterView` material, the player told from Live Activities (same
  ActivityUIServices scene) by its notification-list group
  `com.apple.MediaRemoteUI`. The cover blurred under a scrim sized from its
  brightest tenth, whatever color the lyrics are; between songs the old look
  stays until the new cover is there. Advanced › Transparency (`playerTintClear`,
  default 50 %) thins the cover and the system material under it together
  (`MTMaterialView` `weighting`) so the wallpaper shows through; the thinned
  material first gets a backdrop group of its own (`groupNameBase`), as the
  materials of one group share their filters.
- **Crescendo** (if installed): its switches come from its notify state
  (`com.yves.crescendo.state`); the settings player's dormant volume row is
  forced on (`-[MRUNowPlayingView setShowVolumeControlsView:]`) and the island
  preview gets a `MRUNowPlayingVolumeControlsView` of its own, 40 pt taller.
- **NextUp 3** (if installed): its library is loaded into Settings after
  MediaControls, so the settings player gets its Up Next row as the lock
  screen does. Its iOS 17 island hooks also reach the preview's view on 16.5,
  so the preview takes that view back (`NLNextUpKeepOut`) and places a
  `NUNextUpRowView` of its own, as on the real island.
- **Advanced › Supported Tweaks** (`Tweaks.plist`): a switch each for
  Crescendo (`tweakCrescendo`, below iOS 17, where the system's Always Show
  Volume Control takes over) and NextUp 3 (`tweakNextUp`, iOS 16 and later),
  both on by default, each with the tweak's own icon (its preference bundle's)
  and dimmed when not installed. Off, NextUp's library is not loaded, and one
  already loaded is told it has no next track (`-[NUNextUpManager isActive]`
  in Settings only), so the player's row goes at once.
  On iOS 17 and later the settings player shows the volume row by Always Show
  Volume Control (`-[MRUserSettings alwaysShowVolumeControls]`), as the lock
  screen does; the open island has none either way.
- **Island preview** (island settings page): with music, MediaControls'
  `MRUActivityNowPlayingViewController` (what MediaRemoteUI draws the island
  with): its leading/trailing views as cover and waveform, its open layout when
  opened. Preferences has no island host, so the preview answers
  `-[UIView SBUISA_layoutMode]` and the camera layout guide for views in its
  pill. Waveform levels need an audio tap, so they are made up
  (`NLWaveformDriver`). It stretches when dragged and opens on a long press.
  The open view's `-layoutSubviews` sets the cover's and waveform's frames in
  its own coordinates on every pass, wherever they now live; the preview wraps
  it and puts them back in the same pass. Preview island (`islandPreviewOpen`)
  sets how it comes up: Compact, Expanded, or Auto compact (opens, then closes
  after 5 s left alone).
- **Hide explicit badge** clears `MPMediaItemPropertyIsExplicit` (and Music's
  `explicitItem`) before the system sees it, so no "E" follows the lyric line.
- **Choose Apps** (`NLAppListController`): AltList's app list with a filter at
  the top right (`appListFilter`), music apps by default (the App Store's Music
  genre 6011, Music, Podcasts and the apps already chosen) or all. The filter is
  an AltList section predicate; the subclass is made at runtime, as AltList is
  dlopen'ed rather than linked.

Lyrics are cached per app in `Library/NowLyrics/` (max 300 files; since 1.2.0
with `[ti:]`/`[ar:]`/`[nl-source:]` tags on top, added to older files when they
are next played); added lyrics (pasted or imported in Settings, or dropped in by
hand) in `Library/NowLyrics/manual/Title - Artist.lrc` win over every source.
Each app also writes `Library/NowLyrics/nowplaying.plist`: the real title, the
lyrics file, its source and whether it has word times.

## Build and release

```bash
make package FINALPACKAGE=1   # release; plain `make package` = debug with NSLog
make package FINALPACKAGE=1 THEOS=~/theos-roothide THEOS_PACKAGE_SCHEME=roothide   # roothide, iphoneos-arm64e
```

- Theos + Xcode on a Mac, rootless, `ARCHS = arm64 arm64e`. The arm64e slice
  makes Apple Music work and only Xcode's toolchain produces one that passes
  pointer authentication.
- roothide needs roothide's Theos; its packages link libroothide and find
  jailbreak files through `jbroot()` (`NLJBPath()` in `NLShared.h`). Each scheme
  builds in its own `.theos/obj/<scheme>`, so the two never mix. Not yet run on
  a roothide jailbreak.
- Version lives only in the Makefile's `PACKAGE_VERSION` (package, `NL_VERSION`
  define, `bundle/Info.plist` filled at stage time).
- Runtime deps: PreferenceLoader, AltList; CCSupport for NowLyrics' Control
  Center modules (not a dependency: without it the provider is simply not
  loaded). Install with `sudo dpkg -i`, then
  respring once (Apply on the settings page) so SpringBoard loads
  NowLyricsIsland; the lyrics themselves only need the player relaunched.
- iOS 18 and later rewrote Settings in Swift: PreferenceLoader 2.2.6 shows no
  tweak pages there. With dhinakg's 2.2.8 (https://dhinakg.github.io/repo/)
  NowLyrics is at the bottom of Settings › General.

## Layout

| | |
|---|---|
| `NowLyrics.xm` | hooks, both publishers, Connect rewrite, explicit flag, notification observers |
| `NowLyricsIsland.x` | SpringBoard: lyrics strip under the compact Dynamic Island |
| `NLEngine.m` / `NLSources.m` / `NLLyrics.m` / `NLSettings.m` | engine, providers, LRC (word times, yrc) + cache, settings snapshot |
| `NLIslandStrip.m` / `NLLocate.m` | the island's line strip (word mask); app containers and `nowplaying.plist` (Settings and the island) |
| `prefsbundle/NLNowPlayingController.m`, `NLLibraryController.m`, `NLLyricsEditor.m`, `NLLyricsImport.m` | Now Playing, the library (by app), the editor, paste/import and TTML |
| `NLSystemPlayerSB.x` | SpringBoard: Control Center's media player (iOS 16, 26) and NowLyrics' modules' copies of it: sources under the outputs, sizes, lyrics |
| `NLLyricsSources.m` | the sources offered and picked, the lyrics' status: the Now Playing page and Control Center |
| `cc/` | Control Center modules: the provider and the module (`NLCCModule.m`), the 1×1 and 1×2 tile (`NLCCViews.m`) |
| `prefs/`, `prefsbundle/`, `bundle/Island.plist` | settings page: plist + 4 languages; controller (runtime icons, Apply, version, island page), slider rows, text rows |
| `docs/`, `havoc/` | vPhone runbook; listing text, changelog, clean-install checklist |

## Testing

iPhone 14 Pro / iOS 16.5.1 for everything; vphone-cli VMs (iOS 26.1, 18.6.2)
for the Spotify path, the island, the lock screen and Control Center, and,
with PreferenceLoader 2.2.8, the settings page (no Apple Music there, and no
Settings page with the old 2.2.6). The island strip is verified on the 14 Pro
(16.5.1) and in the 18.6.2 and 26.1 VMs; its animation work was checked frame
by frame on screen recordings. On iOS 17+ it hangs in the element's own view:
there the container's content views assert a single subview, so
`addContentSubview:` would replace the element. iOS 17+ also resizes the
island by laying that view out step by step (26 springs past its size and
widens it again a moment later), so the line waits until the view has stopped
moving on screen before it fades in. Private API used on 18.5 and 26.1 was
checked symbol by symbol against those builds. Control Center was checked on
the 14 Pro (16.5.1, CCSupport 1.3.13) and, for iOS 26, in the ios26 and
ipados26 VMs (26.6.2).

## Limitations

The lock screen shows the line; only the island goes word by word, and only
with lyrics that have word times. NetEase is Simplified Chinese. Musixmatch needs the
app's token (unofficial) or an API key whose timed endpoint is usually paid.
Matching is by strings; Apple Music relies on private API. Lyrics Island
needs the Dynamic Island as SpringBoard has it: SpringBoardServices'
`SBSIsSystemApertureAvailable` asked in SpringBoard once it has launched and
published as the notify state `com.c3x14n.nowlyrics.island`, so a device given the
island by other means (a MobileGestalt edit, a tweak in SpringBoard; an iPad
too) counts, and the settings page says so on others. It rests on
SpringBoard internals checked on 16.5.1, 18.6.2 and 26.1 (and iPadOS 26.6.2
with the island turned on); other versions may need adjusting. iPadOS 26's
Settings floats its sidebar over the page, so the player and the island
preview go by the table's margins and safe area, not its width. Player over its cover: lock screen and Control Center on 16
and 18; on 26 the lock screen's player is glass, which shows what is behind it
over the tint, and Control Center's media module already takes the cover's
colors, so it stays as the system draws it; there the setting is hidden and
the settings page's player keeps the system look too, like the lock screen's.
Spotify timing rests on measurements on 16.5.1: a track that takes longer than
usual to sound after it is announced (up to 1.43 s seen) has its lyrics up to
0.45 s early, and skipping or going back to the start in a song's last 3.5 s
makes the lyrics that follow about 1 s late, both until the next pause;
crossfade and Automix are not accounted for, nor is a Spotify Connect device's
delay. Control Center's media player is laid out on iOS 16 and 26 only;
NowLyrics' own modules need CCSupport and hold iOS 16's player. Each module
is a whole MediaControls player, which MediaControls updates at every
now-playing change (every lyric line) even while Control Center is closed, so
many modules cost more.

## License

© 2026 chxhua2k7. All rights reserved. Not open source.
