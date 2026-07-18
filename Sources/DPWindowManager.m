#import "DPWindowManager.h"
#import "DPFloatingWindow.h"
#import "DPSplitManager.h"
#import "DPSceneHost.h"
#import "DPAppPicker.h"
#import "DPSettings.h"
#import "DPOverlayController.h"

@interface DPWindowManager ()
@property (nonatomic, weak) UIWindow *hostWindow;
@property (nonatomic, strong) UIView *overlayRoot;
@property (nonatomic, strong, readwrite) NSMutableArray<DPFloatingWindow *> *mutableFloatingWindows;
@property (nonatomic, strong, readwrite, nullable) DPSplitManager *splitManager;
@property (nonatomic, assign, readwrite) DPPresentationMode mode;
@property (nonatomic, strong, nullable) DPAppPicker *picker;
@property (nonatomic, strong, nullable) DPOverlayController *modeChooser;
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
        _mode = DPPresentationModeNone;
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

#pragma mark - Install

- (void)installInWindow:(UIWindow *)window {
    if (self.hostWindow == window && self.overlayRoot.superview) return;
    self.hostWindow = window;

    [self.overlayRoot removeFromSuperview];
    self.overlayRoot = [[UIView alloc] initWithFrame:window.bounds];
    self.overlayRoot.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.overlayRoot.userInteractionEnabled = YES;
    self.overlayRoot.backgroundColor = [UIColor clearColor];
    // Don't intercept touches outside our chrome
    self.overlayRoot.layer.zPosition = 10000;
    [window addSubview:self.overlayRoot];

    // Pass-through hit testing is handled by DPPassthroughView if needed;
    // for simplicity we use a custom hitTest override via associated subclass.
}

#pragma mark - Activation

