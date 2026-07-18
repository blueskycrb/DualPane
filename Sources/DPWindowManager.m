#import "DPWindowManager.h"
#import "DPFloatingWindow.h"
#import "DPSplitManager.h"
#import "DPSceneHost.h"
#import "DPAppPicker.h"
#import "DPSettings.h"
#import "DPOverlayController.h"
#import "DPPassthroughWindow.h"

@interface DPWindowManager ()
@property (nonatomic, strong, nullable) DPPassthroughWindow *overlayWindow;
@property (nonatomic, strong) DPPassthroughView *overlayRoot;
@property (nonatomic, strong, readwrite) NSMutableArray<DPFloatingWindow *> *mutableFloatingWindows;
@property (nonatomic, strong, readwrite, nullable) DPSplitManager *splitManager;
@property (nonatomic, assign, readwrite) DPPresentationMode mode;
@property (nonatomic, strong, nullable) DPAppPicker *picker;
@property (nonatomic, strong, nullable) DPOverlayController *modeChooser;
@property (nonatomic, strong) NSMutableSet<NSString *> *mutableHostedBundleIDs;
@property (nonatomic, assign) BOOL suppressLaunch;
@end

@implementation DPWindowManager

+ (instancetype)shared {
    static DPWindowManager *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[DPWindowManager alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _mutableFloatingWindows = [NSMutableArray array];
        _mutableHostedBundleIDs = [NSMutableSet set];
        _mode = DPPresentationModeNone;
        _suppressLaunch = NO;
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(settingsChanged)
                                                     name:kDPSettingsChangedNotification
                                                   object:nil];
    }
    return self;
}

- (NSArray<DPFloatingWindow *> *)floatingWindows {
    return [self.mutableFloatingWindows copy];
}

- (NSSet<NSString *> *)hostedBundleIDs {
    return [self.mutableHostedBundleIDs copy];
}

#pragma mark - Install（独立顶层窗口）

- (void)installInWindow:(UIWindow *)window {
    (void)window;
    [self install];
}

- (void)install {
    if (self.overlayWindow && self.overlayWindow.hidden == NO) {
        [self bringOverlayToFront];
        return;
    }

    CGRect bounds = [UIScreen mainScreen].bounds;
    DPPassthroughWindow *win = nil;

    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self activeWindowScene];
        if (scene) {
            win = [[DPPassthroughWindow alloc] initWithWindowScene:scene];
            win.frame = scene.coordinateSpace.bounds;
        }
    }
    if (!win) {
        win = [[DPPassthroughWindow alloc] initWithFrame:bounds];
    }

    win.windowLevel = UIWindowLevelStatusBar + 120.0;
    win.backgroundColor = [UIColor clearColor];
    win.hidden = NO;

    UIViewController *rootVC = [[UIViewController alloc] init];
    DPPassthroughView *root = [[DPPassthroughView alloc] initWithFrame:win.bounds];
    root.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    root.backgroundColor = [UIColor clearColor];
    rootVC.view = root;
    win.rootViewController = rootVC;

    self.overlayWindow = win;
    self.overlayRoot = root;

    NSLog(@"[DualPane] 顶层窗口已安装 level=%.0f", win.windowLevel);
}

- (UIWindowScene *)activeWindowScene API_AVAILABLE(ios(13.0)) {
    UIWindowScene *fallback = nil;
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        if (ws.activationState == UISceneActivationStateForegroundActive) return ws;
        if (!fallback) fallback = ws;
    }
    return fallback;
}

