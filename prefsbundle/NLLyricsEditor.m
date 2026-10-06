//
//  NLLyricsEditor.m
//  One lyrics file as text: edit and save it, or delete it. Opened from the
//  "Now Playing" page and the library. Saving checks the text still has timed
//  lines; either way the apps are told to look again.
//

#import "NLLyricsPages.h"

@implementation NLLyricsEditorController {
    NSString *_path;
    NSString *_original;
    UITextView *_textView;
}

- (instancetype)initWithPath:(NSString *)path title:(NSString *)title {
    if ((self = [super initWithNibName:nil bundle:nil])) {
        _path = [path copy];
        self.title = title.length ? title : NLL(@"Edit Lyrics");
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    _original = [NSString stringWithContentsOfFile:_path encoding:NSUTF8StringEncoding error:nil] ?: @"";
    _textView = [UITextView new];
    _textView.translatesAutoresizingMaskIntoConstraints = NO;
    _textView.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    _textView.text = _original;
    _textView.autocorrectionType = UITextAutocorrectionTypeNo;
    _textView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _textView.smartQuotesType = UITextSmartQuotesTypeNo;
    _textView.smartDashesType = UITextSmartDashesTypeNo;
    _textView.spellCheckingType = UITextSpellCheckingTypeNo;
    _textView.alwaysBounceVertical = YES;
    _textView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    _textView.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    [self.view addSubview:_textView];
    [NSLayoutConstraint activateConstraints:@[
        [_textView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [_textView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_textView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_textView.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    ]];

    UIBarButtonItem *save = [[UIBarButtonItem alloc] initWithTitle:NLL(@"Save") style:UIBarButtonItemStyleDone
                                                            target:self action:@selector(nlSave)];
    UIBarButtonItem *trash = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemTrash
                                                                           target:self action:@selector(nlDelete)];
    trash.tintColor = UIColor.systemRedColor;
    self.navigationItem.rightBarButtonItems = @[save, trash];
}

- (void)nlSave {
    NSString *text = _textView.text ?: @"";
    if ([text isEqualToString:_original]) {
        [self.navigationController popViewControllerAnimated:YES];
        return;
    }
    if (NLParseLRC(text).count == 0) {
        NLAlert(self, NLL(@"These lyrics have no times"), NLL(@"Every line needs a [mm:ss.xx] time."));
        return;
    }
    if (!NLSaveLyricsFile(self, text, _path)) return;
    _original = text;   // a second Save during the pop finds nothing new
    [self nlDone];
}

- (void)nlDelete {
    NLConfirm(self, NLL(@"Delete these lyrics?"), NLL(@"The app looks the song up again."), NLL(@"Delete"), ^{
        NLDeleteLyricsFile(self->_path);
        [self nlDone];
    });
}

// Saved or deleted: the page that opened this one follows, and the editor closes.
- (void)nlDone {
    if (self.onChange) self.onChange();
    [self.navigationController popViewControllerAnimated:YES];
}

@end
