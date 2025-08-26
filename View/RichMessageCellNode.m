//
//  RichMessageCellNode.m
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import "RichMessageCellNode.h"
#import "CodeBlockView.h"
#import "ResponseParsingTask.h"
#import "ParserResult.h"
#import "AIMarkdownParser.h"
#import "AICodeBlockNode.h"
#import <CoreText/CoreText.h>
#import <AsyncDisplayKit/ASButtonNode.h>
#import <QuartzCore/QuartzCore.h>

// MARK: - 富文本消息节点
@interface RichMessageCellNode ()
@property (nonatomic, strong) ASDisplayNode *bubbleNode;
@property (nonatomic, strong) ASDisplayNode *contentNode;
@property (nonatomic, assign) BOOL isFromUser;
@property (nonatomic, strong) NSArray<ParserResult *> *parsedResults;
@property (nonatomic, copy) NSString *currentMessage;
@property (nonatomic, strong) ResponseParsingTask *parsingTask;
@property (nonatomic, assign) NSInteger lastParsedLength;
@property (nonatomic, copy) NSString *lastParsedText;
@property (nonatomic, strong) NSArray<ASDisplayNode *> *renderNodes;
@property (nonatomic, strong) ASDisplayNode *attachmentsContainerNode; // 新增：附件容器
@property (nonatomic, strong) NSArray *attachmentsData; // 原始附件数据
@property (nonatomic, strong) NSMutableDictionary<NSString *, ASDisplayNode *> *nodeCache;
@property (nonatomic, assign) BOOL isUpdating;
// 恢复AIMarkdownParser以保持富文本效果
@property (nonatomic, strong) AIMarkdownParser *markdownParser;
@property (nonatomic, strong) NSArray<AIMarkdownBlock *> *markdownBlocks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *layoutCache;
@property (nonatomic, assign) BOOL isLayoutStable;
// 高度缓存：key 由文本hash和宽度组成
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *heightCache;
// 新增：丝滑渐显相关属性
@property (nonatomic, assign) BOOL isStreamingMode; // 是否处于流式更新模式
@property (nonatomic, strong) NSMutableArray<ASDisplayNode *> *streamingNodes; // 流式更新中的节点
@property (nonatomic, strong) CADisplayLink *displayLink; // 用于丝滑渐显的显示链接
@property (nonatomic, assign) NSTimeInterval lastAnimationTime; // 上次动画时间
@property (nonatomic, assign) NSInteger currentStreamingIndex; // 当前流式更新的节点索引
@end

@implementation RichMessageCellNode

// MARK: - Initialization

- (instancetype)initWithMessage:(NSString *)message isFromUser:(BOOL)isFromUser {
    self = [super init];
    if (self) {
        _isFromUser = isFromUser;
        _currentMessage = [message copy];
        _lastParsedText = @"";
        _isUpdating = NO;
        
        // 自动管理子节点
        self.automaticallyManagesSubnodes = YES;
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        
        // 初始化子节点
        _bubbleNode = [[ASDisplayNode alloc] init];
        _contentNode = [[ASDisplayNode alloc] init];
        _contentNode.automaticallyManagesSubnodes = YES;
        _renderNodes = @[];
        _nodeCache = [NSMutableDictionary dictionary];
        _layoutCache = [NSMutableDictionary dictionary];
        _isLayoutStable = YES;
        _heightCache = [NSMutableDictionary dictionary];
        
        // 新增：初始化丝滑渐显相关属性
        _isStreamingMode = NO;
        _streamingNodes = [NSMutableArray array];
        _displayLink = nil;
        _lastAnimationTime = 0;
        _currentStreamingIndex = 0;
        
        // 初始化解析器
        _markdownParser = [[AIMarkdownParser alloc] init];
        _markdownBlocks = @[];
        
        // 初始化解析任务
        _parsingTask = [[ResponseParsingTask alloc] init];
        _lastParsedLength = 0;
        
        // 强制首次解析消息内容
        [self parseMessage:message];
        
        // 关键改进：确保富文本效果持久化，重新进入聊天界面时不会丢失
        if (message.length > 0) {
            // 预计算并缓存富文本高度
            CGFloat estimatedWidth = [UIScreen mainScreen].bounds.size.width * 0.75 - 24; // 减去边距
            [self cachedHeightForText:message width:estimatedWidth];
            
            // 预渲染富文本节点，确保重新进入时立即显示
            dispatch_async(dispatch_get_main_queue(), ^{
                [self setNeedsLayout];
                [self layoutIfNeeded];
            });
        }
    }
    return self;
}

// MARK: - Lifecycle

- (void)didLoad {
    [super didLoad];
    
    // 设置气泡样式
    _bubbleNode.layer.cornerRadius = 18;
    if (self.isFromUser) {
        // 调淡用户气泡蓝色，与 MessageCellNode 一致
        _bubbleNode.backgroundColor = [UIColor colorWithRed:28/255.0 green:142/255.0 blue:255/255.0 alpha:1.0];
        _bubbleNode.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner;
    } else {
        _bubbleNode.backgroundColor = [UIColor colorWithRed:229/255.0 green:229/255.0 blue:234/255.0 alpha:1.0];
        _bubbleNode.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    }
}

// MARK: - Layout

