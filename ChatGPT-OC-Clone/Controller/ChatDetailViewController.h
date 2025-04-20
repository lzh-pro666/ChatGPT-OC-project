#import <UIKit/UIKit.h>
@class Chat;

NS_ASSUME_NONNULL_BEGIN

@interface ChatDetailViewController : UIViewController

@property (nonatomic, strong) id chat;
@property (nonatomic, strong) UILabel *placeholderLabel;
@property (nonatomic, strong) NSLayoutConstraint *inputTextViewHeightConstraint;

@end

NS_ASSUME_NONNULL_END 