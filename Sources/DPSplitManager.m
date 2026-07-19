#import "DPSplitManager.h"
#import "DPSceneHost.h"
#import "DPSettings.h"

static const CGFloat kDPDividerHitWidth = 28.0;
static const CGFloat kDPDividerVisualWidth = 4.0;
static const CGFloat kDPSplitToolbarHeight = 40.0;

@interface DPSplitContainerView : UIView
@property (nonatomic, weak, nullable) UIView *passthroughPane;
@end

@implementation DPSplitContainerView

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    UIView *pane = self.passthroughPane;
    if (pane && (hit == pane || [hit isDescendantOfView:pane])) return nil;
    return hit;
}

@end

@interface DPSplitManager ()
@property (nonatomic, strong, readwrite, nullable) UIView *containerView;
@property (nonatomic, copy, readwrite, nullable) NSString *primaryBundleID;
@property (nonatomic, copy, readwrite, nullable) NSString *secondaryBundleID;
@property (nonatomic, assign, readwrite) CGFloat ratio;
@property (nonatomic, assign, readwrite, getter=isActive) BOOL active;

@property (nonatomic, strong) UIView *primaryPane;
@property (nonatomic, strong) UIView *secondaryPane;
@property (nonatomic, strong) UIView *divider;
@property (nonatomic, strong) UIView *dividerKnob;
@property (nonatomic, strong) UIView *toolbar;
@property (nonatomic, strong) UIVisualEffectView *toolbarBlur;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *swapButton;
@property (nonatomic, strong) UIButton *floatButton;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong, nullable) DPSceneHost *primaryHost;
@property (nonatomic, strong, nullable) DPSceneHost *secondaryHost;
@property (nonatomic, strong, nullable) UIView *dimView;
@property (nonatomic, assign) CGFloat dragStartRatio;
- (void)updatePassthroughPane;
@end

@implementation DPSplitManager

- (instancetype)init {
    self = [super init];
    if (self) {
        _ratio = 0.5;
    }
    return self;
}

#pragma mark - Present

- (void)presentInView:(UIView *)parent
        primaryBundle:(NSString *)primaryBundleID
      secondaryBundle:(NSString *)secondaryBundleID
                ratio:(CGFloat)ratio
             animated:(BOOL)animated {

    if (self.active) {
        [self dismissAnimated:NO completion:nil];
    }

    self.primaryBundleID = primaryBundleID;
    self.secondaryBundleID = secondaryBundleID;
    self.ratio = MIN(0.8, MAX(0.2, ratio));
    self.active = YES;

    self.containerView = [[DPSplitContainerView alloc] initWithFrame:parent.bounds];
    self.containerView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.containerView.backgroundColor = [UIColor blackColor];
    self.containerView.clipsToBounds = YES;
    [parent addSubview:self.containerView];

    if ([DPSettings shared].dimBackgroundInSplit) {
        self.dimView = [[UIView alloc] initWithFrame:parent.bounds];
        self.dimView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        self.dimView.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.25];
        self.dimView.userInteractionEnabled = NO;
        [parent insertSubview:self.dimView belowSubview:self.containerView];
    }

    self.primaryPane = [[UIView alloc] init];
    self.primaryPane.backgroundColor = [UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:1.0];
    self.primaryPane.clipsToBounds = YES;
    [self.containerView addSubview:self.primaryPane];

    self.secondaryPane = [[UIView alloc] init];
    self.secondaryPane.backgroundColor = [UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:1.0];
    self.secondaryPane.clipsToBounds = YES;
    [self.containerView addSubview:self.secondaryPane];

    self.divider = [[UIView alloc] init];
    self.divider.backgroundColor = [UIColor clearColor];
    [self.containerView addSubview:self.divider];

    UIView *line = [[UIView alloc] init];
    line.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
    line.tag = 99;
    line.layer.cornerRadius = kDPDividerVisualWidth / 2.0;
    [self.divider addSubview:line];

    self.dividerKnob = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 36, 36)];
    self.dividerKnob.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.18];
    self.dividerKnob.layer.cornerRadius = 18;
    if (@available(iOS 13.0, *)) {
        self.dividerKnob.layer.cornerCurve = kCACornerCurveContinuous;
    }
    [self.divider addSubview:self.dividerKnob];

    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(handleDividerPan:)];
    [self.divider addGestureRecognizer:pan];

    [self buildToolbar];
    [self updatePassthroughPane];
    [self layoutForBounds:self.containerView.bounds];

    if (animated && [DPSettings shared].animateTransitions) {
        self.containerView.alpha = 0;
        self.containerView.transform = CGAffineTransformMakeScale(0.96, 0.96);
        [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.88 initialSpringVelocity:0.5 options:0 animations:^{
            self.containerView.alpha = 1;
            self.containerView.transform = CGAffineTransformIdentity;
        } completion:nil];
    }

    [self haptic:UIImpactFeedbackStyleMedium];
}

