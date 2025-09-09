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
// 新增：附件缩略图尺寸与间距（便于统一调节）
@property (nonatomic, assign) CGFloat attachmentImageSize;
@property (nonatomic, assign) CGFloat attachmentSpacing;
// 恢复AIMarkdownParser以保持富文本效果
@property (nonatomic, strong) AIMarkdownParser *markdownParser;
@property (nonatomic, strong) NSArray<AIMarkdownBlock *> *markdownBlocks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *layoutCache;
@property (nonatomic, assign) BOOL isLayoutStable;
// 高度缓存：key 由文本hash和宽度组成
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *heightCache;
// 新增：丝滑渐显相关属性
@property (nonatomic, assign) BOOL isStreamingMode; // 是否处于流式更新模式

// 新增：逐行渲染调度状态
@property (nonatomic, strong) NSMutableArray<NSString *> *pendingSemanticBlockQueue; // 等待处理的语义块文本
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *currentBlockLineTasks; // 当前块的逐行任务
@property (nonatomic, assign) BOOL isProcessingSemanticBlock; // 是否正在逐行渲染一个块
@property (nonatomic, strong) AICodeBlockNode *activeCodeNode; // 当前块内的活动代码节点（若存在）
@property (nonatomic, copy) NSString *activeAccumulatedCode; // 累计已渲染到代码节点的文本
@property (nonatomic, assign) BOOL pendingFinalizeWhenQueueEmpty; // 队列清空后是否退出流式

// 新增：逐行渲染节奏与日志辅助
@property (nonatomic, assign) NSTimeInterval lineRenderInterval; // 每行渲染间隔
@property (nonatomic, assign) NSInteger processedBlockCounter;   // 已处理块计数（用于日志）
@property (nonatomic, assign) NSInteger currentBlockIndex;       // 当前块序号（1-based，用于日志）
@property (nonatomic, assign) NSInteger currentBlockTotalLines;  // 当前块总行数（用于日志）
@property (nonatomic, assign) NSInteger currentBlockRenderedLineIndex; // 当前块已渲染行数（用于日志）

// 新增：在首行渲染前隐藏气泡，避免空白气泡
@property (nonatomic, assign) BOOL startHiddenUntilFirstLine;
// 新增：调度暂停标记（用户滑动期间暂停逐行推进）
@property (nonatomic, assign) BOOL isSchedulingPaused;
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
        
        // 附件缩略图默认尺寸与间距（可按需调整）
        _attachmentImageSize = 80.0;
        _attachmentSpacing = 6.0;
        
        // 新增：首行渲染前隐藏
        _startHiddenUntilFirstLine = (!isFromUser && (message.length == 0));
        
        // 新增：初始化丝滑渐显相关属性
        _isStreamingMode = NO;
        
        // 初始化解析器
        _markdownParser = [[AIMarkdownParser alloc] init];
        _markdownBlocks = @[];
        
        // 初始化解析任务
        _parsingTask = [[ResponseParsingTask alloc] init];
        _lastParsedLength = 0;
        
        // 强制首次解析消息内容
        [self parseMessage:message];
        
        // 新增：逐行渲染默认间隔与计数
        _lineRenderInterval = 0.15; // 默认 150ms/行，与控制器保持一致
        _processedBlockCounter = 0;
        _currentBlockIndex = 0;
        _currentBlockTotalLines = 0;
        _currentBlockRenderedLineIndex = 0;
        
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
        
        // 关键修复：确保附件数据在重新进入时也能正确显示
        _attachmentsData = @[];
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
    
    // 新增：首行渲染前隐藏，避免空白气泡
    if (self.startHiddenUntilFirstLine) {
        self.bubbleNode.hidden = YES;
        self.contentNode.hidden = YES;
    }
}

// MARK: - Layout