- (void)bringOverlayToFront {
    if (!self.overlayWindow) {
        [self install];
        return;
    }
    self.overlayWindow.hidden = NO;
    self.overlayWindow.windowLevel = UIWindowLevelStatusBar + 120.0;
    // 重新挂到当前 scene（切 App 后 scene 可能变）
    if (@available(iOS 13.0, *)) {
        UIWindowScene *scene = [self activeWindowScene];
        if (scene && self.overlayWindow.windowScene != scene) {
            self.overlayWindow.windowScene = scene;
            self.overlayWindow.frame = scene.coordinateSpace.bounds;
            self.overlayRoot.frame = self.overlayWindow.bounds;
        }
    }
    // 不抢 keyWindow，只确保可见
    self.overlayWindow.hidden = NO;
}

- (UIView *)contentParent {
    [self install];
    [self bringOverlayToFront];
    return self.overlayRoot;
}

#pragma mark - Activation

- (void)handleActivationRequest {
    if (![DPSettings shared].isEnabled) return;
    [self install];

    DPDefaultMode mode = [DPSettings shared].defaultMode;
    if (mode == DPDefaultModeFloating) {
        [self presentAppPickerWithCompletion:^(NSString *bundleID) {
            if (bundleID) [self openFloatingWithBundleID:bundleID];
        }];
    } else if (mode == DPDefaultModeSplit) {
        [self presentAppPickerWithCompletion:^(NSString *bundleID) {
            if (!bundleID) return;
            NSString *primary = [self foregroundBundleID] ?: @"com.apple.springboard";
            [self openSplitWithPrimary:primary secondary:bundleID];
        }];
    } else {
        [self presentModeChooser];
    }
}

- (void)handleActivationForBundleID:(NSString *)bundleID {
    [self handleActivationForBundleID:bundleID preferredMode:DPPresentationModeNone];
}

- (void)handleActivationForBundleID:(NSString *)bundleID preferredMode:(DPPresentationMode)mode {
    if (![DPSettings shared].isEnabled) return;
    if (!bundleID.length) {
        [self handleActivationRequest];
        return;
    }
    if ([[DPSettings shared] isBundleBlacklisted:bundleID]) return;

    [self install];

    DPPresentationMode resolved = mode;
    if (resolved == DPPresentationModeNone) {
        DPDefaultMode dm = [DPSettings shared].defaultMode;
        if (dm == DPDefaultModeFloating) resolved = DPPresentationModeFloating;
        else if (dm == DPDefaultModeSplit) resolved = DPPresentationModeSplit;
    }

    if (resolved == DPPresentationModeFloating) {
        [self openFloatingWithBundleID:bundleID];
        return;
    }
    if (resolved == DPPresentationModeSplit) {
        // 分屏：左边尽量用当前前台 App；主屏触发时用「桌面占位 + 目标 App」
        NSString *primary = [self foregroundBundleID];
        if (!primary.length ||
            [primary isEqualToString:bundleID] ||
            [primary isEqualToString:@"com.apple.springboard"]) {
            // 主屏触发：用目标 App 自己做主屏不合适，改为仅悬浮更直观
            // 但用户要分屏：主侧显示桌面快照占位，右侧目标 App
            primary = @"com.apple.springboard";
        }
        [self openSplitWithPrimary:primary secondary:bundleID];
        return;
    }

    // 询问
    if (self.modeChooser) {
        [self.modeChooser dismiss];
        self.modeChooser = nil;
    }
    UIView *parent = [self contentParent];
    __weak typeof(self) weakSelf = self;
    NSString *target = [bundleID copy];
    self.modeChooser = [[DPOverlayController alloc] init];
    [self.modeChooser presentModeChooserInView:parent
                                    completion:^(DPPresentationMode chosen) {
        weakSelf.modeChooser = nil;
        if (chosen == DPPresentationModeNone) return;
        [weakSelf handleActivationForBundleID:target preferredMode:chosen];
    }];
}

