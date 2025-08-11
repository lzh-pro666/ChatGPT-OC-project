#import <AsyncDisplayKit/AsyncDisplayKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MessageCellNode : ASCellNode

- (instancetype)initWithMessage:(NSString *)message isFromUser:(BOOL)isFromUser;
- (void)updateMessageText:(NSString *)newMessage;

@end

NS_ASSUME_NONNULL_END


