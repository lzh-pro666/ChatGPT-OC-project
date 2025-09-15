//
//  AttachmentScrollNode.h
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import <Foundation/Foundation.h>
#import <AsyncDisplayKit/AsyncDisplayKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AttachmentScrollNode : ASDisplayNode

// 初始化方法：传入附件数组
- (instancetype)initWithAttachments:(NSArray *)attachments isFromUser:(BOOL)isFromUser;

// 更新附件数据
- (void)updateAttachments:(NSArray *)attachments;

// 设置显示宽度（1.5张照片的宽度）
- (void)setDisplayWidth:(CGFloat)displayWidth;

// 根据屏幕宽度动态调整图片大小
- (void)adjustImageSizeForScreenWidth:(CGFloat)screenWidth;

@end

NS_ASSUME_NONNULL_END
