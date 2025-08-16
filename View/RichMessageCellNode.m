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
@property (nonatomic, strong) NSMutableDictionary<NSString *, ASDisplayNode *> *nodeCache;
@property (nonatomic, assign) BOOL isUpdating;
// 恢复AIMarkdownParser以保持富文本效果
@property (nonatomic, strong) AIMarkdownParser *markdownParser;
@property (nonatomic, strong) NSArray<AIMarkdownBlock *> *markdownBlocks;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *layoutCache;
@property (nonatomic, assign) BOOL isLayoutStable;
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
        
        // 初始化解析器
        _markdownParser = [[AIMarkdownParser alloc] init];
        _markdownBlocks = @[];
        
        // 初始化解析任务
        _parsingTask = [[ResponseParsingTask alloc] init];
        _lastParsedLength = 0;
        
        // 强制首次解析消息内容
        [self parseMessage:message];
        
        NSLog(@"RichMessageCellNode: Initialized with message: %@", message);
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
    // 使用解析生成的内容节点进行布局
    UIColor *backgroundColor = self.isFromUser ? [UIColor systemBlueColor] : [UIColor systemGray5Color];

    // 限制最大宽度为 75%
    CGFloat maxWidth = constrainedSize.max.width * 0.75;
    self.contentNode.style.maxWidth = ASDimensionMake(maxWidth);
    
    // 为了避免末尾被裁剪，确保没有强制的 min/max height 限制
    self.contentNode.style.minHeight = ASDimensionMakeWithPoints(0);

    // contentNode 的布局：使用 renderNodes
    __weak typeof(self) weakSelf = self;
    self.contentNode.layoutSpecBlock = ^ASLayoutSpec * _Nonnull(__kindof ASDisplayNode * _Nonnull node, ASSizeRange sizeRange) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        NSArray<ASDisplayNode *> *children = strongSelf.renderNodes ?: @[];
        if (children.count == 0) {
            ASTextNode *placeholderNode = [[ASTextNode alloc] init];
            placeholderNode.attributedText = [strongSelf attributedStringForText:(strongSelf.currentMessage ?: @"")];
            placeholderNode.maximumNumberOfLines = 0;
            // 关键修复：确保占位符节点可以显示完整文本
            placeholderNode.style.flexGrow = 1.0;
            placeholderNode.style.flexShrink = 1.0;
            children = @[placeholderNode];
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
    
    if ((self.currentMessage ?: @"").length == 0 && (newMessage ?: @"").length == 0) {
        return;
    }
    if ([self.currentMessage isEqualToString:newMessage]) {
        return;
    }
    
    self.currentMessage = [newMessage copy];
    
    // 重置缓存尺寸
    self.cachedSize = CGSizeZero;
    
    NSLog(@"RichMessageCellNode: updateMessageText called with: [%@]", newMessage);
    
    // 关键改进：检查是否需要重新解析以保持富文本效果
    BOOL shouldReparse = [self shouldReparseText:newMessage];
    
    if (shouldReparse) {
        // 重新解析时重置布局稳定性
        self.isLayoutStable = YES;
        
        // 关键优化：使用无动画更新，减少视觉跳跃
        [UIView performWithoutAnimation:^{
            [self forceParseMessage:newMessage];
        }];
    } else {
        NSLog(@"RichMessageCellNode: 执行智能增量更新，不重新解析");
        [self updateExistingNodesWithNewText:newMessage];
    }
}

// MARK: - Private Methods

