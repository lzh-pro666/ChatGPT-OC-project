#import <AsyncDisplayKit/AsyncDisplayKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface MessageNode : ASCellNode

@property (nonatomic, strong) ASTextNode *messageTextNode;
@property (nonatomic, strong) ASDisplayNode *bubbleNode;
@property (nonatomic, assign) BOOL isFromUser;

- (void)configureWithMessage:(NSString *)message isFromUser:(BOOL)isFromUser;
+ (CGFloat)heightForMessage:(NSString *)message width:(CGFloat)width;


- (void)updateMessageText:(NSString *)newText;
@end

NS_ASSUME_NONNULL_END