- (ASLayoutSpec *)layoutSpecThatFits:(ASSizeRange)constrainedSize {
    // 使用解析生成的内容节点进行布局
    UIColor *backgroundColor = self.isFromUser ? [UIColor systemBlueColor] : [UIColor systemGray5Color];

    // 限制最大宽度为 85%
    CGFloat maxWidth = constrainedSize.max.width * 0.85;
    self.contentNode.style.maxWidth = ASDimensionMake(maxWidth);
    
    // 为了避免末尾被裁剪，确保没有强制的 min/max height 限制
    self.contentNode.style.minHeight = ASDimensionMakeWithPoints(0);

    // contentNode 的布局：使用 renderNodes
    __weak typeof(self) weakSelf = self;
    self.contentNode.layoutSpecBlock = ^ASLayoutSpec * _Nonnull(__kindof ASDisplayNode * _Nonnull node, ASSizeRange sizeRange) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        NSMutableArray<ASDisplayNode *> *children = [NSMutableArray array];
        NSArray<ASDisplayNode *> *renderChildren = strongSelf.renderNodes ?: @[];
        if (renderChildren.count > 0) {
            [children addObjectsFromArray:renderChildren];
        }
        // 若有附件，追加一个水平容器
        if (strongSelf.attachmentsData.count > 0) {
            if (!strongSelf.attachmentsContainerNode) {
                strongSelf.attachmentsContainerNode = [[ASDisplayNode alloc] init];
                strongSelf.attachmentsContainerNode.automaticallyManagesSubnodes = YES;
            }
            strongSelf.attachmentsContainerNode.layoutSpecBlock = ^ASLayoutSpec * _Nonnull(__kindof ASDisplayNode * _Nonnull node2, ASSizeRange sizeRange2) {
                NSMutableArray *thumbNodes = [NSMutableArray array];
                NSInteger max = MIN(strongSelf.attachmentsData.count, 3);
                for (NSInteger i = 0; i < max; i++) {
                    id a = strongSelf.attachmentsData[i];
                    ASDisplayNode *thumb = [strongSelf createAttachmentThumbNode:a];
                    if (thumb) { [thumbNodes addObject:thumb]; }
                }
                if (thumbNodes.count == 0) return [ASLayoutSpec new];
                ASStackLayoutSpec *row = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionHorizontal
                                                                                spacing:8
                                                                         justifyContent:ASStackLayoutJustifyContentStart
                                                                             alignItems:ASStackLayoutAlignItemsStart
                                                                               children:thumbNodes];
                return row;
            };
            [children addObject:strongSelf.attachmentsContainerNode];
        }
        if (children.count == 0) {
            ASTextNode *placeholderNode = [[ASTextNode alloc] init];
            placeholderNode.attributedText = [strongSelf attributedStringForText:(strongSelf.currentMessage ?: @"")];
            placeholderNode.maximumNumberOfLines = 0;
            // 关键修复：确保占位符节点可以显示完整文本
            placeholderNode.style.flexGrow = 1.0;
            placeholderNode.style.flexShrink = 1.0;
            [children addObject:placeholderNode];
        }
        ASStackLayoutSpec *stack = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionVertical
                                                                           spacing:8
                                                                    justifyContent:ASStackLayoutJustifyContentStart
                                                                        alignItems:ASStackLayoutAlignItemsStretch
                                                                          children:children];
        // 关键修复：确保栈布局可以正确计算高度和宽度
        stack.style.flexGrow = 1.0;
        stack.style.flexShrink = 1.0;
        return stack;
    };

    // 外层内边距（文本与气泡边距）
    ASInsetLayoutSpec *contentInset = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(10, 15, 10, 15) child:self.contentNode];

    // 复用已创建的 bubbleNode，避免每次创建新的背景节点
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
- (ASDisplayNode *)createAttachmentThumbNode:(id)attachment {
    if ([attachment isKindOfClass:[UIImage class]]) {
        ASImageNode *n = [[ASImageNode alloc] init];
        n.image = attachment;
        n.contentMode = UIViewContentModeScaleAspectFill;
        n.clipsToBounds = YES;
        n.cornerRadius = 8.0;
        n.style.width = ASDimensionMake(180); // 3倍
        n.style.height = ASDimensionMake(180);
        // 允许点击
        [(ASControlNode *)n addTarget:self action:@selector(thumbTapped:) forControlEvents:ASControlNodeEventTouchUpInside];
        // 标记为本地图片
        n.accessibilityLabel = @"local-image";
        return n;
    } else if ([attachment isKindOfClass:[NSURL class]]) {
        ASNetworkImageNode *n = [[ASNetworkImageNode alloc] init];
        n.URL = attachment;
        n.contentMode = UIViewContentModeScaleAspectFill;
        n.clipsToBounds = YES;
        n.cornerRadius = 8.0;
        n.placeholderFadeDuration = 0.1;
        n.placeholderColor = [UIColor systemGray5Color];
        n.style.width = ASDimensionMake(180); // 3倍
        n.style.height = ASDimensionMake(180);
        // 允许点击
        [(ASControlNode *)n addTarget:self action:@selector(thumbTapped:) forControlEvents:ASControlNodeEventTouchUpInside];
        // 存储URL字符串
        n.accessibilityLabel = @"remote-url";
        n.accessibilityValue = ((NSURL *)attachment).absoluteString;
        return n;
    }
    return nil;
}

// 缩略图点击：通过通知告知控制器展示预览
- (void)thumbTapped:(ASControlNode *)sender {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    // 远程：传 URL 字符串；本地：传 UIImage
    if ([sender isKindOfClass:[ASNetworkImageNode class]]) {
        ASNetworkImageNode *net = (ASNetworkImageNode *)sender;
        NSString *urlStr = net.accessibilityValue;
        if (urlStr.length > 0) {
            info[@"url"] = urlStr;
        }
    } else if ([sender isKindOfClass:[ASImageNode class]]) {
        ASImageNode *imgNode = (ASImageNode *)sender;
        if (imgNode.image) {
            info[@"image"] = imgNode.image;
        }
    }
    [[NSNotificationCenter defaultCenter] postNotificationName:@"AttachmentPreviewRequested"
                                                        object:self
                                                      userInfo:info];
}

#pragma mark - Public
- (void)setAttachments:(NSArray *)attachments {
    self.attachmentsData = attachments;
    // 触发布局
    [self setNeedsLayout];
}

// MARK: - Public Methods

- (void)updateParsedResults:(NSArray<ParserResult *> *)results {
    self.parsedResults = results;
    [self updateContentNode];
    // 使用异步更新避免闪烁
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsLayout];
    });
}

- (NSString *)currentMessage {
    return _currentMessage;
}

- (void)updateMessageText:(NSString *)newMessage {
    if (self.isUpdating) return;
    
    // 关键修复：如果新消息为空，直接返回，不显示任何内容
    if ((newMessage ?: @"").length == 0) {
        return;
    }
    
    if ([self.currentMessage isEqualToString:newMessage]) {
        return;
    }
    
    // 检测是否进入流式模式
    BOOL enteringStreamingMode = (self.currentMessage.length == 0 && newMessage.length > 0);
    BOOL continuingStreaming = (newMessage.length > self.currentMessage.length && [newMessage hasPrefix:self.currentMessage]);
    
    if (enteringStreamingMode || continuingStreaming) {
        self.isStreamingMode = YES;
    }
    
    self.currentMessage = [newMessage copy];
    
    // 重置缓存尺寸
    self.cachedSize = CGSizeZero;
    
    // 关键改进：在流式模式下，直接更新文本内容，不启动动画
    if (self.isStreamingMode) {
        // 流式模式下，直接更新文本节点，实现按行显示效果
        [self updateTextContentDirectly:newMessage];
    } else {
        // 非流式模式：检查是否需要重新解析以保持富文本效果
        BOOL shouldReparse = [self shouldReparseText:newMessage];
        
        if (shouldReparse) {
            // 重新解析时重置布局稳定性
            self.isLayoutStable = YES;
            
            // 关键优化：使用无动画更新，减少视觉跳跃
            [UIView performWithoutAnimation:^{
                [self forceParseMessage:newMessage];
            }];
        } else {
            [self updateExistingNodesWithNewText:newMessage];
        }
    }
    
    // 关键修复：确保初始状态正确显示
    if (enteringStreamingMode) {
        // 首次进入流式模式时，强制更新一次确保显示
        dispatch_async(dispatch_get_main_queue(), ^{
            [self setNeedsLayout];
            [self layoutIfNeeded];
        });
    }
}

// MARK: - Private Methods