- (ASLayoutSpec *)layoutSpecThatFits:(ASSizeRange)constrainedSize {
    // 若无任何内容与附件且消息为空，返回零高度布局以避免空白气泡
    if ((self.renderNodes.count == 0) && (self.attachmentsData.count == 0) && ((self.currentMessage ?: @"").length == 0)) {
        return [ASLayoutSpec new];
    }
    // 使用解析生成的内容节点进行布局
    UIColor *backgroundColor = self.isFromUser ? [UIColor systemBlueColor] : [UIColor systemGray5Color];

    // 限制最大宽度为 75%，内部行宽也按屏幕宽度 * 0.75 动态计算
    CGFloat maxWidth = constrainedSize.max.width * 0.75;
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
        // 若有附件，使用非滚动的水平布局直接展示（不限制总行宽）
        if (strongSelf.attachmentsData.count > 0) {
            NSMutableArray<ASDisplayNode *> *thumbs = [NSMutableArray array];
            for (id att in strongSelf.attachmentsData) {
                ASDisplayNode *thumb = [strongSelf createAttachmentThumbNode:att];
                if (thumb) {
                    // 固定缩略图尺寸，由 createAttachmentThumbNode 负责
                    thumb.style.flexShrink = 0.0;
                    [thumbs addObject:thumb];
                }
            }
            if (thumbs.count > 0) {
                ASStackLayoutSpec *row = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionHorizontal
                                                                                   spacing:strongSelf.attachmentSpacing
                                                                            justifyContent:ASStackLayoutJustifyContentStart
                                                                                alignItems:ASStackLayoutAlignItemsStart
                                                                                  children:thumbs];
                // 不再添加最大宽度限制，全部按缩略图宽度自然排列
                [children addObject:row];
            }
        }
        // 关键修复：确保带有附件的消息也能正确显示文本内容
        if (children.count == 0 && (strongSelf.currentMessage.length > 0) && !strongSelf.isStreamingMode) {
            ASTextNode *placeholderNode = [[ASTextNode alloc] init];
            placeholderNode.attributedText = [strongSelf attributedStringForText:(strongSelf.currentMessage ?: @"")];
            placeholderNode.maximumNumberOfLines = 0;
            // 关键修复：确保占位符节点可以显示完整文本
            placeholderNode.style.flexGrow = 1.0;
            placeholderNode.style.flexShrink = 1.0;
            [children addObject:placeholderNode];
        }
        
        // 关键修复：如果只有附件没有文本内容，确保消息仍然可见
        if (children.count == 0 && strongSelf.attachmentsData.count > 0) {
            // 创建一个空的文本节点作为占位符，确保消息气泡可见
            ASTextNode *emptyNode = [[ASTextNode alloc] init];
            emptyNode.attributedText = [[NSAttributedString alloc] initWithString:@""];
            emptyNode.style.flexGrow = 1.0;
            emptyNode.style.flexShrink = 1.0;
            [children addObject:emptyNode];
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
        n.style.width = ASDimensionMake(self.attachmentImageSize);
        n.style.height = ASDimensionMake(self.attachmentImageSize);
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
        n.style.width = ASDimensionMake(self.attachmentImageSize);
        n.style.height = ASDimensionMake(self.attachmentImageSize);
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
-(void)setAttachments:(NSArray *)attachments {
    self.attachmentsData = attachments ?: @[];
    // 关键：不再使用滚动容器，直接请求重布局
    if (self.currentMessage.length > 0) {
        [self forceParseMessage:self.currentMessage];
    }
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
        
        // 使用统一方法完成 Markdown → ParserResult 转换
        NSArray<ParserResult *> *results = [self convertMarkdownBlocks:markdownBlocks fallbackFromMessage:message];
        
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
        
        // 使用统一方法完成 Markdown → ParserResult 转换
        NSArray<ParserResult *> *results = [strongSelf convertMarkdownBlocks:markdownBlocks fallbackFromMessage:message];
        
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



// 统一的样式应用方法
- (void)applyMarkdownStyles:(NSMutableAttributedString *)attributedString {
    NSString *text = attributedString.string;
    
    // 预编译正则表达式，避免重复创建
    static NSRegularExpression *boldRegex = nil;
    static NSRegularExpression *italicRegex = nil;
    static NSRegularExpression *codeRegex = nil;
    static NSRegularExpression *urlRegex = nil;
    static NSRegularExpression *emailRegex = nil;
    
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        boldRegex = [NSRegularExpression regularExpressionWithPattern:@"\\*\\*(.*?)\\*\\*" options:0 error:nil];
        italicRegex = [NSRegularExpression regularExpressionWithPattern:@"\\*(.*?)\\*" options:0 error:nil];
        codeRegex = [NSRegularExpression regularExpressionWithPattern:@"`(.*?)`" options:0 error:nil];
        // 简单 URL / 邮箱 检测（容错，避免与 Markdown 语法冲突）
        urlRegex = [NSRegularExpression regularExpressionWithPattern:@"https?://[A-Za-z0-9._~:/?#\\[\\]@!$&'()*+,;=%-]+" options:NSRegularExpressionCaseInsensitive error:nil];
        emailRegex = [NSRegularExpression regularExpressionWithPattern:@"[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}" options:NSRegularExpressionCaseInsensitive error:nil];
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

    // 应用 URL 链接样式（点击行为依赖外部为 ASTextNode 设置 delegate，这里先提供可识别属性与样式）
    [self applyURLStyleWithRegex:urlRegex toAttributedString:attributedString];
    [self applyEmailStyleWithRegex:emailRegex toAttributedString:attributedString];
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

// URL 样式应用方法
- (void)applyURLStyleWithRegex:(NSRegularExpression *)regex 
              toAttributedString:(NSMutableAttributedString *)attributedString {
    NSString *text = attributedString.string;
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    UIColor *linkColor = self.isFromUser ? [UIColor colorWithRed:215/255.0 green:235/255.0 blue:255/255.0 alpha:1.0] : [UIColor systemBlueColor];
    for (NSInteger i = matches.count - 1; i >= 0; i--) {
        NSTextCheckingResult *m = matches[i];
        NSRange r = m.range;
        NSString *urlStr = [text substringWithRange:r];
        if (urlStr.length == 0) continue;
        NSURL *url = [NSURL URLWithString:urlStr];
        if (!url) continue;
        [attributedString addAttributes:@{
            NSLinkAttributeName: url,
            NSForegroundColorAttributeName: linkColor,
            NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)
        } range:r];
    }
}

// 邮箱样式应用方法
- (void)applyEmailStyleWithRegex:(NSRegularExpression *)regex 
                 toAttributedString:(NSMutableAttributedString *)attributedString {
    NSString *text = attributedString.string;
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    UIColor *linkColor = self.isFromUser ? [UIColor colorWithRed:215/255.0 green:235/255.0 blue:255/255.0 alpha:1.0] : [UIColor systemBlueColor];
    for (NSInteger i = matches.count - 1; i >= 0; i--) {
        NSTextCheckingResult *m = matches[i];
        NSRange r = m.range;
        NSString *email = [text substringWithRange:r];
        if (email.length == 0) continue;
        NSString *mailto = [NSString stringWithFormat:@"mailto:%@", email];
        NSURL *url = [NSURL URLWithString:mailto];
        if (!url) continue;
        [attributedString addAttributes:@{
            NSLinkAttributeName: url,
            NSForegroundColorAttributeName: linkColor,
            NSUnderlineStyleAttributeName: @(NSUnderlineStyleSingle)
        } range:r];
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
            // 同时移除可能残留的遮罩，确保完整显示
            node.layer.mask = nil;
        }
        
        // 退出流式模式
        self.isStreamingMode = NO;
        

        
        // 最终布局更新（无动画）
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIView performWithoutAnimation:^{
                [self setNeedsLayout];
                [self layoutIfNeeded];
            }];
        });
    }
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