- (void)presentModeChooser {
    if (self.modeChooser) {
        [self.modeChooser dismiss];
        self.modeChooser = nil;
    }
    UIView *parent = [self contentParent];
    __weak typeof(self) weakSelf = self;
    self.modeChooser = [[DPOverlayController alloc] init];
    [self.modeChooser presentModeChooserInView:parent
                                    completion:^(DPPresentationMode chosen) {
        weakSelf.modeChooser = nil;
        if (chosen == DPPresentationModeNone) return;
        [weakSelf presentAppPickerWithCompletion:^(NSString *bundleID) {
            if (!bundleID) return;
            if (chosen == DPPresentationModeFloating) {
                [weakSelf openFloatingWithBundleID:bundleID];
            } else if (chosen == DPPresentationModeSplit) {
                NSString *primary = [weakSelf foregroundBundleID] ?: @"com.apple.springboard";
                [weakSelf openSplitWithPrimary:primary secondary:bundleID];
            }
        }];
    }];
}

- (void)presentAppPickerWithCompletion:(void (^)(NSString * _Nullable))completion {
    if (self.picker) {
        [self.picker dismissAnimated:NO];
        self.picker = nil;
    }
    UIView *parent = [self contentParent];
    self.picker = [[DPAppPicker alloc] init];
    __weak typeof(self) weakSelf = self;
    [self.picker presentInView:parent
                     favorites:[DPSettings shared].favorites
                     blacklist:[DPSettings shared].blacklist
                    completion:^(NSString *bundleID) {
        weakSelf.picker = nil;
        if (completion) completion(bundleID);
    }];
}

#pragma mark - Open

- (void)openBundleID:(NSString *)bundleID inMode:(DPPresentationMode)mode {
    if (mode == DPPresentationModeFloating) {
        [self openFloatingWithBundleID:bundleID];
    } else if (mode == DPPresentationModeSplit) {
        NSString *primary = [self foregroundBundleID] ?: @"com.apple.springboard";
        [self openSplitWithPrimary:primary secondary:bundleID];
    }
}

- (void)openFloatingWithBundleID:(NSString *)bundleID {
    if (!bundleID.length) return;
    if ([[DPSettings shared] isBundleBlacklisted:bundleID]) return;

    // 关键：先登记托管，再画 UI —— 阻止随后的全屏启动
    [self.mutableHostedBundleIDs addObject:bundleID];
    self.suppressLaunch = YES;

    NSInteger max = [DPSettings shared].maxFloatingWindows;
    while ((NSInteger)self.mutableFloatingWindows.count >= max) {
        DPFloatingWindow *oldest = self.mutableFloatingWindows.firstObject;
        [self closeFloatingWindow:oldest animated:YES];
    }

    if (self.splitManager.isActive) {
        // 分屏里的托管也清掉
        if (self.splitManager.secondaryBundleID) {
            [self.mutableHostedBundleIDs removeObject:self.splitManager.secondaryBundleID];
        }
        [self.splitManager dismissAnimated:NO completion:nil];
        self.splitManager = nil;
    }

    UIView *parent = [self contentParent];
    CGRect frame = [self initialFloatingFrameInBounds:parent.bounds];
    DPFloatingWindow *window = [[DPFloatingWindow alloc] initWithBundleID:bundleID frame:frame];
    window.contentOpacity = [DPSettings shared].floatingOpacity;
    window.cornerRadiusValue = [DPSettings shared].floatingCornerRadius;
    window.showsBorder = [DPSettings shared].showBorder;

    DPSceneHost *host = [[DPSceneHost alloc] initWithBundleID:bundleID];
    [window attachSceneHost:host];

    __weak typeof(self) weakSelf = self;
    window.onClose = ^(DPFloatingWindow *w) {
        [weakSelf closeFloatingWindow:w animated:YES];
    };
    window.onExpandToSplit = ^(DPFloatingWindow *w) {
        NSString *primary = [weakSelf foregroundBundleID];
        if (!primary.length || [primary isEqualToString:w.bundleID]) {
            primary = @"com.apple.springboard";
        }
        NSString *secondary = w.bundleID;
        [weakSelf closeFloatingWindow:w animated:NO];
        [weakSelf openSplitWithPrimary:primary secondary:secondary];
    };
    window.onFocus = ^(DPFloatingWindow *w) {
        for (DPFloatingWindow *other in weakSelf.mutableFloatingWindows) {
            [other setActive:(other == w) animated:YES];
        }
        [weakSelf bringOverlayToFront];
    };
    window.onFrameChanged = ^(DPFloatingWindow *w, CGRect f) {
        [[DPSettings shared] setLastFloatingFrame:f];
        (void)w;
    };

    [parent addSubview:window];
    [self.mutableFloatingWindows addObject:window];
    self.mode = DPPresentationModeFloating;
    [self bringOverlayToFront];

    if ([DPSettings shared].animateTransitions) {
        window.alpha = 0;
        window.transform = CGAffineTransformMakeScale(0.9, 0.9);
        [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.5 options:0 animations:^{
            window.alpha = 1;
            window.transform = CGAffineTransformIdentity;
        } completion:nil];
    }

    [[DPSettings shared] setLastSecondaryBundleID:bundleID];

    // 后台预热进程（不切换前台）。延迟再尝试挂 scene。
    [self warmUpAppInBackground:bundleID];
    __weak DPFloatingWindow *weakWindow = window;
    __weak DPSceneHost *weakHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakHost retryAttach];
        if (weakWindow) [weakWindow attachSceneHost:weakHost];
        [weakSelf bringOverlayToFront];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakHost retryAttach];
        if (weakWindow) [weakWindow attachSceneHost:weakHost];
        [weakSelf bringOverlayToFront];
        weakSelf.suppressLaunch = NO;
    });

    NSLog(@"[DualPane] 打开悬浮窗 %@", bundleID);
}

