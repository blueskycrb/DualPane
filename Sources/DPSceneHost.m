#import "DPSceneHost.h"

// FrontBoard / SpringBoard private bits we resolve dynamically so the project
// still compiles against a public iOS SDK.
@interface DPSceneHost ()
@property (nonatomic, copy, readwrite) NSString *bundleID;
@property (nonatomic, strong, readwrite) UIView *view;
@property (nonatomic, assign, readwrite, getter=isLive) BOOL live;
@property (nonatomic, strong, nullable) id scene;          // FBScene *
@property (nonatomic, strong, nullable) id sceneManager;   // FBSceneManager *
@property (nonatomic, strong, nullable) UIView *placeholder;
@property (nonatomic, strong, nullable) UIImageView *iconView;
@property (nonatomic, strong, nullable) UILabel *nameLabel;
@property (nonatomic, strong, nullable) UILabel *hintLabel;
@end

@implementation DPSceneHost

+ (BOOL)isSceneHostingAvailable {
    // FBSceneManager exists on device SpringBoard; not in public SDK.
    return NSClassFromString(@"FBSceneManager") != Nil;
}

- (instancetype)initWithBundleID:(NSString *)bundleID {
    self = [super init];
    if (self) {
        _bundleID = [bundleID copy];
        _view = [[UIView alloc] initWithFrame:CGRectZero];
        _view.backgroundColor = [UIColor blackColor];
        _view.clipsToBounds = YES;
        _live = NO;

        if ([DPSceneHost isSceneHostingAvailable]) {
            [self attemptLiveSceneHost];
        }
        if (!self.live) {
            [self buildPlaceholder];
        }
    }
    return self;
}

#pragma mark - Live scene (private API path)

- (void)attemptLiveSceneHost {
    /*
     * High-level FrontBoard path (resolved at runtime):
     *
     *   FBSceneManager *manager = [FBSceneManager sharedInstance];
     *   FBSMutableSceneSettings *settings = ...;
     *   FBScene *scene = [manager createSceneWithIdentifier:settings:initialClientSettings:transitionContext:];
     *   // OR look up existing scene for the bundle and create a client identity.
     *   FBSceneLayerManager *layerManager = scene.layerManager;
     *   // Host layers via FBSceneLayerHostContainerView / _UISceneHostingView
     *
     * Exact selectors differ across 15.x / 16.x. We probe several known
     * entry points and only mark live if we successfully attach a host view.
     */
    Class FBSceneManager = NSClassFromString(@"FBSceneManager");
    if (!FBSceneManager) return;

    id manager = nil;
    if ([FBSceneManager respondsToSelector:@selector(sharedInstance)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        manager = [FBSceneManager performSelector:@selector(sharedInstance)];
#pragma clang diagnostic pop
    }
    if (!manager) return;
    self.sceneManager = manager;

    // Try to find an existing scene for this bundle
    id scene = [self existingSceneForBundleID:self.bundleID manager:manager];
    if (!scene) {
        // Defer live hosting until the target app is launched at least once.
        // Callers can re-invoke attach after launch.
        return;
    }

    UIView *hostView = [self hostViewForScene:scene];
    if (!hostView) return;

    hostView.frame = self.view.bounds;
    hostView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:hostView];
    self.scene = scene;
    self.live = YES;
}