- (void)buildToolbar {
    self.toolbar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 100, kDPSplitToolbarHeight)];
    self.toolbar.clipsToBounds = YES;
    self.toolbar.layer.cornerRadius = kDPSplitToolbarHeight / 2.0;

    UIBlurEffect *blur = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
    self.toolbarBlur = [[UIVisualEffectView alloc] initWithEffect:blur];
    self.toolbarBlur.frame = self.toolbar.bounds;
    self.toolbarBlur.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.toolbar addSubview:self.toolbarBlur];

    self.closeButton = [self toolButtonWithSymbol:@"xmark" action:@selector(closeTapped)];
    self.swapButton = [self toolButtonWithSymbol:@"arrow.left.arrow.right" action:@selector(swapTapped)];
    self.floatButton = [self toolButtonWithSymbol:@"rectangle.inset.filled.on.rectangle" action:@selector(floatTapped)];

    self.titleLabel = [[UILabel alloc] init];
    self.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    self.titleLabel.textColor = [UIColor whiteColor];
    self.titleLabel.textAlignment = NSTextAlignmentCenter;
    self.titleLabel.text = @"分屏";

    [self.toolbar addSubview:self.closeButton];
    [self.toolbar addSubview:self.swapButton];
    [self.toolbar addSubview:self.floatButton];
    [self.toolbar addSubview:self.titleLabel];
    [self.containerView addSubview:self.toolbar];
}

- (UIButton *)toolButtonWithSymbol:(NSString *)name action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold];
        [btn setImage:[UIImage systemImageNamed:name withConfiguration:cfg] forState:UIControlStateNormal];
    }
    btn.tintColor = [UIColor whiteColor];
    btn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.12];
    btn.layer.cornerRadius = 14;
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

#pragma mark - Layout

- (void)layoutForBounds:(CGRect)bounds {
    if (!self.containerView) return;
    self.containerView.frame = bounds;

    BOOL horizontal = [DPSettings shared].splitOrientation == DPSplitOrientationHorizontal;
    CGFloat safeTop = 0;
    if (@available(iOS 11.0, *)) {
        safeTop = self.containerView.safeAreaInsets.top;
    }
    // Keep a little room under status area for toolbar
    CGFloat contentY = MAX(safeTop, 12);
    CGFloat contentH = bounds.size.height - contentY;

    if (horizontal) {
        CGFloat totalW = bounds.size.width;
        CGFloat primaryW = floor(totalW * self.ratio);
        CGFloat dividerX = primaryW - kDPDividerHitWidth / 2.0;

        self.primaryPane.frame = CGRectMake(0, contentY, primaryW, contentH);
        self.secondaryPane.frame = CGRectMake(primaryW, contentY, totalW - primaryW, contentH);
        self.divider.frame = CGRectMake(dividerX, contentY, kDPDividerHitWidth, contentH);

        UIView *line = [self.divider viewWithTag:99];
        line.frame = CGRectMake((kDPDividerHitWidth - kDPDividerVisualWidth) / 2.0,
                                0, kDPDividerVisualWidth, contentH);
        self.dividerKnob.center = CGPointMake(kDPDividerHitWidth / 2.0, contentH / 2.0);
    } else {
        CGFloat totalH = contentH;
        CGFloat primaryH = floor(totalH * self.ratio);
        CGFloat dividerY = contentY + primaryH - kDPDividerHitWidth / 2.0;

        self.primaryPane.frame = CGRectMake(0, contentY, bounds.size.width, primaryH);
        self.secondaryPane.frame = CGRectMake(0, contentY + primaryH, bounds.size.width, totalH - primaryH);
        self.divider.frame = CGRectMake(0, dividerY, bounds.size.width, kDPDividerHitWidth);

        UIView *line = [self.divider viewWithTag:99];
        line.frame = CGRectMake(0, (kDPDividerHitWidth - kDPDividerVisualWidth) / 2.0,
                                bounds.size.width, kDPDividerVisualWidth);
        self.dividerKnob.center = CGPointMake(bounds.size.width / 2.0, kDPDividerHitWidth / 2.0);
    }

    // Toolbar centered at top
    CGFloat toolbarW = 210;
    self.toolbar.frame = CGRectMake((bounds.size.width - toolbarW) / 2.0,
                                    MAX(4, contentY - kDPSplitToolbarHeight - 4),
                                    toolbarW,
                                    kDPSplitToolbarHeight);
    self.closeButton.frame = CGRectMake(8, 6, 28, 28);
    self.swapButton.frame = CGRectMake(44, 6, 28, 28);
    self.floatButton.frame = CGRectMake(80, 6, 28, 28);
    self.titleLabel.frame = CGRectMake(116, 0, toolbarW - 124, kDPSplitToolbarHeight);

    [self.primaryHost setHostedFrame:self.primaryPane.bounds];
    [self.secondaryHost setHostedFrame:self.secondaryPane.bounds];
}

