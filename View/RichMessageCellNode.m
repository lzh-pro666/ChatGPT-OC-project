#import "RichMessageCellNode.h"
#import "ParserResult.h"
#import "AIMarkdownParser.h"
#import "AICodeBlockNode.h"
#import <QuartzCore/QuartzCore.h>

// MARK: - 富文本消息节点
@interface RichMessageCellNode ()
@property (nonatomic, strong) ASDisplayNode *bubbleNode;
@property (nonatomic, strong) ASDisplayNode *contentNode;
@property (nonatomic, assign) BOOL isFromUser;
@property (nonatomic, strong) NSArray<ParserResult *> *parsedResults;
@property (nonatomic, copy) NSString *currentMessage;
@property (nonatomic, copy) NSString *lastParsedText;
@property (nonatomic, strong) NSArray<ASDisplayNode *> *renderNodes;
// 已移除未使用的附件容器属性
@property (nonatomic, strong) NSArray *attachmentsData; // 原始附件数据
@property (nonatomic, strong) NSMutableDictionary<NSString *, ASDisplayNode *> *nodeCache;
@property (nonatomic, assign) BOOL isUpdating;
// 新增：附件缩略图尺寸与间距（便于统一调节）
@property (nonatomic, assign) CGFloat attachmentImageSize;
@property (nonatomic, assign) CGFloat attachmentSpacing;
// 动态：根据行内图片张数与可用宽度计算得出，用于本次布局
@property (nonatomic, assign) CGFloat currentAttachmentThumbSize;
// 恢复AIMarkdownParser以保持富文本效果
@property (nonatomic, strong) AIMarkdownParser *markdownParser;
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

// 逐行渲染节奏与日志辅助
@property (nonatomic, assign) NSTimeInterval lineRenderInterval; // 每行渲染间隔
@property (nonatomic, assign) NSTimeInterval codeLineRenderInterval; // 代码行渲染间隔（更长，保证手势响应）
@property (nonatomic, assign) NSInteger currentBlockRenderedLineIndex; // 当前块已渲染行数（用于日志）
@property (nonatomic, assign) NSTimeInterval textLineRevealDuration; // 文本行蒙版渐显时长
@property (nonatomic, assign) BOOL bypassIntervalOnce; // 文本行动画完成后，下一行立即推进一次

// 在首行渲染前隐藏气泡，避免空白气泡
@property (nonatomic, assign) BOOL startHiddenUntilFirstLine;
@property (nonatomic, assign) BOOL hasEmittedFirstVisualLine; // 是否已触发过“首行”事件（全回复维度，而非语义块内）
// 调度暂停标记（用户滑动期间暂停逐行推进）
@property (nonatomic, assign) BOOL isSchedulingPaused;
// 逐行通知帧级合并器
@property (nonatomic, strong) CADisplayLink *lineNotifyLink;
@property (nonatomic, assign) BOOL pendingLineNotify;
// 逐行渲染最小间隔（双保险，避免过密调度）
@property (nonatomic, assign) NSTimeInterval minLineRenderInterval;
@property (nonatomic, assign) NSTimeInterval lastLineRenderTime;
@property (nonatomic, assign) NSInteger activeTextRevealAnimations; // 运行中渐显动画计数（用于排查并发）

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
        _hasEmittedFirstVisualLine = NO;
        
        // 初始化解析器
        _markdownParser = [[AIMarkdownParser alloc] init];
        
        // 强制首次解析消息内容
        [self parseMessage:message];
        
        // 新增：逐行渲染默认间隔与计数（统一 0.41675s）
        _lineRenderInterval = 0.5;
        _codeLineRenderInterval = 0.5;
        _currentBlockRenderedLineIndex = 0;
        _textLineRevealDuration = 0.5;
        _bypassIntervalOnce = NO;
        _minLineRenderInterval = 0.05; // 每行至少 50ms 间隔
        _lastLineRenderTime = 0;
        _activeTextRevealAnimations = 0;
        
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

    // 初始化逐行通知的帧级合并器（默认暂停，按需激活）
    self.pendingLineNotify = NO;
    self.lineNotifyLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(_onLineNotifyTick:)];
    [self.lineNotifyLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.lineNotifyLink.paused = YES;
}

// MARK: - Layout