- (void)parseMessage:(NSString *)message {
    if (self.isUpdating) return;
    
    NSLog(@"RichMessageCellNode: parseMessage called with: %@", message);
    
    // 关键优化：将富文本渲染放在后台线程，减少主线程压力
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        // 后台线程：Markdown解析和富文本处理
        NSArray<AIMarkdownBlock *> *markdownBlocks = [self.markdownParser parse:message];
        
        NSLog(@"RichMessageCellNode: Markdown 解析完成，共 %lu 个语义块", (unsigned long)markdownBlocks.count);
        
        // 将 Markdown 语义块转换为 ParserResult
        NSMutableArray<ParserResult *> *results = [NSMutableArray array];
        
        // 关键改进：如果解析结果为空，强制创建一个段落结果
        if (markdownBlocks.count == 0 && message.length > 0) {
            NSLog(@"RichMessageCellNode: 解析结果为空，创建兜底段落");
            NSMutableAttributedString *fallbackText = [[NSMutableAttributedString alloc] initWithString:message];
            [fallbackText addAttributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:16],
                NSForegroundColorAttributeName: self.isFromUser ? [UIColor whiteColor] : [UIColor blackColor],
                NSParagraphStyleAttributeName: [self defaultParagraphStyle]
            } range:NSMakeRange(0, fallbackText.length)];
            
            ParserResult *fallbackResult = [[ParserResult alloc] initWithAttributedString:fallbackText
                                                                               isCodeBlock:NO
                                                                         codeBlockLanguage:nil];
            [results addObject:fallbackResult];
            NSLog(@"RichMessageCellNode: 创建兜底段落，内容长度: %lu", (unsigned long)message.length);
        } else {
            for (AIMarkdownBlock *block in markdownBlocks) {
                if (block.type == AIMarkdownBlockTypeCodeBlock) {
                    // 代码块：创建代码块结果
                    NSLog(@"RichMessageCellNode: 处理代码块，语言: %@，内容长度: %lu", block.language, (unsigned long)block.code.length);
                    
                    // 验证参数
                    if (!block.code || block.code.length == 0) {
                        NSLog(@"RichMessageCellNode: 代码块内容为空，跳过");
                        continue;
                    }
                    
                    // 创建代码块结果
                    NSAttributedString *codeText = [[NSAttributedString alloc] initWithString:block.code];
                    
                    ParserResult *codeResult = [[ParserResult alloc] initWithAttributedString:codeText
                                                                                   isCodeBlock:YES
                                                                             codeBlockLanguage:block.language];
                    [results addObject:codeResult];
                    
                    NSLog(@"RichMessageCellNode: 创建代码块结果，语言: %@，内容长度: %lu", block.language, (unsigned long)block.code.length);
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
                    
                    NSLog(@"RichMessageCellNode: 创建标题，级别: %ld，内容: %@", (long)block.headingLevel, block.text);
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
                    
                    NSLog(@"RichMessageCellNode: 创建段落，内容长度: %lu", (unsigned long)block.text.length);
                }
            }
        }
        
        // 主线程：UI更新
        dispatch_async(dispatch_get_main_queue(), ^{
            self.parsedResults = [results copy];
            self.lastParsedLength = message.length;
            self.lastParsedText = [message copy];
            
            NSLog(@"RichMessageCellNode: Markdown 解析完成，共 %lu 个结果", (unsigned long)self.parsedResults.count);
            [self updateContentNode];
        });
    });
}

