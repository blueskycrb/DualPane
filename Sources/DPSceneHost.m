#import "DPSceneHost.h"
#import <objc/runtime.h>
#import <objc/message.h>

@interface DPSceneHost ()
@property (nonatomic, copy, readwrite) NSString *bundleID;
@property (nonatomic, strong, readwrite) UIView *view;
@property (nonatomic, assign, readwrite, getter=isLive) BOOL live;
@property (nonatomic, copy, readwrite, nullable) NSString *statusText;
@property (nonatomic, strong, nullable) id scene;
@property (nonatomic, strong, nullable) id sceneHandle;
@property (nonatomic, strong, nullable) UIView *hostView;
@property (nonatomic, strong, nullable) UIView *placeholder;
@property (nonatomic, strong, nullable) UIImageView *iconView;
@property (nonatomic, strong, nullable) UIImageView *snapshotView;
@property (nonatomic, strong, nullable) UILabel *nameLabel;
@property (nonatomic, strong, nullable) UILabel *hintLabel;
@property (nonatomic, strong, nullable) NSString *requesterToken;
@property (nonatomic, assign) NSInteger attemptCount;
@property (nonatomic, assign) BOOL attaching;
@property (nonatomic, assign) BOOL snapshotAttempted;
@property (nonatomic, assign) BOOL sceneSettingsUpdateScheduled;
@property (nonatomic, assign) NSUInteger sceneSettingsGeneration;
@property (nonatomic, assign) CGSize lastCommittedSceneSize;
@property (nonatomic, strong, nullable) id retainedSceneController; // 防止 VC 被释放
@end

@implementation DPSceneHost

+ (BOOL)isSceneHostingAvailable {
    return NSClassFromString(@"FBSceneManager") != Nil
        || NSClassFromString(@"SBApplicationController") != Nil
        || NSClassFromString(@"SBMainDisplaySceneManager") != Nil;
}

- (instancetype)initWithBundleID:(NSString *)bundleID {
    self = [super init];
    if (self) {
        _bundleID = [bundleID copy];
        _view = [[UIView alloc] initWithFrame:CGRectZero];
        _view.backgroundColor = [UIColor colorWithRed:0.07 green:0.08 blue:0.10 alpha:1.0];
        _view.clipsToBounds = YES;
        _live = NO;
        _attaching = NO;
        _requesterToken = [NSString stringWithFormat:@"DualPane.%@.%p",
                           bundleID ?: @"app", self];
        _attemptCount = 0;
        _lastCommittedSceneSize = CGSizeZero;
        [self buildPlaceholder];
        // 延迟到有 frame 后再挂，避免 0x0 尺寸创建坏的 host view
        dispatch_async(dispatch_get_main_queue(), ^{
            [self attemptLiveSceneHost];
        });
    }
    return self;
}

#pragma mark - Lookup

- (id)sbApplication {
    Class cls = NSClassFromString(@"SBApplicationController");
    if (!cls) return nil;
    id controller = nil;
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        controller = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
    } else if ([cls respondsToSelector:@selector(sharedInstanceIfExists)]) {
        controller = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstanceIfExists));
    }
    if (!controller) return nil;

    for (NSString *name in @[@"applicationWithBundleIdentifier:",
                             @"applicationWithBundleID:"]) {
        SEL sel = NSSelectorFromString(name);
        if ([controller respondsToSelector:sel]) {
            id app = ((id (*)(id, SEL, id))objc_msgSend)(controller, sel, self.bundleID);
            if (app) return app;
        }
    }
    return nil;
}

- (id)mainSceneFromApplication:(id)app {
    if (!app) return nil;
    for (NSString *name in @[@"mainScene", @"_mainScene", @"primaryScene"]) {
        @try {
            SEL sel = NSSelectorFromString(name);
            id scene = nil;
            if ([app respondsToSelector:sel]) {
                scene = ((id (*)(id, SEL))objc_msgSend)(app, sel);
            } else {
                scene = [app valueForKey:name];
            }
            if (scene) return scene;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

- (id)fbSceneManager {
    Class cls = NSClassFromString(@"FBSceneManager");
    if (!cls) return nil;
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        return ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
    }
    return nil;
}

- (id)sbMainDisplaySceneManager {
    for (NSString *cn in @[@"SBMainDisplaySceneManager",
                           @"SBSceneManagerCoordinator",
                           @"SBSceneManager"]) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        if ([cls respondsToSelector:@selector(sharedInstance)]) {
            id obj = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
            if ([cn isEqualToString:@"SBSceneManagerCoordinator"] && obj) {
                @try {
                    id m = [obj valueForKey:@"mainDisplaySceneManager"];
                    if (m) return m;
                } @catch (__unused NSException *e) {}
            }
            if (obj) return obj;
        }
        if ([cls respondsToSelector:@selector(mainDisplaySceneManager)]) {
            id obj = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(mainDisplaySceneManager));
            if (obj) return obj;
        }
    }
    return nil;
}

