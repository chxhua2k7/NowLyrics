# 版本號只寫在這裡:也是 tweak 和設定 bundle 的 NL_VERSION(User-Agent、「關於」的版本列),
# bundle/Info.plist 的 __VERSION__ 則在 stage 時填入。control 的 Version 由 Theos 用這個值覆蓋。
export PACKAGE_VERSION := 1.2.0

TARGET := iphone:clang:16.5:15.0

THEOS_PACKAGE_SCHEME = rootless

# arm64 + arm64e.
#
# The arm64e slice is what makes Apple Music work: Music.app is an arm64e
# process and dyld will not load an arm64-only dylib into it. That slice has to
# come from Xcode's toolchain. arm64e slices produced by the on-device
# Theos/Procursus toolchain fail pointer authentication when loaded into an
# arm64e process: libobjc crashes in readClass() with ESR EC 0x1C (PAC failure),
# confirmed for both a preference bundle (Preferences.app) and the tweak itself
# (SpringBoard). -Wl,-no_fixup_chains does not help and actually makes it worse,
# since dyld signs those pointers while processing auth-type chained fixups.
# The Mach-O headers are identical to a working third-party binary — same
# cpusubtype, same DYLD_CHAINED_PTR_ARM64E_USERLAND24 pointer format — so the
# difference is in the signing itself, not the metadata.
#
# Building on the device therefore means `make package ARCHS=arm64`, which also
# means no Apple Music. With the arm64e slice present the dylib does get loaded
# into SpringBoard (the filter matches a class it has too); %ctor bails out
# there before doing anything, see NLProcessIsEligible().
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME += NowLyrics

NowLyrics_FILES += NowLyrics.xm NLSettings.m NLLyrics.m NLTTML.m NLSources.m NLEngine.m NLAppleMusicRemote.m
NowLyrics_CFLAGS += -fobjc-arc -Wall -DNL_VERSION=\"$(PACKAGE_VERSION)\"
NowLyrics_FRAMEWORKS += MediaPlayer QuartzCore

# SpringBoard only: the current lyric line under the compact Dynamic Island.
# Separate so nothing else of the tweak runs there.
TWEAK_NAME += NowLyricsIsland

NowLyricsIsland_FILES += NowLyricsIsland.x NLIslandStrip.m NLLyrics.m NLLocate.m NLPlayerTint.m NLPlayerTintSB.x NLAppleMusicSB.x NLAppleMusicFind.m
NowLyricsIsland_CFLAGS += -fobjc-arc -Wall
NowLyricsIsland_FRAMEWORKS += UIKit ImageIO QuartzCore CoreImage

include $(THEOS_MAKE_PATH)/tweak.mk

# 設定頁:prefs/ 裡是 NowLyrics.plist(entry + items)和各語言的 <lang>.lproj/Localizable.strings;
# 子頁面(歌詞上島 Island.plist、歌詞來源 Sources.plist、進階 Advanced.plist、Apple Music AppleMusic.plist)
# 放在 bundle/(不在 PreferenceLoader 掃描的資料夾裡),各自的 <名稱>.strings 在 stage 時
# 從同一份 Localizable.strings 複製進 bundle;
# PreferenceLoader 會遞迴掃描 Preferences/ 底下所有 .plist,plist 所在的資料夾就是它的
# 來源 bundle,PLLocalizedListController 從那裡讀 .strings。
#
# NowLyricsPrefs.bundle 是真的 preference bundle(和 tweak 一樣編 arm64 + arm64e)。
# 主類別 NLRootListController 繼承 libprefs 的 PLLocalizedListController:每一列的
# iconSymbol / iconColor 在執行期畫成 SF Symbol 圖示(不再打包 PNG),「清除歌詞快取」的
# 動作也在這裡。NLOffsetCell 是偏移那一列的「拉桿 + 可輸入數值」。AltList 由建構子 dlopen。
# 「正在播放」「歌詞庫」和編輯器(NLNowPlayingController / NLLibraryController / NLLyricsEditor)
# 直接讀寫各 App 容器裡的歌詞檔(Preferences 沒有沙盒,NLLocate.m),所以 NLLyrics.m 也編進來。
# libprefs 由 <libprefs/prefs.h> 的 module map 自動連結(@rpath,Theos 的 rootless rpath 指到 /var/jb/usr/lib)。
BUNDLE_NAME += NowLyricsPrefs

NowLyricsPrefs_FILES += prefsbundle/NLOffsetCell.m prefsbundle/NLRootListController.m prefsbundle/NLEditTextCell.m \
                         prefsbundle/NLIslandPreviewCell.m prefsbundle/NLPreviewLines.m NLIslandStrip.m \
                         prefsbundle/NLNowPlayingController.m prefsbundle/NLLibraryController.m \
                         prefsbundle/NLLyricsEditor.m prefsbundle/NLLyricsImport.m prefsbundle/NLWaveformView.m prefsbundle/NLPlayerHeader.m prefsbundle/NLCrescendo.m prefsbundle/NLSourceOrderController.m prefsbundle/NLAppleMusicController.m \
                         prefsbundle/NLAppleMusicAccess.m prefsbundle/NLPopUpCell.m prefsbundle/NLNextUp.m \
                         NLLyrics.m NLTTML.m NLLocate.m NLPlayerTint.m
NowLyricsPrefs_CFLAGS += -fobjc-arc -Wall -DNL_VERSION=\"$(PACKAGE_VERSION)\"
NowLyricsPrefs_FRAMEWORKS += UIKit ImageIO QuartzCore UniformTypeIdentifiers CoreImage
NowLyricsPrefs_PRIVATE_FRAMEWORKS += Preferences
NowLyricsPrefs_INSTALL_PATH = /Library/PreferenceBundles
NowLyricsPrefs_RESOURCE_DIRS = bundle

include $(THEOS_MAKE_PATH)/bundle.mk

internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/NowLyrics"$(ECHO_END)
	$(ECHO_NOTHING)cp -R prefs/ "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/NowLyrics/"$(ECHO_END)
	$(ECHO_NOTHING)sed "s/__VERSION__/$(PACKAGE_VERSION)/g" bundle/Info.plist > "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/NowLyricsPrefs.bundle/Info.plist"$(ECHO_END)
	$(ECHO_NOTHING)for lproj in prefs/*.lproj; do \
		mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/NowLyricsPrefs.bundle/$$(basename $$lproj)"; \
		for page in Island Sources Advanced AppleMusic; do \
			cp "$$lproj/Localizable.strings" "$(THEOS_STAGING_DIR)/Library/PreferenceBundles/NowLyricsPrefs.bundle/$$(basename $$lproj)/$$page.strings"; \
		done; \
	done$(ECHO_END)
