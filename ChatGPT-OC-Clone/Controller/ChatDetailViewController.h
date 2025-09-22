#import <UIKit/UIKit.h>
// #import <AsyncDisplayKit/AsyncDisplayKit.h>
#import <PhotosUI/PhotosUI.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import "ChatDetailMenuDelegate.h"
#import "CustomMenuView.h"
#import "AlertHelper.h"
#import "MediaPickerManager.h"

@class Chat;

NS_ASSUME_NONNULL_BEGIN

@interface ChatDetailViewController : UIViewController <UITextViewDelegate, CustomMenuViewDelegate, MediaPickerManagerDelegate>

@property (nonatomic, strong) id chat;
@property (nonatomic, strong) UILabel *placeholderLabel;
@property (nonatomic, strong) NSLayoutConstraint *inputTextViewHeightConstraint;
@property (nonatomic, weak) id<ChatDetailMenuDelegate> menuDelegate;

@end

NS_ASSUME_NONNULL_END
