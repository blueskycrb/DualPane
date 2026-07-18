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
@end

@implementation DPSceneHost

+ (BOOL)isSceneHostingAvailable {
    return NSClassFromString(@"FBSceneManager") != Nil
        || NSClassFromString(@"SBApplicationController") != Nil
        || NSClassFromString(@"SBSceneManager") != Nil;
}

- (instancetype)initWithBundleID:(NSString *)bundleID {
    self = [super init];
    if (self) {
        _bundleID = [bundleID copy];
        _view = [[UIView alloc] initWithFrame:CGRectZero];
        _view.backgroundColor = [UIColor blackColor];
        _view.clipsToBounds = YES;
        _live = NO;
        _requesterToken = [NSString stringWithFormat:@"DualPane-%@-%@",
                           bundleID ?: @"app",
                           @((NSUInteger)self)];
        _attemptCount = 0;
        [self buildPlaceholder];
        [self attemptLiveSceneHost];
    }
    return self;
}

#pragma mark - Lookup helpers

- (id)sbApplication {
    Class cls = NSClassFromString(@"SBApplicationController");
    if (!cls) return nil;
    id controller = nil;
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        controller = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
    }
    if (!controller) return nil;

    NSArray *sels = @[
        @"applicationWithBundleIdentifier:",
        @"applicationWithPid:", // not used
    ];
    for (NSString *name in @[@"applicationWithBundleIdentifier:"]) {
        SEL sel = NSSelectorFromString(name);
        if ([controller respondsToSelector:sel]) {
            return ((id (*)(id, SEL, id))objc_msgSend)(controller, sel, self.bundleID);
        }
    }
    (void)sels;
    return nil;
}

- (NSArray *)allScenesFromManager:(id)manager {
    if (!manager) return @[];
    NSMutableArray *out = [NSMutableArray array];

    // scenes / scenesIncludingInternal:
    for (NSString *name in @[@"scenes", @"scenesIncludingInternal:", @"_scenes"]) {
        SEL sel = NSSelectorFromString(name);
        if (![manager respondsToSelector:sel]) continue;
        id result = nil;
        if ([name hasSuffix:@":"]) {
            // scenesIncludingInternal:YES
            BOOL yes = YES;
            NSMethodSignature *sig = [manager methodSignatureForSelector:sel];
            if (!sig) continue;
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = manager;
            inv.selector = sel;
            [inv setArgument:&yes atIndex:2];
            [inv invoke];
            __unsafe_unretained id tmp = nil;
            [inv getReturnValue:&tmp];
            result = tmp;
        } else {
            result = ((id (*)(id, SEL))objc_msgSend)(manager, sel);
        }
        if ([result isKindOfClass:[NSSet class]]) {
            [out addObjectsFromArray:[result allObjects]];
        } else if ([result isKindOfClass:[NSArray class]]) {
            [out addObjectsFromArray:result];
        } else if ([result isKindOfClass:[NSDictionary class]]) {
            [out addObjectsFromArray:[result allValues]];
        }
    }

    // scenesByID / sceneMap
    for (NSString *name in @[@"scenesByID", @"_scenesByID", @"sceneMap"]) {
        SEL sel = NSSelectorFromString(name);
        if (![manager respondsToSelector:sel]) continue;
        id map = ((id (*)(id, SEL))objc_msgSend)(manager, sel);
        if ([map isKindOfClass:[NSDictionary class]]) {
            [out addObjectsFromArray:[map allValues]];
        }
    }
    return out;
}

- (id)fbSceneManager {
    Class cls = NSClassFromString(@"FBSceneManager");
    if (!cls) return nil;
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        return ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
    }
    return nil;
}

