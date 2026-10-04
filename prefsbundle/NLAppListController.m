//
//  NLAppListController.m
//  "Choose Apps": AltList's app list with a filter in the navigation bar,
//  music apps only (the default) or every app. A subclass of
//  ATLApplicationListMultiSelectionController made at runtime, as AltList is
//  dlopen'ed rather than linked (NLOffsetCell.m).
//
//  The filter is AltList's own: a custom section whose predicate it runs on
//  the apps it lists anyway. A music app is one the App Store files under
//  Music (genre 6011), the system's Music or Podcasts, one of the apps chosen
//  by default, or one chosen already (an app installed outside the App Store
//  has no genre).
//

#import "NLLyricsPages.h"
#import <Preferences/PSSpecifier.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString *const kNLFilterKey = @"appListFilter";   // "music" (the default) or "all"

@interface PSListController (NLAltList)
- (void)_loadSectionsFromSpecifier;
- (void)_populateSections;
- (void)reloadApplications;
@end

static Class gListBase;   // ATLApplicationListMultiSelectionController

static BOOL NLMusicOnly(void) {
    return ![NLReadPref(nil, kNLFilterKey) isEqual:@"all"];
}

// The sections for the filter: one of music apps, or the plist's own.
static NSArray *NLListSections(PSListController *list) {
    NSArray *plist = [list.specifier propertyForKey:@"nlAllSections"];
    if (!plist) {
        plist = [list.specifier propertyForKey:@"sections"] ?: @[];
        [list.specifier setProperty:plist forKey:@"nlAllSections"];
    }
    if (!NLMusicOnly()) return plist;

    NSMutableOrderedSet<NSString *> *ids = [NSMutableOrderedSet orderedSetWithArray:@[@"com.apple.Music", @"com.apple.podcasts"]];
    for (id chosen in @[[list.specifier propertyForKey:@"default"] ?: @[], NLReadPref(nil, @"enabledApps") ?: @[]]) {
        if (![chosen isKindOfClass:NSArray.class]) continue;
        for (id bundleID in chosen) {
            // Bundle IDs only, so the predicate format stays a plain list.
            if ([bundleID isKindOfClass:NSString.class] &&
                [bundleID rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:
                    @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_"] invertedSet]].location == NSNotFound) {
                [ids addObject:bundleID];
            }
        }
    }
    NSString *listed = [NSString stringWithFormat:@"bundleIdentifier IN {\"%@\"}", [ids.array componentsJoinedByString:@"\", \""]];
    BOOL genres = [objc_getClass("LSApplicationProxy") instancesRespondToSelector:@selector(genreID)];
    NSString *predicate = genres ? [@"genreID == 6011 OR " stringByAppendingString:listed] : listed;
    return @[@{@"sectionType": @"Custom", @"sectionName": NLL(@"Music Apps"), @"sectionPredicate": predicate}];
}

static void NLListLoadSections(PSListController *self, SEL _cmd) {
    [self.specifier setProperty:NLListSections(self) forKey:@"sections"];
    struct objc_super base = {self, gListBase};
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&base, _cmd);
}

static void NLListSetFilter(PSListController *self, BOOL musicOnly);

// The filter button: filled while it hides something, as Mail's is.
static void NLListUpdateButton(PSListController *self) {
    BOOL music = NLMusicOnly();
    __weak PSListController *weakSelf = self;
    UIAction *musicAction = [UIAction actionWithTitle:NLL(@"Music Apps") image:[UIImage systemImageNamed:@"music.note"]
                                           identifier:nil handler:^(UIAction *action) { NLListSetFilter(weakSelf, YES); }];
    UIAction *allAction = [UIAction actionWithTitle:NLL(@"All Apps") image:[UIImage systemImageNamed:@"square.grid.2x2"]
                                         identifier:nil handler:^(UIAction *action) { NLListSetFilter(weakSelf, NO); }];
    musicAction.state = music ? UIMenuElementStateOn : UIMenuElementStateOff;
    allAction.state = music ? UIMenuElementStateOff : UIMenuElementStateOn;
    NSString *symbol = music ? @"line.3.horizontal.decrease.circle.fill" : @"line.3.horizontal.decrease.circle";
    UIImage *image = [UIImage systemImageNamed:symbol] ?: [UIImage systemImageNamed:@"line.horizontal.3.decrease.circle"];
    UIMenu *menu = [UIMenu menuWithTitle:NLL(@"Filter") children:@[musicAction, allAction]];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:image menu:menu];
}

static void NLListSetFilter(PSListController *self, BOOL musicOnly) {
    if (!self || musicOnly == NLMusicOnly()) return;
    NLWritePrefs(@{kNLFilterKey: musicOnly ? @"music" : @"all"});
    [self _loadSectionsFromSpecifier];
    [self _populateSections];
    [self reloadApplications];
    NLListUpdateButton(self);
}

static void NLListViewDidLoad(PSListController *self, SEL _cmd) {
    struct objc_super base = {self, gListBase};
    ((void (*)(struct objc_super *, SEL))objc_msgSendSuper)(&base, _cmd);
    NLListUpdateButton(self);
}

// Made whenever AltList is there, as the plist names it; an AltList without
// these methods gets its own list, unfiltered.
void NLRegisterAppListController(void) {
    gListBase = objc_getClass("ATLApplicationListMultiSelectionController");
    if (!gListBase || objc_getClass("NLAppListController")) return;
    Class list = objc_allocateClassPair(gListBase, "NLAppListController", 0);
    if (!list) return;
    if ([gListBase instancesRespondToSelector:@selector(_loadSectionsFromSpecifier)] &&
        [gListBase instancesRespondToSelector:@selector(_populateSections)] &&
        [gListBase instancesRespondToSelector:@selector(reloadApplications)]) {
        class_addMethod(list, @selector(viewDidLoad), (IMP)NLListViewDidLoad, "v@:");
        class_addMethod(list, @selector(_loadSectionsFromSpecifier), (IMP)NLListLoadSections, "v@:");
    }
    objc_registerClassPair(list);
}
