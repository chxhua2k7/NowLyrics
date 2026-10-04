//
//  NLEditTextCell.m
//  The text rows (User Token, API Key). Stock PSEditTextCell leaves the keyboard
//  up when Return is pressed; this one commits the value and dismisses it, and
//  labels the key "Done". The values are credentials (and a pasted debug-info
//  dump), so they show as dots rather than in full.
//

#import <UIKit/UIKit.h>
#import <Preferences/PSEditableTableCell.h>
#import <Preferences/PSSpecifier.h>

@interface PSEditableTableCell (NLTextField) <UITextFieldDelegate>
- (UITextField *)textField;
@end

@interface NLEditTextCell : PSEditableTableCell
@end

@implementation NLEditTextCell

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    self.textField.returnKeyType = UIReturnKeyDone;
    self.textField.secureTextEntry = YES;
}

- (BOOL)textFieldShouldReturn:(UITextField *)textField {
    if ([PSEditableTableCell instancesRespondToSelector:_cmd]) [super textFieldShouldReturn:textField];   // stock commit, if any
    [textField resignFirstResponder];
    return YES;
}

@end
