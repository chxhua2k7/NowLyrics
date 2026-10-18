# 版本號只寫在這裡:也是 tweak 和設定 bundle 的 NL_VERSION(User-Agent、「關於」的版本列),
# bundle/Info.plist 的 __VERSION__ 則在 stage 時填入。control 不寫 Version,Theos 打包時寫入這個值。
export PACKAGE_VERSION := 1.2.3

TARGET := iphone:clang:16.5:15.0

# rootless by default; `make package THEOS_PACKAGE_SCHEME=roothide THEOS=~/theos-roothide`
# for roothide (roothide's Theos: jbroot(), libroothide, iphoneos-arm64e).
THEOS_PACKAGE_SCHEME ?= rootless

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

# Each scheme builds in its own folder (.theos/obj/rootless, .theos/obj/roothide).
# With one shared folder, a build of the other scheme reused the last one's
# products: the rootless settings bundle shipped linked to libroothide.
THEOS_OBJ_DIR_NAME = obj/$(THEOS_PACKAGE_SCHEME)$(_THEOS_OBJ_DIR_EXTENSION)

include $(THEOS)/makefiles/common.mk

# 三個 binary 共用:ARC、NL_VERSION(只有 tweak 和設定 bundle 讀它)、符號隱藏並剝掉用不到的程式碼
# (沒有東西靠符號名跨 binary 找:類別走 ObjC runtime,建構子照樣執行)。
ADDITIONAL_CFLAGS += -fobjc-arc -fvisibility=hidden -DNL_VERSION=\"$(PACKAGE_VERSION)\"
ADDITIONAL_LDFLAGS += -Wl,-dead_strip

TWEAK_NAME += NowLyrics

NowLyrics_FILES += NowLyrics.xm NLSettings.m NLLyrics.m NLTTML.m NLSources.m NLEngine.m NLAppleMusicRemote.m
NowLyrics_FRAMEWORKS += MediaPlayer QuartzCore AVFoundation AudioToolbox

# SpringBoard only: the current lyric line under the compact Dynamic Island.
# Separate so nothing else of the tweak runs there.
TWEAK_NAME += NowLyricsIsland

NowLyricsIsland_FILES += NowLyricsIsland.x NLIslandStrip.m NLLyrics.m NLLocate.m NLPlayerTint.m NLPlayerTintSB.x NLAppleMusicSB.x NLAppleMusicFind.m NLHistorySB.x NLHistory.m
NowLyricsIsland_FRAMEWORKS += UIKit ImageIO QuartzCore CoreImage

include $(THEOS_MAKE_PATH)/tweak.mk

# 設定頁:prefs/ 裡是 NowLyrics.plist(entry + items)和各語言的 <lang>.lproj/Localizable.strings;
# 子頁面(歌詞上島 Island.plist、歌詞來源 Sources.plist、進階 Advanced.plist、Apple Music AppleMusic.plist、
# Musixmatch Musixmatch.plist、支援的插件 Tweaks.plist)是 bundle/ 裡 Info.plist 以外的每個 .plist
# (下面的 NL_PAGES 照這樣找出它們;bundle/ 不在 PreferenceLoader 掃描的資料夾裡),
# 各自的 <名稱>.strings 在 stage 時從同一份 Localizable.strings 複製進 bundle;
# PreferenceLoader 會遞迴掃描 Preferences/ 底下所有 .plist,plist 所在的資料夾就是它的
# 來源 bundle,PLLocalizedListController 從那裡讀 .strings。
#
# NowLyricsPrefs.bundle 是真的 preference bundle(和 tweak 一樣編 arm64 + arm64e)。
# 主類別 NLRootListController 繼承 libprefs 的 PLLocalizedListController:每一列的
# iconSymbol / iconColor 在執行期畫成 SF Symbol 圖示(不再打包 PNG)。
# NLOffsetCell 是偏移那一列的「拉桿 + 可輸入數值」。AltList 由 NLAppListController.m 的建構子 dlopen。
# 「正在播放」「歌詞庫」和編輯器(NLNowPlayingController / NLLibraryController / NLLyricsEditor)
# 直接讀寫各 App 容器裡的歌詞檔(Preferences 沒有沙盒,NLLocate.m),所以 NLLyrics.m 也編進來。
# libprefs 由 <libprefs/prefs.h> 的 module map 自動連結(@rpath,Theos 的 rootless rpath 指到 /var/jb/usr/lib)。
BUNDLE_NAME += NowLyricsPrefs

# prefsbundle/ 裡每個 .m 都編進來(別在那裡放草稿)。
NowLyricsPrefs_FILES += $(sort $(wildcard prefsbundle/*.m)) NLIslandStrip.m NLLyrics.m NLTTML.m NLLocate.m NLPlayerTint.m NLHistory.m NLAppleMusicFind.m
NowLyricsPrefs_FRAMEWORKS += UIKit ImageIO QuartzCore UniformTypeIdentifiers CoreImage
NowLyricsPrefs_PRIVATE_FRAMEWORKS += Preferences
NowLyricsPrefs_INSTALL_PATH = /Library/PreferenceBundles
NowLyricsPrefs_RESOURCE_DIRS = bundle

include $(THEOS_MAKE_PATH)/bundle.mk

NL_PAGES = $(filter-out Info,$(basename $(notdir $(wildcard bundle/*.plist))))
NL_BUNDLE_STAGE = $(THEOS_STAGING_DIR)/Library/PreferenceBundles/NowLyricsPrefs.bundle

internal-stage::
	$(ECHO_NOTHING)mkdir -p "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/NowLyrics"$(ECHO_END)
	$(ECHO_NOTHING)cp -R prefs/. "$(THEOS_STAGING_DIR)/Library/PreferenceLoader/Preferences/NowLyrics/"$(ECHO_END)
	$(ECHO_NOTHING)sed "s/__VERSION__/$(PACKAGE_VERSION)/g" bundle/Info.plist > "$(NL_BUNDLE_STAGE)/Info.plist"$(ECHO_END)
	$(ECHO_NOTHING)for lproj in prefs/*.lproj; do \
		dir="$(NL_BUNDLE_STAGE)/$$(basename $$lproj)"; \
		mkdir -p "$$dir"; \
		for page in $(NL_PAGES); do \
			cp "$$lproj/Localizable.strings" "$$dir/$$page.strings"; \
		done; \
	done$(ECHO_END)

# Finder's .DS_Store files (prefs/ has one) are not the package's: 1.2.2
# shipped /Library/PreferenceLoader/Preferences/NowLyrics/.DS_Store.
before-package::
	$(ECHO_NOTHING)find "$(THEOS_STAGING_DIR)" -name .DS_Store -delete$(ECHO_END)

# roothide: the package's own paths are jbroot-based (its dpkg and Sileo
# resolve them in the jailbreak's root), so the icon loses /var/jb. The
# backup suffix is attached, the one -i form BSD and GNU sed both read.
ifeq ($(THEOS_PACKAGE_SCHEME),roothide)
ADDITIONAL_LDFLAGS += -lroothide
before-package:: $(THEOS_STAGING_DIR)/DEBIAN/control
	$(ECHO_NOTHING)sed -i.bak 's#file:///var/jb/#file:///#' "$(THEOS_STAGING_DIR)/DEBIAN/control" && rm -f "$(THEOS_STAGING_DIR)/DEBIAN/control.bak"$(ECHO_END)
endif