- (void)updateContentNode {
    if (self.isUpdating) return;
    
    self.isUpdating = YES;
    
    NSLog(@"RichMessageCellNode: updateContentNode 开始，parsedResults count: %lu", (unsigned long)self.parsedResults.count);
    
    // 使用节点缓存，避免重复创建
    NSMutableArray<ASDisplayNode *> *childNodes = [NSMutableArray array];
    NSMutableSet<ASDisplayNode *> *addedNodes = [NSMutableSet set]; // 防止重复添加
    
    if (self.parsedResults.count == 0) {
        // 关键改进：使用统一样式的文本节点，确保所有文本都有稳定的渲染
        NSLog(@"RichMessageCellNode: 使用统一样式的文本节点");
        ASTextNode *defaultTextNode = [self getOrCreateTextNodeForText:(self.currentMessage ?: @"")];
        if (![addedNodes containsObject:defaultTextNode]) {
            [childNodes addObject:defaultTextNode];
            [addedNodes addObject:defaultTextNode];
        }
    } else {
        for (NSInteger i = 0; i < self.parsedResults.count; i++) {
            ParserResult *result = self.parsedResults[i];
            NSLog(@"RichMessageCellNode: 处理第 %ld 个结果，isCodeBlock: %@, content: %@", 
                  (long)i, result.isCodeBlock ? @"YES" : @"NO", 
                  [result.attributedString.string substringToIndex:MIN(50, result.attributedString.string.length)]);
            
            if (result.isCodeBlock) {
                // 关键改进：智能检查是否需要重新创建代码块节点
                ASDisplayNode *codeNode = nil;
                
                // 检查现有渲染节点中是否有可重用的代码块
                if (i < self.renderNodes.count) {
                    ASDisplayNode *existingNode = self.renderNodes[i];
                    if ([existingNode isKindOfClass:[AICodeBlockNode class]]) {
                        // 使用新方法检查代码块内容是否发生变化
                        if (![self isCodeBlockContentChanged:existingNode forResult:result]) {
                            NSLog(@"RichMessageCellNode: 重用现有代码块节点 %ld", (long)i);
                            codeNode = existingNode;
                        }
                    }
                }
                
                // 如果没有可重用的节点，则创建新的
                if (!codeNode) {
                    NSLog(@"RichMessageCellNode: 创建新的代码块节点");
                    codeNode = [self createCodeBlockNode:result];
                }
                
                if (![addedNodes containsObject:codeNode]) {
                    [childNodes addObject:codeNode];
                    [addedNodes addObject:codeNode];
                    NSLog(@"RichMessageCellNode: 代码块节点已添加到 childNodes，当前数量: %lu", (unsigned long)childNodes.count);
                }
            } else {
                // 创建文本节点
                NSLog(@"RichMessageCellNode: 创建文本节点");
                ASTextNode *textNode = [self getOrCreateTextNodeForAttributedString:result.attributedString];
                
                if (![addedNodes containsObject:textNode]) {
                    [childNodes addObject:textNode];
                    [addedNodes addObject:textNode];
                }
            }
        }
    }
    
    if (childNodes.count == 0) {
        NSLog(@"RichMessageCellNode: 添加占位节点");
        ASTextNode *placeholderNode = [self getOrCreateTextNodeForText:@"(空消息)"];
        // 关键修复：确保占位符节点可以显示完整内容
        placeholderNode.style.flexGrow = 1.0;
        placeholderNode.style.flexShrink = 1.0;
        if (![addedNodes containsObject:placeholderNode]) {
            [childNodes addObject:placeholderNode];
            [addedNodes addObject:placeholderNode];
        }
    }
    
    NSLog(@"RichMessageCellNode: 最终 childNodes 数量: %lu, renderNodes 数量: %lu", 
          (unsigned long)childNodes.count, (unsigned long)self.renderNodes.count);
    
    // 关键改进：只有当内容真正改变时才更新，减少不必要的布局
    BOOL contentChanged = ![self.renderNodes isEqualToArray:childNodes];
    
    // 关键优化：检查是否只是节点顺序变化，而不是内容变化
    if (!contentChanged && self.renderNodes.count == childNodes.count) {
        BOOL onlyOrderChanged = YES;
        for (NSInteger i = 0; i < self.renderNodes.count; i++) {
            if (![self.renderNodes[i] isEqual:childNodes[i]]) {
                onlyOrderChanged = NO;
                break;
            }
        }
        if (onlyOrderChanged) {
            NSLog(@"RichMessageCellNode: 仅节点顺序变化，跳过更新");
            self.isUpdating = NO;
            return;
        }
    }
    
    if (contentChanged) {
        NSLog(@"RichMessageCellNode: 内容发生变化，更新渲染节点");
        self.renderNodes = [childNodes copy];
        
        // 使用智能布局更新，减少抖动
        [self smartLayoutUpdate];
    } else {
        NSLog(@"RichMessageCellNode: 内容未变化，跳过更新");
    }
    
    self.isUpdating = NO;
    NSLog(@"RichMessageCellNode: updateContentNode 完成");
}