- (void)parseMessage:(NSString *)message {
    if (self.isUpdating) return;
    
    // 关键优化：将富文本渲染放在后台线程，减少主线程压力
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 后台线程：Markdown解析和富文本处理
        NSArray<AIMarkdownBlock *> *markdownBlocks = [self.markdownParser parse:message];
        
        // 将 Markdown 语义块转换为 ParserResult
        NSMutableArray<ParserResult *> *results = [NSMutableArray array];
        
        // 关键改进：如果解析结果为空，强制创建一个段落结果
        if (markdownBlocks.count == 0 && message.length > 0) {
            NSMutableAttributedString *fallbackText = [[NSMutableAttributedString alloc] initWithString:message];
            [fallbackText addAttributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:16],
                NSForegroundColorAttributeName: self.isFromUser ? [UIColor whiteColor] : [UIColor blackColor],
                NSParagraphStyleAttributeName: [self defaultParagraphStyle]
            } range:NSMakeRange(0, fallbackText.length)];
            // 应用内联 Markdown 样式，保持富文本效果
            [self applyMarkdownStyles:fallbackText];
            
            ParserResult *fallbackResult = [[ParserResult alloc] initWithAttributedString:fallbackText
                                                                               isCodeBlock:NO
                                                                         codeBlockLanguage:nil];
            [results addObject:fallbackResult];
        } else {
            for (AIMarkdownBlock *block in markdownBlocks) {
                if (block.type == AIMarkdownBlockTypeCodeBlock) {
                    // 代码块：创建代码块结果
                    if (!block.code || block.code.length == 0) {
                        continue;
                    }
                    
                    NSAttributedString *codeText = [[NSAttributedString alloc] initWithString:block.code];
                    
                    ParserResult *codeResult = [[ParserResult alloc] initWithAttributedString:codeText
                                                                                   isCodeBlock:YES
                                                                             codeBlockLanguage:block.language];
                    [results addObject:codeResult];
                    
                } else if (block.type == AIMarkdownBlockTypeHeading) {
                    // 标题：创建富文本
                    NSMutableAttributedString *headingText = [[NSMutableAttributedString alloc] initWithString:block.text];
                    CGFloat fontSize = (block.headingLevel <= 2) ? 22 : 18;
                    UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
                    
                    [headingText addAttributes:@{
                        NSFontAttributeName: font,
                        NSForegroundColorAttributeName: self.isFromUser ? [UIColor whiteColor] : [UIColor blackColor]
                    } range:NSMakeRange(0, headingText.length)];
                    
                    ParserResult *headingResult = [[ParserResult alloc] initWithAttributedString:headingText
                                                                                       isCodeBlock:NO
                                                                                 codeBlockLanguage:nil];
                    [results addObject:headingResult];
                    
                } else {
                    // 段落：创建富文本
                    NSMutableAttributedString *paragraphText = [[NSMutableAttributedString alloc] initWithString:block.text];
                    UIFont *font = [UIFont systemFontOfSize:16];
                    
                    [paragraphText addAttributes:@{
                        NSFontAttributeName: font,
                        NSForegroundColorAttributeName: self.isFromUser ? [UIColor whiteColor] : [UIColor blackColor],
                        NSParagraphStyleAttributeName: [self defaultParagraphStyle]
                    } range:NSMakeRange(0, paragraphText.length)];
                    
                    // 应用 Markdown 内联样式
                    [self applyMarkdownStyles:paragraphText];
                    
                    ParserResult *paragraphResult = [[ParserResult alloc] initWithAttributedString:paragraphText
                                                                                        isCodeBlock:NO
                                                                                  codeBlockLanguage:nil];
                    [results addObject:paragraphResult];
                }
            }
        }
        
        // 主线程：UI更新
        dispatch_async(dispatch_get_main_queue(), ^{
            self.parsedResults = [results copy];
            self.lastParsedLength = message.length;
            self.lastParsedText = [message copy];
            
            [self updateContentNode];
        });
    });
}

- (void)updateContentNode {
    if (self.isUpdating) return;
    
    self.isUpdating = YES;
    
    // 使用节点缓存，避免重复创建
    NSMutableArray<ASDisplayNode *> *childNodes = [NSMutableArray array];
    NSMutableSet<ASDisplayNode *> *addedNodes = [NSMutableSet set]; // 防止重复添加
    
    if (self.parsedResults.count == 0) {
        // 关键修复：如果解析结果为空且消息也为空，则不显示任何内容
        if (self.currentMessage.length == 0) {
            self.renderNodes = @[];
            self.isUpdating = NO;
            return;
        }
        
        // 如果消息不为空但解析失败，显示原始消息
        NSString *displayText = self.currentMessage;
        ASTextNode *defaultTextNode = [self getOrCreateTextNodeForText:displayText];
        // 关键修复：确保占位符节点完全可见
        defaultTextNode.alpha = 1.0;
        if (![addedNodes containsObject:defaultTextNode]) {
            [childNodes addObject:defaultTextNode];
            [addedNodes addObject:defaultTextNode];
        }
    } else {
        for (NSInteger i = 0; i < self.parsedResults.count; i++) {
            ParserResult *result = self.parsedResults[i];
            
            if (result.isCodeBlock) {
                // 关键改进：智能检查是否需要重新创建代码块节点
                ASDisplayNode *codeNode = nil;
                
                // 检查现有渲染节点中是否有可重用的代码块
                if (i < self.renderNodes.count) {
                    ASDisplayNode *existingNode = self.renderNodes[i];
                    if ([existingNode isKindOfClass:[AICodeBlockNode class]]) {
                        // 使用新方法检查代码块内容是否发生变化
                        if (![self isCodeBlockContentChanged:existingNode forResult:result]) {
                            codeNode = existingNode;
                        }
                    }
                }
                
                // 如果没有可重用的节点，则创建新的
                if (!codeNode) {
                    codeNode = [self createCodeBlockNode:result];
                }
                
                if (![addedNodes containsObject:codeNode]) {
                    [childNodes addObject:codeNode];
                    [addedNodes addObject:codeNode];
                }
            } else {
                // 创建文本节点
                ASTextNode *textNode = [self getOrCreateTextNodeForAttributedString:result.attributedString];
                
                if (![addedNodes containsObject:textNode]) {
                    [childNodes addObject:textNode];
                    [addedNodes addObject:textNode];
                }
            }
        }
    }
    
    // 关键修复：确保始终有内容显示，避免空白气泡
    if (childNodes.count == 0) {
        NSString *fallbackText = self.currentMessage.length > 0 ? self.currentMessage : @"";
        if (fallbackText.length == 0) {
            // 如果消息为空，不显示任何内容
            self.renderNodes = @[];
            self.isUpdating = NO;
            return;
        }
        
        ASTextNode *fallbackNode = [self getOrCreateTextNodeForText:fallbackText];
        // 关键修复：确保占位符节点可以显示完整内容
        fallbackNode.style.flexGrow = 1.0;
        fallbackNode.style.flexShrink = 1.0;
        fallbackNode.alpha = 1.0; // 确保完全可见
        if (![addedNodes containsObject:fallbackNode]) {
            [childNodes addObject:fallbackNode];
            [addedNodes addObject:fallbackNode];
        }
    }
    
    // 富文本实时更新：每次都更新渲染节点，确保富文本效果实时显示
    BOOL contentChanged = ![self.renderNodes isEqualToArray:childNodes];
    
    if (contentChanged) {
        self.renderNodes = [childNodes copy];
        
        // 关键修复：确保所有节点都可见，避免空白
        for (ASDisplayNode *node in self.renderNodes) {
            if (node && node.layer) {
                node.alpha = 1.0;
            }
        }
        
        // 富文本实时更新：立即布局，确保效果实时显示
        [self immediateLayoutUpdate];
    }
    
    self.isUpdating = NO;
}


