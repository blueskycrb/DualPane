#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@class DPSceneHost;

/// Side-by-side (or stacked) dual-app layout with a draggable divider.
@interface DPSplitManager : NSObject

@property (nonatomic, strong, readonly, nullable) UIView *containerView;
@property (nonatomic, copy, readonly, nullable) NSString *primaryBundleID;
@property (nonatomic, copy, readonly, nullable) NSString *secondaryBundleID;
@property (nonatomic, assign, readonly) CGFloat ratio; // primary share, 0.2–0.8
@property (nonatomic, assign, readonly, getter=isActive) BOOL active;
@property (nonatomic, copy, nullable) void (^onClose)(void);
@property (nonatomic, copy, nullable) void (^onSwap)(void);
@property (nonatomic, copy, nullable) void (^onRatioChanged)(CGFloat ratio);
@property (nonatomic, copy, nullable) void (^onPromoteSecondaryToFloating)(NSString *bundleID);

- (void)presentInView:(UIView *)parent
        primaryBundle:(NSString *)primaryBundleID
      secondaryBundle:(NSString *)secondaryBundleID
                ratio:(CGFloat)ratio
             animated:(BOOL)animated;

- (void)attachPrimaryHost:(DPSceneHost *)host;
- (void)attachSecondaryHost:(DPSceneHost *)host;
- (nullable DPSceneHost *)detachPrimaryHost;
- (nullable DPSceneHost *)detachSecondaryHost;
- (void)setRatio:(CGFloat)ratio animated:(BOOL)animated;
- (void)swapSidesAnimated:(BOOL)animated;
- (void)dismissAnimated:(BOOL)animated completion:(void (^ _Nullable)(void))completion;
- (void)layoutForBounds:(CGRect)bounds;
- (void)commitHostedFrames;

@end

NS_ASSUME_NONNULL_END