- (BOOL)string:(NSString *)s matchesBundleID:(NSString *)bid {
    if (![s isKindOfClass:[NSString class]] || !bid.length) return NO;
    if ([s isEqualToString:bid]) return YES;
    // scene id 常见形态: sceneID:com.xxx-default / com.xxx-default
    if ([s containsString:bid]) return YES;
    return NO;
}

- (BOOL)object:(id)obj matchesBundleID:(NSString *)bid {
    if (!obj || !bid.length) return NO;

    NSArray *keys = @[@"identifier", @"sceneIdentifier", @"persistentIdentifier",
                      @"clientIdentifier", @"bundleIdentifier",
                      @"applicationBundleIdentifier", @"_identifier"];
    for (NSString *key in keys) {
        @try {
            id val = [obj valueForKey:key];
            if ([self string:val matchesBundleID:bid]) return YES;
        } @catch (__unused NSException *e) {}
    }

    for (NSString *key in @[@"application", @"clientProcess", @"definition",
                             @"sceneIdentity", @"identity"]) {
        @try {
            id nested = [obj valueForKey:key];
            if (!nested || nested == obj) continue;
            for (NSString *nk in @[@"bundleIdentifier", @"identifier",
                                    @"applicationBundleIdentifier",
                                    @"workspaceIdentifier"]) {
                @try {
                    id val = [nested valueForKey:nk];
                    if ([self string:val matchesBundleID:bid]) return YES;
                } @catch (__unused NSException *e) {}
            }
            // definition.identity
            @try {
                id identity = [nested valueForKey:@"identity"];
                NSString *ws = [identity valueForKey:@"workspaceIdentifier"];
                if ([self string:ws matchesBundleID:bid]) return YES;
            } @catch (__unused NSException *e) {}
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

- (NSArray *)arrayFromCollection:(id)result {
    if ([result isKindOfClass:[NSSet class]]) return [result allObjects];
    if ([result isKindOfClass:[NSArray class]]) return result;
    if ([result isKindOfClass:[NSDictionary class]]) return [result allValues];
    return @[];
}

- (NSArray *)allScenesFromManager:(id)manager {
    if (!manager) return @[];
    NSMutableArray *out = [NSMutableArray array];

    for (NSString *name in @[@"scenes", @"_scenes"]) {
        SEL sel = NSSelectorFromString(name);
        if (![manager respondsToSelector:sel]) continue;
        id result = ((id (*)(id, SEL))objc_msgSend)(manager, sel);
        [out addObjectsFromArray:[self arrayFromCollection:result]];
    }

    // scenesIncludingInternal:
    SEL inc = NSSelectorFromString(@"scenesIncludingInternal:");
    if ([manager respondsToSelector:inc]) {
        NSMethodSignature *sig = [manager methodSignatureForSelector:inc];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = manager;
            inv.selector = inc;
            BOOL yes = YES;
            [inv setArgument:&yes atIndex:2];
            [inv invoke];
            __unsafe_unretained id tmp = nil;
            [inv getReturnValue:&tmp];
            [out addObjectsFromArray:[self arrayFromCollection:tmp]];
        }
    }

    for (NSString *name in @[@"scenesByID", @"_scenesByID", @"sceneMap"]) {
        SEL sel = NSSelectorFromString(name);
        if (![manager respondsToSelector:sel]) continue;
        id map = ((id (*)(id, SEL))objc_msgSend)(manager, sel);
        [out addObjectsFromArray:[self arrayFromCollection:map]];
    }
    return out;
}

#pragma mark - Scene handle / FBScene

- (id)sceneHandleForBundleID {
    id app = [self sbApplication];

    // 1) SBApplication 上直接取
    if (app) {
        for (NSString *key in @[@"mainSceneHandle", @"_mainSceneHandle",
                                 @"sceneHandle", @"mainScene", @"_mainScene",
                                 @"primaryScene"]) {
            @try {
                id val = nil;
                SEL sel = NSSelectorFromString(key);
                if ([app respondsToSelector:sel]) {
                    val = ((id (*)(id, SEL))objc_msgSend)(app, sel);
                } else {
                    val = [app valueForKey:key];
                }
                if (val) return val;
            } @catch (__unused NSException *e) {}
        }

        @try {
            id scenes = nil;
            if ([app respondsToSelector:@selector(scenes)]) {
                scenes = ((id (*)(id, SEL))objc_msgSend)(app, @selector(scenes));
            } else {
                scenes = [app valueForKey:@"scenes"];
            }
            NSArray *arr = [self arrayFromCollection:scenes];
            for (id s in arr) {
                if ([self object:s matchesBundleID:self.bundleID]) return s;
            }
            if (arr.count) return arr.firstObject;
        } @catch (__unused NSException *e) {}
    }

    // 2) SBMainDisplaySceneManager 的 external handles
    id sbm = [self sbMainDisplaySceneManager];
    if (sbm) {
        for (NSString *name in @[@"externalForegroundApplicationSceneHandles",
                                 @"externalApplicationSceneHandles",
                                 @"applicationSceneHandles",
                                 @"sceneHandles",
                                 @"_externalForegroundApplicationSceneHandles",
                                 @"_externalApplicationSceneHandles"]) {
            @try {
                id set = nil;
                SEL sel = NSSelectorFromString(name);
                if ([sbm respondsToSelector:sel]) {
                    set = ((id (*)(id, SEL))objc_msgSend)(sbm, sel);
                } else {
                    set = [sbm valueForKey:name];
                }
                for (id handle in [self arrayFromCollection:set]) {
                    if ([self object:handle matchesBundleID:self.bundleID]) return handle;
                    @try {
                        id a = [handle valueForKey:@"application"];
                        NSString *bid = [a valueForKey:@"bundleIdentifier"];
                        if ([bid isEqualToString:self.bundleID]) return handle;
                    } @catch (__unused NSException *e) {}
                }
            } @catch (__unused NSException *e) {}
        }

        // sceneHandleForIdentifier: / existingSceneHandleForPersistenceIdentifier:
        for (NSString *name in @[@"sceneHandleForIdentifier:",
                                 @"existingSceneHandleForPersistenceIdentifier:",
                                 @"sceneHandleForSceneIdentity:"]) {
            SEL sel = NSSelectorFromString(name);
            if (![sbm respondsToSelector:sel]) continue;
            // 尝试常见 scene id 形态
            NSArray *candidates = @[
                self.bundleID,
                [NSString stringWithFormat:@"sceneID:%@-default", self.bundleID],
                [NSString stringWithFormat:@"%@-default", self.bundleID],
            ];
            for (NSString *cid in candidates) {
                @try {
                    id h = ((id (*)(id, SEL, id))objc_msgSend)(sbm, sel, cid);
                    if (h) return h;
                } @catch (__unused NSException *e) {}
            }
        }
    }
    return nil;
}

- (id)fbSceneFromHandle:(id)handle {
    if (!handle) return nil;
    for (NSString *name in @[@"sceneIfExists", @"scene", @"fbScene", @"_scene"]) {
        @try {
            SEL sel = NSSelectorFromString(name);
            id s = nil;
            if ([handle respondsToSelector:sel]) {
                s = ((id (*)(id, SEL))objc_msgSend)(handle, sel);
            } else {
                s = [handle valueForKey:name];
            }
            if (s) return s;
        } @catch (__unused NSException *e) {}
    }
    NSString *cn = NSStringFromClass([handle class]);
    if ([cn containsString:@"FBScene"] && ![cn containsString:@"Handle"] &&
        ![cn containsString:@"Manager"] && ![cn containsString:@"Host"]) {
        return handle;
    }
    return nil;
}

- (id)findFBScene {
    id appScene = [self mainSceneFromApplication:[self sbApplication]];
    if (appScene) {
        self.sceneHandle = appScene;
        return appScene;
    }

    id handle = [self sceneHandleForBundleID];
    self.sceneHandle = handle;
    id scene = [self fbSceneFromHandle:handle];
    if (scene) return scene;

    // 直接按 identifier 取
    id mgr = [self fbSceneManager];
    if (mgr) {
        for (NSString *name in @[@"sceneWithIdentifier:", @"sceneFromIdentifier:"]) {
            SEL sel = NSSelectorFromString(name);
            if (![mgr respondsToSelector:sel]) continue;
            NSArray *candidates = @[
                self.bundleID,
                [NSString stringWithFormat:@"sceneID:%@-default", self.bundleID],
                [NSString stringWithFormat:@"%@-default", self.bundleID],
            ];
            for (NSString *cid in candidates) {
                @try {
                    id s = ((id (*)(id, SEL, id))objc_msgSend)(mgr, sel, cid);
                    if (s) return s;
                } @catch (__unused NSException *e) {}
            }
        }

        for (id s in [self allScenesFromManager:mgr]) {
            if ([self object:s matchesBundleID:self.bundleID]) return s;
        }
    }

    id sbm = [self sbMainDisplaySceneManager];
    for (id s in [self allScenesFromManager:sbm]) {
        if ([self object:s matchesBundleID:self.bundleID]) {
            id inner = [self fbSceneFromHandle:s];
            return inner ?: s;
        }
    }
    return nil;
}

#pragma mark - Host view creation

- (UIView *)viewFromMaybeController:(id)result {
    if ([result isKindOfClass:[UIView class]]) return (UIView *)result;
    if (result && [result respondsToSelector:@selector(view)]) {
        self.retainedSceneController = result; // 强引用，避免 VC 释放带走 view
        UIView *v = ((UIView *(*)(id, SEL))objc_msgSend)(result, @selector(view));
        if ([v isKindOfClass:[UIView class]]) return v;
    }
    return nil;
}

- (UIView *)hostViewFromSceneHandle:(id)handle size:(CGSize)size {
    if (!handle) return nil;
    CGSize s = size;
    if (s.width < 2 || s.height < 2) {
        s = CGSizeMake(180, 320);
    }
    long long orientation = 1; // UIInterfaceOrientationPortrait
    NSString *req = self.requesterToken ?: @"DualPane";

    // 优先 SceneViewController（iOS 15/16 更稳）
    NSArray *vcSels = @[
        @"newSceneViewControllerForReferenceSize:orientation:hostRequester:",
        @"newSceneViewControllerForReferenceSize:",
    ];
    for (NSString *name in vcSels) {
        SEL sel = NSSelectorFromString(name);
        if (![handle respondsToSelector:sel]) continue;
        NSMethodSignature *sig = [handle methodSignatureForSelector:sel];
        if (!sig) continue;
        @try {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = handle;
            inv.selector = sel;
            [inv setArgument:&s atIndex:2];
            if (sig.numberOfArguments >= 4) {
                [inv setArgument:&orientation atIndex:3];
            }
            if (sig.numberOfArguments >= 5) {
                [inv setArgument:&req atIndex:4];
            }
            [inv invoke];
            __unsafe_unretained id result = nil;
            [inv getReturnValue:&result];
            UIView *v = [self viewFromMaybeController:result];
            if (v) {
                NSLog(@"[DualPane] %@ via %@", self.bundleID, name);
                return v;
            }
        } @catch (NSException *e) {
            NSLog(@"[DualPane] %@ 异常: %@", name, e);
        }
    }

    // newSceneViewWithReferenceSize:orientation:hostRequester:
    SEL viewSel = NSSelectorFromString(@"newSceneViewWithReferenceSize:orientation:hostRequester:");
    if ([handle respondsToSelector:viewSel]) {
        NSMethodSignature *sig = [handle methodSignatureForSelector:viewSel];
        if (sig) {
            @try {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = handle;
                inv.selector = viewSel;
                [inv setArgument:&s atIndex:2];
                [inv setArgument:&orientation atIndex:3];
                [inv setArgument:&req atIndex:4];
                [inv invoke];
                __unsafe_unretained id result = nil;
                [inv getReturnValue:&result];
                UIView *v = [self viewFromMaybeController:result];
                if (v) {
                    NSLog(@"[DualPane] newSceneViewWithReferenceSize OK %@", self.bundleID);
                    return v;
                }
            } @catch (NSException *e) {
                NSLog(@"[DualPane] newSceneView 异常: %@", e);
            }
        }
    }

    // 无 orientation 变体
    SEL viewSel2 = NSSelectorFromString(@"newSceneViewWithReferenceSize:hostRequester:");
    if ([handle respondsToSelector:viewSel2]) {
        NSMethodSignature *sig = [handle methodSignatureForSelector:viewSel2];
        if (sig) {
            @try {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = handle;
                inv.selector = viewSel2;
                [inv setArgument:&s atIndex:2];
                [inv setArgument:&req atIndex:3];
                [inv invoke];
                __unsafe_unretained id result = nil;
                [inv getReturnValue:&result];
                UIView *v = [self viewFromMaybeController:result];
                if (v) return v;
            } @catch (__unused NSException *e) {}
        }
    }
    return nil;
}

- (void)enableHostingOnManager:(id)hostManager {
    if (!hostManager) return;
    NSString *req = self.requesterToken ?: @"DualPane";

    // enableHostingForRequester:orderFront:  (经典 FBSceneHostManager)
    SEL en = NSSelectorFromString(@"enableHostingForRequester:orderFront:");
    if ([hostManager respondsToSelector:en]) {
        NSMethodSignature *sig = [hostManager methodSignatureForSelector:en];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = hostManager;
            inv.selector = en;
            [inv setArgument:&req atIndex:2];
            BOOL order = YES;
            [inv setArgument:&order atIndex:3];
            @try { [inv invoke]; } @catch (__unused NSException *e) {}
            return;
        }
    }

    // enableHostingForRequester:priority:
    en = NSSelectorFromString(@"enableHostingForRequester:priority:");
    if ([hostManager respondsToSelector:en]) {
        NSMethodSignature *sig = [hostManager methodSignatureForSelector:en];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = hostManager;
            inv.selector = en;
            [inv setArgument:&req atIndex:2];
            // FBSceneHostingPriority 常见 default/high
            NSInteger prio = 1;
            [inv setArgument:&prio atIndex:3];
            @try { [inv invoke]; } @catch (__unused NSException *e) {}
            return;
        }
    }

    // enableAndOrderFrontForRequester:
    en = NSSelectorFromString(@"enableAndOrderFrontForRequester:");
    if ([hostManager respondsToSelector:en]) {
        @try {
            ((void (*)(id, SEL, id))objc_msgSend)(hostManager, en, req);
        } @catch (__unused NSException *e) {}
    }
}

