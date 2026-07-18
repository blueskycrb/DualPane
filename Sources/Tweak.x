#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DPSettings.h"
#import "DPWindowManager.h"
#import "DPGestureController.h"

// ── 主屏幕图标工具 ─────────────────────────────────────────────────────────

static char kDPIconSwipeKey;

static NSString *DPBundleIDFromIcon(id icon) {
    if (!icon) return nil;
    NSArray *keys = @[@"applicationBundleID", @"bundleIdentifier", @"applicationBundleIdentifier"];
    for (NSString *key in keys) {
        @try {
            id val = [icon valueForKey:key];
            if ([val isKindOfClass:[NSString class]] && [val length]) return val;
        } @catch (__unused NSException *e) {}
    }
    if ([icon respondsToSelector:@selector(applicationBundleID)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id val = [icon performSelector:@selector(applicationBundleID)];
#pragma clang diagnostic pop
        if ([val isKindOfClass:[NSString class]] && [val length]) return val;
    }
    @try {
        if ([[icon valueForKey:@"isFolderIcon"] boolValue]) return nil;
    } @catch (__unused NSException *e) {}
    return nil;
}

static NSString *DPBundleIDFromIconView(id iconView) {
    if (!iconView) return nil;
    id icon = nil;
    @try { icon = [iconView valueForKey:@"icon"]; } @catch (__unused NSException *e) {}
    return DPBundleIDFromIcon(icon);
}

static NSString *DPBundleIDFromObject(id obj) {
    if (!obj) return nil;
    if ([obj isKindOfClass:[NSString class]]) return (NSString *)obj;
    NSArray *keys = @[@"bundleIdentifier", @"bundleID", @"applicationBundleIdentifier",
                      @"_bundleIdentifier", @"applicationIdentifier"];
    for (NSString *key in keys) {
        @try {
            id val = [obj valueForKey:key];
            if ([val isKindOfClass:[NSString class]] && [val length]) return val;
        } @catch (__unused NSException *e) {}
    }
    // SBApplication
    @try {
        id app = [obj valueForKey:@"application"];
        if (app && app != obj) return DPBundleIDFromObject(app);
    } @catch (__unused NSException *e) {}
    @try {
        id app = [obj valueForKey:@"sbApplication"];
        if (app) return DPBundleIDFromObject(app);
    } @catch (__unused NSException *e) {}
    return nil;
}

static void DPHaptic(void) {
    if (![DPSettings shared].hapticFeedback) return;
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [g impactOccurred];
}

static void DPGoHomeIfNeeded(void) {
    // 若系统已经把托管 App 切到前台，立刻回桌面，保留我们的顶层悬浮/分屏窗
    dispatch_async(dispatch_get_main_queue(), ^{
        Class SBUIController = NSClassFromString(@"SBUIController");
        if (!SBUIController) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id ui = [SBUIController performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
        if ([ui respondsToSelector:NSSelectorFromString(@"clickedMenuButton")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [ui performSelector:NSSelectorFromString(@"clickedMenuButton")];
#pragma clang diagnostic pop
        } else if ([ui respondsToSelector:NSSelectorFromString(@"handleHomeButtonSinglePressUp")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [ui performSelector:NSSelectorFromString(@"handleHomeButtonSinglePressUp")];
#pragma clang diagnostic pop
        }
        [[DPWindowManager shared] bringOverlayToFront];
    });
}

// 上滑手势
@interface DPIconGestureTarget : NSObject
@property (nonatomic, weak) UIView *iconView;
- (void)handleSwipe:(UISwipeGestureRecognizer *)gr;
@end

@implementation DPIconGestureTarget
- (void)handleSwipe:(UISwipeGestureRecognizer *)gr {
    if (gr.state != UIGestureRecognizerStateRecognized) return;
    if (![DPSettings shared].isEnabled) return;
    if (![[DPSettings shared] isGestureEnabled:DPActivationGestureIconSwipeUp]) return;
    NSString *bid = DPBundleIDFromIconView(self.iconView);
    if (!bid.length) return;
    DPHaptic();
    DPDefaultMode dm = [DPSettings shared].defaultMode;
    DPPresentationMode mode = DPPresentationModeSplit;
    if (dm == DPDefaultModeFloating) mode = DPPresentationModeFloating;
    else if (dm == DPDefaultModeAsk) mode = DPPresentationModeNone;
    [[DPWindowManager shared] handleActivationForBundleID:bid preferredMode:mode];
}
@end

static void DPAttachIconSwipe(UIView *iconView) {
    if (!iconView) return;
    if (![[DPSettings shared] isGestureEnabled:DPActivationGestureIconSwipeUp]) return;
    if (objc_getAssociatedObject(iconView, &kDPIconSwipeKey)) return;

    DPIconGestureTarget *target = [[DPIconGestureTarget alloc] init];
    target.iconView = iconView;
    UISwipeGestureRecognizer *swipe = [[UISwipeGestureRecognizer alloc] initWithTarget:target action:@selector(handleSwipe:)];
    swipe.direction = UISwipeGestureRecognizerDirectionUp;
    swipe.numberOfTouchesRequired = 1;
    swipe.cancelsTouchesInView = YES; // 上滑成功后不要再落到系统点击
    swipe.delaysTouchesBegan = NO;
    [iconView addGestureRecognizer:swipe];
    objc_setAssociatedObject(iconView, &kDPIconSwipeKey, target, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static id DPMakeShortcutItem(NSString *type, NSString *title, NSString *systemImage) {
    Class ItemClass = NSClassFromString(@"SBSApplicationShortcutItem");
    if (!ItemClass) return nil;
    id item = [[ItemClass alloc] init];
    @try { [item setValue:type forKey:@"type"]; } @catch (__unused NSException *e) {}
    @try { [item setValue:title forKey:@"localizedTitle"]; } @catch (__unused NSException *e) {}
    @try { [item setValue:@YES forKey:@"iconIsTemplate"]; } @catch (__unused NSException *e) {}

    Class IconClass = NSClassFromString(@"SBSApplicationShortcutSystemIcon");
    if (IconClass && systemImage.length) {
        id iconObj = nil;
        if ([IconClass respondsToSelector:NSSelectorFromString(@"iconWithSystemImageName:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            iconObj = [IconClass performSelector:NSSelectorFromString(@"iconWithSystemImageName:") withObject:systemImage];
#pragma clang diagnostic pop
        }
        if (iconObj) {
            @try { [item setValue:iconObj forKey:@"icon"]; } @catch (__unused NSException *e) {}
        }
    }
    return item;
}

static BOOL DPHandleShortcutType(NSString *type, NSString *bundleID, id iconView) {
    if (![type isKindOfClass:[NSString class]]) return NO;
    DPPresentationMode mode = DPPresentationModeNone;
    if ([type isEqualToString:@"com.dualpane.action.split"]) {
        mode = DPPresentationModeSplit;
    } else if ([type isEqualToString:@"com.dualpane.action.float"]) {
        mode = DPPresentationModeFloating;
    } else {
        return NO;
    }
    NSString *bid = bundleID;
    if (!bid.length) bid = DPBundleIDFromIconView(iconView);
    if (!bid.length) return YES;
    DPHaptic();
    [[DPWindowManager shared] handleActivationForBundleID:bid preferredMode:mode];
    return YES;
}

// ── SpringBoard 启动：装独立顶层窗 ─────────────────────────────────────────

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![DPSettings shared].isEnabled) return;
        [[DPWindowManager shared] install];
        // 手势仍挂在主 window，作为备用
        UIWindow *keyWindow = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        keyWindow = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
        if (keyWindow) {
            [[DPGestureController shared] installOnView:keyWindow];
        }
    });
}

%end

// ── 拦截：托管中的 App 禁止切到全屏前台 ───────────────────────────────────

%hook SBMainWorkspace

// iOS 15/16 常见事务执行入口（签名因版本略有差异，多写几个）
- (BOOL)executeTransitionRequest:(id)request {
    NSString *bid = DPBundleIDFromObject(request);
    if (!bid.length) {
        @try {
            id app = [request valueForKey:@"application"];
            bid = DPBundleIDFromObject(app);
        } @catch (__unused NSException *e) {}
        @try {
            id dest = [request valueForKey:@"destinationApplication"];
            if (!bid) bid = DPBundleIDFromObject(dest);
        } @catch (__unused NSException *e) {}
        @try {
            id info = [request valueForKey:@"applicationSceneEntity"];
            if (!bid) bid = DPBundleIDFromObject(info);
            if (!bid) {
                id app = [info valueForKey:@"application"];
                bid = DPBundleIDFromObject(app);
            }
        } @catch (__unused NSException *e) {}
    }
    if ([[DPWindowManager shared] shouldSuppressFullscreenForBundleID:bid]) {
        NSLog(@"[DualPane] 拦截全屏切换: %@", bid);
        [[DPWindowManager shared] bringOverlayToFront];
        return NO;
    }
    BOOL ok = %orig;
    // 若还是被切过去了，补救回桌面
    if (ok && [[DPWindowManager shared] shouldSuppressFullscreenForBundleID:bid]) {
        DPGoHomeIfNeeded();
    }
    return ok;
}

- (void)noteInterfaceOrientationChanged:(long long)orientation duration:(double)duration {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DPWindowManager shared] handleOrientationChange];
    });
}