// 在dealloc中清理缓存
- (void)dealloc {
    [self clearCache];
}

// MARK: - 按行更新优化方法



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
    self.isSchedulingPaused = YES;
}

// 新增：恢复流式更新动画
- (void)resumeStreamingAnimation {
    self.isSchedulingPaused = NO;
    if (self.currentBlockLineTasks.count > 0 || self.pendingSemanticBlockQueue.count > 0) {
        [self scheduleNextLineTask];
    }
}

// 新增：按语义块增量追加（逐行渲染）
- (void)appendSemanticBlocks:(NSArray<NSString *> *)blocks isFinal:(BOOL)isFinal {
    if (blocks.count == 0) {
        if (isFinal) { self.pendingFinalizeWhenQueueEmpty = YES; [self processNextSemanticBlockIfIdle]; }
        return;
    }
    self.isStreamingMode = YES;
    if (!self.pendingSemanticBlockQueue) { self.pendingSemanticBlockQueue = [NSMutableArray array]; }
    if (!self.currentBlockLineTasks) { self.currentBlockLineTasks = [NSMutableArray array]; }
    for (NSString *s in blocks) {
        if (s.length > 0) {
            [self.pendingSemanticBlockQueue addObject:s];
            // 同步累计 currentMessage，保持外部一致
            if (!self.currentMessage) { self.currentMessage = @""; }
            self.currentMessage = [self.currentMessage stringByAppendingString:s];
        }
    }
    self.lastParsedText = [self.currentMessage copy];
    self.lastParsedLength = self.lastParsedText.length;
    if (isFinal) { self.pendingFinalizeWhenQueueEmpty = YES; }
    // 尝试启动处理
    [self processNextSemanticBlockIfIdle];
}

