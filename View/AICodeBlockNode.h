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

// 新增：代码块逐行渲染 API
// 说明：在代码块未完成时，逐行追加并显示为普通文本行（不启用横向滚动），每行左到右渐显。
// isFirst 为 YES 时进入“流式模式”；完成后需调用 finalizeStreaming 切换为滚动展示。
- (void)appendCodeLine:(NSString *)line isFirst:(BOOL)isFirst completion:(void (^ _Nullable)(void))completion;

// 新增：结束逐行渲染，切换为完整代码滚动展示
- (void)finalizeStreaming;

// 新增：配置代码行渐显时长（默认 0.5s）
- (void)setCodeLineRevealDuration:(NSTimeInterval)duration;

// 设定固定内容宽度（用于滚动容器内容的最大行宽），传入>0生效
- (void)setFixedContentWidth:(CGFloat)width;

// 锁定/解除锁定容器高度（用于流式渲染避免抖动）
- (void)lockContentHeight:(CGFloat)height;
- (void)unlockContentHeight;

@end

NS_ASSUME_NONNULL_END

