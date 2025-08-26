//
//  ImagePreviewOverlay.h
//  ChatGPT-OC-Clone
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ImagePreviewOverlay : UIView

// 配置并显示（image 与 url 二选一）
- (void)presentInView:(UIView *)parent image:(nullable UIImage *)image imageURL:(nullable NSURL *)url;

@end

NS_ASSUME_NONNULL_END


