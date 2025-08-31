//
//  MediaMessageCellNode.h
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import <AsyncDisplayKit/AsyncDisplayKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MediaMessageCellNode : ASCellNode

// 缓存的尺寸
@property (nonatomic, assign) CGSize cachedSize;

/**
 * 初始化多媒体消息节点
 * @param message 消息文本内容
 * @param isFromUser 是否来自用户
 * @param attachments 附件数组，包含UIImage或NSURL
 */
- (instancetype)initWithMessage:(NSString *)message 
                     isFromUser:(BOOL)isFromUser 
                     attachments:(NSArray *)attachments;

/**
 * 更新消息文本
 * @param newMessage 新的消息内容
 */
- (void)updateMessageText:(NSString *)newMessage;

/**
 * 获取当前消息内容
 * @return 当前消息文本
 */
- (NSString *)currentMessage;

@end

NS_ASSUME_NONNULL_END

