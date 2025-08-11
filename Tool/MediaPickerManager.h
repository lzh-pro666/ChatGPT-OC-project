//
//  MediaPickerManager.h
//  ChatGPT-OC-Clone
//
//  Created by mac—lzh on 2025/8/5.
//

#import <UIKit/UIKit.h>
#import "AlertHelper.h" // 引入弹窗工具类来处理权限提示
#import <PhotosUI/PhotosUI.h>
#import <AVFoundation/AVFoundation.h>
#import <MobileCoreServices/MobileCoreServices.h>

NS_ASSUME_NONNULL_BEGIN

@class MediaPickerManager;

// 1. 定义一个代理协议，用于将选择结果回调给调用者
@protocol MediaPickerManagerDelegate <NSObject>

@optional // 所有方法都是可选的
- (void)mediaPicker:(MediaPickerManager *)picker didPickImages:(NSArray<UIImage *> *)images;
- (void)mediaPicker:(MediaPickerManager *)picker didPickDocumentAtURL:(NSURL *)url;
- (void)mediaPickerDidCancel:(MediaPickerManager *)picker;

@end

@interface MediaPickerManager : NSObject

// 2. 声明一个 weak 代理属性，避免循环引用
@property (nonatomic, weak) id<MediaPickerManagerDelegate> delegate;

/**
 * @brief 初始化方法
 * @param presenter 用于呈现选择器的视图控制器
 * @return MediaPickerManager 实例
 */
- (instancetype)initWithPresenter:(UIViewController *)presenter;

// 3. 提供给外部调用的�共方法
- (void)presentPhotoPicker;
- (void)presentCameraPicker;
- (void)presentFilePicker;

@end

NS_ASSUME_NONNULL_END