// 新增：按固定宽度切分富文本为可视行（后台可调用）
- (NSArray<NSAttributedString *> *)lineFragmentsForAttributedString:(NSAttributedString *)attributed width:(CGFloat)width {
    if (attributed.length == 0) return @[];
    NSTextStorage *storage = [[NSTextStorage alloc] initWithAttributedString:attributed];
    NSLayoutManager *layoutManager = [[NSLayoutManager alloc] init];
    [storage addLayoutManager:layoutManager];
    NSTextContainer *container = [[NSTextContainer alloc] initWithSize:CGSizeMake(width, CGFLOAT_MAX)];
    container.lineFragmentPadding = 0;
    container.maximumNumberOfLines = 0;
    container.lineBreakMode = NSLineBreakByWordWrapping;
    [layoutManager addTextContainer:container];
    NSMutableArray<NSAttributedString *> *lines = [NSMutableArray array];
    NSUInteger glyphIndex = 0;
    while (glyphIndex < (NSUInteger)layoutManager.numberOfGlyphs) {
        NSRange glyphRange;
        (void)[layoutManager lineFragmentUsedRectForGlyphAtIndex:glyphIndex effectiveRange:&glyphRange];
        NSRange charRange = [layoutManager characterRangeForGlyphRange:glyphRange actualGlyphRange:NULL];
        if (charRange.length == 0) { break; }
        [lines addObject:[storage attributedSubstringFromRange:charRange]];
        glyphIndex = NSMaxRange(glyphRange);
    }
    return [lines copy];
}

// 新增：按设备动态计算文本最大宽度（屏幕宽度 * 0.75）
- (CGFloat)preferredTextMaxWidth {
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    return floor(screenWidth * 0.75);
}

// 新增：按固定宽度切分纯文本为可视行（指定字体）
- (NSArray<NSString *> *)lineFragmentsForPlainString:(NSString *)text font:(UIFont *)font width:(CGFloat)width {
    if (text.length == 0) return @[];
    NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:text];
    [attr addAttributes:@{ NSFontAttributeName: font } range:NSMakeRange(0, attr.length)];
    NSArray<NSAttributedString *> *attrLines = [self lineFragmentsForAttributedString:[attr copy] width:width];
    NSMutableArray<NSString *> *lines = [NSMutableArray arrayWithCapacity:attrLines.count];
    for (NSAttributedString *l in attrLines) { [lines addObject:l.string ?: @""]; }
    return [lines copy];
}

