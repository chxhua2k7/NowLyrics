# 用 vphone-cli 虛擬 iPhone 測 NowLyrics

2026-09-18 整理。主機：Apple Silicon MacBook Air，macOS 27.2，16 GB RAM。

## 主機環境

- SIP 用 Option B：Recovery 跑 `csrutil enable --without debug` 與 `csrutil allow-research-guests enable`（後者已是 enabled）。
- `brew install zqxwce/tap/vphone-cli`（1.0.14）。依賴中 `ipsw` 沿用 blacktop/tap 版本；`ldid` 與 `ldid-procursus` 衝突，已 `brew unlink ldid`（還原：`brew unlink ldid-procursus && brew link ldid`）。
- 沒有 Xcode.app，只有 Command Line Tools；brew 版 vphone-cli 是預編譯的，不需要 Xcode。
- amfidont 由 pip 裝在 `~/Library/Python/3.9/bin`。**每次重開 Mac 後**：

  ```bash
  export PATH="$HOME/Library/Python/3.9/bin:$PATH"
  vphone-amfidont      # 需要 sudo
  vphone-cli --help    # 不再 zsh: killed 即可
  ```

- 所有產物在 `~/.vphone/`：`VMs/`、`ipsws/`（兩包 IPSW 約 20 GB）、`venv/`。

## 現有 VM

| 名稱 | iOS | 用途 | 備註 |
|---|---|---|---|
| `myphone` | 26.1 (23B85) | 主要測試機 | Spotify 9.1.78、NowLyrics 2.22 已裝，歌詞替換驗證通過 |
| `myphone18` | 18.6.2 (22G100) + cloudOS 26.1 | 舊版 iOS | Spotify、NowLyrics 已裝；ellekit 1.2 完整套件已裝但 TweakLoader 已還原成 vphone 版 |

兩台不能同時開。iPhone 17 沒得裝：機型是 iPhone17,3，出廠即 iOS 18。

```bash
vphone-cli vm launch myphone        # 開機（前景跑，或丟背景）
vphone-cli vm stop myphone
vphone-cli vm info myphone
```

IP 由 NAT 分配（192.168.64.2 起），從 launch log 的 `connected to vphoned v1 (<ip>)` 取得。

## 連線

- SSH：`ssh -p 22222 root@<ip>`，密碼 `alpine`（mobile 也可）。dropbear 偶爾會拒絕一次密碼，重試即可。
- 非登入 shell 的 PATH 只有 `/usr/bin:/bin`，指令前先 `export PATH=/var/jb/usr/bin:/var/jb/bin:$PATH`。
- VM 沒有 sftp-server，scp 不能用，傳檔用管線：

  ```bash
  cat packages/xxx.deb | sshpass -p alpine ssh -p 22222 root@<ip> 'export PATH=/var/jb/usr/bin:$PATH; cat > /tmp/x.deb && dpkg -i --force-depends /tmp/x.deb'
  ```

- VNC：`vnc://<ip>:5901`，右鍵當 Home。
- 主機控制 socket `~/.vphone/VMs/<name>/vphone.sock`，一行 JSON 進一行 JSON 出，座標是 1290×2796 像素：

  ```bash
  printf '{"t":"screenshot","path":"/tmp/x.png"}\n' | nc -U ~/.vphone/VMs/myphone/vphone.sock
  printf '{"t":"tap","x":848,"y":2205}\n' | nc -U ...
  printf '{"t":"swipe","x1":645,"y1":2400,"x2":645,"y2":400,"ms":200}\n' | nc -U ...
  printf '{"t":"key","name":"power"}\n' | nc -U ...     # home/power/volup/voldown
  ```

## 越獄環境的差異（重要）