- (UIView *)invokeHostViewForRequester:(id)hostManager {
    if (!hostManager) return nil;
    NSString *req = self.requesterToken ?: @"DualPane";

    // 先 enable，再取 view —— 绝不递归
    [self enableHostingOnManager:hostManager];

    // hostViewForRequester:enableAndOrderFront:
    SEL sel = NSSelectorFromString(@"hostViewForRequester:enableAndOrderFront:");
    if ([hostManager respondsToSelector:sel]) {
        NSMethodSignature *sig = [hostManager methodSignatureForSelector:sel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = hostManager;
            inv.selector = sel;
            [inv setArgument:&req atIndex:2];
            BOOL order = YES;
            [inv setArgument:&order atIndex:3];
            @try {
                [inv invoke];
                __unsafe_unretained UIView *view = nil;
                [inv getReturnValue:&view];
                if ([view isKindOfClass:[UIView class]]) {
                    NSLog(@"[DualPane] hostViewForRequester:enableAndOrderFront OK %@", self.bundleID);
                    return view;
                }
            } @catch (NSException *e) {
                NSLog(@"[DualPane] hostViewForRequester 异常: %@", e);
            }
        }
    }

    // hostViewForRequester:
    sel = NSSelectorFromString(@"hostViewForRequester:");
    if ([hostManager respondsToSelector:sel]) {
        @try {
            UIView *view = ((id (*)(id, SEL, id))objc_msgSend)(hostManager, sel, req);
            if ([view isKindOfClass:[UIView class]]) return view;
        } @catch (__unused NSException *e) {}
    }

    // Compatibility fallbacks that still return a live host view.
    for (NSString *name in @[@"contextHostViewForRequester:",
                             @"_hostViewForRequester:"]) {
        SEL s2 = NSSelectorFromString(name);
        if (![hostManager respondsToSelector:s2]) continue;
        @try {
            UIView *view = ((id (*)(id, SEL, id))objc_msgSend)(hostManager, s2, req);
            if ([view isKindOfClass:[UIView class]]) return view;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

- (id)hostManagerFromScene:(id)scene {
    if (!scene) return nil;
    for (NSString *name in @[@"hostManager", @"contextHostManager",
                             @"_hostManager", @"_contextHostManager",
                             @"layerHostManager"]) {
        @try {
            SEL sel = NSSelectorFromString(name);
            id hm = nil;
            if ([scene respondsToSelector:sel]) {
                hm = ((id (*)(id, SEL))objc_msgSend)(scene, sel);
            } else {
                hm = [scene valueForKey:name];
            }
            if (hm) return hm;
        } @catch (__unused NSException *e) {}
    }
    // layerManager 上再取 hostManager
    @try {
        id lm = nil;
        if ([scene respondsToSelector:NSSelectorFromString(@"layerManager")]) {
            lm = ((id (*)(id, SEL))objc_msgSend)(scene, NSSelectorFromString(@"layerManager"));
        } else {
            lm = [scene valueForKey:@"layerManager"];
        }
        if (lm) {
            for (NSString *name in @[@"hostManager", @"contextHostManager", @"_hostManager"]) {
                @try {
                    id hm = [lm valueForKey:name];
                    if (hm) return hm;
                } @catch (__unused NSException *e) {}
            }
        }
    } @catch (__unused NSException *e) {}
    return nil;
}

- (UIView *)hostViewFromFBScene:(id)scene {
    if (!scene) return nil;

    id hostManager = [self hostManagerFromScene:scene];
    if (hostManager) {
        UIView *hv = [self invokeHostViewForRequester:hostManager];
        if (hv) return hv;
    }
    return nil;
}

#pragma mark - Snapshot / icon

- (UIImage *)iconImageLarge {
    id app = [self sbApplication];
    if (app) {
        for (NSString *key in @[@"iconImage", @"_iconImage"]) {
            @try {
                id img = [app valueForKey:key];
                if ([img isKindOfClass:[UIImage class]]) return img;
            } @catch (__unused NSException *e) {}
        }
        // iconImageForFormat: 0 = home screen style (best-effort)
        SEL sel = NSSelectorFromString(@"iconImageForFormat:");
        if ([app respondsToSelector:sel]) {
            @try {
                NSMethodSignature *sig = [app methodSignatureForSelector:sel];
                if (sig) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.target = app;
                    inv.selector = sel;
                    NSInteger fmt = 0;
                    [inv setArgument:&fmt atIndex:2];
                    [inv invoke];
                    __unsafe_unretained id img = nil;
                    [inv getReturnValue:&img];
                    if ([img isKindOfClass:[UIImage class]]) return img;
                }
            } @catch (__unused NSException *e) {}
        }
    }
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:@"app.fill"];
    }
    return nil;
}

