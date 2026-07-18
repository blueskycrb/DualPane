#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Lightweight host for a second application scene.
///
/// On a fully instrumented device this talks to FrontBoard / FBSScene to
/// clone an application scene into a UIView. When private APIs are unavailable
/// (simulator / incomplete SDK headers), it falls back to a placeholder that
/// still lets the chrome, gestures, and layout pipeline be exercised.
@interface DPSceneHost : NSObject

@property (nonatomic, copy, readonly) NSString *bundleID;
@property (nonatomic, strong, readonly) UIView *view;
@property (nonatomic, assign, readonly, getter=isLive) BOOL live;

+ (BOOL)isSceneHostingAvailable;

- (instancetype)initWithBundleID:(NSString *)bundleID;
- (void)setHostedFrame:(CGRect)frame;
- (void)setSuspended:(BOOL)suspended;
- (void)retryAttach;   // 进程起来后再次尝试挂接真实画面
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
