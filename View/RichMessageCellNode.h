//
//  RichMessageCellNode.h
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import <Foundation/Foundation.h>
#import <AsyncDisplayKit/AsyncDisplayKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface RichMessageCellNode : ASCellNode

// 设计化初始化：传入初始文本与气泡方向
- (instancetype)initWithMessage:(NSString *)message isFromUser:(BOOL)isFromUser NS_DESIGNATED_INITIALIZER;

// 禁用不支持的初始化方法
- (instancetype)init NS_UNAVAILABLE;
- (instancetype)new NS_UNAVAILABLE;

// 附件（图片 / 远程 URL）
- (void)setAttachments:(NSArray *)attachments;

// 流式更新文本（增量）
- (void)updateMessageText:(NSString *)newMessage;

// 流式更新文本（带结束态标记，结束态绕过行级截断）
- (void)updateMessageText:(NSString *)newMessage isFinal:(BOOL)isFinal;

// 新增：按语义块增量追加，避免重复解析已渲染内容
- (void)appendSemanticBlocks:(NSArray<NSString *> *)blocks isFinal:(BOOL)isFinal;

// 新增：配置每一行渲染的时间间隔（秒）
- (void)setLineRenderInterval:(NSTimeInterval)lineRenderInterval;

// 流式结束的收尾
- (void)completeStreamingUpdate;

// 高度缓存辅助
- (CGFloat)cachedHeightForText:(NSString *)text width:(CGFloat)width;
- (void)clearHeightCache;

@end

NS_ASSUME_NONNULL_END