- (UIImage *)snapshotImage {
    id handle = self.sceneHandle ?: [self sceneHandleForBundleID];
    if (handle) {
        for (NSString *name in @[@"snapshotView", @"sceneSnapshotView", @"_snapshotView"]) {
            @try {
                id v = nil;
                SEL sel = NSSelectorFromString(name);
                if ([handle respondsToSelector:sel]) {
                    v = ((id (*)(id, SEL))objc_msgSend)(handle, sel);
                } else {
                    v = [handle valueForKey:name];
                }
                if ([v isKindOfClass:[UIImage class]]) return v;
                if ([v isKindOfClass:[UIView class]]) {
                    UIView *vv = (UIView *)v;
                    if (vv.bounds.size.width > 1 && vv.bounds.size.height > 1) {
                        UIGraphicsBeginImageContextWithOptions(vv.bounds.size, NO, 0);
                        [vv drawViewHierarchyInRect:vv.bounds afterScreenUpdates:NO];
                        UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
                        UIGraphicsEndImageContext();
                        if (img) return img;
                    }
                }
            } @catch (__unused NSException *e) {}
        }
    }
    return [self iconImageLarge];
}

#pragma mark - Main attach

- (void)attemptLiveSceneHost {
    if (self.attaching || (self.live && self.hostView.superview == self.view)) return;
    self.attaching = YES;
    self.attemptCount += 1;

    @try {
        if ([self.bundleID isEqualToString:@"com.apple.springboard"]) {
            self.statusText = @"主屏幕";
            [self updatePlaceholderHint:@"主屏幕区域\n（右侧/下方是你选择的应用）"];
            self.placeholder.backgroundColor = [UIColor colorWithRed:0.05 green:0.06 blue:0.09 alpha:1];
            self.live = NO;
            return;
        }

        // The established path is SBApplication.mainScene.hostManager.
        // Scene-handle factories differ across iOS versions and often render blank.
        id scene = [self findFBScene];
        self.scene = scene;
        if (scene) {
            UIView *hv = [self hostViewFromFBScene:scene];
            if (hv) {
                [self attachHostView:hv scene:scene];
                self.statusText = @"已连接画面";
                return;
            }
            self.statusText = @"找到进程画面，但宿主视图创建失败";
            NSLog(@"[DualPane] scene found but no host view: %@ class=%@",
                  self.bundleID, NSStringFromClass([scene class]));
        } else {
            self.statusText = @"应用尚未在后台运行";
            NSLog(@"[DualPane] no scene for %@", self.bundleID);
        }

        [self applySnapshotFallback];
    } @finally {
        self.attaching = NO;
    }
}

