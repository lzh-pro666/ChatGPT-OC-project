//
//  MediaMessageCellNode.m
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import "MediaMessageCellNode.h"
#import <AsyncDisplayKit/ASImageNode.h>
#import <AsyncDisplayKit/ASNetworkImageNode.h>

@interface MediaMessageCellNode ()
@property (nonatomic, strong) ASDisplayNode *bubbleNode;
@property (nonatomic, strong) ASDisplayNode *contentNode;
@property (nonatomic, strong) ASTextNode *messageTextNode;
@property (nonatomic, strong) ASDisplayNode *attachmentsContainerNode;
@property (nonatomic, strong) NSArray *attachments;
@property (nonatomic, assign) BOOL isFromUser;
@property (nonatomic, copy) NSString *currentMessage;
@end

@implementation MediaMessageCellNode

// MARK: - Initialization

- (instancetype)initWithMessage:(NSString *)message 
                     isFromUser:(BOOL)isFromUser 
                     attachments:(NSArray *)attachments {
    self = [super init];
    if (self) {
        _isFromUser = isFromUser;
        _currentMessage = [message copy];
        _attachments = [attachments copy];
        
        // 自动管理子节点
        self.automaticallyManagesSubnodes = YES;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        
        // 初始化子节点
        _bubbleNode = [[ASDisplayNode alloc] init];
        _contentNode = [[ASDisplayNode alloc] init];
        _contentNode.automaticallyManagesSubnodes = YES;
        _messageTextNode = [[ASTextNode alloc] init];
        _messageTextNode.maximumNumberOfLines = 0;
        _attachmentsContainerNode = [[ASDisplayNode alloc] init];
        _attachmentsContainerNode.automaticallyManagesSubnodes = YES;
        
        // 设置文本内容
        [self updateMessageText:message];
        
        // 设置附件容器布局
        [self setupAttachmentsContainer];
    }
    return self;
}

// MARK: - Lifecycle

- (void)didLoad {
    [super didLoad];
    
    // 设置气泡样式
    _bubbleNode.layer.cornerRadius = 18;
    if (self.isFromUser) {
        _bubbleNode.backgroundColor = [UIColor colorWithRed:0/255.0 green:122/255.0 blue:255/255.0 alpha:1.0];
        _bubbleNode.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner;
    } else {
        _bubbleNode.backgroundColor = [UIColor colorWithRed:229/255.0 green:229/255.0 blue:234/255.0 alpha:1.0];
        _bubbleNode.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    }
}

// MARK: - Layout

- (ASLayoutSpec *)layoutSpecThatFits:(ASSizeRange)constrainedSize {
    // 限制最大宽度为 75%
    CGFloat maxWidth = constrainedSize.max.width * 0.75;
    self.contentNode.style.maxWidth = ASDimensionMake(maxWidth);
    
    // 内容节点布局：文本 + 附件
    __weak typeof(self) weakSelf = self;
    self.contentNode.layoutSpecBlock = ^ASLayoutSpec * _Nonnull(__kindof ASDisplayNode * _Nonnull node, ASSizeRange sizeRange) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        
        NSMutableArray *children = [NSMutableArray array];
        
        // 添加文本节点（如果有文本）
        if (strongSelf.currentMessage.length > 0) {
            [children addObject:strongSelf.messageTextNode];
        }
        
        // 添加附件容器（如果有附件）
        if (strongSelf.attachments.count > 0) {
            [children addObject:strongSelf.attachmentsContainerNode];
        }
        
        // 如果没有内容，添加占位符
        if (children.count == 0) {
            ASTextNode *placeholderNode = [[ASTextNode alloc] init];
            placeholderNode.attributedText = [[NSAttributedString alloc] initWithString:@" "];
            [children addObject:placeholderNode];
        }
        
        ASStackLayoutSpec *stack = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionVertical
                                                                           spacing:8
                                                                    justifyContent:ASStackLayoutJustifyContentStart
                                                                        alignItems:ASStackLayoutAlignItemsStretch
                                                                          children:children];
        return stack;
    };
    
    // 附件容器布局：水平排列附件
    self.attachmentsContainerNode.layoutSpecBlock = ^ASLayoutSpec * _Nonnull(__kindof ASDisplayNode * _Nonnull node, ASSizeRange sizeRange) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        
        NSMutableArray *attachmentNodes = [NSMutableArray array];
        
        // 创建附件节点（最多显示3个）
        NSInteger maxAttachments = MIN(strongSelf.attachments.count, 3);
        for (NSInteger i = 0; i < maxAttachments; i++) {
            id attachment = strongSelf.attachments[i];
            ASDisplayNode *attachmentNode = [strongSelf createAttachmentNode:attachment];
            if (attachmentNode) {
                [attachmentNodes addObject:attachmentNode];
            }
        }
        
        if (attachmentNodes.count == 0) {
            return [ASLayoutSpec new];
        }
        
        ASStackLayoutSpec *stack = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionHorizontal
                                                                           spacing:8
                                                                    justifyContent:ASStackLayoutJustifyContentStart
                                                                        alignItems:ASStackLayoutAlignItemsStart
                                                                          children:attachmentNodes];
        return stack;
    };

    // 外层内边距（文本与气泡边距）
    ASInsetLayoutSpec *contentInset = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(10, 15, 10, 15) child:self.contentNode];

    // 气泡背景
    ASBackgroundLayoutSpec *backgroundSpec = [ASBackgroundLayoutSpec backgroundLayoutSpecWithChild:contentInset background:self.bubbleNode];

    // 左右对齐（用户消息靠右，AI靠左）
    ASStackLayoutSpec *stackSpec = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionHorizontal
                                                                           spacing:0
                                                                    justifyContent:(self.isFromUser ? ASStackLayoutJustifyContentEnd : ASStackLayoutJustifyContentStart)
                                                                        alignItems:ASStackLayoutAlignItemsStart
                                                                          children:@[backgroundSpec]];

    // 与 cell 边缘的外边距
    return [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(5, 12, 5, 12) child:stackSpec];
}

