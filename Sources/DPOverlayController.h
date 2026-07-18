#import <UIKit/UIKit.h>
#import "DPWindowManager.h"

NS_ASSUME_NONNULL_BEGIN

/// Lightweight mode chooser + small utility overlays.
@interface DPOverlayController : NSObject

- (void)presentModeChooserInView:(UIView *)parent
                      completion:(void (^)(DPPresentationMode mode))completion;
- (void)dismiss;

@end

NS_ASSUME_NONNULL_END