- (void)attachHostView:(UIView *)hostView scene:(id)scene {
    if (!hostView) return;

    if (self.hostView == hostView && hostView.superview == self.view) {
        hostView.frame = self.view.bounds;
        self.scene = scene ?: self.scene;
        self.placeholder.hidden = YES;
        self.snapshotView.hidden = YES;
        self.live = YES;
        return;
    }

    if (self.hostView != hostView) {
        [self.hostView removeFromSuperview];
    }
    self.hostView = hostView;
    self.scene = scene;
    self.lastCommittedSceneSize = CGSizeZero;
    hostView.frame = self.view.bounds;
    hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    hostView.clipsToBounds = YES;
    [self.view addSubview:hostView];
    [self.view bringSubviewToFront:hostView];

    self.placeholder.hidden = YES;
    self.snapshotView.hidden = YES;
    self.live = YES;

    [self commitHostedFrame];
    NSLog(@"[DualPane] LIVE attach %@ view=%@", self.bundleID, NSStringFromClass([hostView class]));
}

- (void)applySnapshotFallback {
    UIImage *snap = self.snapshotView.image;
    if (!self.snapshotAttempted) {
        self.snapshotAttempted = YES;
        snap = [self snapshotImage];
    }
    if (!self.snapshotView) {
        self.snapshotView = [[UIImageView alloc] initWithFrame:self.view.bounds];
        self.snapshotView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.snapshotView.contentMode = UIViewContentModeScaleAspectFill;
        self.snapshotView.clipsToBounds = YES;
        self.snapshotView.alpha = 0.35;
        [self.view insertSubview:self.snapshotView aboveSubview:self.placeholder];
    }
    if (snap && snap != self.iconView.image) {
        self.snapshotView.image = snap;
        self.snapshotView.hidden = NO;
    } else {
        self.snapshotView.hidden = YES;
    }

    NSString *hint = nil;
    if (self.scene || self.sceneHandle) {
        hint = [NSString stringWithFormat:
                @"暂时无法嵌入实时画面\n%@\n点下方重试，或先打开该 App 再回桌面",
                self.statusText ?: @""];
    } else {
        hint = [NSString stringWithFormat:
                @"%@\n系统会先拉起应用再嵌入\n若仍失败请点「重新连接」",
                self.statusText ?: @"应用尚未在后台运行"];
    }
    [self updatePlaceholderHint:hint];
    self.placeholder.hidden = NO;
    self.live = NO;
}

