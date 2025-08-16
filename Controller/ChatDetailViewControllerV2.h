//
//  ChatDetailViewControllerV2.h
//  ChatGPT-OC-Clone
//
//  Created by mac—lzh on 2025/8/12.
//

#import <UIKit/UIKit.h>
#import <AsyncDisplayKit/AsyncDisplayKit.h>
#import <PhotosUI/PhotosUI.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import "CustomMenuView.h"
#import "AlertHelper.h"
#import "MediaPickerManager.h"

@class Chat;

NS_ASSUME_NONNULL_BEGIN

@interface ChatDetailViewControllerV2 : ASDKViewController <UITextViewDelegate, ASTableDataSource, ASTableDelegate, CustomMenuViewDelegate, MediaPickerManagerDelegate>

@property (nonatomic, strong) id chat;
@property (nonatomic, strong) UILabel *placeholderLabel;
@property (nonatomic, strong) NSLayoutConstraint *inputTextViewHeightConstraint;

@end

NS_ASSUME_NONNULL_END

