#import "vendor/include/Preferences/PSListController.h"
#import "vendor/include/Preferences/PSSpecifier.h"
#import <spawn.h>
#import <notify.h>

static BOOL DPValueForGestureKey(NSString *key, BOOL fallback) {
    CFPropertyListRef val = CFPreferencesCopyAppValue((__bridge CFStringRef)key, CFSTR("com.dualpane.tweak"));
    if (!val) return fallback;
    BOOL result = fallback;
    if (CFGetTypeID(val) == CFBooleanGetTypeID()) {
        result = CFBooleanGetValue(val);
    } else if ([(__bridge id)val respondsToSelector:@selector(boolValue)]) {
        result = [(__bridge id)val boolValue];
    }
    CFRelease(val);
    return result;
}

@interface DPRootListController : PSListController
@end

@implementation DPRootListController

- (NSArray *)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"DualPane";
}

- (void)respring {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Respring"
                                                                   message:@"Respring SpringBoard now?\n立即注销 SpringBoard？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Respring" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        pid_t pid;
        const char *args[] = { "sbreload", NULL };
        if (posix_spawn(&pid, "/var/jb/usr/bin/sbreload", NULL, NULL, (char *const *)args, NULL) != 0) {
            const char *args2[] = { "killall", "-9", "SpringBoard", NULL };
            posix_spawn(&pid, "/var/jb/usr/bin/killall", NULL, NULL, (char *const *)args2, NULL);
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetSettings {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reset Settings"
                                                                   message:@"Restore all DualPane preferences to defaults?\n恢复所有 DualPane 设置为默认值？"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        (void)action;
        NSString *domain = @"com.dualpane.tweak";
        CFArrayRef keys = CFPreferencesCopyKeyList((__bridge CFStringRef)domain,
                                                   kCFPreferencesCurrentUser,
                                                   kCFPreferencesAnyHost);
        if (keys) {
            CFPreferencesSetMultiple(NULL, keys,
                                     (__bridge CFStringRef)domain,
                                     kCFPreferencesCurrentUser,
                                     kCFPreferencesAnyHost);
            CFRelease(keys);
        }
        CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
        notify_post("com.dualpane.tweak/settings.changed");
        [self reloadSpecifiers];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)openGitHub {
    NSURL *url = [NSURL URLWithString:@"https://github.com/blueskycrb/DualPane"];
    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    NSString *key = [specifier propertyForKey:@"key"];
    NSArray *gestureKeys = @[@"gestureEdgeSwipe", @"gestureThreeFinger", @"gestureStatusBar", @"gestureHomeIndicator"];
    if ([gestureKeys containsObject:key]) {
        BOOL edge = DPValueForGestureKey(@"gestureEdgeSwipe", YES);
        BOOL three = DPValueForGestureKey(@"gestureThreeFinger", YES);
        BOOL status = DPValueForGestureKey(@"gestureStatusBar", NO);
        BOOL home = DPValueForGestureKey(@"gestureHomeIndicator", NO);

        if ([key isEqualToString:@"gestureEdgeSwipe"]) edge = [value boolValue];
        if ([key isEqualToString:@"gestureThreeFinger"]) three = [value boolValue];
        if ([key isEqualToString:@"gestureStatusBar"]) status = [value boolValue];
        if ([key isEqualToString:@"gestureHomeIndicator"]) home = [value boolValue];

        NSMutableArray *enabled = [NSMutableArray array];
        if (edge) [enabled addObject:@0];
        if (three) [enabled addObject:@1];
        if (status) [enabled addObject:@2];
        if (home) [enabled addObject:@3];

        CFPreferencesSetAppValue(CFSTR("enabledGestures"),
                                 (__bridge CFPropertyListRef)enabled,
                                 CFSTR("com.dualpane.tweak"));
        CFPreferencesAppSynchronize(CFSTR("com.dualpane.tweak"));
        notify_post("com.dualpane.tweak/settings.changed");
    }
}

@end