#pragma mark - Placeholder UI

- (void)buildPlaceholder {
    self.placeholder = [[UIView alloc] initWithFrame:self.view.bounds];
    self.placeholder.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // 深灰，不要系统蓝——避免被看成「蓝屏」
    self.placeholder.backgroundColor = [UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:1.0];
    [self.view addSubview:self.placeholder];

    UIStackView *stack = [[UIStackView alloc] init];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 10;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.tag = 7701;
    [self.placeholder addSubview:stack];

    self.iconView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.layer.cornerRadius = 14;
    self.iconView.clipsToBounds = YES;
    self.iconView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    self.iconView.image = [self iconImageLarge];
    [stack addArrangedSubview:self.iconView];
    [self.iconView.widthAnchor constraintEqualToConstant:64].active = YES;
    [self.iconView.heightAnchor constraintEqualToConstant:64].active = YES;

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.textColor = [UIColor whiteColor];
    self.nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.nameLabel.text = [self displayNameForBundleID:self.bundleID];
    [stack addArrangedSubview:self.nameLabel];

    self.hintLabel = [[UILabel alloc] init];
    self.hintLabel.textColor = [UIColor colorWithWhite:1 alpha:0.72];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.text = @"正在连接应用画面…";
    [stack addArrangedSubview:self.hintLabel];

    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    [retry setTitle:@"重新连接画面" forState:UIControlStateNormal];
    retry.tintColor = [UIColor colorWithRed:0.45 green:0.72 blue:1.0 alpha:1.0];
    retry.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [retry addTarget:self action:@selector(retryAttach) forControlEvents:UIControlEventTouchUpInside];
    [stack addArrangedSubview:retry];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.placeholder.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.placeholder.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.placeholder.leadingAnchor constant:16],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.placeholder.trailingAnchor constant:-16],
    ]];
}

