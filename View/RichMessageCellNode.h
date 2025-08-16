//
//  RichMessageCellNode.h
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import <AsyncDisplayKit/AsyncDisplayKit.h>
#import "ParserResult.h"

NS_ASSUME_NONNULL_BEGIN

@interface RichMessageCellNode : ASCellNode

// 【优化】1. 添加公共属性以存储缓存的尺寸
// 这个尺寸将在首次布局后被计算和存储，与MessageCellNode保持一致
@property (nonatomic, assign) CGSize cachedSize;

/**
 * 初始化富文本消息节点
 * @param message 消息内容（支持 Markdown 格式）
 * @param isFromUser 是否来自用户
 */
- (instancetype)initWithMessage:(NSString *)message isFromUser:(BOOL)isFromUser;

/**
 * 更新消息文本（用于打字机效果）
 * @param newMessage 新的消息内容
 */
- (void)updateMessageText:(NSString *)newMessage;

/**
 * 更新解析结果（用于优化解析）
 * @param results 解析结果数组
 */
- (void)updateParsedResults:(NSArray<ParserResult *> *)results;

/**
 * 获取当前消息内容
 * @return 当前消息文本
 */
- (NSString *)currentMessage;

/**
 * 测试代码块显示（用于调试）
 */
- (void)testCodeBlockDisplay;

/**
 * 手动设置测试解析结果（用于调试）
 */
- (void)setTestParsedResults;

/**
 * 简单测试代码块（最小化测试）
 */
- (void)testSimpleCodeBlock;

/**
 * 增量更新现有节点（不重新解析）
 */
- (void)updateExistingNodesWithNewText:(NSString *)newText;

/**
 * 获取或缓存文本高度
 */
- (CGFloat)cachedHeightForText:(NSString *)text width:(CGFloat)width;

/**
 * 清理高度缓存
 */
- (void)clearHeightCache;

@end

NS_ASSUME_NONNULL_END