- (void)openSplitWithPrimary:(NSString *)primary secondary:(NSString *)secondary {
    if (!secondary.length) return;
    if ([[DPSettings shared] isBundleBlacklisted:secondary]) return;

    [self.mutableHostedBundleIDs addObject:secondary];
    if (primary.length && ![primary isEqualToString:@"com.apple.springboard"]) {
        [self.mutableHostedBundleIDs addObject:primary];
    }
    self.suppressLaunch = YES;

    NSArray *copy = [self.mutableFloatingWindows copy];
    for (DPFloatingWindow *w in copy) {
        [self closeFloatingWindow:w animated:NO];
    }

    UIView *parent = [self contentParent];

    if (self.splitManager.isActive) {
        [self.splitManager dismissAnimated:NO completion:nil];
    }

    self.splitManager = [[DPSplitManager alloc] init];
    CGFloat ratio = [DPSettings shared].lastSplitRatio;

    __weak typeof(self) weakSelf = self;
    self.splitManager.onClose = ^{
        NSString *p = weakSelf.splitManager.primaryBundleID;
        NSString *s = weakSelf.splitManager.secondaryBundleID;
        if (p) [weakSelf.mutableHostedBundleIDs removeObject:p];
        if (s) [weakSelf.mutableHostedBundleIDs removeObject:s];
        [weakSelf.splitManager dismissAnimated:YES completion:^{
            weakSelf.splitManager = nil;
            weakSelf.mode = DPPresentationModeNone;
            weakSelf.suppressLaunch = NO;
        }];
    };
    self.splitManager.onRatioChanged = ^(CGFloat r) {
        [[DPSettings shared] setLastSplitRatio:r];
    };
    self.splitManager.onPromoteSecondaryToFloating = ^(NSString *bundleID) {
        NSString *p = weakSelf.splitManager.primaryBundleID;
        NSString *s = weakSelf.splitManager.secondaryBundleID;
        if (p) [weakSelf.mutableHostedBundleIDs removeObject:p];
        if (s) [weakSelf.mutableHostedBundleIDs removeObject:s];
        [weakSelf.splitManager dismissAnimated:YES completion:^{
            weakSelf.splitManager = nil;
            [weakSelf openFloatingWithBundleID:bundleID];
        }];
    };

    [self.splitManager presentInView:parent
                       primaryBundle:primary ?: @"com.apple.springboard"
                     secondaryBundle:secondary
                               ratio:ratio
                            animated:YES];

    DPSceneHost *pHost = [[DPSceneHost alloc] initWithBundleID:primary ?: @"com.apple.springboard"];
    DPSceneHost *sHost = [[DPSceneHost alloc] initWithBundleID:secondary];
    [self.splitManager attachPrimaryHost:pHost];
    [self.splitManager attachSecondaryHost:sHost];

    self.mode = DPPresentationModeSplit;
    [[DPSettings shared] setLastPrimaryBundleID:primary];
    [[DPSettings shared] setLastSecondaryBundleID:secondary];
    [self bringOverlayToFront];

    [self warmUpAppInBackground:secondary];
    __weak DPSceneHost *weakSHost = sHost;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSHost retryAttach];
        [weakSelf.splitManager attachSecondaryHost:weakSHost];
        [weakSelf bringOverlayToFront];
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSHost retryAttach];
        [weakSelf.splitManager attachSecondaryHost:weakSHost];
        [weakSelf bringOverlayToFront];
        weakSelf.suppressLaunch = NO;
    });

    NSLog(@"[DualPane] 打开分屏 primary=%@ secondary=%@", primary, secondary);
}