- (void)forceParseMessage:(NSString *)message {
    NSLog(@"RichMessageCellNode: forceParseMessage called with: [%@]", message);
    
    // 对于强制解析，使用 AIMarkdownParser 进行完整解析
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        
        // 后台线程：Markdown解析和富文本处理
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
            
            NSLog(@"RichMessageCellNode: Full parsing completed with %lu results", (unsigned long)strongSelf.parsedResults.count);
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
    NSLog(@"RichMessageCellNode: attributedStringForText called with: %@", text);
    
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
    
    NSLog(@"RichMessageCellNode: created attributedString with length: %lu", (unsigned long)attributedString.length);
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
        NSLog(@"RichMessageCellNode: 使用缓存的代码块节点，语言: %@", language);
        return cachedNode;
    }
    
    NSLog(@"RichMessageCellNode: 创建新的代码块节点，语言: %@，内容: %@", language, [codeText substringToIndex:MIN(100, codeText.length)]);
    
    // 使用新的 AICodeBlockNode
    AICodeBlockNode *codeBlockNode = [[AICodeBlockNode alloc] initWithCode:codeText 
                                                                   language:language 
                                                                 isFromUser:self.isFromUser];
    
    // 缓存新创建的代码块节点
    self.nodeCache[cacheKey] = codeBlockNode;
    
    NSLog(@"RichMessageCellNode: 代码块节点创建完成并已缓存");
    
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
        NSLog(@"RichMessageCellNode: 代码块内容发生变化 - 内容: %@, 语言: %@", 
              contentChanged ? @"YES" : @"NO", 
              languageChanged ? @"YES" : @"NO");
        return YES;
    }
    
    return NO;
}

// 新增：智能布局更新
- (void)smartLayoutUpdate {
    if (!self.isLayoutStable) {
        NSLog(@"RichMessageCellNode: 布局不稳定，跳过更新");
        return;
    }
    
    // 关键优化：使用节流机制，减少布局更新频率
    static NSTimeInterval lastLayoutUpdateTime = 0;
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    
    if (currentTime - lastLayoutUpdateTime < 0.05) { // 50ms节流
        NSLog(@"RichMessageCellNode: 布局更新过于频繁，跳过此次更新");
        return;
    }
    
    lastLayoutUpdateTime = currentTime;
    
    // 确保在主线程执行布局更新
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
    
    NSLog(@"RichMessageCellNode: 开始智能增量更新，当前解析结果数量: %lu", (unsigned long)self.parsedResults.count);
    
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
                        NSLog(@"RichMessageCellNode: 智能更新文本节点 %ld，追加内容长度: %lu", 
                              (long)i, (unsigned long)appendedText.length);
                        
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
                                
                                // 关键改进：降低高度阈值，确保最后几句话能完整显示
                                CGFloat heightDifference = fabs(newSize.height - oldSize.height);
                                if (heightDifference > 5.0 && isStable) { // 从15改为5像素
                                    NSLog(@"RichMessageCellNode: 高度变化显著且布局稳定 (%.1f -> %.1f)，需要更新布局", oldSize.height, newSize.height);
                                    
                                    textNode.attributedText = newAttributedString;
                                    [self smartLayoutUpdate];
                                } else if (heightDifference > 5.0 && !isStable) {
                                    // 高度变化显著但布局不稳定，标记为不稳定
                                    NSLog(@"RichMessageCellNode: 高度变化显著但布局不稳定 (%.1f -> %.1f)，标记为不稳定", oldSize.height, newSize.height);
                                    self.isLayoutStable = NO;
                                    textNode.attributedText = newAttributedString;
                                } else {
                                    // 高度变化微小，只更新文本内容，不触发布局
                                    textNode.attributedText = newAttributedString;
                                    NSLog(@"RichMessageCellNode: 高度变化微小 (%.1f -> %.1f)，只更新文本内容", oldSize.height, newSize.height);
                                }
                            }
                        }
                    } else {
                        NSLog(@"RichMessageCellNode: 追加内容过短 (%lu)，跳过更新", (unsigned long)appendedText.length);
                    }
                } else {
                    // 不是追加内容，可能是重新开始输入
                    NSLog(@"RichMessageCellNode: 检测到重新开始输入，跳过增量更新");
                }
            } else {
                // 新文本比当前内容短，可能是删除操作，跳过
                NSLog(@"RichMessageCellNode: 检测到删除操作，跳过增量更新");
            }
            
            break; // 只更新最后一个文本节点
        }
    }
    
    NSLog(@"RichMessageCellNode: 智能增量更新完成");
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

// 缓存清理方法
- (void)clearCache {
    [self.nodeCache removeAllObjects];
    [self.layoutCache removeAllObjects];
    NSLog(@"RichMessageCellNode: 缓存已清理");
}

// 在dealloc中清理缓存
- (void)dealloc {
    [self clearCache];
}

@end