- (void)attachPrimaryHost:(DPSceneHost *)host {
    if (self.primaryHost == host && host.view.superview == self.primaryPane) {
        [host setHostedFrame:self.primaryPane.bounds];
        return;
    }
    [self.primaryHost.view removeFromSuperview];
    self.primaryHost = host;
    host.view.frame = self.primaryPane.bounds;
    host.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.primaryPane addSubview:host.view];
    [host setHostedFrame:self.primaryPane.bounds];
}

- (void)attachSecondaryHost:(DPSceneHost *)host {
    if (self.secondaryHost == host && host.view.superview == self.secondaryPane) {
        [host setHostedFrame:self.secondaryPane.bounds];
        return;
    }
    [self.secondaryHost.view removeFromSuperview];
    self.secondaryHost = host;
    host.view.frame = self.secondaryPane.bounds;
    host.view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.secondaryPane addSubview:host.view];
    [host setHostedFrame:self.secondaryPane.bounds];
}

- (DPSceneHost *)detachPrimaryHost {
    DPSceneHost *host = self.primaryHost;
    if (!host) return nil;
    [host.view removeFromSuperview];
    self.primaryHost = nil;
    return host;
}

- (DPSceneHost *)detachSecondaryHost {
    DPSceneHost *host = self.secondaryHost;
    if (!host) return nil;
    [host.view removeFromSuperview];
    self.secondaryHost = nil;
    return host;
}

- (void)updatePassthroughPane {
    BOOL primaryIsHome = [self.primaryBundleID isEqualToString:@"com.apple.springboard"];
    BOOL secondaryIsHome = [self.secondaryBundleID isEqualToString:@"com.apple.springboard"];
    DPSplitContainerView *container = [self.containerView isKindOfClass:[DPSplitContainerView class]]
        ? (DPSplitContainerView *)self.containerView : nil;
    container.passthroughPane = primaryIsHome ? self.primaryPane
        : (secondaryIsHome ? self.secondaryPane : nil);
    container.backgroundColor = (primaryIsHome || secondaryIsHome)
        ? [UIColor clearColor] : [UIColor blackColor];
    self.primaryPane.backgroundColor = primaryIsHome
        ? [UIColor clearColor]
        : [UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:1.0];
    self.secondaryPane.backgroundColor = secondaryIsHome
        ? [UIColor clearColor]
        : [UIColor colorWithRed:0.10 green:0.11 blue:0.13 alpha:1.0];
    self.floatButton.enabled = !secondaryIsHome;
    self.floatButton.alpha = secondaryIsHome ? 0.35 : 1.0;
}

#pragma mark - Divider

