#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class DPFloatingWindow;
@class DPSplitManager;

typedef NS_ENUM(NSInteger, DPPresentationMode) {
    DPPresentationModeNone = 0,
    DPPresentationModeFloating,
    DPPresentationModeSplit,
};

/// Central coordinator for floating windows and split-screen sessions.
@interface DPWindowManager : NSObject

+ (instancetype)shared;

@property (nonatomic, strong, readonly) NSArray<DPFloatingWindow *> *floatingWindows;
@property (nonatomic, strong, readonly, nullable) DPSplitManager *splitManager;
@property (nonatomic, assign, readonly) DPPresentationMode mode;

- (void)installInWindow:(UIWindow *)window;
- (void)handleActivationRequest;
/// 从主屏幕某个 App 图标触发：bundleID 为该图标对应应用（作为副屏/悬浮目标）
- (void)handleActivationForBundleID:(NSString *)bundleID;
- (void)handleActivationForBundleID:(NSString *)bundleID preferredMode:(DPPresentationMode)mode;
- (void)presentAppPickerWithCompletion:(void (^ _Nullable)(NSString * _Nullable bundleID))completion;
- (void)openBundleID:(NSString *)bundleID inMode:(DPPresentationMode)mode;
- (void)openFloatingWithBundleID:(NSString *)bundleID;
- (void)openSplitWithPrimary:(NSString *)primary secondary:(NSString *)secondary;
- (void)dismissAllAnimated:(BOOL)animated;
- (void)handleOrientationChange;

@end

NS_ASSUME_NONNULL_END