// 新增：为单个语义块文本生成逐行任务（后台解析与计算行）
- (void)buildLineTasksForBlockText:(NSString *)blockText completion:(void (^)(NSArray<NSDictionary *> *tasks))completion {
    if (!blockText) { if (completion) completion(@[]); return; }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { if (completion) completion(@[]); return; }
        // 只解析本语义块文本
        NSArray<AIMarkdownBlock *> *mdBlocks = [strongSelf.markdownParser parse:blockText];
        NSMutableArray<NSDictionary *> *tasks = [NSMutableArray array];
        // 动态行宽：按设备屏幕宽度 * 0.75
        const CGFloat lineWidth = [strongSelf preferredTextMaxWidth];
        
        NSLog(@"[LineRender][build] blockText=%@ len=%lu", (blockText.length > 60 ? [[blockText substringToIndex:60] stringByAppendingString:@"…"] : blockText), (unsigned long)blockText.length);
        NSLog(@"[LineRender][build] markdownBlocks=%lu", (unsigned long)mdBlocks.count);
        
                        for (AIMarkdownBlock *blk in mdBlocks) {
                    NSLog(@"[LineRender][build] processing block type=%ld text=%@", (long)blk.type, (blk.text.length > 40 ? [[blk.text substringToIndex:40] stringByAppendingString:@"…"] : blk.text));
                    
                    if (blk.type == AIMarkdownBlockTypeCodeBlock) {
                        NSString *code = blk.code ?: @"";
                        NSString *lang = blk.language.length ? blk.language : @"plaintext";
                        NSLog(@"[LineRender][build] code block lang=%@ codeLen=%lu", lang, (unsigned long)code.length);
                        
                        // 计算此代码块的最长行像素宽度，便于 AICodeBlockNode 设置固定内容宽度
                        CGFloat maxLineWidth = 0.0;
                        UIFont *mono = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
                        NSArray<NSString *> *codeLines = [code componentsSeparatedByString:@"\n"];
                        for (NSString *line in codeLines) {
                            if (line.length == 0) continue;
                            CGSize s = [line boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                                          options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                       attributes:@{ NSFontAttributeName: mono }
                                                          context:nil].size;
                            if (s.width > maxLineWidth) maxLineWidth = s.width;
                        }
                        maxLineWidth = ceil(maxLineWidth) + 4.0;
                        NSLog(@"[LineRender][build] code lines=%lu maxLineWidth=%.1f", (unsigned long)codeLines.count, maxLineWidth);
                        
                        BOOL isFirst = YES;
                        for (NSString *line in codeLines) {
                            NSString *ln = line ?: @"";
                            if ([[ln stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] length] == 0) {
                                continue; // 跳过空行，避免首行为空导致看不到内容
                            }
                            [tasks addObject:@{ @"type": @"code_line",
                                                @"language": lang,
                                                @"line": ln,
                                                @"start": @(isFirst),
                                                @"maxWidth": @(maxLineWidth) }];
                            isFirst = NO;
                        }
                    } else if (blk.type == AIMarkdownBlockTypeHeading) {
                NSMutableAttributedString *headingText = [[NSMutableAttributedString alloc] initWithString:(blk.text ?: @"")];
                CGFloat fontSize = (blk.headingLevel <= 2) ? 22 : 18;
                UIFont *font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightSemibold];
                [headingText addAttributes:@{ NSFontAttributeName: font,
                                              NSForegroundColorAttributeName: strongSelf.isFromUser ? [UIColor whiteColor] : [UIColor blackColor] }
                                      range:NSMakeRange(0, headingText.length)];
                
                NSArray<NSAttributedString *> *lines = [strongSelf lineFragmentsForAttributedString:[headingText copy] width:lineWidth];
                NSLog(@"[LineRender][build] heading lines=%lu", (unsigned long)lines.count);
                
                for (NSAttributedString *l in lines) {
                    [tasks addObject:@{ @"type": @"text_line",
                                        @"attr": l ?: [[NSAttributedString alloc] initWithString:@""] }];
                }
            } else {
                NSMutableAttributedString *paragraph = [[NSMutableAttributedString alloc] initWithString:(blk.text ?: @"")];
                [paragraph addAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:16],
                                            NSForegroundColorAttributeName: strongSelf.isFromUser ? [UIColor whiteColor] : [UIColor blackColor],
                                            NSParagraphStyleAttributeName: [strongSelf defaultParagraphStyle] }
                                     range:NSMakeRange(0, paragraph.length)];
                [strongSelf applyMarkdownStyles:paragraph];
                
                NSArray<NSAttributedString *> *lines = [strongSelf lineFragmentsForAttributedString:[paragraph copy] width:lineWidth];
                NSLog(@"[LineRender][build] paragraph lines=%lu", (unsigned long)lines.count);
                
                for (NSAttributedString *l in lines) {
                    [tasks addObject:@{ @"type": @"text_line",
                                        @"attr": l ?: [[NSAttributedString alloc] initWithString:@""] }];
                }
            }
        }
        
        // 记录当前块总行数用于日志
        strongSelf.currentBlockTotalLines = tasks.count;
        NSLog(@"[LineRender][build] total tasks=%lu", (unsigned long)tasks.count);
        
        if (completion) completion([tasks copy]);
    });
}

