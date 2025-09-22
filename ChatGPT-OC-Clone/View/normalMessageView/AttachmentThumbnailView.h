#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AttachmentThumbnailView : UIView

@property (nonatomic, strong, readonly) UIImageView *imageView;
@property (nonatomic, copy, nullable) void (^deleteAction)(void);

@end

NS_ASSUME_NONNULL_END


