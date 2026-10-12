# 乾淨重裝驗證(上架前)

目的:模擬第一次購買的人,從零安裝、用預設設定、不填 Musixmatch token。
在 iPhone 上執行的 `sudo` 指令由你在自己的終端機跑;其餘檢查我從 Mac 用 `ssh iPhone14Pro` 做。

## 0. 備份現在的設定(裡面有 Musixmatch token)

```bash
cp /var/jb/var/mobile/Library/Preferences/com.c3x14n.nowlyrics.plist /var/mobile/com.c3x14n.nowlyrics.backup.plist
```

## 1. 移除

```bash
sudo dpkg --purge com.c3x14n.nowlyrics
```

```bash
rm -f /var/jb/var/mobile/Library/Preferences/com.c3x14n.nowlyrics.plist
```

之後我檢查:
- `dpkg -s com.c3x14n.nowlyrics` 回報 not installed
- `/var/jb/Library/MobileSubstrate/DynamicLibraries/NowLyrics.*`、`/var/jb/Library/PreferenceBundles/NowLyricsPrefs.bundle`、`/var/jb/Library/PreferenceLoader/Preferences/NowLyrics/` 都不存在
- Spotify 的 `Library/NowLyrics/` 快取還在(套件移除不該碰使用者資料;要模擬全新使用者可以順便刪掉)

## 2. 安裝

```bash
sudo dpkg -i /var/mobile/com.c3x14n.nowlyrics_1.0.0_release.deb
```

```bash
killall Preferences
```

之後我檢查:
- `dpkg -L com.c3x14n.nowlyrics` 列出的檔案都在、權限正常
- 設定檔不存在(等於全部用預設值)

## 3. 預設值行為(你操作,我看檔案)

1. 設定 → NowLyrics:應該看到「啟用」開、「選擇 App」預設八個播放器、Musixmatch 關、LRCLIB 與網易雲開、偏移 0、版本 1.0.0、新 logo。
2. 用 Spotify 播一首歌,鎖定畫面曲名應該在幾秒內換成歌詞(不填 token,只靠 LRCLIB / 網易雲)。
3. 用 Music 播一首歌,同樣檢查。
4. 開「診斷」,演出者欄位後面應該出現來源名稱。
5. 關掉「啟用」,鎖定畫面曲名應立刻恢復原樣;再打開。

## 4. 還原你的設定

```bash
cp /var/mobile/com.c3x14n.nowlyrics.backup.plist /var/jb/var/mobile/Library/Preferences/com.c3x14n.nowlyrics.plist
```

```bash
killall Spotify Music
```

設定頁重新打開會看到 token 和 App 清單回來。