- (void)updatePlaceholderHint:(NSString *)text {
    self.hintLabel.text = text;
    self.placeholder.hidden = NO;
    if (!self.iconView.image) {
        self.iconView.image = [self iconImageLarge];
    }
    if (!self.nameLabel.text.length) {
        self.nameLabel.text = [self displayNameForBundleID:self.bundleID];
    }
}

- (NSString *)displayNameForBundleID:(NSString *)bundleID {
    if ([bundleID isEqualToString:@"com.apple.springboard"]) return @"主屏幕";
    id app = [self sbApplication];
    if (app) {
        @try {
            NSString *n = [app valueForKey:@"displayName"];
            if (n.length) return n;
        } @catch (__unused NSException *e) {}
    }
    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    if (LSApplicationProxy) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(LSApplicationProxy,
            @selector(applicationProxyForIdentifier:), bundleID);
        @try {
            NSString *name = [proxy valueForKey:@"localizedName"];
            if (name.length) return name;
        } @catch (__unused NSException *e) {}
    }
    NSString *last = [[bundleID componentsSeparatedByString:@"."] lastObject];
    return last.length ? last.capitalizedString : bundleID;
}

#pragma mark - Public

- (void)setHostedFrame:(CGRect)frame {
    if (self.view.superview) {
        self.view.frame = self.view.superview.bounds;
    } else {
        self.view.frame = frame;
    }
    self.hostView.frame = self.view.bounds;
    self.placeholder.frame = self.view.bounds;
    self.snapshotView.frame = self.view.bounds;
    if (self.live && self.scene) {
        [self scheduleSceneSettingsUpdate];
    }
}