%end

// 另一种事务入口
%hook SBWorkspaceTransaction

- (void)begin {
    id selfObj = (id)self;
    NSString *bid = nil;
    @try { bid = DPBundleIDFromObject([selfObj valueForKey:@"application"]); } @catch (__unused NSException *e) {}
    @try {
        if (!bid) {
            id req = [selfObj valueForKey:@"transitionRequest"];
            bid = DPBundleIDFromObject(req);
            if (!bid) bid = DPBundleIDFromObject([req valueForKey:@"application"]);
        }
    } @catch (__unused NSException *e) {}
    if ([[DPWindowManager shared] shouldSuppressFullscreenForBundleID:bid]) {
        NSLog(@"[DualPane] 拦截 WorkspaceTransaction: %@", bid);
        return;
    }
    %orig;
}

%end

// 前台 App 变化时：如果切到了我们托管的 App，强制回桌面并置顶悬浮窗
%hook SpringBoard

- (void)frontDisplayDidChange:(id)arg {
    %orig;
    NSString *bid = DPBundleIDFromObject(arg);
    if ([[DPWindowManager shared] shouldSuppressFullscreenForBundleID:bid]) {
        NSLog(@"[DualPane] frontDisplay 补救回桌面: %@", bid);
        DPGoHomeIfNeeded();
    } else {
        // 切到别的 App 时也保持置顶窗
        if ([DPWindowManager shared].mode != DPPresentationModeNone) {
            [[DPWindowManager shared] bringOverlayToFront];
        }
    }
}