// 新增：启动或继续处理队列中的下一个语义块
- (void)processNextSemanticBlockIfIdle {
    if (self.isProcessingSemanticBlock) { return; }
    if (self.currentBlockLineTasks.count > 0) { return; }
    if (self.pendingSemanticBlockQueue.count == 0) { 
        if (self.pendingFinalizeWhenQueueEmpty) {
            self.isStreamingMode = NO; 
            self.pendingFinalizeWhenQueueEmpty = NO;
        }
        return; 
    }
    self.isProcessingSemanticBlock = YES;
    NSString *nextBlock = [self.pendingSemanticBlockQueue firstObject];
    [self.pendingSemanticBlockQueue removeObjectAtIndex:0];
    
    // 验证块内容有效性
    if (!nextBlock || nextBlock.length == 0 || [nextBlock stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]].length == 0) {
        NSLog(@"[LineRender][skip] block=%ld empty or whitespace only, skipping", (long)(self.processedBlockCounter + 1));
        self.isProcessingSemanticBlock = NO;
        [self processNextSemanticBlockIfIdle]; // 继续处理下一个
        return;
    }
    
    // 日志：开始处理一个新语义块
    self.processedBlockCounter += 1;
    self.currentBlockIndex = self.processedBlockCounter;
    self.currentBlockRenderedLineIndex = 0;
    self.currentBlockTotalLines = 0;
    
    NSString *preview = (nextBlock.length > 60) ? [[nextBlock substringToIndex:60] stringByAppendingString:@"…"] : nextBlock;
    NSLog(@"[LineRender][start] block=%ld len=%lu preview=%@", (long)self.currentBlockIndex, (unsigned long)nextBlock.length, preview ?: @"");
    
    __weak typeof(self) weakSelf = self;
    [self buildLineTasksForBlockText:nextBlock completion:^(NSArray<NSDictionary *> *tasks) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        void (^applyOnMain)(void) = ^{
            // 验证任务有效性
            if (!tasks || tasks.count == 0) {
                NSLog(@"[LineRender][skip] block=%ld no valid tasks generated, skipping", (long)strongSelf.currentBlockIndex);
                strongSelf.isProcessingSemanticBlock = NO;
                [strongSelf processNextSemanticBlockIfIdle]; // 继续处理下一个
                return;
            }
            
            strongSelf.currentBlockLineTasks = [tasks mutableCopy];
            strongSelf.activeCodeNode = nil;
            strongSelf.activeAccumulatedCode = @"";
            strongSelf.isProcessingSemanticBlock = NO;
            
            NSLog(@"[LineRender][ready] block=%ld tasks=%lu", (long)strongSelf.currentBlockIndex, (unsigned long)tasks.count);
            
            [strongSelf scheduleNextLineTask];
        };
        
        if ([NSThread isMainThread]) {
            applyOnMain();
        } else {
            dispatch_async(dispatch_get_main_queue(), applyOnMain);
        }
    }];
}

// 新增：调度下一行渲染（逐行推进）
- (void)scheduleNextLineTask {
    if (self.currentBlockLineTasks.count == 0) {
        // 当前块结束
        if (self.currentBlockIndex > 0) {
            NSLog(@"[LineRender][finish] block=%ld totalLines=%ld", (long)self.currentBlockIndex, (long)self.currentBlockTotalLines);
        }
        // 尝试处理下一个块
        [self processNextSemanticBlockIfIdle];
        return;
    }
    if (self.isSchedulingPaused) {
        return; // 暂停中不推进
    }
    // 为了平滑，使用可配置间隔（首行立即渲染，其余延迟）
    const NSTimeInterval interval = (self.currentBlockRenderedLineIndex == 0 ? 0.0 : (self.lineRenderInterval > 0.0 ? self.lineRenderInterval : 0.5));
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (strongSelf.isSchedulingPaused) { return; }
        [strongSelf performNextLineTask];
    });
}

