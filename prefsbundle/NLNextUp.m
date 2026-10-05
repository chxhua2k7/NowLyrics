//
//  NLNextUp.m
//  NextUp 3 (com.yves.nextup3, GPL-3.0) adds an "Up Next" row to the lock
//  screen's player and the open island. It is injected into the players'
//  display side, not into Settings, so the copies on these pages would lack
//  it. With NextUp installed, its library is loaded here as well (after
//  MediaControls, whose classes it hooks): it counts any process that is not
//  a media app as a display side, and our player is a cover sheet one, which
//  it treats as the lock screen's. The island preview (not the class it hooks
//  on iOS 16) gets its row from NLIslandPreviewCell, with NextUp's own view.
//
//  NextUp's switches are read as it reads them: its notify-state token
//  ("com.yves.nextup3.state") when Settings has published one, else its
//  preferences.
//

#import "NLLyricsPages.h"
#import <dlfcn.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <notify.h>

#define kNLNextUpDylib NLJBPath(@"/Library/MobileSubstrate/DynamicLibraries/NextUp3.dylib")

// NextUp's NUPrefs.h: bit 63 = published; value bit n, and bit n + 32 when the
// publishing build knew that key.
static const uint64_t kNLNUValid = 1ULL << 63;

static BOOL NLNextUpPref(NSString *key, uint64_t bit, BOOL fallback) {
    static int token = -1;
    if (token == -1 && notify_register_check("com.yves.nextup3.state", &token) != NOTIFY_STATUS_OK) token = -2;
    uint64_t state = 0;
    if (token >= 0 && notify_get_state(token, &state) == NOTIFY_STATUS_OK &&
        (state & kNLNUValid) && (state & (bit << 32))) {
        return (state & bit) != 0;
    }
    id value = CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.yves.nextup3")));
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

BOOL NLNextUpInstalled(void) {
    static BOOL installed;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ installed = [[NSFileManager defaultManager] fileExistsAtPath:kNLNextUpDylib]; });
    return installed;
}

// Advanced › Supported Tweaks › NextUp 3 (on unless switched off). Once its
// library is in, its own hooks give the player its row until Settings quits.
static BOOL NLNextUpWanted(void) {
    id on = NLReadPref(nil, @"tweakNextUp");
    return ![on respondsToSelector:@selector(boolValue)] || [on boolValue];
}

@interface NSObject (NLNextUp)
+ (instancetype)sharedManager;
- (BOOL)isActive;
@end

// Switched off with its library already in, which cannot be taken out again:
// its manager says it has no next track here, which its own row and the
// player's size go by, so they go as well (Settings only; SpringBoard's
// NextUp is untouched).
static BOOL (*gIsActive)(id, SEL);
static BOOL NLIsActive(id self, SEL _cmd) {
    return NLNextUpWanted() && gIsActive(self, _cmd);
}

static void NLHookManager(void) {
    Class manager = objc_getClass("NUNextUpManager");
    Method isActive = manager ? class_getInstanceMethod(manager, @selector(isActive)) : NULL;
    if (isActive) gIsActive = (BOOL (*)(id, SEL))method_setImplementation(isActive, (IMP)NLIsActive);
}

void NLNextUpLoad(void) {
    if (!NLNextUpWanted()) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Its rows here were made against iOS 16's player and island.
        if (@available(iOS 16.0, *)) {} else return;
        if (!NLNextUpInstalled()) return;
        dlopen("/System/Library/PrivateFrameworks/MediaControls.framework/MediaControls", RTLD_NOW);
        dlopen(kNLNextUpDylib.fileSystemRepresentation, RTLD_NOW);
        NLHookManager();
    });
}

BOOL NLNextUpShowsInIsland(void) {
    if (!NLNextUpInstalled() || !NLNextUpWanted() || !NLNextUpPref(@"Enabled", 1ULL << 0, YES)) return NO;
    return NLNextUpPref(@"showDynamicIsland", 1ULL << 4, YES);
}

// NextUp's manager: whether there is a next track to show for what plays.
BOOL NLNextUpActive(void) {
    Class manager = objc_getClass("NUNextUpManager");
    id shared = [manager respondsToSelector:@selector(sharedManager)] ? [manager sharedManager] : nil;
    return [shared respondsToSelector:@selector(isActive)] && [shared isActive];
}

void NLNextUpStart(void) {
    Class manager = objc_getClass("NUNextUpManager");
    id shared = [manager respondsToSelector:@selector(sharedManager)] ? [manager sharedManager] : nil;
    // -start is declared elsewhere with other types: called by hand.
    if ([shared respondsToSelector:@selector(start)]) ((void (*)(id, SEL))objc_msgSend)(shared, @selector(start));
}

// On iOS 16.5 MediaControls has MRUActivityNowPlaying* too, the class NextUp
// gives a row to on iOS 17 and later, and loaded here its hooks reach the
// island preview's view: a row of its own placed for a taller island, and the
// player laid out shorter by that much (the transport controls landed on the
// scrubber). The preview has its own row, placed as on the real island; the
// view is taken back from NextUp: its row out, its "this is the island" mark
// (kNUHostViewKey, which its layout hooks go by) off.
void NLNextUpKeepOut(UIView *view) {
    if (!view || !NLNextUpInstalled()) return;
    Class rowClass = objc_getClass("NUNextUpRowView");
    if (rowClass) {
        for (UIView *sub in [view.subviews copy]) {
            if ([sub isKindOfClass:rowClass]) [sub removeFromSuperview];
        }
    }
    static void *key;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void * const *symbol = dlsym(RTLD_DEFAULT, "kNUHostViewKey");
        key = symbol ? *symbol : NULL;
    });
    if (key && objc_getAssociatedObject(view, key)) objc_setAssociatedObject(view, key, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
