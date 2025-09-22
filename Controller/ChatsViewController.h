#import <UIKit/UIKit.h>
@class Chat;

NS_ASSUME_NONNULL_BEGIN

@protocol ChatsViewControllerDelegate <NSObject>
- (void)didSelectChat:(id)chat;
@end

@interface ChatsViewController : UIViewController

@property (nonatomic, weak) id<ChatsViewControllerDelegate> delegate;

@end

NS_ASSUME_NONNULL_END 