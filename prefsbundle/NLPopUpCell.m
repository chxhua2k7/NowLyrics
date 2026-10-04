//
//  NLPopUpCell.m
//  Choices picked in place, as Settings' own pop-up rows do: the value in use
//  and a chevron at the row's end, a menu of the others on a tap. Instead of
//  a PSLinkListCell's page of its own.
//
//  In a plist: `cell` PSDefaultCell, `cellClass` NLPopUpCell, and the usual
//  `key`, `defaults`, `default`, `validValues`, `validTitles` (localized
//  here), `PostNotification`. A pick goes through the page's
//  -setPreferenceValue:specifier:, like any other row's.
//

#import "NLLyricsPages.h"
#import <Preferences/PSSpecifier.h>
#import <Preferences/PSTableCell.h>

@interface PSListController (NLPopUp)
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

UIButton *NLPopUpButton(NSArray<NSString *> *titles, NSArray *values, id current, void (^picked)(id value)) {
    NSMutableArray<UIAction *> *actions = [NSMutableArray array];
    NSString *currentTitle = titles.firstObject ?: @"";
    for (NSUInteger i = 0; i < values.count && i < titles.count; i++) {
        id value = values[i];
        BOOL on = [value isEqual:current];
        if (on) currentTitle = titles[i];
        UIAction *action = [UIAction actionWithTitle:titles[i] image:nil identifier:nil
                                             handler:^(UIAction *a) { if (!on && picked) picked(value); }];
        action.state = on ? UIMenuElementStateOn : UIMenuElementStateOff;
        [actions addObject:action];
    }
    UIButtonConfiguration *config = [UIButtonConfiguration plainButtonConfiguration];
    config.title = currentTitle;
    config.image = [UIImage systemImageNamed:@"chevron.up.chevron.down"
                           withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:12 weight:UIImageSymbolWeightMedium]];
    config.imagePlacement = NSDirectionalRectEdgeTrailing;
    config.imagePadding = 4;
    // Room on both sides, so the highlight behind it while the menu is up does
    // not end at the chevron.
    config.contentInsets = NSDirectionalEdgeInsetsMake(6, 8, 6, 8);
    config.baseForegroundColor = UIColor.secondaryLabelColor;
    UIButton *button = [UIButton buttonWithConfiguration:config primaryAction:nil];
    button.menu = [UIMenu menuWithChildren:actions];
    button.showsMenuAsPrimaryAction = YES;
    [button sizeToFit];
    return button;
}

@interface NLPopUpCell : PSTableCell
@end

@implementation NLPopUpCell

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.accessoryType = UITableViewCellAccessoryNone;

    NSArray *values = [specifier propertyForKey:@"validValues"];
    NSArray *rawTitles = [specifier propertyForKey:@"validTitles"];
    if (![values isKindOfClass:NSArray.class] || ![rawTitles isKindOfClass:NSArray.class]) return;
    NSMutableArray<NSString *> *titles = [NSMutableArray array];
    for (NSString *title in rawTitles) [titles addObject:NLL(title)];

    PSListController *page = [specifier.target isKindOfClass:PSListController.class] ? specifier.target : nil;
    id current = [page respondsToSelector:@selector(readPreferenceValue:)] ? [page readPreferenceValue:specifier] : nil;
    if (![values containsObject:current]) current = [specifier propertyForKey:@"default"];

    __weak typeof(self) weakSelf = self;
    __weak PSSpecifier *weakSpecifier = specifier;
    self.accessoryView = NLPopUpButton(titles, values, current, ^(id value) {
        PSSpecifier *picked = weakSpecifier;
        PSListController *target = [picked.target isKindOfClass:PSListController.class] ? picked.target : nil;
        [target setPreferenceValue:value specifier:picked];
        if (picked) [weakSelf refreshCellContentsWithSpecifier:picked];
    });
}

@end
