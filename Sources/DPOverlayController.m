#import "DPOverlayController.h"
#import "DPSettings.h"

@interface DPOverlayController ()
@property (nonatomic, strong, nullable) UIView *container;
@property (nonatomic, copy, nullable) void (^completion)(DPPresentationMode);
@end

@implementation DPOverlayController

- (void)presentModeChooserInView:(UIView *)parent
                      completion:(void (^)(DPPresentationMode))completion {
    self.completion = completion;

    self.container = [[UIView alloc] initWithFrame:parent.bounds];
    self.container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.container.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.45];
    self.container.alpha = 0;
    [parent addSubview:self.container];

    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cancel)];
    [self.container addGestureRecognizer:tap];

    UIView *card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 300, 220)];
    card.center = self.container.center;
    card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                            UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
    card.backgroundColor = [UIColor colorWithRed:0.12 green:0.13 blue:0.17 alpha:0.98];
    card.layer.cornerRadius = 20;
    if (@available(iOS 13.0, *)) {
        card.layer.cornerCurve = kCACornerCurveContinuous;
    }
    card.layer.shadowColor = [UIColor blackColor].CGColor;
    card.layer.shadowOpacity = 0.4;
    card.layer.shadowRadius = 20;
    card.tag = 10;
    [self.container addSubview:card];

    // Prevent cancel when tapping card
    UITapGestureRecognizer *noop = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    [card addGestureRecognizer:noop];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(20, 18, 260, 24)];
    title.text = @"分屏助手";
    title.font = [UIFont systemFontOfSize:18 weight:UIFontWeightBold];
    title.textColor = [UIColor whiteColor];
    title.textAlignment = NSTextAlignmentCenter;
    [card addSubview:title];

    UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(20, 44, 260, 20)];
    sub.text = @"请选择打开方式";
    sub.font = [UIFont systemFontOfSize:13];
    sub.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    sub.textAlignment = NSTextAlignmentCenter;
    [card addSubview:sub];

    UIButton *floatBtn = [self bigButtonWithTitle:@"悬浮窗口"
                                           symbol:@"rectangle.on.rectangle"
                                            frame:CGRectMake(20, 80, 125, 100)
                                           action:@selector(chooseFloating)];
    [card addSubview:floatBtn];

    UIButton *splitBtn = [self bigButtonWithTitle:@"左右分屏"
                                           symbol:@"rectangle.split.2x1"
                                            frame:CGRectMake(155, 80, 125, 100)
                                           action:@selector(chooseSplit)];
    [card addSubview:splitBtn];

    [UIView animateWithDuration:0.22 animations:^{
        self.container.alpha = 1;
    }];

    if ([DPSettings shared].hapticFeedback) {
        UIImpactFeedbackGenerator *g = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        [g impactOccurred];
    }
}

- (UIButton *)bigButtonWithTitle:(NSString *)title symbol:(NSString *)symbol frame:(CGRect)frame action:(SEL)action {
    UIButton *btn = [UIButton buttonWithType:UIButtonTypeSystem];
    btn.frame = frame;
    btn.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.08];
    btn.layer.cornerRadius = 16;
    btn.tintColor = [UIColor whiteColor];
    btn.titleLabel.numberOfLines = 2;
    btn.titleLabel.textAlignment = NSTextAlignmentCenter;
    btn.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];

    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:28 weight:UIImageSymbolWeightMedium];
        UIImage *img = [UIImage systemImageNamed:symbol withConfiguration:cfg];
        [btn setImage:img forState:UIControlStateNormal];
        [btn setTitle:[@"\n" stringByAppendingString:title] forState:UIControlStateNormal];
        btn.contentVerticalAlignment = UIControlContentVerticalAlignmentCenter;
        // Image on top
        btn.titleEdgeInsets = UIEdgeInsetsMake(8, -img.size.width, 0, 0);
        btn.imageEdgeInsets = UIEdgeInsetsMake(-36, 0, 0, -[[NSAttributedString alloc] initWithString:title].size.width);
    } else {
        [btn setTitle:title forState:UIControlStateNormal];
    }
    [btn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [btn addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return btn;
}

- (void)chooseFloating {
    [self finishWith:DPPresentationModeFloating];
}

- (void)chooseSplit {
    [self finishWith:DPPresentationModeSplit];
}

- (void)cancel {
    [self finishWith:DPPresentationModeNone];
}

- (void)finishWith:(DPPresentationMode)mode {
    void (^done)(DPPresentationMode) = self.completion;
    self.completion = nil;
    [self dismiss];
    if (done) done(mode);
}

- (void)dismiss {
    if (!self.container) return;
    [UIView animateWithDuration:0.18 animations:^{
        self.container.alpha = 0;
    } completion:^(BOOL finished) {
        (void)finished;
        [self.container removeFromSuperview];
        self.container = nil;
    }];
}

@end