- (id)existingSceneForBundleID:(NSString *)bundleID manager:(id)manager {
    // -[FBSceneManager scenes] / scenesIncludingInternal: / sceneWithIdentifier:
    NSArray *scenes = nil;
    if ([manager respondsToSelector:@selector(scenes)]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        scenes = [manager performSelector:@selector(scenes)];
#pragma clang diagnostic pop
    }
    if (![scenes isKindOfClass:[NSArray class]]) {
        // Some builds expose an NSDictionary keyed by identifier
        if ([manager respondsToSelector:NSSelectorFromString(@"scenesByID")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            id map = [manager performSelector:NSSelectorFromString(@"scenesByID")];
#pragma clang diagnostic pop
            if ([map isKindOfClass:[NSDictionary class]]) {
                scenes = [map allValues];
            }
        }
    }
    if (![scenes isKindOfClass:[NSArray class]]) return nil;

    for (id scene in scenes) {
        NSString *identifier = nil;
        if ([scene respondsToSelector:@selector(identifier)]) {
            identifier = [scene valueForKey:@"identifier"];
        }
        if (!identifier && [scene respondsToSelector:@selector(clientIdentifier)]) {
            identifier = [scene valueForKey:@"clientIdentifier"];
        }
        // Scene identifiers typically contain the bundle id
        if (identifier && [identifier containsString:bundleID]) {
            return scene;
        }

        // Also check clientProcess / application bundleIdentifier
        id client = nil;
        if ([scene respondsToSelector:@selector(clientProcess)]) {
            client = [scene valueForKey:@"clientProcess"];
        }
        NSString *clientBundle = [client valueForKey:@"bundleIdentifier"];
        if ([clientBundle isEqualToString:bundleID]) {
            return scene;
        }
    }
    return nil;
}

- (UIView *)hostViewForScene:(id)scene {
    // Preferred modern host: _UISceneHostingView / FBSceneLayerHostContainerView
    Class hostClass = NSClassFromString(@"FBSceneLayerHostContainerView");
    if (!hostClass) hostClass = NSClassFromString(@"_UISceneHostingView");
    if (!hostClass) hostClass = NSClassFromString(@"FBSceneHostManager");

    if (hostClass && [hostClass instancesRespondToSelector:@selector(initWithFrame:)]) {
        UIView *host = [[hostClass alloc] initWithFrame:CGRectZero];
        // Try common attach selectors
        NSArray<NSString *> *selectors = @[
            @"setScene:",
            @"hostScene:",
            @"setHostingScene:",
            @"_setScene:",
        ];
        for (NSString *name in selectors) {
            SEL sel = NSSelectorFromString(name);
            if ([host respondsToSelector:sel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [host performSelector:sel withObject:scene];
#pragma clang diagnostic pop
                return host;
            }
        }
        // Some hosts take scene in init
        if ([hostClass instancesRespondToSelector:NSSelectorFromString(@"initWithScene:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            host = [hostClass alloc];
            host = [host performSelector:NSSelectorFromString(@"initWithScene:") withObject:scene];
#pragma clang diagnostic pop
            if ([host isKindOfClass:[UIView class]]) return (UIView *)host;
        }
    }

    // Fallback: ask scene for its host manager content view
    if ([scene respondsToSelector:NSSelectorFromString(@"hostManager")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id hostManager = [scene performSelector:NSSelectorFromString(@"hostManager")];
#pragma clang diagnostic pop
        if ([hostManager respondsToSelector:NSSelectorFromString(@"hostViewForRequester:enableAndOrderFront:")]) {
            // signature varies; skip complex form
        }
        if ([hostManager respondsToSelector:NSSelectorFromString(@"contentView")]) {
            id content = [hostManager valueForKey:@"contentView"];
            if ([content isKindOfClass:[UIView class]]) return (UIView *)content;
        }
    }
    return nil;
}

#pragma mark - Placeholder

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
    [self.placeholder addSubview:stack];

    self.iconView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 64, 64)];
    self.iconView.contentMode = UIViewContentModeScaleAspectFit;
    self.iconView.layer.cornerRadius = 14;
    self.iconView.clipsToBounds = YES;
    self.iconView.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    self.iconView.image = [self iconForBundleID:self.bundleID];
    [stack addArrangedSubview:self.iconView];
    [self.iconView.widthAnchor constraintEqualToConstant:64].active = YES;
    [self.iconView.heightAnchor constraintEqualToConstant:64].active = YES;

    self.nameLabel = [[UILabel alloc] init];
    self.nameLabel.textColor = [UIColor whiteColor];
    self.nameLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    self.nameLabel.text = [self displayNameForBundleID:self.bundleID];
    [stack addArrangedSubview:self.nameLabel];

    self.hintLabel = [[UILabel alloc] init];
    self.hintLabel.textColor = [UIColor colorWithWhite:1 alpha:0.55];
    self.hintLabel.font = [UIFont systemFontOfSize:12];
    self.hintLabel.numberOfLines = 0;
    self.hintLabel.textAlignment = NSTextAlignmentCenter;
    self.hintLabel.text = self.class.isSceneHostingAvailable
        ? @"正在等待应用画面…\n请先打开一次该应用，再重新分屏。"
        : @"应用画面预览\n真机嵌入需要 SpringBoard 私有接口。";
    [stack addArrangedSubview:self.hintLabel];

    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:self.placeholder.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.placeholder.centerYAnchor],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.placeholder.leadingAnchor constant:16],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.placeholder.trailingAnchor constant:-16],
    ]];
}