// MARK: - Public Methods

- (void)updateMessageText:(NSString *)newMessage {
    if ([self.currentMessage isEqualToString:newMessage]) {
        return;
    }
    
    // 仅展示用户正文，去除附加的“附件链接块”，以提升可读性
    NSString *displayText = newMessage ?: @"";
    NSRange marker = [displayText rangeOfString:@"[附件链接："];
    if (marker.location != NSNotFound) {
        displayText = [displayText substringToIndex:marker.location];
        displayText = [displayText stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }

    self.currentMessage = [displayText copy];
    self.messageTextNode.attributedText = [self attributedStringForText:displayText];
    
    // 重置缓存尺寸
    self.cachedSize = CGSizeZero;
    
    [self setNeedsLayout];
}

- (NSString *)currentMessage {
    return _currentMessage;
}

// MARK: - Private Methods

- (void)setupAttachmentsContainer {
    // 附件容器已经在layoutSpecBlock中配置
}

- (ASDisplayNode *)createAttachmentNode:(id)attachment {
    if ([attachment isKindOfClass:[UIImage class]]) {
        // 本地图片使用ASImageNode
        ASImageNode *imageNode = [[ASImageNode alloc] init];
        imageNode.image = attachment;
        imageNode.contentMode = UIViewContentModeScaleAspectFill;
        imageNode.clipsToBounds = YES;
        imageNode.cornerRadius = 8.0; // 使用 Texture 提供的线程安全属性
        
        // 设置固定尺寸，模仿底部输入栏的样式
        imageNode.style.width = ASDimensionMake(60);
        imageNode.style.height = ASDimensionMake(60);
        
        return imageNode;
        
    } else if ([attachment isKindOfClass:[NSURL class]]) {
        // 网络图片使用ASNetworkImageNode
        ASNetworkImageNode *networkImageNode = [[ASNetworkImageNode alloc] init];
        networkImageNode.URL = attachment;
        networkImageNode.contentMode = UIViewContentModeScaleAspectFill;
        networkImageNode.clipsToBounds = YES;
        networkImageNode.cornerRadius = 8.0; // 使用 Texture 提供的线程安全属性
        
        // 设置固定尺寸，模仿底部输入栏的样式
        networkImageNode.style.width = ASDimensionMake(60);
        networkImageNode.style.height = ASDimensionMake(60);
        
        // 设置占位图
        networkImageNode.placeholderFadeDuration = 0.1;
        networkImageNode.placeholderColor = [UIColor systemGray5Color];
        
        return networkImageNode;
    }
    
    return nil;
}

- (NSAttributedString *)attributedStringForText:(NSString *)text {
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.lineSpacing = 5;
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