- (void)forceParseMessage:(NSString *)message {
    // 富文本实时解析：使用 AIMarkdownParser 进行完整解析
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_HIGH, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        // 后台线程：Markdown解析和富文本处理（高优先级）
        NSArray<AIMarkdownBlock *> *markdownBlocks = [strongSelf.markdownParser parse:(message ?: @"")];
        
        // 将 Markdown 语义块转换为 ParserResult
        NSMutableArray<ParserResult *> *results = [NSMutableArray array];
        
        // 关键改进：如果解析结果为空，强制创建一个段落结果
        if (markdownBlocks.count == 0 && message.length > 0) {
            NSMutableAttributedString *fallbackText = [[NSMutableAttributedString alloc] initWithString:message];
            [fallbackText addAttributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:16],
                NSForegroundColorAttributeName: strongSelf.isFromUser ? [UIColor whiteColor] : [UIColor blackColor],
                NSParagraphStyleAttributeName: [strongSelf defaultParagraphStyle]
            } range:NSMakeRange(0, fallbackText.length)];
            // 应用内联 Markdown 样式
            [strongSelf applyMarkdownStyles:fallbackText];
            
            ParserResult *fallbackResult = [[ParserResult alloc] initWithAttributedString:fallbackText
                                                                               isCodeBlock:NO
                                                                         codeBlockLanguage:nil];
            [results addObject:fallbackResult];
        } else {
            for (AIMarkdownBlock *block in markdownBlocks) {
                if (block.type == AIMarkdownBlockTypeCodeBlock) {
                    // 代码块：创建代码块结果
                    if (!block.code || block.code.length == 0) {
                        continue;
                    }
                    
                    NSAttributedString *codeText = [[NSAttributedString alloc] initWithString:block.code];
                    
                    ParserResult *codeResult = [[ParserResult alloc] initWithAttributedString:codeText
                                                                                   isCodeBlock:YES
                                                                             codeBlockLanguage:block.language];
                    [results addObject:codeResult];
                    
                } else if (block.type == AIMarkdownBlockTypeHeading) {
                    // 标题：创建富文本
                    NSMutableAttributedString *headingText = [[NSMutableAttributedString alloc] initWithString:block.text];
                    CGFloat fontSize = (block.headingLevel <= 2) ? 22 : 18;
                    UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
                    
                    [headingText addAttributes:@{
                        NSFontAttributeName: font,
                        NSForegroundColorAttributeName: strongSelf.isFromUser ? [UIColor whiteColor] : [UIColor blackColor]
                    } range:NSMakeRange(0, headingText.length)];
                    
                    ParserResult *headingResult = [[ParserResult alloc] initWithAttributedString:headingText
                                                                                       isCodeBlock:NO
                                                                                 codeBlockLanguage:nil];
                    [results addObject:headingResult];
                    
                } else {
                    // 段落：创建富文本
                    NSMutableAttributedString *paragraphText = [[NSMutableAttributedString alloc] initWithString:block.text];
                    UIFont *font = [UIFont systemFontOfSize:16];
                    
                    [paragraphText addAttributes:@{
                        NSFontAttributeName: font,
                        NSForegroundColorAttributeName: strongSelf.isFromUser ? [UIColor whiteColor] : [UIColor blackColor],
                        NSParagraphStyleAttributeName: [strongSelf defaultParagraphStyle]
                    } range:NSMakeRange(0, paragraphText.length)];
                    
                    // 应用 Markdown 内联样式
                    [strongSelf applyMarkdownStyles:paragraphText];
                    
                    ParserResult *paragraphResult = [[ParserResult alloc] initWithAttributedString:paragraphText
                                                                                        isCodeBlock:NO
                                                                                  codeBlockLanguage:nil];
                    [results addObject:paragraphResult];
                }
            }
        }
        
        // 主线程：UI更新
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.parsedResults = [results copy];
            strongSelf.lastParsedLength = message.length;
            strongSelf.lastParsedText = [message copy];
            
            [strongSelf updateContentNode];
            [strongSelf setNeedsLayout];
        });
    });
}

- (NSArray<NSString *> *)splitMessageIntoParts:(NSString *)message {
    // 此方法已废弃，现在使用统一的ResponseParsingTask
    return @[message];
}

- (BOOL)isCodeBlock:(NSString *)text {
    // 此方法已废弃，现在使用统一的ResponseParsingTask
    return [text containsString:@"```"];
}

- (NSString *)extractCodeLanguage:(NSString *)codeBlock {
    // 此方法已废弃，现在使用统一的ResponseParsingTask
    return @"code";
}

- (NSAttributedString *)attributedStringForText:(NSString *)text {
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.lineSpacing = 5; // 与 MessageCellNode 一致
    paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
    
    UIColor *textColor = self.isFromUser ? [UIColor whiteColor] : [UIColor blackColor];
    
    // 简化版本：只应用基础样式
    NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc] initWithString:text];
    
    // 应用基础样式
    [attributedString addAttributes:@{
        NSParagraphStyleAttributeName: paragraphStyle,
        NSFontAttributeName: [UIFont systemFontOfSize:17], // 与 MessageCellNode 一致
        NSForegroundColorAttributeName: textColor
    } range:NSMakeRange(0, attributedString.length)];
    
    return [attributedString copy];
}

- (NSAttributedString *)attributedStringForCodeBlock:(NSString *)codeBlock {
    // 此方法已废弃，现在使用统一的ResponseParsingTask
    return [self attributedStringForText:codeBlock];
}

// 统一的样式应用方法
- (void)applyMarkdownStyles:(NSMutableAttributedString *)attributedString {
    NSString *text = attributedString.string;
    
    // 预编译正则表达式，避免重复创建
    static NSRegularExpression *boldRegex = nil;
    static NSRegularExpression *italicRegex = nil;
    static NSRegularExpression *codeRegex = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        boldRegex = [NSRegularExpression regularExpressionWithPattern:@"\\*\\*(.*?)\\*\\*" options:0 error:nil];
        italicRegex = [NSRegularExpression regularExpressionWithPattern:@"\\*(.*?)\\*" options:0 error:nil];
        codeRegex = [NSRegularExpression regularExpressionWithPattern:@"`(.*?)`" options:0 error:nil];
    });
    
    // 应用粗体样式
    [self applyStyleWithRegex:boldRegex 
                    toAttributedString:attributedString 
                    styleBlock:^UIFont *(UIFont *currentFont) {
        return [UIFont fontWithDescriptor:[currentFont.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitBold] 
                                    size:currentFont.pointSize];
    }];
    
    // 应用斜体样式
    [self applyStyleWithRegex:italicRegex 
                    toAttributedString:attributedString 
                    styleBlock:^UIFont *(UIFont *currentFont) {
        return [UIFont fontWithDescriptor:[currentFont.fontDescriptor fontDescriptorWithSymbolicTraits:UIFontDescriptorTraitItalic] 
                                    size:currentFont.pointSize];
    }];
    
    // 应用内联代码样式
    [self applyCodeStyleWithRegex:codeRegex toAttributedString:attributedString];
}

