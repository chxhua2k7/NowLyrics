//
//  NLCCPrivate.h
//  ControlCenterUIKit's and MediaControls' private interfaces the module
//  uses, by the selectors iOS 16.5.1 has. Theos' vendor/include has only the
//  two CCUIContentModule protocols.
//

#import <UIKit/UIKit.h>
#import <ControlCenterUIKit/CCUIContentModule-Protocol.h>
#import <ControlCenterUIKit/CCUIContentModuleContentViewController-Protocol.h>

// A module's size in Control Center's grid: columns and rows.
typedef struct CCUILayoutSize {
    unsigned long long width;
    unsigned long long height;
} CCUILayoutSize;

// The corners Control Center gives a closed module.
extern CGFloat CCUICompactModuleContinuousCornerRadius(void);

// Between the module and Control Center.
@interface CCUIContentModuleContext : NSObject
- (void)requestExpandModule;
- (void)dismissModule;
- (void)setHomeGestureDismissalAllowed:(BOOL)allowed;
@end

// MediaControls' player as the media module makes it ([... new]), which
// asks its module through these: to close it, to let the home gesture close
// it, to open it (its closed output button tapped).
@interface MRUControlCenterViewController : UIViewController <CCUIContentModuleContentViewController>
@property (nonatomic, copy) void (^dismissalBlock)(void (^completion)(void));
@property (nonatomic, copy) void (^homeGestureDismissalAllowedBlock)(BOOL allowed);
@property (nonatomic, copy) void (^routingCornerViewTappedBlock)(void);
@end