%end

// ── 图标：上滑 + 长按菜单 ─────────────────────────────────────────────────

%hook SBIconView

- (void)didMoveToWindow {
    %orig;
    UIView *view = (UIView *)self;
    if (view.window) {
        DPAttachIconSwipe(view);
    }
}

- (void)setIcon:(id)icon {
    %orig;
    DPAttachIconSwipe((UIView *)self);
}

- (id)applicationShortcutItems {
    NSArray *items = %orig;
    if (![DPSettings shared].isEnabled) return items;
    if (![[DPSettings shared] isGestureEnabled:DPActivationGestureIconLongPress]) return items;

    NSString *bid = DPBundleIDFromIconView((id)self);
    if (!bid.length) return items;

    id splitItem = DPMakeShortcutItem(@"com.dualpane.action.split", @"分屏打开", @"rectangle.split.2x1");
    id floatItem = DPMakeShortcutItem(@"com.dualpane.action.float", @"悬浮窗打开", @"rectangle.on.rectangle");
    if (!splitItem && !floatItem) return items;

    NSMutableArray *out = items ? [items mutableCopy] : [NSMutableArray array];
    if (floatItem) [out insertObject:floatItem atIndex:0];
    if (splitItem) [out insertObject:splitItem atIndex:0];
    return out;
}

- (void)activateShortcut:(id)item withBundleIdentifier:(NSString *)bundleID forIconView:(id)iconView {
    NSString *type = nil;
    @try { type = [item valueForKey:@"type"]; } @catch (__unused NSException *e) {}
    if (DPHandleShortcutType(type, bundleID, iconView ?: (id)self)) {
        return; // 绝不 %orig，防止系统再全屏打开
    }
    %orig;
}

%end

%hook SBIconController

- (void)appIconView:(id)iconView activateShortcut:(id)item withBundleIdentifier:(NSString *)bundleID {
    NSString *type = nil;
    @try { type = [item valueForKey:@"type"]; } @catch (__unused NSException *e) {}
    if (DPHandleShortcutType(type, bundleID, iconView)) {
        return;
    }
    %orig;
}

%end

%hook SBHIconManager

- (void)iconView:(id)iconView activateShortcut:(id)item withBundleIdentifier:(NSString *)bundleID {
    NSString *type = nil;
    @try { type = [item valueForKey:@"type"]; } @catch (__unused NSException *e) {}
    if (DPHandleShortcutType(type, bundleID, iconView)) {
        return;
    }
    %orig;
}

%end

%ctor {
    @autoreleasepool {
        [DPSettings shared];
        NSLog(@"[DualPane] 已加载 — 启用=%d", [DPSettings shared].isEnabled);
    }
}
