#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import "DPSettings.h"
#import "DPWindowManager.h"
#import "DPGestureController.h"

// ── SpringBoard hooks ──────────────────────────────────────────────────────

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;

    // Defer a bit so keyWindow / UI is ready
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
        // SB fallback
        if (!keyWindow) {
            Class SBClass = NSClassFromString(@"SpringBoard");
            id sb = [SBClass performSelector:@selector(sharedApplication)];
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

// Keep floating / split chrome laid out across orientation changes
%hook SBMainWorkspace

- (void)noteInterfaceOrientationChanged:(long long)orientation duration:(double)duration {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[DPWindowManager shared] handleOrientationChange];
    });
}

%end

// Optional: also re-layout when the active interface orientation animates
%hook SBSceneManager

- (void)scene:(id)scene didUpdateClientSettingsWithDiff:(id)diff oldClientSettings:(id)old transitionContext:(id)ctx {
    %orig;
    // no-op placeholder for future scene-sync hooks
}

%end

// ── Constructor ────────────────────────────────────────────────────────────

%ctor {
    @autoreleasepool {
        // Ensure settings are loaded early
        [DPSettings shared];

        NSLog(@"[DualPane] loaded — enabled=%d", [DPSettings shared].isEnabled);
    }
}