- (ASLayoutSpec *)layoutSpecThatFits:(ASSizeRange)constrainedSize {
    // 若无任何内容与附件且消息为空，返回零高度布局以避免空白气泡
    
    if ((self.renderNodes.count == 0) && (self.attachmentsData.count == 0) && ((self.currentMessage ?: @"").length == 0)) {
        return [ASLayoutSpec new];
    }
    // 使用解析生成的内容节点进行布局
    // 固定 + 单行自适应：默认固定 capWidth；若无附件且仅一行文本则按文本自然宽度收窄
    CGFloat devicePreferred = [self preferredTextMaxWidth];
    CGFloat capWidth = floor(MIN(constrainedSize.max.width, devicePreferred));
    CGFloat finalWidth = capWidth;
    BOOL canUseDynamicSingleLine = (self.renderNodes.count == 1);
    if (canUseDynamicSingleLine) {
        ASDisplayNode *only = self.renderNodes.firstObject;
        if ([only isKindOfClass:[ASTextNode class]]) {
            ASTextNode *t = (ASTextNode *)only;
            NSString *s = t.attributedText.string ?: @"";
            if (s.length > 0 && [s rangeOfString:@"\n"].location == NSNotFound) {
                UIFont *font = [t.attributedText attribute:NSFontAttributeName atIndex:0 effectiveRange:NULL] ?: [UIFont systemFontOfSize:16];
                CGSize sz = [s boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                             options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                          attributes:@{ NSFontAttributeName: font }
                                             context:nil].size;
                CGFloat desired = ceil(sz.width) + 30.0; // 左右内边距 15+15
                finalWidth = MAX(60.0, MIN(desired, capWidth));
            }
        }
    }
    // 如果存在附件：按“单行水平排布”的宽度需求扩张气泡（最多扩到 constrainedSize.max.width）
    // 同时若仍超出可用宽度，则按比例缩小每个缩略图尺寸以适配单行。
    self.currentAttachmentThumbSize = self.attachmentImageSize;
    if (self.attachmentsData.count > 0) {
        NSInteger count = (NSInteger)self.attachmentsData.count;
        CGFloat desiredRowWidth = (CGFloat)count * self.attachmentImageSize + (CGFloat)MAX(0, count - 1) * self.attachmentSpacing;
        // 允许突破 0.75 屏的 cap，将气泡扩至本 Cell 最大宽度（由父层提供）
        CGFloat allowedContentMax = constrainedSize.max.width;
        // 将内容宽度扩张到图片单行所需与文本所需的较大值，但不超过 allowedContentMax
        finalWidth = MIN(allowedContentMax, MAX(finalWidth, desiredRowWidth));
        // 若单行仍放不下，则按行整体等比缩小每张缩略图尺寸
        if (desiredRowWidth > finalWidth && count > 0) {
            CGFloat totalSpacing = (CGFloat)MAX(0, count - 1) * self.attachmentSpacing;
            CGFloat availableForThumbs = MAX(finalWidth - totalSpacing, 1.0);
            CGFloat scaled = floor(availableForThumbs / (CGFloat)count);
            // 给个下限，避免过小导致点击困难
            self.currentAttachmentThumbSize = MAX(44.0, scaled);
        } else {
            self.currentAttachmentThumbSize = self.attachmentImageSize;
        }
    }

    self.contentNode.style.width = ASDimensionMake(finalWidth);
    self.contentNode.style.maxWidth = ASDimensionMake(finalWidth);
    self.contentNode.style.minWidth = ASDimensionMake(finalWidth);
    self.contentNode.style.flexGrow = 0.0;
    self.contentNode.style.flexShrink = 0.0;
    
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
        // 关键修复：确保带有附件的消息也能正确显示文本内容（即使已添加附件行）
        if ((renderChildren.count == 0) && (strongSelf.currentMessage.length > 0) && !strongSelf.isStreamingMode) {
            ASTextNode *placeholderNode = [[ASTextNode alloc] init];
            placeholderNode.attributedText = [strongSelf attributedStringForText:(strongSelf.currentMessage ?: @"")];
            placeholderNode.maximumNumberOfLines = 0;
            placeholderNode.style.flexGrow = 1.0;
            placeholderNode.style.flexShrink = 1.0;
            // 文本应出现在附件行之前
            [children insertObject:placeholderNode atIndex:0];
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
    ASInsetLayoutSpec *finalSpec = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(5, 12, 5, 12) child:stackSpec];
    (void)finalWidth;
    return finalSpec;
}
- (ASDisplayNode *)createAttachmentThumbNode:(id)attachment {
    if ([attachment isKindOfClass:[UIImage class]]) {
        ASImageNode *n = [[ASImageNode alloc] init];
        n.image = attachment;
        n.contentMode = UIViewContentModeScaleAspectFill;
        n.clipsToBounds = YES;
        n.cornerRadius = 8.0;
        CGFloat side = (self.currentAttachmentThumbSize > 0.0 ? self.currentAttachmentThumbSize : self.attachmentImageSize);
        n.style.width = ASDimensionMake(side);
        n.style.height = ASDimensionMake(side);
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
        CGFloat side = (self.currentAttachmentThumbSize > 0.0 ? self.currentAttachmentThumbSize : self.attachmentImageSize);
        n.style.width = ASDimensionMake(side);
        n.style.height = ASDimensionMake(side);
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
        // 流式模式下禁止占位符渲染，避免“非富文本一次性上屏”与后续重复
        if (self.isStreamingMode) {
            self.isUpdating = NO;
            return;
        }
        // 非流式：如果消息不为空但解析失败，显示原始消息（富文本基础样式）
        NSString *displayText = self.currentMessage;
        ASTextNode *defaultTextNode = [self getOrCreateTextNodeForText:displayText];
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
    // 降低同步布局强度：仅标记需要布局，交由系统下一帧统一处理
    if ([NSThread isMainThread]) {
        [self setNeedsLayout];
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{ [self setNeedsLayout]; });
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
    // 使用时间阈值节流，仅提交 setNeedsLayout，避免 layoutIfNeeded
    static NSTimeInterval lastLayoutUpdateTime = 0;
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    if (currentTime - lastLayoutUpdateTime < 0.05) { return; }
    lastLayoutUpdateTime = currentTime;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self setNeedsLayout];
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
        // 重置首行事件标记，便于下一条回复复用节点时正确触发
        self.hasEmittedFirstVisualLine = NO;
        
        // 最终布局更新（无动画）
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIView performWithoutAnimation:^{
                [self setNeedsLayout];
                [self layoutIfNeeded];
            }];
        });
    }
}