// 通用的样式应用方法
- (void)applyStyleWithRegex:(NSRegularExpression *)regex 
                toAttributedString:(NSMutableAttributedString *)attributedString 
                styleBlock:(UIFont *(^)(UIFont *))styleBlock {
    NSString *text = attributedString.string;
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    
    for (NSInteger i = matches.count - 1; i >= 0; i--) {
        NSTextCheckingResult *match = matches[i];
        NSRange styleRange = [match rangeAtIndex:1];
        
        UIFont *currentFont = [attributedString attribute:NSFontAttributeName atIndex:styleRange.location effectiveRange:nil] ?: [UIFont systemFontOfSize:17];
        UIFont *styledFont = styleBlock(currentFont);
        
        [attributedString addAttribute:NSFontAttributeName value:styledFont range:styleRange];
        [attributedString replaceCharactersInRange:[match rangeAtIndex:0] withString:[text substringWithRange:styleRange]];
    }
}

// 代码样式应用方法
- (void)applyCodeStyleWithRegex:(NSRegularExpression *)regex 
                toAttributedString:(NSMutableAttributedString *)attributedString {
    NSString *text = attributedString.string;
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    
    for (NSInteger i = matches.count - 1; i >= 0; i--) {
        NSTextCheckingResult *match = matches[i];
        NSRange codeRange = [match rangeAtIndex:1];
        
        UIColor *backgroundColor = self.isFromUser ? 
            [UIColor colorWithRed:1.0 green:1.0 blue:1.0 alpha:0.2] :
            [UIColor colorWithRed:0/255.0 green:0/255.0 blue:0/255.0 alpha:0.1];
        
        [attributedString addAttributes:@{
            NSFontAttributeName: [UIFont monospacedSystemFontOfSize:16 weight:UIFontWeightRegular],
            NSBackgroundColorAttributeName: backgroundColor
        } range:codeRange];
        
        [attributedString replaceCharactersInRange:[match rangeAtIndex:0] withString:[text substringWithRange:codeRange]];
    }
}

// 统一的文本节点创建方法
- (ASTextNode *)getOrCreateTextNodeForText:(NSString *)text {
    NSString *cacheKey = [NSString stringWithFormat:@"text_%@", text];
    ASTextNode *cachedNode = self.nodeCache[cacheKey];
    
    if (!cachedNode) {
        cachedNode = [[ASTextNode alloc] init];
        cachedNode.attributedText = [self attributedStringForText:text];
        cachedNode.maximumNumberOfLines = 0;
        cachedNode.style.flexGrow = 1.0;
        cachedNode.style.flexShrink = 1.0;
        self.nodeCache[cacheKey] = cachedNode;
    }
    
    return cachedNode;
}

// 统一的富文本节点创建方法
- (ASTextNode *)getOrCreateTextNodeForAttributedString:(NSAttributedString *)attributedString {
    NSString *cacheKey = [NSString stringWithFormat:@"attributed_%lu", (unsigned long)attributedString.hash];
    ASTextNode *cachedNode = self.nodeCache[cacheKey];
    
    if (!cachedNode) {
        cachedNode = [[ASTextNode alloc] init];
        cachedNode.attributedText = attributedString;
        cachedNode.maximumNumberOfLines = 0;
        cachedNode.style.flexGrow = 1.0;
        cachedNode.style.flexShrink = 1.0;
        self.nodeCache[cacheKey] = cachedNode;
    }
    
    return cachedNode;
}

// 新增：创建代码块节点
- (ASDisplayNode *)createCodeBlockNode:(ParserResult *)result {
    NSString *codeText = result.attributedString.string ?: @"";
    NSString *language = result.codeBlockLanguage.length > 0 ? result.codeBlockLanguage : @"code";
    
    // 关键改进：为代码块创建唯一的缓存键
    NSString *cacheKey = [NSString stringWithFormat:@"codeblock_%@_%@_%lu", 
                          language, 
                          [codeText substringToIndex:MIN(50, codeText.length)], 
                          (unsigned long)codeText.length];
    
    // 检查缓存中是否已存在相同的代码块节点
    ASDisplayNode *cachedNode = self.nodeCache[cacheKey];
    if (cachedNode) {
        return cachedNode;
    }
    
    // 使用新的 AICodeBlockNode
    AICodeBlockNode *codeBlockNode = [[AICodeBlockNode alloc] initWithCode:codeText 
                                                                   language:language 
                                                                 isFromUser:self.isFromUser];
    
    // 缓存新创建的代码块节点
    self.nodeCache[cacheKey] = codeBlockNode;
    
    return codeBlockNode;
}

// 新增：检查代码块内容是否发生变化
- (BOOL)isCodeBlockContentChanged:(ASDisplayNode *)existingNode forResult:(ParserResult *)result {
    if (![existingNode isKindOfClass:[AICodeBlockNode class]]) {
        return YES; // 类型不同，需要重新创建
    }
    
    AICodeBlockNode *existingCodeNode = (AICodeBlockNode *)existingNode;
    
    // 使用KVC获取属性值，避免直接访问私有属性
    NSString *existingCode = nil;
    NSString *existingLanguage = nil;
    
    @try {
        existingCode = [existingCodeNode valueForKey:@"code"];
        existingLanguage = [existingCodeNode valueForKey:@"language"];
    } @catch (NSException *exception) {
        NSLog(@"RichMessageCellNode: 无法获取代码块属性，需要重新创建: %@", exception.reason);
        return YES;
    }
    
    // 检查代码内容和语言是否相同
    BOOL contentChanged = ![existingCode isEqualToString:result.attributedString.string];
    BOOL languageChanged = ![existingLanguage isEqualToString:result.codeBlockLanguage];
    
    if (contentChanged || languageChanged) {
        return YES;
    }
    
    return NO;
}

// 新增：富文本实时布局更新（无节流，确保实时显示）
- (void)immediateLayoutUpdate {
    // 富文本实时更新：立即布局，不进行节流
    if ([NSThread isMainThread]) {
        [UIView performWithoutAnimation:^{
            [self setNeedsLayout];
            [self layoutIfNeeded];
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIView performWithoutAnimation:^{
                [self setNeedsLayout];
                [self layoutIfNeeded];
            }];
        });
    }
}