- (UIImage *)iconForBundleID:(NSString *)bundleID {
    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    if (LSApplicationProxy) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id proxy = [LSApplicationProxy performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleID];
#pragma clang diagnostic pop
        if (proxy) {
            // -iconDataForVariant: / -icon
            if ([proxy respondsToSelector:NSSelectorFromString(@"iconDataForVariant:")]) {
                // skip complex signature
            }
        }
    }
    if (@available(iOS 13.0, *)) {
        return [UIImage systemImageNamed:@"app.dashed"];
    }
    return nil;
}

- (NSString *)displayNameForBundleID:(NSString *)bundleID {
    Class LSApplicationProxy = NSClassFromString(@"LSApplicationProxy");
    if (LSApplicationProxy) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        id proxy = [LSApplicationProxy performSelector:@selector(applicationProxyForIdentifier:) withObject:bundleID];
#pragma clang diagnostic pop
        NSString *name = [proxy valueForKey:@"localizedName"];
        if (name.length) return name;
    }
    return bundleID.pathExtension.length ? bundleID.pathExtension : bundleID;
}

#pragma mark - Public

- (void)setHostedFrame:(CGRect)frame {
    self.view.frame = self.view.superview ? self.view.superview.bounds : frame;
    // Propagate size into scene settings when live
    if (self.live && self.scene) {
        [self updateSceneSettingsWithSize:self.view.bounds.size];
    }
}

- (void)updateSceneSettingsWithSize:(CGSize)size {
    // Best-effort: mutate FBSSceneSettings display configuration
    if (![self.scene respondsToSelector:NSSelectorFromString(@"updateSettings:withTransitionBlock:")]) {
        // Alternative path used on some versions
        if ([self.scene respondsToSelector:NSSelectorFromString(@"mutableSettings")]) {
            id settings = [self.scene valueForKey:@"mutableSettings"];
            if ([settings respondsToSelector:NSSelectorFromString(@"setFrame:")]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                NSValue *val = [NSValue valueWithCGRect:CGRectMake(0, 0, size.width, size.height)];
                // setFrame: takes CGRect — use NSInvocation for non-object args
                NSMethodSignature *sig = [settings methodSignatureForSelector:NSSelectorFromString(@"setFrame:")];
                if (sig) {
                    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:sig];
                    inv.selector = NSSelectorFromString(@"setFrame:");
                    inv.target = settings;
                    CGRect r = CGRectMake(0, 0, size.width, size.height);
                    [inv setArgument:&r atIndex:2];
                    [inv invoke];
                }
                (void)val;
#pragma clang diagnostic pop
            }
        }
        return;
    }
}

- (void)setSuspended:(BOOL)suspended {
    if (!self.live || !self.scene) return;
    if ([self.scene respondsToSelector:NSSelectorFromString(@"updateSettings:withTransitionBlock:")]) {
        // best-effort
    }
    self.view.alpha = suspended ? 0.0 : 1.0;
}

- (void)retryAttach {
    if (self.live) return;
    [self attemptLiveSceneHost];
    if (self.live && self.placeholder) {
        [self.placeholder removeFromSuperview];
        self.placeholder = nil;
        self.hintLabel.text = @"已连接应用画面";
    }
}

- (void)invalidate {
    [self.view removeFromSuperview];
    self.scene = nil;
    self.live = NO;
}

@end
