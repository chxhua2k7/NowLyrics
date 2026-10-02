# NowLyrics

<img src="logo/NowLyrics-1024.png" width="96" alt="NowLyrics">

Synced lyrics in place of the track title on the lock screen, Control Center,
the Dynamic Island and CarPlay, for Spotify, Apple Music and any player that
publishes now-playing info. Sources: Musixmatch, LRCLIB, NetEase.

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
  sources in preferred order; position extrapolated from the last anchor;
  `dispatch_after` per line. Blank lines count as gaps only if the next line is
  ≥ 5 s away.

Lyrics are cached per app in `Library/NowLyrics/` (max 300 files); a hand-made
`Library/NowLyrics/manual/Title - Artist.lrc` wins over every source.

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
| `NowLyrics.xm` | hooks, both publishers, Connect rewrite, notification observers |
| `NLEngine.m` / `NLSources.m` / `NLLyrics.m` / `NLSettings.m` | engine, providers, LRC + cache, settings snapshot |
| `prefs/`, `prefsbundle/` | settings page: plist + 4 languages; controller (runtime icons, Apply, version), offset row, text rows |
| `docs/`, `havoc/` | vPhone runbook; listing text, changelog, clean-install checklist |

## Testing

iPhone 14 Pro / iOS 16.5.1 for everything; vphone-cli VMs (iOS 26.1, 18.6.2)
for injection and the Spotify path only (their Settings never shows the page).

## Limitations

Per line, not per syllable. NetEase is Simplified Chinese. Musixmatch needs the
app's token (unofficial) or an API key whose timed endpoint is usually paid.
Matching is by strings; Apple Music relies on private API.

## License

© 2026 chxhua2k7. All rights reserved. Not open source.
