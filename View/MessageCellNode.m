#import "MessageCellNode.h"

@interface MessageCellNode ()
@property (nonatomic, strong) ASTextNode *messageTextNode;
@property (nonatomic, strong) ASDisplayNode *bubbleNode;
@property (nonatomic, assign) BOOL isFromUser;
@end

@implementation MessageCellNode

// MARK: - Initialization

- (instancetype)initWithMessage:(NSString *)message isFromUser:(BOOL)isFromUser {
    self = [super init];
    if (self) {
        _isFromUser = isFromUser;
        
        // 自动管理子节点，这是ASDK推荐的做法
        self.automaticallyManagesSubnodes = YES;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        
        // 1. 初始化子节点
        _bubbleNode = [[ASDisplayNode alloc] init];
        _messageTextNode = [[ASTextNode alloc] init];
        
        // 2. 设置节点的初始内容
        // 直接调用我们统一的更新方法来设置初始文本
        [self updateMessageText:(message ?: @"")];
    }
    return self;
}

// MARK: - Lifecycle

- (void)didLoad {
    [super didLoad];
    // didLoad 是配置CALayer属性的最佳位置
    _bubbleNode.layer.cornerRadius = 18; // 圆角可以稍微大一点，视觉效果更好
    if (self.isFromUser) {
        // 调淡用户气泡蓝色
        _bubbleNode.backgroundColor = [UIColor colorWithRed:28/255.0 green:142/255.0 blue:255/255.0 alpha:1.0];
        _bubbleNode.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner;
    } else {
        _bubbleNode.backgroundColor = [UIColor colorWithRed:229/255.0 green:229/255.0 blue:234/255.0 alpha:1.0]; // 使用标准的iOS灰色
        _bubbleNode.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    }
}

// MARK: - Layout

- (ASLayoutSpec *)layoutSpecThatFits:(ASSizeRange)constrainedSize {
    // 限制气泡的最大宽度为屏幕的75%，防止文本过长
    CGFloat bubbleMaxWidth = constrainedSize.max.width * 0.75;
    self.messageTextNode.style.maxWidth = ASDimensionMake(bubbleMaxWidth);
    
    // 为文本内容设置内边距，使其与气泡边缘有空间
    ASInsetLayoutSpec *textInsetSpec = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(10, 15, 10, 15)
                                                                               child:self.messageTextNode];
    
    // 将文本作为子视图，气泡作为背景
    ASBackgroundLayoutSpec *backgroundSpec = [ASBackgroundLayoutSpec backgroundLayoutSpecWithChild:textInsetSpec
                                                                                          background:self.bubbleNode];
    
    // 使用水平堆栈来控制气泡的左右对齐
    ASStackLayoutSpec *horizontalStack = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionHorizontal
                                                                                 spacing:0
                                                                          justifyContent:(self.isFromUser ? ASStackLayoutJustifyContentEnd : ASStackLayoutJustifyContentStart)
                                                                              alignItems:ASStackLayoutAlignItemsStart
                                                                                children:@[backgroundSpec]];
                                                                                
    // 最后，为整个Cell设置外边距，使其与其他Cell有间距
    return [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(5, 12, 5, 12) child:horizontalStack];
}

// MARK: - Public Methods

/**
 * 这是更新节点文本的唯一入口点。
 * 它会重新生成富文本并触发布局刷新。
 */
- (void)updateMessageText:(NSString *)newMessage {
    // 检查新旧文本是否相同，避免不必要的刷新
    if ([self.messageTextNode.attributedText.string isEqualToString:newMessage]) {
        return;
    }
    
    // 使用辅助方法生成新的富文本并赋值
    self.messageTextNode.attributedText = [self attributedStringForText:newMessage];
    
    // 内容变更后重置缓存尺寸，避免沿用过期的缓存
    self.cachedSize = CGSizeZero;
    
    // 当内容改变并可能影响大小时，调用此方法来触发布局重新计算
    [self setNeedsLayout];
}

// MARK: - Private Helpers

/**
 * 这是一个集中的辅助方法，用于根据给定的字符串生成统一样式的富文本。
 */
- (NSAttributedString *)attributedStringForText:(NSString *)text {
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.lineSpacing = 5; // 增加行间距，提高可读性
    paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
    
    UIColor *textColor = self.isFromUser ? [UIColor whiteColor] : [UIColor blackColor];
    
    NSDictionary *attributes = @{
        NSParagraphStyleAttributeName: paragraphStyle,
        NSFontAttributeName: [UIFont systemFontOfSize:17],
        NSForegroundColorAttributeName: textColor
    };
    
    return [[NSAttributedString alloc] initWithString:text attributes:attributes];
}

@end
