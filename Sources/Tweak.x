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

static void DPHaptic(void) {
    if (![DPSettings shared].hapticFeedback) return;
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium];
    [g impactOccurred];
}

// 上滑手势 target（挂在 iconView 关联对象上，避免 category 冲突）
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
    // 图标上滑默认直接分屏打开该 App（更容易理解）；若默认模式是悬浮/询问则尊重设置
    DPDefaultMode dm = [DPSettings shared].defaultMode;
    if (dm == DPDefaultModeFloating) {
        [[DPWindowManager shared] handleActivationForBundleID:bid preferredMode:DPPresentationModeFloating];
    } else if (dm == DPDefaultModeAsk) {
        [[DPWindowManager shared] handleActivationForBundleID:bid preferredMode:DPPresentationModeNone];
    } else {
        [[DPWindowManager shared] handleActivationForBundleID:bid preferredMode:DPPresentationModeSplit];
    }
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
    // 允许与系统手势同时识别，尽量不挡单击打开
    swipe.cancelsTouchesInView = NO;
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
    if (!bid.length) return YES; // 吞掉未知，避免误启动
    DPHaptic();
    [[DPWindowManager shared] handleActivationForBundleID:bid preferredMode:mode];
    return YES;
}

// ── SpringBoard 启动 ───────────────────────────────────────────────────────

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (![DPSettings shared].isEnabled) return;

        UIWindow *keyWindow = nil;
        if (@available(iOS 13.0, *)) {
            for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
                if (scene.activationState != UISceneActivationStateForegroundActive) continue;
                if (![scene isKindOfClass:[UIWindowScene class]]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow) { keyWindow = w; break; }
                }
                if (keyWindow) break;
            }
        }
        if (!keyWindow) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            keyWindow = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
        }
        if (!keyWindow) {
            Class SBClass = NSClassFromString(@"SpringBoard");
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id sb = [SBClass performSelector:@selector(sharedApplication)];
#pragma clang diagnostic pop
            if ([sb respondsToSelector:@selector(keyWindow)]) {
                keyWindow = [sb valueForKey:@"keyWindow"];
            }
        }
        if (!keyWindow) return;

        [[DPWindowManager shared] installInWindow:keyWindow];
        [[DPGestureController shared] installOnView:keyWindow];
    });
}

%end

// ── 图标：上滑 + 长按菜单 ─────────────────────────────────────────────────

%hook SBIconView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        DPAttachIconSwipe((UIView *)self);
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

    NSString *bid = DPBundleIDFromIconView(self);
    if (!bid.length) return items;

    id splitItem = DPMakeShortcutItem(@"com.dualpane.action.split", @"分屏打开", @"rectangle.split.2x1");
    id floatItem = DPMakeShortcutItem(@"com.dualpane.action.float", @"悬浮窗打开", @"rectangle.on.rectangle");
    if (!splitItem && !floatItem) return items;

    NSMutableArray *out = items ? [items mutableCopy] : [NSMutableArray array];
    if (floatItem) [out insertObject:floatItem atIndex:0];
    if (splitItem) [out insertObject:splitItem atIndex:0];
    return out;
}

// iOS 14–16 常见入口
- (void)activateShortcut:(id)item withBundleIdentifier:(NSString *)bundleID forIconView:(id)iconView {
    NSString *type = nil;
    @try { type = [item valueForKey:@"type"]; } @catch (__unused NSException *e) {}
    if (DPHandleShortcutType(type, bundleID, iconView ?: self)) {
        return;
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

// 部分 16.x 路径
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

%hook SBMainWorkspace

- (void)noteInterfaceOrientationChanged:(long long)orientation duration:(double)duration {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DPWindowManager shared] handleOrientationChange];
    });
}

%end

%ctor {
    @autoreleasepool {
        [DPSettings shared];
        NSLog(@"[DualPane] 已加载 — 启用=%d", [DPSettings shared].isEnabled);
    }
}