// 新增：在控制器通知“流式结束”时确保触发最终一次行渲染推进
- (void)ensureFinalFlushAfterStreamDone {
    if (!self.isStreamingMode) { return; }
    [self completeStreamingUpdate];
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
    [self.lineNotifyLink invalidate];
    self.lineNotifyLink = nil;
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
    
    // 仅标记需要布局，避免同步布局
    dispatch_async(dispatch_get_main_queue(), ^{ [self setNeedsLayout]; });
}

// 新增：暂停流式更新动画
- (void)pauseStreamingAnimation {
    self.isSchedulingPaused = YES;
}

// 新增：恢复流式更新动画
- (void)resumeStreamingAnimation {
    self.isSchedulingPaused = NO;
    // 恢复后维持统一节奏（0.5s），避免交互导致速率改变
    self.lineRenderInterval = 0.5;
    self.codeLineRenderInterval = 0.5;
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
            // 相邻去重（语义块级）：若与队尾相同则跳过
            NSString *last = [self.pendingSemanticBlockQueue lastObject];
            if (last && [last isEqualToString:s]) { continue; }
            [self.pendingSemanticBlockQueue addObject:s];
            // 同步累计 currentMessage，保持外部一致
            if (!self.currentMessage) { self.currentMessage = @""; }
            // 若末尾与本块相同，避免重复追加
            if (![self.currentMessage hasSuffix:s]) {
                self.currentMessage = [self.currentMessage stringByAppendingString:s];
            }
        }
    }
    self.lastParsedText = [self.currentMessage copy];
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
        
        for (AIMarkdownBlock *blk in mdBlocks) {
                    if (blk.type == AIMarkdownBlockTypeCodeBlock) {
                        NSString *code = blk.code ?: @"";
                        NSString *lang = blk.language.length ? blk.language : @"plaintext";
                    
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
                
                
                for (NSAttributedString *l in lines) {
                    [tasks addObject:@{ @"type": @"text_line",
                                        @"attr": l ?: [[NSAttributedString alloc] initWithString:@""] }];
                }
            } else if (blk.type == AIMarkdownBlockTypeListItem) {
                // 列表项：根据缩进与类型生成前缀，并设置缩进
                NSString *raw = blk.text ?: @"";
                NSString *trim = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                // 计算缩进层级（前导空白，2 空格≈一级）
                NSInteger leadingSpaces = 0;
                for (NSUInteger i = 0; i < raw.length; i++) {
                    unichar c = [raw characterAtIndex:i];
                    if (c == ' ') leadingSpaces++; else if (c == '\t') leadingSpaces += 2; else break;
                }
                NSInteger level = MAX(0, (NSInteger)floor((double)leadingSpaces / 2.0));
                // 识别编号列表
                NSRegularExpression *numRe = [NSRegularExpression regularExpressionWithPattern:@"^\\s*(\\d+)[\\.|)]\\s+" options:0 error:nil];
                NSTextCheckingResult *m = [numRe firstMatchInString:trim options:0 range:NSMakeRange(0, trim.length)];
                NSString *prefix = @"• ";
                NSString *content = trim;
                if ([trim hasPrefix:@"- "] || [trim hasPrefix:@"* "] || [trim hasPrefix:@"+ "]) {
                    content = [trim substringFromIndex:2];
                    static NSArray<NSString *> *bullets; static dispatch_once_t once; dispatch_once(&once, ^{ bullets = @[ @"• ", @"◦ ", @"▪︎ "]; });
                    prefix = bullets[(NSUInteger)(level % (NSInteger)bullets.count)];
                } else if (m) {
                    NSRange rNum = [m rangeAtIndex:1];
                    NSString *num = (rNum.location != NSNotFound) ? [trim substringWithRange:rNum] : @"1";
                    NSRange rAll = [m rangeAtIndex:0];
                    content = (rAll.location != NSNotFound) ? [trim substringFromIndex:(rAll.location + rAll.length)] : trim;
                    prefix = [NSString stringWithFormat:@"%@. ", num];
                }
                // 富文本：前缀 + 内容，设置缩进
                NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@%@", prefix, content ?: @""]];
                NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
                ps.lineSpacing = 5;
                ps.lineBreakMode = NSLineBreakByWordWrapping;
                CGFloat baseIndent = 18.0;
                CGFloat levelIndent = (CGFloat)level * 16.0;
                ps.firstLineHeadIndent = 0;
                ps.headIndent = baseIndent + levelIndent;
                [attr addAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:16],
                                       NSForegroundColorAttributeName: strongSelf.isFromUser ? [UIColor whiteColor] : [UIColor blackColor],
                                       NSParagraphStyleAttributeName: ps }
                             range:NSMakeRange(0, attr.length)];
                // 对内容部分应用 Markdown 行内样式
                if (content.length > 0) {
                    NSRange contentRange = NSMakeRange(prefix.length, attr.length - prefix.length);
                    NSMutableAttributedString *contentAttr = [[NSMutableAttributedString alloc] initWithAttributedString:[attr attributedSubstringFromRange:contentRange]];
                    [strongSelf applyMarkdownStyles:contentAttr];
                    [attr replaceCharactersInRange:contentRange withAttributedString:contentAttr];
                }
                NSArray<NSAttributedString *> *lines = [strongSelf lineFragmentsForAttributedString:[attr copy] width:lineWidth];
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
                
                
                for (NSAttributedString *l in lines) {
                    [tasks addObject:@{ @"type": @"text_line",
                                        @"attr": l ?: [[NSAttributedString alloc] initWithString:@""] }];
                }
            }
        }
        
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
        
        self.isProcessingSemanticBlock = NO;
        [self processNextSemanticBlockIfIdle]; // 继续处理下一个
        return;
    }
    
    self.currentBlockRenderedLineIndex = 0;
    
    
    __weak typeof(self) weakSelf = self;
    [self buildLineTasksForBlockText:nextBlock completion:^(NSArray<NSDictionary *> *tasks) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        void (^applyOnMain)(void) = ^{
            // 验证任务有效性
            if (!tasks || tasks.count == 0) {
                
                strongSelf.isProcessingSemanticBlock = NO;
                [strongSelf processNextSemanticBlockIfIdle]; // 继续处理下一个
                return;
            }
            
            strongSelf.currentBlockLineTasks = [tasks mutableCopy];
            strongSelf.activeCodeNode = nil;
            strongSelf.activeAccumulatedCode = @"";
            strongSelf.isProcessingSemanticBlock = NO;
            
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
        // 尝试处理下一个块
        [self processNextSemanticBlockIfIdle];
        return;
    }
    if (self.isSchedulingPaused) {
        return; // 暂停中不推进
    }
    // 为了平滑，使用可配置间隔（首行立即渲染，其余延迟）；代码行使用更长延迟
    NSDictionary *nextTask = [self.currentBlockLineTasks firstObject];
    BOOL isCode = [[nextTask objectForKey:@"type"] isEqualToString:@"code_line"];
    // 若当前已有文本行渐显在进行，跳过额外调度，等待动画完成回调推进
    if (!isCode && self.activeTextRevealAnimations > 0) {
        return;
    }
    NSTimeInterval baseInterval = isCode ? (self.codeLineRenderInterval > 0.0 ? self.codeLineRenderInterval : 0.3)
                                         : (self.lineRenderInterval > 0.0 ? self.lineRenderInterval : 0.15);
    // 行级节流（双保险）：确保相邻两行至少间隔 minLineRenderInterval
    NSTimeInterval nowTs = CACurrentMediaTime();
    NSTimeInterval since = nowTs - self.lastLineRenderTime;
    NSTimeInterval need = MAX(0.0, self.minLineRenderInterval - since);
    // 仅整条回复的第一行立即渲染，其余行（包括后续语义块的首行）按统一节奏推进
    NSTimeInterval interval = (self.hasEmittedFirstVisualLine ? MAX(baseInterval, need) : 0.0);
    if (self.bypassIntervalOnce) {
        interval = 0.0;
        self.bypassIntervalOnce = NO;
    }
    (void)baseInterval; (void)need; // silence unused in release
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(interval * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf.lastLineRenderTime = CACurrentMediaTime();
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
    // 只有在整条回复的第一行到来时，才触发“首行即将追加”的事件
    if (!self.hasEmittedFirstVisualLine) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"RichMessageCellNodeWillAppendFirstLine" object:self];
        self.hasEmittedFirstVisualLine = YES;
        if (self.startHiddenUntilFirstLine) {
            self.bubbleNode.hidden = NO;
            self.contentNode.hidden = NO;
            [self immediateLayoutUpdate];
        }
    }
    NSDictionary *task = [self.currentBlockLineTasks firstObject];
    [self.currentBlockLineTasks removeObjectAtIndex:0];
    NSString *type = task[@"type"];
    
    self.currentBlockRenderedLineIndex += 1;
    
    if ([type isEqualToString:@"text_line"]) {
        NSAttributedString *line = task[@"attr"];
        if (line && line.length > 0) {
            // 相邻文本节点内容相同则跳过，避免渲染重复行
            ASDisplayNode *prev = self.renderNodes.lastObject;
            if ([prev isKindOfClass:[ASTextNode class]]) {
                ASTextNode *prevText = (ASTextNode *)prev;
                if ([prevText.attributedText.string ?: @"" isEqualToString:line.string ?: @""]) {
                    [self scheduleNextLineTask];
                    return;
                }
            }
            ASTextNode *textNode = [[ASTextNode alloc] init];
            textNode.layerBacked = YES; // 减少 UIView 开销
            textNode.attributedText = line;
            textNode.maximumNumberOfLines = 0;
            textNode.style.flexGrow = 1.0;
            textNode.style.flexShrink = 1.0;
            
            // 确保文本节点可见
            textNode.alpha = 1.0;
            
            NSMutableArray *mutable = self.renderNodes ? [self.renderNodes mutableCopy] : [NSMutableArray array];
            [mutable addObject:textNode];
            self.renderNodes = [mutable copy];
            // 对新增文本行应用从左到右的蒙版渐显动画，动画完成后再推进下一行
            __weak typeof(self) weakSelf = self;
            [self immediateLayoutUpdate];
            dispatch_async(dispatch_get_main_queue(), ^{
                __strong typeof(weakSelf) strongSelf = weakSelf;
                if (!strongSelf) { return; }
                strongSelf.activeTextRevealAnimations += 1;
                [strongSelf _applyLeftToRightRevealMaskOnNode:textNode duration:strongSelf.textLineRevealDuration completion:^{
                    strongSelf.activeTextRevealAnimations = MAX(0, strongSelf.activeTextRevealAnimations - 1);
                    // 动画结束后立即推进下一行（本次跳过间隔）
                    strongSelf.bypassIntervalOnce = YES;
                    [strongSelf scheduleNextLineTask];
                }];
            });
        } else {
            
            // 尝试使用备用文本创建
            NSString *fallbackText = @"";
            if ([task[@"attr"] isKindOfClass:[NSString class]]) {
                fallbackText = task[@"attr"];
            }
            if (fallbackText.length > 0) {
                ASTextNode *textNode = [[ASTextNode alloc] init];
                textNode.layerBacked = YES; // 减少 UIView 开销
                textNode.attributedText = [self attributedStringForText:fallbackText];
                textNode.maximumNumberOfLines = 0;
                textNode.style.flexGrow = 1.0;
                textNode.style.flexShrink = 1.0;
                textNode.alpha = 1.0;
                
                NSMutableArray *mutable = self.renderNodes ? [self.renderNodes mutableCopy] : [NSMutableArray array];
                [mutable addObject:textNode];
                self.renderNodes = [mutable copy];
                // 空文本兜底也推进（无需动画）
                [self scheduleNextLineTask];
            }
        }
    } else if ([type isEqualToString:@"code_line"]) {
        NSString *lang = task[@"language"] ?: @"plaintext";
        NSString *lineText = task[@"line"] ?: @"";
        BOOL isStart = [task[@"start"] boolValue];
        
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
            
            
        }
        
        // 追加一行并更新代码块
        if (lineText && lineText.length > 0) {
            // 若上一行相同，跳过重复追加
            if ([self.activeAccumulatedCode hasSuffix:[@"\n" stringByAppendingString:lineText]] || [self.activeAccumulatedCode isEqualToString:lineText]) {
                [self scheduleNextLineTask];
                return;
            }
            self.activeAccumulatedCode = self.activeAccumulatedCode.length > 0 ? [self.activeAccumulatedCode stringByAppendingFormat:@"\n%@", lineText] : lineText;
            [self.activeCodeNode updateCodeText:self.activeAccumulatedCode];
            
        } else {
            
        }
    }
    // 使用节流布局更新，减少主线程压力并提升手势响应
    [self performDelayedLayoutUpdate];
    // 合并逐行通知：只标记待通知，在下一帧发送一次
    [self scheduleBatchedLineNotification];
    
    // 推进下一行：
    // - 文本行在动画完成回调中推进
    // - 代码行按节奏立即推进
    if ([type isEqualToString:@"code_line"]) {
        [self scheduleNextLineTask];
    }
}