- (void)closeFloatingWindow:(DPFloatingWindow *)window animated:(BOOL)animated {
    if (!window) return;
    if (window.bundleID) {
        [self.mutableHostedBundleIDs removeObject:window.bundleID];
    }
    [self.mutableFloatingWindows removeObject:window];
    [window closeAnimated:animated completion:nil];
    if (self.mutableFloatingWindows.count == 0 && !self.splitManager.isActive) {
        self.mode = DPPresentationModeNone;
        self.suppressLaunch = NO;
    }
}

- (void)dismissAllAnimated:(BOOL)animated {
    NSArray *copy = [self.mutableFloatingWindows copy];
    for (DPFloatingWindow *w in copy) {
        [self closeFloatingWindow:w animated:animated];
    }
    if (self.splitManager.isActive) {
        if (self.splitManager.primaryBundleID) {
            [self.mutableHostedBundleIDs removeObject:self.splitManager.primaryBundleID];
        }
        if (self.splitManager.secondaryBundleID) {
            [self.mutableHostedBundleIDs removeObject:self.splitManager.secondaryBundleID];
        }
        [self.splitManager dismissAnimated:animated completion:nil];
        self.splitManager = nil;
    }
    self.mode = DPPresentationModeNone;
    self.suppressLaunch = NO;
    [self.mutableHostedBundleIDs removeAllObjects];
}

- (void)handleOrientationChange {
    if (self.overlayWindow) {
        CGRect bounds = [UIScreen mainScreen].bounds;
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = self.overlayWindow.windowScene ?: [self activeWindowScene];
            if (scene) bounds = scene.coordinateSpace.bounds;
        }
        self.overlayWindow.frame = bounds;
        self.overlayRoot.frame = self.overlayWindow.bounds;
    }
    if (self.splitManager.isActive) {
        [self.splitManager layoutForBounds:self.overlayRoot.bounds];
    }
    for (DPFloatingWindow *w in self.mutableFloatingWindows) {
        CGRect f = w.frame;
        CGRect bounds = self.overlayRoot.bounds;
        if (CGRectGetMaxX(f) < 40) f.origin.x = 0;
        if (CGRectGetMaxY(f) < 40) f.origin.y = 0;
        if (f.origin.x > bounds.size.width - 40) f.origin.x = bounds.size.width - f.size.width;
        if (f.origin.y > bounds.size.height - 40) f.origin.y = bounds.size.height - 40;
        w.frame = f;
    }
    [self bringOverlayToFront];
}

