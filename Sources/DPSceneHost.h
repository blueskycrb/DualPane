#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// 把目标 App 的画面嵌进 UIView。
/// 依次尝试：SceneHandle 视图 → FBSceneHostManager → 图层宿主 → 快照回退。
@interface DPSceneHost : NSObject

@property (nonatomic, copy, readonly) NSString *bundleID;
@property (nonatomic, strong, readonly) UIView *view;
@property (nonatomic, assign, readonly, getter=isLive) BOOL live;
@property (nonatomic, copy, readonly, nullable) NSString *statusText;

+ (BOOL)isSceneHostingAvailable;

- (instancetype)initWithBundleID:(NSString *)bundleID;
- (void)setHostedFrame:(CGRect)frame;
- (void)setSuspended:(BOOL)suspended;
- (void)retryAttach;
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