// 新增：外部可配置每行渲染间隔
- (void)setLineRenderInterval:(NSTimeInterval)lineRenderInterval {
    _lineRenderInterval = lineRenderInterval;
}
// 允许控制器设置代码行间隔（通过 NSInvocation 调用）
- (void)setCodeLineRenderInterval:(NSTimeInterval)value {
    _codeLineRenderInterval = value;
}

#pragma mark - 文本行蒙版渐显

- (void)_applyLeftToRightRevealMaskOnNode:(ASDisplayNode *)node
                                  duration:(NSTimeInterval)duration
                                 completion:(dispatch_block_t)completion {
    [self _applyLeftToRightRevealMaskOnNode:node duration:duration tries:4 completion:completion];
}

- (void)_applyLeftToRightRevealMaskOnNode:(ASDisplayNode *)node
                                  duration:(NSTimeInterval)duration
                                      tries:(NSInteger)tries
                                 completion:(dispatch_block_t)completion {
    if (!node) { if (completion) completion(); return; }
    CALayer *targetLayer = node.layer;
    if (!targetLayer) { if (completion) completion(); return; }
    CGSize size = node.bounds.size;
    if ((size.width < 1.0 || size.height < 1.0) && tries > 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) { if (completion) completion(); return; }
            [strongSelf _applyLeftToRightRevealMaskOnNode:node duration:duration tries:(tries - 1) completion:completion];
        });
        return;
    }
    if (size.width < 1.0 || size.height < 1.0) {
        if (completion) completion();
        return;
    }
    CALayer *maskLayer = [CALayer layer];
    maskLayer.backgroundColor = [UIColor blackColor].CGColor;
    maskLayer.anchorPoint = CGPointMake(0.0, 0.5);
    maskLayer.bounds = CGRectMake(0, 0, size.width, size.height);
    maskLayer.position = CGPointMake(0, size.height * 0.5);
    maskLayer.transform = CATransform3DMakeScale(0.0, 1.0, 1.0);
    targetLayer.mask = maskLayer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [CATransaction setCompletionBlock:^{
        // 复位到最终状态并移除蒙版，避免后续布局受影响
        maskLayer.transform = CATransform3DIdentity;
        targetLayer.mask = nil;
        if (completion) completion();
    }];
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"transform.scale.x"];
    anim.fromValue = @(0.0);
    anim.toValue = @(1.0);
    anim.duration = MAX(0.01, duration);
    anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [maskLayer addAnimation:anim forKey:@"revealX"];
    // 将模型层同步到最终值
    maskLayer.transform = CATransform3DIdentity;
    [CATransaction commit];
}