// 新增：执行一条行任务并立刻请求下一条
- (void)performNextLineTask {
    if (self.currentBlockLineTasks.count == 0) {
        [self processNextSemanticBlockIfIdle];
        return;
    }
    if (self.isSchedulingPaused) { return; }
    // 在首行实际追加前发出"即将追加首行"的事件，便于控制器先移除Thinking
    if (self.currentBlockRenderedLineIndex == 0) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RichMessageCellNodeWillAppendFirstLine" object:self];
        // 首行即将加入，显示气泡与内容
        if (self.startHiddenUntilFirstLine) {
            self.bubbleNode.hidden = NO;
            self.contentNode.hidden = NO;
            [self immediateLayoutUpdate];
        }
    }
    NSDictionary *task = [self.currentBlockLineTasks firstObject];
    [self.currentBlockLineTasks removeObjectAtIndex:0];
    NSString *type = task[@"type"];
    
    // 日志：行序号更新
    self.currentBlockRenderedLineIndex += 1;
    NSInteger blockIdx = self.currentBlockIndex;
    NSInteger lineIdx = self.currentBlockRenderedLineIndex;
    NSInteger total = self.currentBlockTotalLines;
    NSString *textPreviewForLog = @"";
    
    NSLog(@"[LineRender][execute] block=%ld line=%ld/%ld type=%@", (long)blockIdx, (long)lineIdx, (long)total, type ?: @"");
    
    if ([type isEqualToString:@"text_line"]) {
        NSAttributedString *line = task[@"attr"];
        if (line && line.length > 0) {
            ASTextNode *textNode = [[ASTextNode alloc] init];
            textNode.attributedText = line;
            textNode.maximumNumberOfLines = 0;
            textNode.style.flexGrow = 1.0;
            textNode.style.flexShrink = 1.0;
            
            // 确保文本节点可见
            textNode.alpha = 1.0;
            
            NSMutableArray *mutable = self.renderNodes ? [self.renderNodes mutableCopy] : [NSMutableArray array];
            [mutable addObject:textNode];
            self.renderNodes = [mutable copy];
            
            textPreviewForLog = line.string ?: @"";
            NSLog(@"[LineRender][text] added textNode text=%@ len=%lu", textPreviewForLog, (unsigned long)line.length);
        } else {
            NSLog(@"[LineRender][text] invalid line data: attr=%@", line);
            // 尝试使用备用文本创建
            NSString *fallbackText = @"";
            if ([task[@"attr"] isKindOfClass:[NSString class]]) {
                fallbackText = task[@"attr"];
            }
            if (fallbackText.length > 0) {
                ASTextNode *textNode = [[ASTextNode alloc] init];
                textNode.attributedText = [self attributedStringForText:fallbackText];
                textNode.maximumNumberOfLines = 0;
                textNode.style.flexGrow = 1.0;
                textNode.style.flexShrink = 1.0;
                textNode.alpha = 1.0;
                
                NSMutableArray *mutable = self.renderNodes ? [self.renderNodes mutableCopy] : [NSMutableArray array];
                [mutable addObject:textNode];
                self.renderNodes = [mutable copy];
                
                textPreviewForLog = fallbackText;
                NSLog(@"[LineRender][text] added fallback textNode text=%@", textPreviewForLog);
            }
        }
    } else if ([type isEqualToString:@"code_line"]) {
        NSString *lang = task[@"language"] ?: @"plaintext";
        NSString *lineText = task[@"line"] ?: @"";
        BOOL isStart = [task[@"start"] boolValue];
        
        NSLog(@"[LineRender][code] lang=%@ isStart=%@ lineText=%@", lang, (isStart ? @"YES" : @"NO"), lineText);
        
        if (isStart || !self.activeCodeNode) {
            self.activeCodeNode = [[AICodeBlockNode alloc] initWithCode:@"" language:lang isFromUser:self.isFromUser];
            
            // 传入此块的最大行宽，确保scroll内容宽度足够
            NSNumber *maxW = task[@"maxWidth"];
            if ([maxW isKindOfClass:[NSNumber class]] && maxW.doubleValue > 0) {
                [self.activeCodeNode setFixedContentWidth:maxW.doubleValue];
            }
            
            // 确保代码节点可见
            self.activeCodeNode.alpha = 1.0;
            
            NSMutableArray *mutable = self.renderNodes ? [self.renderNodes mutableCopy] : [NSMutableArray array];
            [mutable addObject:self.activeCodeNode];
            self.renderNodes = [mutable copy];
            self.activeAccumulatedCode = @"";
            
            NSLog(@"[LineRender][code] created new codeNode lang=%@", lang);
        }
        
        // 追加一行并更新代码块
        if (lineText && lineText.length > 0) {
            self.activeAccumulatedCode = self.activeAccumulatedCode.length > 0 ? [self.activeAccumulatedCode stringByAppendingFormat:@"\n%@", lineText] : lineText;
            [self.activeCodeNode updateCodeText:self.activeAccumulatedCode];
            textPreviewForLog = lineText;
            
            NSLog(@"[LineRender][code] updated codeNode accumulatedLen=%lu", (unsigned long)self.activeAccumulatedCode.length);
        } else {
            NSLog(@"[LineRender][code] empty lineText, skipping update");
        }
    }
    
    // 截断日志文本，避免过长
    NSString *preview = textPreviewForLog.length > 80 ? [[textPreviewForLog substringToIndex:80] stringByAppendingString:@"…"] : textPreviewForLog;
    NSLog(@"[LineRender][complete] block=%ld line=%ld/%ld type=%@ text=%@", (long)blockIdx, (long)lineIdx, (long)total, type ?: @"", preview ?: @"");
    
    // 立即布局更新并通知控制器粘底
    [self immediateLayoutUpdate];
    
    // 调试：检查渲染节点状态
    [self debugRenderNodesState];
    
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RichMessageCellNodeDidAppendLine" object:self];
    
    // 推进下一行
    [self scheduleNextLineTask];
}