- (void)scheduleSceneSettingsUpdate {
    if (!self.live || !self.scene || self.sceneSettingsUpdateScheduled) return;

    self.sceneSettingsUpdateScheduled = YES;
    NSUInteger generation = ++self.sceneSettingsGeneration;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self2 = weakSelf;
        if (!self2 || generation != self2.sceneSettingsGeneration) return;
        self2.sceneSettingsUpdateScheduled = NO;
        [self2 updateSceneSettingsWithSize:self2.view.bounds.size];
    });
}

- (void)commitHostedFrame {
    self.sceneSettingsGeneration += 1;
    self.sceneSettingsUpdateScheduled = NO;
    if (self.live && self.scene) {
        [self updateSceneSettingsWithSize:self.view.bounds.size];
    }
}

- (void)updateSceneSettingsWithSize:(CGSize)size {
    if (!self.scene || size.width < 1 || size.height < 1) return;
    if (CGSizeEqualToSize(size, self.lastCommittedSceneSize)) return;

    @try {
        id settings = nil;
        if ([self.scene respondsToSelector:NSSelectorFromString(@"mutableSettings")]) {
            settings = ((id (*)(id, SEL))objc_msgSend)(self.scene, NSSelectorFromString(@"mutableSettings"));
        }
        if (!settings) return;

        CGRect r = CGRectMake(0, 0, size.width, size.height);
        SEL setFrame = NSSelectorFromString(@"setFrame:");
        if ([settings respondsToSelector:setFrame]) {
            NSMethodSignature *sig = [settings methodSignatureForSelector:setFrame];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = settings;
                inv.selector = setFrame;
                [inv setArgument:&r atIndex:2];
                [inv invoke];
            }
        }

        SEL setFg = NSSelectorFromString(@"setForeground:");
        if ([settings respondsToSelector:setFg]) {
            NSMethodSignature *sig = [settings methodSignatureForSelector:setFg];
            if (sig) {
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = settings;
                inv.selector = setFg;
                BOOL yes = YES;
                [inv setArgument:&yes atIndex:2];
                [inv invoke];
            }
        }

        // 尝试提交 settings（若 API 存在）
        for (NSString *name in @[@"updateSettings:", @"_updateSettings:"]) {
            SEL sel = NSSelectorFromString(name);
            if ([self.scene respondsToSelector:sel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(self.scene, sel, settings);
                break;
            }
        }
        self.lastCommittedSceneSize = size;
    } @catch (__unused NSException *e) {}
}

- (void)setSuspended:(BOOL)suspended {
    self.view.alpha = suspended ? 0.0 : 1.0;
}

- (void)retryAttach {
    if (self.attaching) return;
    NSLog(@"[DualPane] retryAttach #%@ %@", @(self.attemptCount + 1), self.bundleID);
    [self.hostView removeFromSuperview];
    self.hostView = nil;
    self.retainedSceneController = nil;
    self.live = NO;
    self.scene = nil;
    self.lastCommittedSceneSize = CGSizeZero;
    // 保留 sceneHandle 缓存也可清掉重找
    self.sceneHandle = nil;
    self.placeholder.hidden = NO;
    [self updatePlaceholderHint:@"正在重新连接…"];
    [self attemptLiveSceneHost];
}

- (void)invalidate {
    self.sceneSettingsGeneration += 1;
    self.sceneSettingsUpdateScheduled = NO;
    if (self.scene) {
        id hostManager = [self hostManagerFromScene:self.scene];
        if (hostManager) {
            NSString *req = self.requesterToken ?: @"DualPane";
            for (NSString *name in @[@"invalidateHostViewForRequester:",
                                     @"disableHostingForRequester:",
                                     @"disableHostingForRequester:priority:"]) {
                SEL sel = NSSelectorFromString(name);
                if (![hostManager respondsToSelector:sel]) continue;
                @try {
                    if ([name containsString:@"priority"]) {
                        NSMethodSignature *sig = [hostManager methodSignatureForSelector:sel];
                        if (!sig) continue;
                        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                        inv.target = hostManager;
                        inv.selector = sel;
                        [inv setArgument:&req atIndex:2];
                        NSInteger prio = 1;
                        [inv setArgument:&prio atIndex:3];
                        [inv invoke];
                    } else {
                        ((void (*)(id, SEL, id))objc_msgSend)(hostManager, sel, req);
                    }
                } @catch (__unused NSException *e) {}
            }
        }
    }
    [self.hostView removeFromSuperview];
    self.hostView = nil;
    self.retainedSceneController = nil;
    [self.view removeFromSuperview];
    self.scene = nil;
    self.sceneHandle = nil;
    self.live = NO;
}

@end