// 新增：智能布局更新（保留原有功能，用于非实时场景）
- (void)smartLayoutUpdate {
    if (!self.isLayoutStable) {
        return;
    }
    
    // 关键优化：使用更激进的节流机制，提高渲染性能
    static NSTimeInterval lastLayoutUpdateTime = 0;
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    
    if (currentTime - lastLayoutUpdateTime < 0.05) { // 从100ms减少到50ms，提高响应速度
        return;
    }
    
    lastLayoutUpdateTime = currentTime;
    
    // 确保在主线程执行布局更新，使用无动画避免TableView弹动
    if ([NSThread isMainThread]) {
        [UIView performWithoutAnimation:^{
            [self setNeedsLayout];
        }];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIView performWithoutAnimation:^{
                [self setNeedsLayout];
            }];
        });
    }
}

// 新增：默认段落样式
- (NSParagraphStyle *)defaultParagraphStyle {
    NSMutableParagraphStyle *style = [[NSMutableParagraphStyle alloc] init];
    style.lineSpacing = 5;
    style.lineBreakMode = NSLineBreakByWordWrapping;
    return style;
}

// 新增：智能增量更新现有节点（固定已显示文本）
- (void)updateExistingNodesWithNewText:(NSString *)newText {
    if (self.parsedResults.count == 0) return;
    
    // 关键改进：找到最后一个文本节点（非代码块）进行更新
    for (NSInteger i = self.parsedResults.count - 1; i >= 0; i--) {
        ParserResult *result = self.parsedResults[i];
        if (!result.isCodeBlock) {
            // 智能更新：只更新正在输入的文本，固定已显示的文本
            NSString *currentContent = result.attributedString.string;
            
            // 如果新文本比当前内容长，说明正在输入
            if (newText.length > currentContent.length) {
                // 检查是否是追加内容
                if ([newText hasPrefix:currentContent]) {
                    NSString *appendedText = [newText substringFromIndex:currentContent.length];
                    
                    // 关键改进：降低更新阈值，确保最后几句话能完整显示
                    if (appendedText.length > 1) { // 从5改为1，确保及时更新
                        
                        // 创建新的富文本属性字符串
                        NSMutableAttributedString *newAttributedString = [[NSMutableAttributedString alloc] initWithString:newText];
                        [newAttributedString addAttributes:@{
                            NSFontAttributeName: [UIFont systemFontOfSize:16],
                            NSForegroundColorAttributeName: self.isFromUser ? [UIColor whiteColor] : [UIColor blackColor],
                            NSParagraphStyleAttributeName: [self defaultParagraphStyle]
                        } range:NSMakeRange(0, newAttributedString.length)];
                        
                        // 更新解析结果
                        ParserResult *updatedResult = [[ParserResult alloc] initWithAttributedString:newAttributedString
                                                                                         isCodeBlock:NO
                                                                                   codeBlockLanguage:nil];
                        NSMutableArray<ParserResult *> *mutableResults = [self.parsedResults mutableCopy];
                        mutableResults[i] = updatedResult;
                        self.parsedResults = [mutableResults copy];
                        
                        // 更新对应的渲染节点
                        if (i < self.renderNodes.count) {
                            ASDisplayNode *existingNode = self.renderNodes[i];
                            if ([existingNode isKindOfClass:[ASTextNode class]]) {
                                ASTextNode *textNode = (ASTextNode *)existingNode;
                                
                                // 检查高度是否会发生显著变化
                                CGSize oldSize = [textNode.attributedText boundingRectWithSize:CGSizeMake(textNode.bounds.size.width, CGFLOAT_MAX) 
                                                                                      options:NSStringDrawingUsesLineFragmentOrigin 
                                                                                      context:nil].size;
                                CGSize newSize = [newAttributedString boundingRectWithSize:CGSizeMake(textNode.bounds.size.width, CGFLOAT_MAX) 
                                                                                  options:NSStringDrawingUsesLineFragmentOrigin 
                                                                                  context:nil].size;
                                
                                // 检查布局稳定性
                                BOOL isStable = [self isLayoutStableForText:newText];
                                
                                // 关键优化：降低高度阈值，提高响应速度
                                CGFloat heightDifference = fabs(newSize.height - oldSize.height);
                                if (heightDifference > 3.0 && isStable) { // 从5改为3像素，更敏感
                                    
                                    textNode.attributedText = newAttributedString;
                                    // 关键优化：减少布局更新频率，避免TableView弹动
                                    [self performDelayedLayoutUpdate];
                                } else if (heightDifference > 3.0 && !isStable) {
                                    // 高度变化显著但布局不稳定，标记为不稳定
                                    self.isLayoutStable = NO;
                                    textNode.attributedText = newAttributedString;
                                } else {
                                    // 高度变化微小，只更新文本内容，不触发布局
                                    textNode.attributedText = newAttributedString;
                                }
                            }
                        }
                    } else {
                        // 追加内容过短，跳过更新
                    }
                } else {
                    // 不是追加内容，可能是重新开始输入
                }
            } else {
                // 新文本比当前内容短，可能是删除操作，跳过
            }
            
            break; // 只更新最后一个文本节点
        }
    }
}

// 新增：延迟布局更新，减少TableView弹动
- (void)performDelayedLayoutUpdate {
    // 使用更激进的节流机制，提高渲染性能
    static NSTimeInterval lastLayoutUpdateTime = 0;
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    
    if (currentTime - lastLayoutUpdateTime < 0.05) { // 从100ms减少到50ms，提高响应速度
        return;
    }
    
    lastLayoutUpdateTime = currentTime;
    
    // 关键优化：减少延迟时间，提高响应速度
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [UIView performWithoutAnimation:^{
            [self setNeedsLayout];
        }];
    });
}

// 新增：检查布局是否稳定
- (BOOL)isLayoutStableForText:(NSString *)text {
    if (!text || text.length == 0) return YES;
    
    NSString *cacheKey = [NSString stringWithFormat:@"stable_%@", text];
    NSNumber *cachedValue = self.layoutCache[cacheKey];
    
    if (cachedValue) {
        return cachedValue.boolValue;
    }
    
    // 检查文本是否包含可能导致布局变化的元素
    BOOL isStable = YES;
    
    // 检查是否包含代码块标记
    if ([text containsString:@"```"]) {
        isStable = NO;
    }
    
    // 检查是否包含标题标记
    if ([text containsString:@"###"] || [text containsString:@"##"] || [text containsString:@"#"]) {
        isStable = NO;
    }
    
    // 检查是否包含列表标记
    if ([text containsString:@"- "] || [text containsString:@"* "]) {
        isStable = NO;
    }
    
    // 缓存结果
    self.layoutCache[cacheKey] = @(isStable);
    
    return isStable;
}