- (id)sbSceneManager {
    // SBSceneManagerCoordinator / SBMainDisplaySceneManager / SBSceneManager
    for (NSString *cn in @[@"SBMainDisplaySceneManager",
                           @"SBSceneManagerCoordinator",
                           @"SBSceneManager"]) {
        Class cls = NSClassFromString(cn);
        if (!cls) continue;
        if ([cls respondsToSelector:@selector(sharedInstance)]) {
            id obj = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(sharedInstance));
            if (obj) return obj;
        }
        if ([cls respondsToSelector:@selector(mainDisplaySceneManager)]) {
            id obj = ((id (*)(id, SEL))objc_msgSend)(cls, @selector(mainDisplaySceneManager));
            if (obj) return obj;
        }
    }
    // coordinator.mainDisplaySceneManager
    Class coord = NSClassFromString(@"SBSceneManagerCoordinator");
    if (coord && [coord respondsToSelector:@selector(sharedInstance)]) {
        id c = ((id (*)(id, SEL))objc_msgSend)(coord, @selector(sharedInstance));
        @try {
            id m = [c valueForKey:@"mainDisplaySceneManager"];
            if (m) return m;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

- (BOOL)object:(id)obj matchesBundleID:(NSString *)bid {
    if (!obj || !bid.length) return NO;
    NSArray *keys = @[@"identifier", @"sceneIdentifier", @"persistentIdentifier",
                      @"clientIdentifier", @"bundleIdentifier", @"applicationBundleIdentifier"];
    for (NSString *key in keys) {
        @try {
            id val = [obj valueForKey:key];
            if ([val isKindOfClass:[NSString class]] && [val containsString:bid]) return YES;
        } @catch (__unused NSException *e) {}
    }
    // nested application
    for (NSString *key in @[@"application", @"clientProcess", @"clientSettings", @"definition"]) {
        @try {
            id nested = [obj valueForKey:key];
            if (!nested || nested == obj) continue;
            NSString *nb = nil;
            @try { nb = [nested valueForKey:@"bundleIdentifier"]; } @catch (__unused NSException *e) {}
            if ([nb isEqualToString:bid]) return YES;
            @try {
                NSString *ident = [nested valueForKey:@"identifier"];
                if ([ident isKindOfClass:[NSString class]] && [ident containsString:bid]) return YES;
            } @catch (__unused NSException *e) {}
        } @catch (__unused NSException *e) {}
    }
    return NO;
}

- (id)sceneHandleForBundleID {
    id app = [self sbApplication];
    if (!app) {
        self.statusText = @"未找到应用对象";
        return nil;
    }

    // 常见属性 / 方法
    NSArray *props = @[
        @"mainSceneHandle", @"_mainSceneHandle", @"sceneHandle",
        @"mainScene", @"_mainScene", @"primaryScene"
    ];
    for (NSString *key in props) {
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

    // scenes 集合
    @try {
        id scenes = nil;
        if ([app respondsToSelector:@selector(scenes)]) {
            scenes = ((id (*)(id, SEL))objc_msgSend)(app, @selector(scenes));
        } else {
            scenes = [app valueForKey:@"scenes"];
        }
        if ([scenes isKindOfClass:[NSSet class]] || [scenes isKindOfClass:[NSArray class]]) {
            for (id s in scenes) {
                if ([self object:s matchesBundleID:self.bundleID]) return s;
            }
            // 任意一个
            id first = [scenes isKindOfClass:[NSSet class]] ? [scenes anyObject] : [scenes firstObject];
            if (first) return first;
        }
    } @catch (__unused NSException *e) {}

    // 从 SBSceneManager 的 external handles 找
    id sbm = [self sbSceneManager];
    if (sbm) {
        for (NSString *name in @[@"externalForegroundApplicationSceneHandles",
                                 @"externalApplicationSceneHandles",
                                 @"applicationSceneHandles",
                                 @"sceneHandles"]) {
            SEL sel = NSSelectorFromString(name);
            if (![sbm respondsToSelector:sel]) continue;
            id set = ((id (*)(id, SEL))objc_msgSend)(sbm, sel);
            NSArray *arr = nil;
            if ([set isKindOfClass:[NSSet class]]) arr = [set allObjects];
            else if ([set isKindOfClass:[NSArray class]]) arr = set;
            for (id handle in arr ?: @[]) {
                if ([self object:handle matchesBundleID:self.bundleID]) return handle;
                @try {
                    id app2 = [handle valueForKey:@"application"];
                    NSString *bid = [app2 valueForKey:@"bundleIdentifier"];
                    if ([bid isEqualToString:self.bundleID]) return handle;
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
    // handle 本身就是 FBScene
    if ([NSStringFromClass([handle class]) containsString:@"FBScene"] &&
        ![NSStringFromClass([handle class]) containsString:@"Handle"]) {
        return handle;
    }
    return nil;
}

- (id)findFBScene {
    // 1) via handle
    id handle = [self sceneHandleForBundleID];
    self.sceneHandle = handle;
    id scene = [self fbSceneFromHandle:handle];
    if (scene) return scene;

    // 2) FBSceneManager 枚举
    id mgr = [self fbSceneManager];
    NSArray *scenes = [self allScenesFromManager:mgr];
    for (id s in scenes) {
        if ([self object:s matchesBundleID:self.bundleID]) return s;
    }

    // 3) SB scene manager 枚举
    id sbm = [self sbSceneManager];
    scenes = [self allScenesFromManager:sbm];
    for (id s in scenes) {
        if ([self object:s matchesBundleID:self.bundleID]) {
            id inner = [self fbSceneFromHandle:s];
            return inner ?: s;
        }
    }
    return nil;
}

#pragma mark - Host view creation

- (UIView *)invokeHostViewForRequester:(id)hostManager {
    if (!hostManager) return nil;
    NSString *req = self.requesterToken ?: @"DualPane";

    // hostViewForRequester:enableAndOrderFront:
    SEL sel = NSSelectorFromString(@"hostViewForRequester:enableAndOrderFront:");
    if ([hostManager respondsToSelector:sel]) {
        NSMethodSignature *sig = [hostManager methodSignatureForSelector:sel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = hostManager;
            inv.selector = sel;
            NSString *r = req;
            BOOL order = YES;
            [inv setArgument:&r atIndex:2];
            [inv setArgument:&order atIndex:3];
            [inv invoke];
            __unsafe_unretained UIView *view = nil;
            [inv getReturnValue:&view];
            if ([view isKindOfClass:[UIView class]]) {
                NSLog(@"[DualPane] hostViewForRequester OK %@", self.bundleID);
                return view;
            }
        }
    }

    // hostViewForRequester:
    sel = NSSelectorFromString(@"hostViewForRequester:");
    if ([hostManager respondsToSelector:sel]) {
        UIView *view = ((id (*)(id, SEL, id))objc_msgSend)(hostManager, sel, req);
        if ([view isKindOfClass:[UIView class]]) return view;
    }

    // enableRenderingForRequester: / setContextId: etc.
    sel = NSSelectorFromString(@"enableRenderingForRequester:enableAndOrderFront:");
    if ([hostManager respondsToSelector:sel]) {
        NSMethodSignature *sig = [hostManager methodSignatureForSelector:sel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = hostManager;
            inv.selector = sel;
            NSString *r = req;
            BOOL order = YES;
            [inv setArgument:&r atIndex:2];
            [inv setArgument:&order atIndex:3];
            [inv invoke];
        }
        // 再取 host view
        return [self invokeHostViewForRequester:hostManager];
    }
    return nil;
}

- (UIView *)hostViewFromSceneHandle:(id)handle size:(CGSize)size {
    if (!handle) return nil;

    // newSceneViewWithReferenceSize:orientation:hostRequester:
    SEL sel = NSSelectorFromString(@"newSceneViewWithReferenceSize:orientation:hostRequester:");
    if ([handle respondsToSelector:sel]) {
        NSMethodSignature *sig = [handle methodSignatureForSelector:sel];
        if (sig) {
            NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
            inv.target = handle;
            inv.selector = sel;
            CGSize s = size;
            if (s.width < 1 || s.height < 1) s = [UIScreen mainScreen].bounds.size;
            long long orientation = 1; // UIInterfaceOrientationPortrait
            NSString *req = self.requesterToken ?: @"DualPane";
            [inv setArgument:&s atIndex:2];
            [inv setArgument:&orientation atIndex:3];
            [inv setArgument:&req atIndex:4];
            [inv invoke];
            __unsafe_unretained id result = nil;
            [inv getReturnValue:&result];
            if ([result isKindOfClass:[UIView class]]) {
                NSLog(@"[DualPane] newSceneViewWithReferenceSize OK %@", self.bundleID);
                return (UIView *)result;
            }
            // 有的返回 controller
            if (result && [result respondsToSelector:@selector(view)]) {
                UIView *v = ((UIView *(*)(id, SEL))objc_msgSend)(result, @selector(view));
                if ([v isKindOfClass:[UIView class]]) return v;
            }
        }
    }

    // newSceneViewControllerForReferenceSize: ...
    for (NSString *name in @[
        @"newSceneViewControllerForDisplayIdentity:",
        @"newScenePlaceholderContentViewWithFrame:",
    ]) {
        SEL s2 = NSSelectorFromString(name);
        if ([handle respondsToSelector:s2]) {
            // 签名复杂，跳过带参困难的
        }
    }

    // sceneSnapshotView / snapshotView
    for (NSString *name in @[@"snapshotView", @"sceneSnapshotView", @"_snapshotView"]) {
        @try {
            id v = [handle valueForKey:name];
            if ([v isKindOfClass:[UIView class]]) return v;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

- (UIView *)hostViewFromFBScene:(id)scene {
    if (!scene) return nil;

    // 1) hostManager
    id hostManager = nil;
    for (NSString *name in @[@"hostManager", @"_hostManager", @"contextHostManager"]) {
        @try {
            SEL sel = NSSelectorFromString(name);
            if ([scene respondsToSelector:sel]) {
                hostManager = ((id (*)(id, SEL))objc_msgSend)(scene, sel);
            } else {
                hostManager = [scene valueForKey:name];
            }
            if (hostManager) break;
        } @catch (__unused NSException *e) {}
    }
    if (hostManager) {
        UIView *hv = [self invokeHostViewForRequester:hostManager];
        if (hv) return hv;
    }

    // 2) layerManager → host container
    id layerManager = nil;
    @try {
        if ([scene respondsToSelector:NSSelectorFromString(@"layerManager")]) {
            layerManager = ((id (*)(id, SEL))objc_msgSend)(scene, NSSelectorFromString(@"layerManager"));
        } else {
            layerManager = [scene valueForKey:@"layerManager"];
        }
    } @catch (__unused NSException *e) {}

    // FBSceneLayerHostContainerView
    Class hostClass = NSClassFromString(@"FBSceneLayerHostContainerView");
    if (!hostClass) hostClass = NSClassFromString(@"_UISceneHostingView");
    if (hostClass) {
        UIView *host = nil;
        if ([hostClass instancesRespondToSelector:@selector(initWithFrame:)]) {
            host = [[hostClass alloc] initWithFrame:self.view.bounds];
        }
        if (host) {
            for (NSString *name in @[@"setScene:", @"hostScene:", @"setHostingScene:", @"_setScene:", @"setLayerManager:"]) {
                SEL sel = NSSelectorFromString(name);
                if ([host respondsToSelector:sel]) {
                    id arg = [name containsString:@"Layer"] ? (layerManager ?: scene) : scene;
                    ((void (*)(id, SEL, id))objc_msgSend)(host, sel, arg);
                    NSLog(@"[DualPane] %@ attach via %@", self.bundleID, name);
                    return host;
                }
            }
        }
        if ([hostClass instancesRespondToSelector:NSSelectorFromString(@"initWithScene:")]) {
            id h = [hostClass alloc];
            h = ((id (*)(id, SEL, id))objc_msgSend)(h, NSSelectorFromString(@"initWithScene:"), scene);
            if ([h isKindOfClass:[UIView class]]) return (UIView *)h;
        }
    }

    // 3) contentView on hostManager
    if (hostManager) {
        @try {
            id cv = [hostManager valueForKey:@"contentView"];
            if ([cv isKindOfClass:[UIView class]]) return cv;
        } @catch (__unused NSException *e) {}
    }
    return nil;
}

- (UIImage *)snapshotImage {
    id app = [self sbApplication];
    if (!app) return nil;

    // 常见快照接口
    NSArray *sels = @[
        @"iconImageForFormat:", // not snapshot
    ];
    (void)sels;

    // valueForKey paths
    for (NSString *key in @[@"_snapshotImage", @"snapshotImage", @"defaultSnapshot"]) {
        @try {
            id img = [app valueForKey:key];
            if ([img isKindOfClass:[UIImage class]]) return img;
        } @catch (__unused NSException *e) {}
    }

    // SBApplicationSnapshot / SBSApplicationShortcutIcon - skip

    // FBScene snapshot
    id scene = self.scene ?: [self findFBScene];
    if (scene) {
        // createSnapshotWithContext: 太复杂
        @try {
            id settings = [scene valueForKey:@"settings"];
            (void)settings;
        } @catch (__unused NSException *e) {}
    }

    // UIKit snapshot of nothing - no

    // LS icon as last resort already in placeholder
    return [self iconImageLarge];
}

- (UIImage *)iconImageLarge {
    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    if (LSApplicationProxy) {
        id proxy = ((id (*)(id, SEL, id))objc_msgSend)(LSApplicationProxy,
            @selector(applicationProxyForIdentifier:), self.bundleID);
        // icon data APIs vary; skip
        (void)proxy;
    }
    // SBApplication icon
    id app = [self sbApplication];
    if (app) {
        for (NSString *name in @[@"iconImageForFormat:", @"iconImageWithFormat:"]) {
            SEL sel = NSSelectorFromString(name);
            if ([app respondsToSelector:sel]) {
                // int format = 0; complex
            }
        }
        @try {
            id img = [app valueForKey:@"iconImage"];
            if ([img isKindOfClass:[UIImage class]]) return img;
        } @catch (__unused NSException *e) {}
    }
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:@"app.fill"];
    }
    return nil;
}

#pragma mark - Main attach

- (void)attemptLiveSceneHost {
    self.attemptCount += 1;
    if ([self.bundleID isEqualToString:@"com.apple.springboard"]) {
        // 主屏：显示壁纸色 + 提示
        self.statusText = @"主屏幕";
        [self updatePlaceholderHint:@"主屏幕区域\n（副屏为你选择的应用）"];
        [self applySnapshotFallback];
        return;
    }

    // Path 1: SceneHandle → newSceneView
    id handle = self.sceneHandle ?: [self sceneHandleForBundleID];
    self.sceneHandle = handle;
    if (handle) {
        CGSize size = self.view.bounds.size;
        if (size.width < 2 || size.height < 2) {
            size = CGSizeMake(180, 320);
        }
        UIView *hv = [self hostViewFromSceneHandle:handle size:size];
        if (hv) {
            [self attachHostView:hv scene:[self fbSceneFromHandle:handle]];
            self.statusText = @"SceneHandle 画面";
            return;
        }
    }

    // Path 2: FBScene → hostManager
    id scene = [self findFBScene];
    self.scene = scene;
    if (scene) {
        UIView *hv = [self hostViewFromFBScene:scene];
        if (hv) {
            [self attachHostView:hv scene:scene];
            self.statusText = @"FBScene 画面";
            return;
        }
        self.statusText = @"找到 scene，但无法创建宿主视图";
        NSLog(@"[DualPane] scene found but no host view: %@ class=%@",
              self.bundleID, NSStringFromClass([scene class]));
    } else {
        self.statusText = @"未找到应用 scene（进程可能已挂起）";
        NSLog(@"[DualPane] no scene for %@", self.bundleID);
    }

    // Path 3: 快照回退
    [self applySnapshotFallback];
}

- (void)attachHostView:(UIView *)hostView scene:(id)scene {
    if (!hostView) return;

    // 清掉旧的
    [self.hostView removeFromSuperview];
    self.hostView = hostView;
    self.scene = scene;
    hostView.frame = self.view.bounds;
    hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:hostView];
    [self.view bringSubviewToFront:hostView];

    // 隐藏占位
    self.placeholder.hidden = YES;
    self.live = YES;

    // 尝试把 scene 设为可见 / 更新尺寸
    [self updateSceneSettingsWithSize:self.view.bounds.size];
    NSLog(@"[DualPane] LIVE attach %@ view=%@", self.bundleID, NSStringFromClass([hostView class]));
}

- (void)applySnapshotFallback {
    UIImage *snap = [self snapshotImage];
    if (!self.snapshotView) {
        self.snapshotView = [[UIImageView alloc] initWithFrame:self.view.bounds];
        self.snapshotView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.snapshotView.contentMode = UIViewContentModeScaleAspectFill;
        self.snapshotView.clipsToBounds = YES;
        [self.view insertSubview:self.snapshotView aboveSubview:self.placeholder];
    }
    if (snap) {
        self.snapshotView.image = snap;
        self.snapshotView.hidden = NO;
        [self updatePlaceholderHint:[NSString stringWithFormat:
            @"暂用快照显示\n%@\n（真实画面嵌入失败，可再试一次）",
            self.statusText ?: @""]];
    } else {
        [self updatePlaceholderHint:[NSString stringWithFormat:
            @"无法嵌入应用画面\n%@\n尝试：先打开该 App，按 Home 回桌面，再分屏",
            self.statusText ?: @""]];
    }
    self.placeholder.hidden = NO;
    self.live = NO;
}

#pragma mark - Placeholder UI

- (void)buildPlaceholder {
    self.placeholder = [[UIView alloc] initWithFrame:self.view.bounds];
    self.placeholder.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.placeholder.backgroundColor = [UIColor colorWithRed:0.09 green:0.10 blue:0.14 alpha:1.0];
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
    self.hintLabel.textColor = [UIColor colorWithWhite:1 alpha:0.7];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.text = @"正在连接应用画面…";
    [stack addArrangedSubview:self.hintLabel];

    // 手动重试按钮
    UIButton *retry = [UIButton buttonWithType:UIButtonTypeSystem];
    [retry setTitle:@"重新连接画面" forState:UIControlStateNormal];
    retry.tintColor = [UIColor systemBlueColor];
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
        NSString *name = [proxy valueForKey:@"localizedName"];
        if (name.length) return name;
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
        [self updateSceneSettingsWithSize:self.view.bounds.size];
    }
}

- (void)updateSceneSettingsWithSize:(CGSize)size {
    if (!self.scene || size.width < 1 || size.height < 1) return;

    // updateSettingsWithBlock: 或 mutableSettings setFrame
    SEL blockSel = NSSelectorFromString(@"updateSettingsWithBlock:");
    if ([self.scene respondsToSelector:blockSel]) {
        // block 签名 (FBSMutableSceneSettings *) -> void，运行时难构造，跳过
    }

    @try {
        id settings = nil;
        if ([self.scene respondsToSelector:NSSelectorFromString(@"mutableSettings")]) {
            settings = ((id (*)(id, SEL))objc_msgSend)(self.scene, NSSelectorFromString(@"mutableSettings"));
        }
        if (settings) {
            CGRect r = CGRectMake(0, 0, size.width, size.height);
            SEL setFrame = NSSelectorFromString(@"setFrame:");
            if ([settings respondsToSelector:setFrame]) {
                NSMethodSignature *sig = [settings methodSignatureForSelector:setFrame];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = settings;
                inv.selector = setFrame;
                [inv setArgument:&r atIndex:2];
                [inv invoke];
            }
            // setForeground:YES
            SEL setFg = NSSelectorFromString(@"setForeground:");
            if ([settings respondsToSelector:setFg]) {
                NSMethodSignature *sig = [settings methodSignatureForSelector:setFg];
                NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                inv.target = settings;
                inv.selector = setFg;
                BOOL yes = YES;
                [inv setArgument:&yes atIndex:2];
                [inv invoke];
            }
        }
    } @catch (__unused NSException *e) {}
}

- (void)setSuspended:(BOOL)suspended {
    self.view.alpha = suspended ? 0.0 : 1.0;
}

- (void)retryAttach {
    NSLog(@"[DualPane] retryAttach #%@ %@", @(self.attemptCount + 1), self.bundleID);
    [self.hostView removeFromSuperview];
    self.hostView = nil;
    self.live = NO;
    self.scene = nil;
    self.placeholder.hidden = NO;
    [self updatePlaceholderHint:@"正在重新连接…"];
    [self attemptLiveSceneHost];
    if (self.live) {
        [self updatePlaceholderHint:@"已连接"];
        self.placeholder.hidden = YES;
    }
}

- (void)invalidate {
    // 释放 host requester
    if (self.scene) {
        id hostManager = nil;
        @try {
            hostManager = [self.scene valueForKey:@"hostManager"];
        } @catch (__unused NSException *e) {}
        if (hostManager) {
            SEL sel = NSSelectorFromString(@"invalidateHostViewForRequester:");
            if ([hostManager respondsToSelector:sel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(hostManager, sel, self.requesterToken);
            }
            sel = NSSelectorFromString(@"disableHostingForRequester:");
            if ([hostManager respondsToSelector:sel]) {
                ((void (*)(id, SEL, id))objc_msgSend)(hostManager, sel, self.requesterToken);
            }
        }
    }
    [self.hostView removeFromSuperview];
    self.hostView = nil;
    [self.view removeFromSuperview];
    self.scene = nil;
    self.sceneHandle = nil;
    self.live = NO;
}

@end