#pragma mark - Launch suppress

- (BOOL)shouldSuppressFullscreenForBundleID:(NSString *)bundleID {
    if (!bundleID.length) return NO;
    if (self.mode == DPPresentationModeNone && self.mutableHostedBundleIDs.count == 0) return NO;
    if ([self.mutableHostedBundleIDs containsObject:bundleID]) return YES;
    // 抑制窗口打开后的一小段抢焦点
    if (self.suppressLaunch && [bundleID isEqualToString:[DPSettings shared].lastSecondaryBundleID]) {
        return YES;
    }
    return NO;
}

#pragma mark - Helpers

- (CGRect)initialFloatingFrameInBounds:(CGRect)bounds {
    CGRect last = [DPSettings shared].lastFloatingFrame;
    if (!CGRectIsNull(last) && !CGRectIsEmpty(last)) {
        last.origin.x = MIN(MAX(0, last.origin.x), bounds.size.width - 80);
        last.origin.y = MIN(MAX(0, last.origin.y), bounds.size.height - 80);
        last.size.width = MIN(last.size.width, bounds.size.width);
        last.size.height = MIN(last.size.height, bounds.size.height);
        return last;
    }
    CGSize size = [DPSettings shared].defaultFloatingSize;
    size.width = MIN(size.width, bounds.size.width - 24);
    size.height = MIN(size.height, bounds.size.height - 48);
    CGFloat x = bounds.size.width - size.width - 12;
    CGFloat y = MAX(48, (bounds.size.height - size.height) / 2.0);
    CGFloat stagger = self.mutableFloatingWindows.count * 24.0;
    return CGRectMake(x - stagger, y + stagger, size.width, size.height);
}

- (NSString *)foregroundBundleID {
    Class SBAppController = NSClassFromString(@"SBApplicationController");
    if (SBAppController) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id controller = [SBAppController performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
        NSArray *sels = @[@"frontmostApplication", @"_frontMostApplication", @"focusedApplication"];
        for (NSString *name in sels) {
            SEL sel = NSSelectorFromString(name);
            if ([controller respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                id app = [controller performSelector:sel];
#pragma clang diagnostic pop
                NSString *bid = [app valueForKey:@"bundleIdentifier"];
                if (bid.length) return bid;
            }
        }
    }
    return nil;
}

/// 后台预热：不再调用会切前台的 openApplication。
/// 真实画面依赖用户曾经打开过该 App；占位页可正常使用悬浮/分屏壳。
- (void)warmUpAppInBackground:(NSString *)bundleID {
    if (!bundleID.length) return;
    // 尝试通过 SpringBoard 的 application 对象“预热”但不激活
    Class SBAppController = NSClassFromString(@"SBApplicationController");
    if (!SBAppController) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id controller = [SBAppController performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
    id app = nil;
    if ([controller respondsToSelector:NSSelectorFromString(@"applicationWithBundleIdentifier:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        app = [controller performSelector:NSSelectorFromString(@"applicationWithBundleIdentifier:") withObject:bundleID];
#pragma clang diagnostic pop
    }
    if (!app) return;
    // 某些版本有 createRunningBoardAssertion / awake 类方法；全部 best-effort
    if ([app respondsToSelector:NSSelectorFromString(@"_setActivationSettings:")]) {
        // skip — 避免误激活
    }
    NSLog(@"[DualPane] 预热引用 %@（不切换前台）", bundleID);
}

- (void)settingsChanged {
    if (![DPSettings shared].isEnabled) {
        [self dismissAllAnimated:YES];
    }
    for (DPFloatingWindow *w in self.mutableFloatingWindows) {
        w.contentOpacity = [DPSettings shared].floatingOpacity;
        w.cornerRadiusValue = [DPSettings shared].floatingCornerRadius;
        w.showsBorder = [DPSettings shared].showBorder;
    }
}

@end