// 新增：外部可配置每行渲染间隔
- (void)setLineRenderInterval:(NSTimeInterval)lineRenderInterval {
    _lineRenderInterval = lineRenderInterval;
}

// 新增：调试渲染节点状态
- (void)debugRenderNodesState {
    NSLog(@"[LineRender][debug] renderNodes count=%lu", (unsigned long)self.renderNodes.count);
    for (NSInteger i = 0; i < self.renderNodes.count; i++) {
        ASDisplayNode *node = self.renderNodes[i];
        if ([node isKindOfClass:[ASTextNode class]]) {
            ASTextNode *textNode = (ASTextNode *)node;
            NSString *text = textNode.attributedText.string ?: @"";
            NSLog(@"[LineRender][debug] node[%ld] = ASTextNode text=%@ len=%lu alpha=%.2f", 
                  (long)i, (text.length > 30 ? [[text substringToIndex:30] stringByAppendingString:@"…"] : text), 
                  (unsigned long)text.length, textNode.alpha);
        } else if ([node isKindOfClass:[AICodeBlockNode class]]) {
            AICodeBlockNode *codeNode = (AICodeBlockNode *)node;
            NSString *code = @"";
            @try {
                code = [codeNode valueForKey:@"code"] ?: @"";
            } @catch (NSException *exception) {
                code = @"<error>";
            }
            NSLog(@"[LineRender][debug] node[%ld] = AICodeBlockNode codeLen=%lu alpha=%.2f", 
                  (long)i, (unsigned long)code.length, codeNode.alpha);
        } else {
            NSLog(@"[LineRender][debug] node[%ld] = %@ alpha=%.2f", 
                  (long)i, NSStringFromClass([node class]), node.alpha);
        }
    }
}

// 新增：统一将 Markdown 语义块转换为 ParserResult 的方法，避免重复实现
- (NSArray<ParserResult *> *)convertMarkdownBlocks:(NSArray<AIMarkdownBlock *> *)markdownBlocks
                               fallbackFromMessage:(NSString *)message {
    NSMutableArray<ParserResult *> *results = [NSMutableArray array];
    if (markdownBlocks.count == 0 && message.length > 0) {
        NSMutableAttributedString *fallbackText = [[NSMutableAttributedString alloc] initWithString:message ?: @""];
        [fallbackText addAttributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:16],
            NSForegroundColorAttributeName: self.isFromUser ? [UIColor whiteColor] : [UIColor blackColor],
            NSParagraphStyleAttributeName: [self defaultParagraphStyle]
        } range:NSMakeRange(0, fallbackText.length)];
        [self applyMarkdownStyles:fallbackText];
        ParserResult *fallbackResult = [[ParserResult alloc] initWithAttributedString:fallbackText
                                                                           isCodeBlock:NO
                                                                     codeBlockLanguage:nil];
        [results addObject:fallbackResult];
    } else {
        for (AIMarkdownBlock *block in markdownBlocks) {
            if (block.type == AIMarkdownBlockTypeCodeBlock) {
                if (!block.code || block.code.length == 0) { continue; }
                NSAttributedString *codeText = [[NSAttributedString alloc] initWithString:block.code];
                ParserResult *codeResult = [[ParserResult alloc] initWithAttributedString:codeText
                                                                              isCodeBlock:YES
                                                                        codeBlockLanguage:block.language];
                [results addObject:codeResult];
            } else if (block.type == AIMarkdownBlockTypeHeading) {
                NSMutableAttributedString *headingText = [[NSMutableAttributedString alloc] initWithString:(block.text ?: @"")];
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
                NSMutableAttributedString *paragraphText = [[NSMutableAttributedString alloc] initWithString:(block.text ?: @"")];
                [paragraphText addAttributes:@{
                    NSFontAttributeName: [UIFont systemFontOfSize:16],
                    NSForegroundColorAttributeName: self.isFromUser ? [UIColor whiteColor] : [UIColor blackColor],
                    NSParagraphStyleAttributeName: [self defaultParagraphStyle]
                } range:NSMakeRange(0, paragraphText.length)];
                [self applyMarkdownStyles:paragraphText];
                ParserResult *paragraphResult = [[ParserResult alloc] initWithAttributedString:paragraphText
                                                                                    isCodeBlock:NO
                                                                              codeBlockLanguage:nil];
                [results addObject:paragraphResult];
            }
        }
    }
    return [results copy];
}

@end