- (void)handleActivationRequest {
    if (![DPSettings shared].isEnabled) return;

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

- (void)presentModeChooser {
    if (self.modeChooser) {
        [self.modeChooser dismiss];
        self.modeChooser = nil;
    }

    UIView *parent = self.overlayRoot ?: self.hostWindow;
    if (!parent) return;

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
    UIView *parent = self.overlayRoot ?: self.hostWindow;
    if (!parent) {
        if (completion) completion(nil);
        return;
    }

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

    // Cap windows
    NSInteger max = [DPSettings shared].maxFloatingWindows;
    while ((NSInteger)self.mutableFloatingWindows.count >= max) {
        DPFloatingWindow *oldest = self.mutableFloatingWindows.firstObject;
        [self closeFloatingWindow:oldest animated:YES];
    }

    // Dismiss split if needed
    if (self.splitManager.isActive) {
        [self.splitManager dismissAnimated:YES completion:nil];
        self.splitManager = nil;
    }

    UIView *parent = self.overlayRoot ?: self.hostWindow;
    if (!parent) return;

    CGRect frame = [self initialFloatingFrameInBounds:parent.bounds];
    DPFloatingWindow *window = [[DPFloatingWindow alloc] initWithBundleID:bundleID frame:frame];
    window.contentOpacity = [DPSettings shared].floatingOpacity;
    window.cornerRadiusValue = [DPSettings shared].floatingCornerRadius;
    window.showsBorder = [DPSettings shared].showBorder;

    DPSceneHost *host = [[DPSceneHost alloc] initWithBundleID:bundleID];
    [window attachSceneHost:host];

    __weak typeof(self) weakSelf = self;
    __weak DPFloatingWindow *weakWindow = window;
    window.onClose = ^(DPFloatingWindow *w) {
        [weakSelf closeFloatingWindow:w animated:YES];
    };
    window.onExpandToSplit = ^(DPFloatingWindow *w) {
        NSString *primary = [weakSelf foregroundBundleID] ?: @"com.apple.springboard";
        NSString *secondary = w.bundleID;
        [weakSelf closeFloatingWindow:w animated:NO];
        [weakSelf openSplitWithPrimary:primary secondary:secondary];
    };
    window.onFocus = ^(DPFloatingWindow *w) {
        for (DPFloatingWindow *other in weakSelf.mutableFloatingWindows) {
            [other setActive:(other == w) animated:YES];
        }
    };
    window.onFrameChanged = ^(DPFloatingWindow *w, CGRect f) {
        [[DPSettings shared] setLastFloatingFrame:f];
        (void)w;
    };

    [parent addSubview:window];
    [self.mutableFloatingWindows addObject:window];
    self.mode = DPPresentationModeFloating;

    if ([DPSettings shared].animateTransitions) {
        window.alpha = 0;
        window.transform = CGAffineTransformMakeScale(0.9, 0.9);
        [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.5 options:0 animations:^{
            window.alpha = 1;
            window.transform = CGAffineTransformIdentity;
        } completion:nil];
    }

    [[DPSettings shared] setLastSecondaryBundleID:bundleID];
    [self ensureTargetAppLaunched:bundleID];
    (void)weakWindow;
}

- (void)openSplitWithPrimary:(NSString *)primary secondary:(NSString *)secondary {
    if (!secondary.length) return;
    if ([[DPSettings shared] isBundleBlacklisted:secondary]) return;

    // Clear floating windows
    NSArray *copy = [self.mutableFloatingWindows copy];
    for (DPFloatingWindow *w in copy) {
        [self closeFloatingWindow:w animated:NO];
    }

    UIView *parent = self.overlayRoot ?: self.hostWindow;
    if (!parent) return;

    if (self.splitManager.isActive) {
        [self.splitManager dismissAnimated:NO completion:nil];
    }

    self.splitManager = [[DPSplitManager alloc] init];
    CGFloat ratio = [DPSettings shared].lastSplitRatio;

    __weak typeof(self) weakSelf = self;
    self.splitManager.onClose = ^{
        [weakSelf.splitManager dismissAnimated:YES completion:^{
            weakSelf.splitManager = nil;
            weakSelf.mode = DPPresentationModeNone;
        }];
    };
    self.splitManager.onRatioChanged = ^(CGFloat r) {
        [[DPSettings shared] setLastSplitRatio:r];
    };
    self.splitManager.onPromoteSecondaryToFloating = ^(NSString *bundleID) {
        [weakSelf.splitManager dismissAnimated:YES completion:^{
            weakSelf.splitManager = nil;
            [weakSelf openFloatingWithBundleID:bundleID];
        }];
    };

    [self.splitManager presentInView:parent
                       primaryBundle:primary
                     secondaryBundle:secondary
                               ratio:ratio
                            animated:YES];

    DPSceneHost *pHost = [[DPSceneHost alloc] initWithBundleID:primary];
    DPSceneHost *sHost = [[DPSceneHost alloc] initWithBundleID:secondary];
    [self.splitManager attachPrimaryHost:pHost];
    [self.splitManager attachSecondaryHost:sHost];

    self.mode = DPPresentationModeSplit;
    [[DPSettings shared] setLastPrimaryBundleID:primary];
    [[DPSettings shared] setLastSecondaryBundleID:secondary];

    [self ensureTargetAppLaunched:secondary];
}

- (void)closeFloatingWindow:(DPFloatingWindow *)window animated:(BOOL)animated {
    if (!window) return;
    [self.mutableFloatingWindows removeObject:window];
    [window closeAnimated:animated completion:nil];
    if (self.mutableFloatingWindows.count == 0 && !self.splitManager.isActive) {
        self.mode = DPPresentationModeNone;
    }
}

- (void)dismissAllAnimated:(BOOL)animated {
    NSArray *copy = [self.mutableFloatingWindows copy];
    for (DPFloatingWindow *w in copy) {
        [self closeFloatingWindow:w animated:animated];
    }
    if (self.splitManager.isActive) {
        [self.splitManager dismissAnimated:animated completion:nil];
        self.splitManager = nil;
    }
    self.mode = DPPresentationModeNone;
}

- (void)handleOrientationChange {
    UIView *parent = self.overlayRoot.superview;
    if (parent) {
        self.overlayRoot.frame = parent.bounds;
    }
    if (self.splitManager.isActive) {
        [self.splitManager layoutForBounds:self.overlayRoot.bounds];
    }
    // Keep floating windows on-screen
    for (DPFloatingWindow *w in self.mutableFloatingWindows) {
        CGRect f = w.frame;
        CGRect bounds = self.overlayRoot.bounds;
        if (CGRectGetMaxX(f) < 40) f.origin.x = 0;
        if (CGRectGetMaxY(f) < 40) f.origin.y = 0;
        if (f.origin.x > bounds.size.width - 40) f.origin.x = bounds.size.width - f.size.width;
        if (f.origin.y > bounds.size.height - 40) f.origin.y = bounds.size.height - 40;
        w.frame = f;
    }
}

#pragma mark - Helpers

- (CGRect)initialFloatingFrameInBounds:(CGRect)bounds {
    CGRect last = [DPSettings shared].lastFloatingFrame;
    if (!CGRectIsNull(last) && !CGRectIsEmpty(last)) {
        // Clamp into current bounds
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
    // Stagger if multiple windows
    CGFloat stagger = self.mutableFloatingWindows.count * 24.0;
    return CGRectMake(x - stagger, y + stagger, size.width, size.height);
}

- (NSString *)foregroundBundleID {
    // SBApplicationController / SpringBoard frontmost
    Class SBAppController = NSClassFromString(@"SBApplicationController");
    if (SBAppController) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id controller = [SBAppController performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
        // -frontmostApplication / -_frontMostApplication
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

- (void)ensureTargetAppLaunched:(NSString *)bundleID {
    // Best-effort launch so a scene can exist to host
    Class LSApplicationWorkspace = NSClassFromString(@"LSApplicationWorkspace");
    if (!LSApplicationWorkspace) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    id workspace = [LSApplicationWorkspace performSelector:@selector(defaultWorkspace)];
#pragma clang diagnostic pop
    if ([workspace respondsToSelector:NSSelectorFromString(@"openApplicationWithBundleID:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [workspace performSelector:NSSelectorFromString(@"openApplicationWithBundleID:") withObject:bundleID];
#pragma clang diagnostic pop
    }
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