// 新增：智能判断是否需要重新解析
- (BOOL)shouldReparseText:(NSString *)newText {
    // 如果文本相同，不需要重新解析
    if ([newText isEqualToString:self.lastParsedText]) {
        return NO;
    }
    
    // 计算新增内容
    NSString *appendedText = @"";
    if (newText.length > self.lastParsedText.length && [newText hasPrefix:self.lastParsedText]) {
        appendedText = [newText substringFromIndex:self.lastParsedText.length];
    }
    
    // 如果新增内容包含完整的代码块结束标记（从未闭合变为闭合），需要重新解析
    if ([appendedText containsString:@"```"] && [self.lastParsedText containsString:@"```"]) {
        // 计算上次解析时代码块开始标记的数量
        NSInteger lastCodeBlockStarts = [[self.lastParsedText componentsSeparatedByString:@"```"] count] - 1;
        NSInteger newCodeBlockStarts = [[newText componentsSeparatedByString:@"```"] count] - 1;
        
        // 如果代码块标记数量从奇数变为偶数，说明有代码块闭合了
        if (lastCodeBlockStarts % 2 == 1 && newCodeBlockStarts % 2 == 0) {
            return YES;
        }
    }
    
    // 如果新文本新增了完整的 Markdown 结构，需要重新解析
    if ([appendedText rangeOfString:@"\n### " options:0].location != NSNotFound ||
        [appendedText rangeOfString:@"\n## " options:0].location != NSNotFound ||
        [appendedText rangeOfString:@"\n# " options:0].location != NSNotFound ||
        [appendedText rangeOfString:@"\n- " options:0].location != NSNotFound ||
        [appendedText rangeOfString:@"\n* " options:0].location != NSNotFound ||
        [appendedText rangeOfString:@"**" options:0].location != NSNotFound) {
        return YES;
    }
    
    // 如果文本长度变化很大，可能需要重新解析
    if (abs((int)(newText.length - self.lastParsedText.length)) > 100) {
        return YES;
    }
    
    return NO;
}

// MARK: - 丝滑渐显动画核心方法

// 启动丝滑渐显动画
- (void)startSmoothFadeInAnimation {
    if (self.displayLink) {
        return; // 动画已在运行
    }
    
    // 重置动画状态
    self.currentStreamingIndex = 0;
    self.lastAnimationTime = 0;
    
    // 创建CADisplayLink，60fps的流畅动画
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(updateSmoothAnimation:)];
    self.displayLink.preferredFramesPerSecond = 60;
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

// 更新丝滑渐显动画 - 逐行渐显逻辑
- (void)updateSmoothAnimation:(CADisplayLink *)displayLink {
    NSTimeInterval currentTime = CACurrentMediaTime();
    NSTimeInterval deltaTime = currentTime - self.lastAnimationTime;
    
    // 关键优化：提高动画频率到30fps，更流畅的体验
    if (deltaTime < 0.033) { // 约30fps，平衡性能和流畅度
        return;
    }
    
    self.lastAnimationTime = currentTime;
    
    // 获取当前需要渐显的节点
    if (self.currentStreamingIndex < self.renderNodes.count) {
        ASDisplayNode *node = self.renderNodes[self.currentStreamingIndex];
        
        // 应用逐行渐显效果
        [self applyLineByLineFadeInToNode:node atIndex:self.currentStreamingIndex];
        
        self.currentStreamingIndex++;
        
        // 检查是否所有节点都已渐显完成
        if (self.currentStreamingIndex >= self.renderNodes.count) {
            [self completeSmoothAnimation];
        }
    }
}

// 应用逐行渐显到指定节点
- (void)applyLineByLineFadeInToNode:(ASDisplayNode *)node atIndex:(NSInteger)index {
    // 关键改进：只对新节点应用渐显，已显示的节点保持不变
    if (node.alpha >= 1.0) {
        return; // 节点已经完全可见，跳过
    }
    
    // 设置节点初始状态为透明
    node.alpha = 0.0;
    
    // 关键优化：实现真正的逐行遮盖显示效果
    if ([node isKindOfClass:[ASTextNode class]]) {
        ASTextNode *textNode = (ASTextNode *)node;
        [self applyTextNodeRevealAnimation:textNode atIndex:index];
    } else {
        // 非文本节点使用传统的渐显动画
        [self applyTraditionalFadeInAnimation:node atIndex:index];
    }
}

// 新增：文本节点的逐行遮盖显示动画
- (void)applyTextNodeRevealAnimation:(ASTextNode *)textNode atIndex:(NSInteger)index {
    // 创建遮罩层，实现逐行显示效果
    CAShapeLayer *maskLayer = [CAShapeLayer layer];
    maskLayer.frame = textNode.bounds;
    maskLayer.fillColor = [UIColor blackColor].CGColor; // 黑色表示显示区域
    
    // 初始状态：完全隐藏
    UIBezierPath *initialPath = [UIBezierPath bezierPathWithRect:CGRectMake(0, 0, 0, textNode.bounds.size.height)];
    maskLayer.path = initialPath.CGPath;
    
    // 设置遮罩
    textNode.layer.mask = maskLayer;
    
    // 创建动画：从左到右逐渐显示
    CABasicAnimation *revealAnimation = [CABasicAnimation animationWithKeyPath:@"path"];
    revealAnimation.fromValue = (__bridge id)initialPath.CGPath;
    
    // 最终状态：完全显示
    UIBezierPath *finalPath = [UIBezierPath bezierPathWithRect:textNode.bounds];
    revealAnimation.toValue = (__bridge id)finalPath.CGPath;
    
    // 动画配置
    revealAnimation.duration = 0.3; // 300ms的显示时间
    revealAnimation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    revealAnimation.fillMode = kCAFillModeForwards;
    revealAnimation.removedOnCompletion = NO;
    
    // 为每个节点设置不同的延迟，创造逐行出现的效果
    revealAnimation.beginTime = CACurrentMediaTime() + (index * 0.08); // 每行延迟80ms，更流畅
    
    // 应用动画
    [maskLayer addAnimation:revealAnimation forKey:[NSString stringWithFormat:@"reveal_%ld", (long)index]];
    
    // 同时应用透明度动画，增强效果
    CABasicAnimation *fadeAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fadeAnimation.fromValue = @(0.0);
    fadeAnimation.toValue = @(1.0);
    fadeAnimation.duration = 0.2; // 200ms的渐显时间
    fadeAnimation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    fadeAnimation.fillMode = kCAFillModeForwards;
    fadeAnimation.removedOnCompletion = NO;
    fadeAnimation.beginTime = CACurrentMediaTime() + (index * 0.08);
    
    [textNode.layer addAnimation:fadeAnimation forKey:[NSString stringWithFormat:@"fade_%ld", (long)index]];
    
    // 立即设置最终状态，避免闪烁
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        textNode.alpha = 1.0;
        maskLayer.path = finalPath.CGPath;
    });
}

// 新增：传统渐显动画（用于非文本节点）
- (void)applyTraditionalFadeInAnimation:(ASDisplayNode *)node atIndex:(NSInteger)index {
    // 创建渐显动画
    CABasicAnimation *fadeInAnimation = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fadeInAnimation.fromValue = @(0.0);
    fadeInAnimation.toValue = @(1.0);
    fadeInAnimation.duration = 0.3; // 300ms的渐显时间，更流畅
    fadeInAnimation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    fadeInAnimation.fillMode = kCAFillModeForwards; // 保持最终状态
    fadeInAnimation.removedOnCompletion = NO; // 不移除动画
    
    // 为每个节点设置不同的延迟，创造逐行出现的效果
    fadeInAnimation.beginTime = CACurrentMediaTime() + (index * 0.08); // 每行延迟80ms，更流畅
    
    // 应用动画
    [node.layer addAnimation:fadeInAnimation forKey:[NSString stringWithFormat:@"fadeIn_%ld", (long)index]];
    
    // 立即设置最终状态，避免闪烁
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        node.alpha = 1.0;
    });
}