// MARK: - 帧级合并通知
- (void)scheduleBatchedLineNotification {
    self.pendingLineNotify = YES;
    self.lineNotifyLink.paused = NO;
}

- (void)_onLineNotifyTick:(CADisplayLink *)link {
    if (!self.pendingLineNotify) {
        link.paused = YES;
        return;
    }
    self.pendingLineNotify = NO;
    [[NSNotificationCenter defaultCenter] postNotificationName:@"RichMessageCellNodeDidAppendLine" object:self];
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
            } else if (block.type == AIMarkdownBlockTypeListItem) {
                // 非流式整块渲染时的列表项样式
                NSString *raw = block.text ?: @"";
                NSString *trim = [raw stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                NSInteger leadingSpaces = 0; for (NSUInteger i = 0; i < raw.length; i++) { unichar c = [raw characterAtIndex:i]; if (c == ' ') leadingSpaces++; else if (c == '\t') leadingSpaces += 2; else break; }
                NSInteger level = MAX(0, (NSInteger)floor((double)leadingSpaces / 2.0));
                NSRegularExpression *numRe = [NSRegularExpression regularExpressionWithPattern:@"^\\s*(\\d+)[\\.|)]\\s+" options:0 error:nil];
                NSTextCheckingResult *m = [numRe firstMatchInString:trim options:0 range:NSMakeRange(0, trim.length)];
                NSString *prefix = @"• ";
                NSString *content = trim;
                if ([trim hasPrefix:@"- "] || [trim hasPrefix:@"* "] || [trim hasPrefix:@"+ "]) {
                    content = [trim substringFromIndex:2];
                    static NSArray<NSString *> *bullets; static dispatch_once_t once; dispatch_once(&once, ^{ bullets = @[ @"• ", @"◦ ", @"▪︎ "]; });
                    prefix = bullets[(NSUInteger)(level % (NSInteger)bullets.count)];
                } else if (m) {
                    NSRange rNum = [m rangeAtIndex:1];
                    NSString *num = (rNum.location != NSNotFound) ? [trim substringWithRange:rNum] : @"1";
                    NSRange rAll = [m rangeAtIndex:0];
                    content = (rAll.location != NSNotFound) ? [trim substringFromIndex:(rAll.location + rAll.length)] : trim;
                    prefix = [NSString stringWithFormat:@"%@. ", num];
                }
                NSMutableAttributedString *attr = [[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%@%@", prefix, content ?: @""]];
                NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
                ps.lineSpacing = 5; ps.lineBreakMode = NSLineBreakByWordWrapping;
                CGFloat baseIndent = 18.0; CGFloat levelIndent = (CGFloat)level * 16.0;
                ps.firstLineHeadIndent = 0; ps.headIndent = baseIndent + levelIndent;
                [attr addAttributes:@{ NSFontAttributeName: [UIFont systemFontOfSize:16],
                                       NSForegroundColorAttributeName: self.isFromUser ? [UIColor whiteColor] : [UIColor blackColor],
                                       NSParagraphStyleAttributeName: ps }
                             range:NSMakeRange(0, attr.length)];
                if (content.length > 0) {
                    NSRange contentRange = NSMakeRange(prefix.length, attr.length - prefix.length);
                    NSMutableAttributedString *contentAttr = [[NSMutableAttributedString alloc] initWithAttributedString:[attr attributedSubstringFromRange:contentRange]];
                    [self applyMarkdownStyles:contentAttr];
                    [attr replaceCharactersInRange:contentRange withAttributedString:contentAttr];
                }
                ParserResult *li = [[ParserResult alloc] initWithAttributedString:[attr copy] isCodeBlock:NO codeBlockLanguage:nil];
                [results addObject:li];
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