- jb variant 的 hook 元件在 `/cores/`（`systemhook.dylib`、`libellekit.dylib`、`launchdhook.dylib`），tweak loader 是 vphone 自己的 `/var/jb/usr/lib/TweakLoader.dylib`，它會寫 log 到 `/var/jb/var/mobile/Library/TweakLoader/tweakloader.log`，可以直接看哪個程序載了哪個 dylib。
- VM 預設**沒有** `mobilesubstrate` provider、PreferenceLoader、AltList。Havoc/Chariz 沒有 ellekit 與 AltList，要加：

  ```
  deb https://ellekit.space/ ./
  deb https://opa334.github.io/ ./
  ```

- 不要直接 `apt install ellekit`：它的 preinst 會把 `DynamicLibraries` 換成 `TweakInject` 的 symlink，並把 `TweakLoader.dylib` 換成 ellekit 的 injector，vphone 的注入 log 會消失。最省事的做法只補 shim：

  ```bash
  mkdir -p /var/jb/Library/Frameworks/CydiaSubstrate.framework
  ln -sf /cores/libellekit.dylib /var/jb/usr/lib/libellekit.dylib
  ln -sf /var/jb/usr/lib/libellekit.dylib /var/jb/Library/Frameworks/CydiaSubstrate.framework/CydiaSubstrate
  ln -sf /var/jb/usr/lib/libellekit.dylib /var/jb/usr/lib/libsubstrate.dylib
  apt-get -o APT::Get::AllowUnauthenticated=true download preferenceloader com.opa334.altlist
  dpkg -i --force-depends preferenceloader_*.deb com.opa334.altlist_*.deb <nowlyrics>.deb
  ```

  若真要裝完整 ellekit，先 `touch /var/jb/.installed_dopamine` 讓 postinst 不跑它的 loader，裝完再把 vphone 的 `TweakLoader.dylib` 複製回去。

## 裝 IPA（Spotify）

主機開 HTTP 服務，VM 內用 TrollStore Lite 的 URL scheme：

```bash
# 主機
ln -sf ~/Downloads/com.spotify.client_9.1.78_decrypted.ipa /tmp/ipaserve/spotify.ipa
(cd /tmp/ipaserve && python3 -m http.server 8765 --bind 192.168.64.1 &)
# VM
uiopen "apple-magnifier://install?url=http://192.168.64.1:8765/spotify.ipa"
```

然後用 socket 點 Install（座標約 848,2205）。裝完記得關掉 HTTP 服務。

## 測試結果

- 26.1：NowLyrics 注入 Spotify，鎖定畫面標題換成同步歌詞，演出者列顯示「曲名 — 演出者」，行會隨時間更新，進度條不跳。同一首歌前後行出現繁簡混用，可能是來源中途切換，開 Diagnostics 可確認。
- 18.6.2：注入正常，功能待播歌驗證。
- arm64e slice 在 arm64e 程序（SpringBoard、Preferences、Spotify）裡載入正常，沒有 PAC crash。
- **PreferenceLoader 在兩台 VM 上都掛不出設定頁**：dylib 有載入、`dlopen` 全部成功、沒有 crash，但 Settings 沒有 Tweaks 區段，`prefs:root=NowLyrics` 不導頁。裝完整 ellekit 也一樣。懷疑是 vphone 對 Preferences.app 的 sandbox 沒放行 `/var/jb` 目錄列舉，未證實。設定頁與 AltList app picker 要用真機測。
- 改設定的替代方法：

  ```bash
  plutil -replace diagnostics -bool true /var/jb/var/mobile/Library/Preferences/com.c3x14n.nowlyrics.plist
  notifyutil -p com.c3x14n.nowlyrics/ReloadPrefs
  ```

- 每次 respring 都會有 SBRendererService / AegirPoster / rapportd 的 SIGABRT crash log，是 vphone 本身的雜訊，與 tweak 無關。
- 主機沒有 Xcode，只能用 `~/theos/sdks/iPhoneOS16.5.sdk` 編 arm64；DEBUG 版（有 `NLLog`）的 arm64e slice 需要 Xcode toolchain，在這台 Mac 上做不到。
