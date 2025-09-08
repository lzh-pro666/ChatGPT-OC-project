//
//  AICodeBlockNode.h
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import <AsyncDisplayKit/AsyncDisplayKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AICodeBlockNode : ASDisplayNode

- (instancetype)initWithCode:(NSString *)code 
                    language:(NSString *)lang 
                  isFromUser:(BOOL)isFromUser;

// 新增：增量更新代码文本（会重新高亮并触发布局）
- (void)updateCodeText:(NSString *)code;

// 设定固定内容宽度（用于滚动容器内容的最大行宽），传入>0生效
- (void)setFixedContentWidth:(CGFloat)width;

// 锁定/解除锁定容器高度（用于流式渲染避免抖动）
- (void)lockContentHeight:(CGFloat)height;
- (void)unlockContentHeight;

@end

NS_ASSUME_NONNULL_END

