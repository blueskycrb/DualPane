#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DPActivationGesture) {
    DPActivationGestureEdgeSwipe = 0,
    DPActivationGestureThreeFingerSwipeUp = 1,
    DPActivationGestureStatusBarDoubleTap = 2,
    DPActivationGestureHomeIndicatorLongPress = 3,
    DPActivationGestureIconSwipeUp = 4,     // 主屏幕图标上滑
    DPActivationGestureIconLongPress = 5,   // 主屏幕图标长按菜单
};

typedef NS_ENUM(NSInteger, DPDefaultMode) {
    DPDefaultModeFloating = 0,
    DPDefaultModeSplit = 1,
    DPDefaultModeAsk = 2,
};

typedef NS_ENUM(NSInteger, DPSplitOrientation) {
    DPSplitOrientationHorizontal = 0, // left | right
    DPSplitOrientationVertical = 1,   // top / bottom
};

@interface DPSettings : NSObject

+ (instancetype)shared;

@property (nonatomic, readonly, getter=isEnabled) BOOL enabled;
@property (nonatomic, readonly) DPDefaultMode defaultMode;
@property (nonatomic, readonly) DPSplitOrientation splitOrientation;
@property (nonatomic, readonly) CGFloat defaultSplitRatio; // 0.2 – 0.8
@property (nonatomic, readonly) CGFloat floatingOpacity;   // 0.5 – 1.0
@property (nonatomic, readonly) CGFloat floatingCornerRadius;
@property (nonatomic, readonly) CGSize defaultFloatingSize;
@property (nonatomic, readonly) BOOL showBorder;
@property (nonatomic, readonly) BOOL hapticFeedback;
@property (nonatomic, readonly) BOOL rememberLastApps;
@property (nonatomic, readonly) BOOL allowLandscape;
@property (nonatomic, readonly) NSInteger maxFloatingWindows;
@property (nonatomic, readonly) NSArray<NSNumber *> *enabledGestures; // DPActivationGesture
@property (nonatomic, readonly) NSArray<NSString *> *blacklist;       // bundle IDs
@property (nonatomic, readonly) NSArray<NSString *> *favorites;       // bundle IDs
@property (nonatomic, readonly) CGFloat edgeSwipeSensitivity;         // 0.0 – 1.0
@property (nonatomic, readonly) BOOL dimBackgroundInSplit;
@property (nonatomic, readonly) BOOL animateTransitions;
@property (nonatomic, readonly, nullable) NSString *lastPrimaryBundleID;
@property (nonatomic, readonly, nullable) NSString *lastSecondaryBundleID;
@property (nonatomic, readonly) CGFloat lastSplitRatio;
@property (nonatomic, readonly) CGRect lastFloatingFrame;

- (void)reload;
- (void)setLastPrimaryBundleID:(nullable NSString *)bundleID;
- (void)setLastSecondaryBundleID:(nullable NSString *)bundleID;
- (void)setLastSplitRatio:(CGFloat)ratio;
- (void)setLastFloatingFrame:(CGRect)frame;
- (BOOL)isBundleBlacklisted:(NSString *)bundleID;
- (BOOL)isGestureEnabled:(DPActivationGesture)gesture;

@end

// Darwin notification posted when prefs change
FOUNDATION_EXPORT NSString * const kDPSettingsChangedNotification;

NS_ASSUME_NONNULL_END