- (void)handleDividerPan:(UIPanGestureRecognizer *)gr {
    if (!self.containerView) return;
    BOOL horizontal = [DPSettings shared].splitOrientation == DPSplitOrientationHorizontal;
    CGPoint t = [gr translationInView:self.containerView];

    if (gr.state == UIGestureRecognizerStateBegan) {
        self.dragStartRatio = self.ratio;
        [self haptic:UIImpactFeedbackStyleLight];
    } else if (gr.state == UIGestureRecognizerStateChanged) {
        CGFloat delta;
        if (horizontal) {
            delta = t.x / self.containerView.bounds.size.width;
        } else {
            delta = t.y / self.containerView.bounds.size.height;
        }
        CGFloat newRatio = MIN(0.8, MAX(0.2, self.dragStartRatio + delta));
        self.ratio = newRatio;
        [self layoutForBounds:self.containerView.bounds];
    } else if (gr.state == UIGestureRecognizerStateEnded || gr.state == UIGestureRecognizerStateCancelled) {
        [self commitHostedFrames];
        if (self.onRatioChanged) self.onRatioChanged(self.ratio);
        [[DPSettings shared] setLastSplitRatio:self.ratio];
        [self haptic:UIImpactFeedbackStyleMedium];
    }
}

- (void)setRatio:(CGFloat)ratio animated:(BOOL)animated {
    CGFloat r = MIN(0.8, MAX(0.2, ratio));
    void (^apply)(void) = ^{
        self.ratio = r;
        [self layoutForBounds:self.containerView.bounds];
    };
    if (animated && [DPSettings shared].animateTransitions) {
        [UIView animateWithDuration:0.25 animations:apply completion:^(__unused BOOL finished) {
            [self commitHostedFrames];
        }];
    } else {
        apply();
        [self commitHostedFrames];
    }
}

- (void)commitHostedFrames {
    [self.primaryHost commitHostedFrame];
    [self.secondaryHost commitHostedFrame];
}

- (void)swapSidesAnimated:(BOOL)animated {
    NSString *tmp = self.primaryBundleID;
    self.primaryBundleID = self.secondaryBundleID;
    self.secondaryBundleID = tmp;

    DPSceneHost *tmpHost = self.primaryHost;
    self.primaryHost = self.secondaryHost;
    self.secondaryHost = tmpHost;

    self.ratio = 1.0 - self.ratio;

    [self updatePassthroughPane];

    // Re-parent views
    [self.primaryHost.view removeFromSuperview];
    [self.secondaryHost.view removeFromSuperview];
    if (self.primaryHost) {
        [self.primaryPane addSubview:self.primaryHost.view];
    }
    if (self.secondaryHost) {
        [self.secondaryPane addSubview:self.secondaryHost.view];
    }

    [self setRatio:self.ratio animated:animated];
    if (self.onSwap) self.onSwap();
    [self haptic:UIImpactFeedbackStyleMedium];
}

#pragma mark - Actions

- (void)closeTapped {
    if (self.onClose) self.onClose();
    else [self dismissAnimated:YES completion:nil];
}

- (void)swapTapped {
    [self swapSidesAnimated:YES];
}

- (void)floatTapped {
    NSString *secondary = self.secondaryBundleID;
    if (self.onPromoteSecondaryToFloating) {
        self.onPromoteSecondaryToFloating(secondary);
    }
}

- (void)dismissAnimated:(BOOL)animated completion:(void (^)(void))completion {
    void (^cleanup)(BOOL) = ^(BOOL finished) {
        (void)finished;
        [self.primaryHost invalidate];
        [self.secondaryHost invalidate];
        self.primaryHost = nil;
        self.secondaryHost = nil;
        [self.containerView removeFromSuperview];
        [self.dimView removeFromSuperview];
        self.containerView = nil;
        self.dimView = nil;
        self.active = NO;
        if (completion) completion();
    };

    if (animated && [DPSettings shared].animateTransitions) {
        [UIView animateWithDuration:0.22 animations:^{
            self.containerView.alpha = 0;
            self.containerView.transform = CGAffineTransformMakeScale(0.96, 0.96);
            self.dimView.alpha = 0;
        } completion:cleanup];
    } else {
        cleanup(YES);
    }
}

- (void)haptic:(UIImpactFeedbackStyle)style {
    if (![DPSettings shared].hapticFeedback) return;
    UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:style];
    [g impactOccurred];
}

@end
