#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MainViewController : UIViewController

// AB测试控制变量，YES使用V2版本，NO使用原版本
@property (nonatomic, assign) BOOL useV2Controller;

// AB测试方法：动态切换控制器版本
- (void)switchToVersion:(BOOL)useV2;

@end

NS_ASSUME_NONNULL_END