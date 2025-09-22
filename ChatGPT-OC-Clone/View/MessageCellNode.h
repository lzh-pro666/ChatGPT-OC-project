#import <AsyncDisplayKit/AsyncDisplayKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MessageCellNode : ASCellNode

// 【优化】1. 添加公共属性以存储缓存的尺寸
// 这个尺寸将在首次布局后被计算和存储。
@property (nonatomic, assign) CGSize cachedSize;

- (instancetype)initWithMessage:(NSString *)message isFromUser:(BOOL)isFromUser;

// 更新节点文本的唯一公共接口
- (void)updateMessageText:(NSString *)newMessage;

@end

NS_ASSUME_NONNULL_END