// 完成丝滑渐显动画
- (void)completeSmoothAnimation {
    // 停止显示链接
    if (self.displayLink) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
    
    // 退出流式模式
    self.isStreamingMode = NO;
    
    // 确保所有节点都完全可见
    for (ASDisplayNode *node in self.renderNodes) {
        node.alpha = 1.0;
        // 移除所有动画
        [node.layer removeAllAnimations];
    }
    
    // 触发最终布局更新，确保富文本完全渲染
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsLayout];
        [self layoutIfNeeded];
    });
}

// 新增：流式更新完成时的处理
- (void)completeStreamingUpdate {
    if (self.isStreamingMode) {
        // 强制完成所有富文本解析
        [self forceParseMessage:self.currentMessage];
        
        // 确保所有节点都完全可见
        for (ASDisplayNode *node in self.renderNodes) {
            node.alpha = 1.0;
            // 移除所有动画
            [node.layer removeAllAnimations];
        }
        
        // 退出流式模式
        self.isStreamingMode = NO;
        
        // 停止动画
        if (self.displayLink) {
            [self.displayLink invalidate];
            self.displayLink = nil;
        }
        
        // 最终布局更新（无动画）
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIView performWithoutAnimation:^{
                [self setNeedsLayout];
                [self layoutIfNeeded];
            }];
        });
    }
}

// 新增：检查富文本是否完全渲染
- (BOOL)isRichTextFullyRendered {
    if (self.parsedResults.count == 0) {
        return NO;
    }
    
    // 检查所有解析结果是否都有对应的渲染节点
    if (self.parsedResults.count != self.renderNodes.count) {
        return NO;
    }
    
    // 检查所有节点是否都完全可见
    for (ASDisplayNode *node in self.renderNodes) {
        if (node.alpha < 1.0) {
            return NO;
        }
    }
    
    return YES;
}

// 缓存清理方法
- (void)clearCache {
    [self.nodeCache removeAllObjects];
    [self.layoutCache removeAllObjects];
}

// MARK: - Public: 高度缓存接口

- (CGFloat)cachedHeightForText:(NSString *)text width:(CGFloat)width {
    if (text.length == 0 || width <= 1.0) {
        return 0.0;
    }
    // 使用文本hash与宽度生成缓存键
    NSString *cacheKey = [NSString stringWithFormat:@"%lu_%.1f", (unsigned long)text.hash, width];
    NSNumber *cached = self.heightCache[cacheKey];
    if (cached) {
        return cached.doubleValue;
    }

    // 计算富文本高度
    NSAttributedString *attr = [self attributedStringForText:text];
    CGSize bounding = [attr boundingRectWithSize:CGSizeMake(width, CGFLOAT_MAX)
                                         options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                         context:nil].size;
    // 额外内边距：cell 外边距(5+5) + 气泡内边距(10+10)
    CGFloat extra = 5.0 + 5.0 + 10.0 + 10.0;
    CGFloat height = ceil(bounding.height + extra);
    self.heightCache[cacheKey] = @(height);
    return height;
}

- (void)clearHeightCache {
    [self.heightCache removeAllObjects];
}

// MARK: - Public: 测试与调试辅助

- (void)testSimpleCodeBlock {
    NSString *demo = @"```\nprint(\"Hello\")\n```";
    [self forceParseMessage:demo];
}

- (void)testCodeBlockDisplay {
    NSString *demo = @"# 标题\n\n这是段落。\n\n```swift\nlet x = 1\nprint(x)\n```\n\n继续正文。";
    [self forceParseMessage:demo];
}

- (void)setTestParsedResults {
    NSMutableAttributedString *p1 = [[NSMutableAttributedString alloc] initWithString:@"这是一个段落测试。"];
    [p1 addAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:16],
                         NSForegroundColorAttributeName: (self.isFromUser ? [UIColor whiteColor] : [UIColor blackColor]),
                         NSParagraphStyleAttributeName: [self defaultParagraphStyle]
    } range:NSMakeRange(0, p1.length)];

    NSAttributedString *code = [[NSAttributedString alloc] initWithString:@"print('code')\nlet a = 1"];
    ParserResult *r1 = [[ParserResult alloc] initWithAttributedString:p1 isCodeBlock:NO codeBlockLanguage:nil];
    ParserResult *r2 = [[ParserResult alloc] initWithAttributedString:code isCodeBlock:YES codeBlockLanguage:@"swift"];
    self.parsedResults = @[r1, r2];
    [self updateContentNode];
}

// 在dealloc中清理缓存
- (void)dealloc {
    // 停止动画
    if (self.displayLink) {
        [self.displayLink invalidate];
        self.displayLink = nil;
    }
    
    [self clearCache];
}

// MARK: - 按行更新优化方法

// 新增：检测文本中是否有新的完整行
- (BOOL)detectNewLinesInText:(NSString *)newText {
    if (!newText || newText.length == 0) {
        return NO;
    }
    
    // 计算新文本中的行数
    NSArray<NSString *> *newLines = [newText componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    NSArray<NSString *> *currentLines = [self.currentMessage componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    
    // 如果新文本的行数比当前文本多，说明有新行
    if (newLines.count > currentLines.count) {
        return YES;
    }
    
    // 检查是否有行内容发生变化（长度增加超过阈值）
    if (newLines.count == currentLines.count) {
        for (NSInteger i = 0; i < newLines.count; i++) {
            if (i < currentLines.count) {
                NSString *newLine = newLines[i];
                NSString *currentLine = currentLines[i];
                
                // 如果某一行长度增加超过5个字符，认为有新内容（降低阈值，提高响应性）
                if (newLine.length > currentLine.length + 5) {
                    return YES;
                }
            }
        }
    }
    
    return NO;
}

- (void)updateTextContentDirectly:(NSString *)newMessage {
    if (!newMessage || newMessage.length == 0) {
        return;
    }
    
    // 更新当前消息
    self.currentMessage = [newMessage copy];
    
    // 富文本逐行显示：每次都进行富文本解析，确保实时显示富文本效果
    [self forceParseMessage:newMessage];
    
    // 强制布局更新，确保UI立即反映变化（无动画）
    dispatch_async(dispatch_get_main_queue(), ^{
        [UIView performWithoutAnimation:^{
            [self setNeedsLayout];
            [self layoutIfNeeded];
        }];
    });
}

// 新增：暂停流式更新动画
- (void)pauseStreamingAnimation {
    if (self.displayLink) {
        [self.displayLink setPaused:YES];
    }
}

// 新增：恢复流式更新动画
- (void)resumeStreamingAnimation {
    if (self.displayLink) {
        [self.displayLink setPaused:NO];
    }
}

@end
