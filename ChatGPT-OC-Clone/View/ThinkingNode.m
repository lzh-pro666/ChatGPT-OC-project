// ThinkingNode.m
#import "ThinkingNode.h"

@interface ThinkingNode ()
// 新增一个“气泡”节点
@property (nonatomic, strong) ASDisplayNode *bubbleNode;
@property (nonatomic, strong) NSArray<ASDisplayNode *> *dotNodes;
@property (nonatomic, strong) ASTextNode *hintTextNode;
@end

@implementation ThinkingNode

// 基于字体与内边距动态计算单行气泡高度（与 RichMessage 单行视觉一致）
static inline CGFloat ThinkingBubbleMinHeight(void) {
    UIFont *font = [UIFont systemFontOfSize:17];
    // 单行高度取字体行高，并向上取整以避免截断
    CGFloat lineHeight = ceil(font.lineHeight);
    // 与消息气泡一致的内边距（上下各 10）
    CGFloat verticalPadding = 10.0 + 10.0;
    // 预留微小冗余，避免不同渲染路径下的像素抖动
    CGFloat epsilon = 2.0;
    return lineHeight + verticalPadding + epsilon; // 约 44-48
}

- (instancetype)init {
    self = [super init];
    if (self) {
        // 让 ThinkingNode 本身透明
        self.backgroundColor = [UIColor clearColor];
        self.selectionStyle = UITableViewCellSelectionStyleNone;
        
        // 自动管理子节点
        self.automaticallyManagesSubnodes = YES;
        
        [self setupNodes];
    }
    return self;
}

- (void)setupNodes {
    // --- 设置气泡节点 ---
    // 这是真正显示为气泡的节点
    _bubbleNode = [[ASDisplayNode alloc] init];
    _bubbleNode.backgroundColor = [UIColor colorWithRed:233/255.0 green:236/255.0 blue:239/255.0 alpha:1.0];
    _bubbleNode.cornerRadius = 16;
    _bubbleNode.cornerRoundingType = ASCornerRoundingTypeDefaultSlowCALayer;
    _bubbleNode.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    
    // --- 设置圆点节点 ---
    NSMutableArray *dotNodes = [NSMutableArray arrayWithCapacity:3];
    for (int i = 0; i < 3; i++) {
        ASDisplayNode *dotNode = [[ASDisplayNode alloc] init];
        dotNode.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.6];
        dotNode.cornerRadius = 4;
        // 设置圆点的大小
        dotNode.style.preferredSize = CGSizeMake(8, 8);
        [dotNodes addObject:dotNode];
    }
    self.dotNodes = dotNodes;

    // 提示文本节点（默认隐藏，按需显示）
    _hintTextNode = [[ASTextNode alloc] init];
    _hintTextNode.maximumNumberOfLines = 1;
    _hintTextNode.truncationMode = NSLineBreakByTruncatingTail;
    _hintTextNode.hidden = YES;
}

- (void)didEnterVisibleState {
    [super didEnterVisibleState];
    [self startAnimating];
}

- (void)didExitVisibleState {
    [super didExitVisibleState];
    [self stopAnimating];
}

- (void)startAnimating {
    [self.dotNodes enumerateObjectsUsingBlock:^(ASDisplayNode * _Nonnull dotNode, NSUInteger idx, BOOL * _Nonnull stop) {
        [dotNode.layer removeAllAnimations];
        
        CAKeyframeAnimation *scaleAnimation = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        scaleAnimation.values = @[@0.6, @1.0, @0.6];
        scaleAnimation.keyTimes = @[@0, @0.4, @1.0];
        scaleAnimation.duration = 1.4;
        scaleAnimation.repeatCount = HUGE_VALF;
        
        CFTimeInterval delay = idx * 0.16;
        // 使用 addAnimation:forKey: 时，beginTime 应基于 layer 的本地时间
        scaleAnimation.beginTime = [dotNode.layer convertTime:CACurrentMediaTime() fromLayer:nil] + delay;
        
        [dotNode.layer addAnimation:scaleAnimation forKey:@"thinking"];
    }];
}

- (void)stopAnimating {
    [self.dotNodes enumerateObjectsUsingBlock:^(ASDisplayNode * _Nonnull dotNode, NSUInteger idx, BOOL * _Nonnull stop) {
        [dotNode.layer removeAllAnimations];
    }];
}


// --- 核心修改：重写布局方法 ---
- (ASLayoutSpec *)layoutSpecThatFits:(ASSizeRange)constrainedSize {
    
    // 1. 创建一个水平布局：可选提示文本 + 小圆点
    NSMutableArray<ASLayoutElement> *rowChildren = [NSMutableArray array];
    if (!self.hintTextNode.hidden) {
        [rowChildren addObject:self.hintTextNode];
    }
    ASStackLayoutSpec *dotsLayout = [ASStackLayoutSpec horizontalStackLayoutSpec];
    dotsLayout.spacing = 8;
    dotsLayout.justifyContent = ASStackLayoutJustifyContentCenter;
    dotsLayout.alignItems = ASStackLayoutAlignItemsCenter;
    dotsLayout.children = self.dotNodes;
    [rowChildren addObject:dotsLayout];

    ASStackLayoutSpec *row = [ASStackLayoutSpec horizontalStackLayoutSpec];
    row.spacing = 8;
    row.justifyContent = ASStackLayoutJustifyContentCenter;
    row.alignItems = ASStackLayoutAlignItemsCenter;
    row.children = rowChildren;

    // 2. 使用居中布局确保三个点在可用空间内居中
    ASCenterLayoutSpec *centerSpec = [ASCenterLayoutSpec centerLayoutSpecWithCenteringOptions:ASCenterLayoutSpecCenteringXY
                                                                                sizingOptions:ASCenterLayoutSpecSizingOptionMinimumXY
                                                                                        child:row];
    
    // 3. 将内容包裹起来，使用与消息气泡一致的内边距（10,15,10,15）
    ASInsetLayoutSpec *bubbleContentLayout = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(10, 15, 10, 15) child:centerSpec];
    // 使用动态计算的单行最小高度，匹配单行文本气泡视觉高度
    bubbleContentLayout.style.minHeight = ASDimensionMake(ThinkingBubbleMinHeight());
    
    // 4. 【关键】将内容（步骤3的结果）和气泡背景组合起来
    // ASBackgroundLayoutSpec 将 bubbleContentLayout 放在上层，将 bubbleNode 作为背景
    // 气泡的最终大小将由 bubbleContentLayout 的大小决定
    ASBackgroundLayoutSpec *bubbleLayout = [ASBackgroundLayoutSpec backgroundLayoutSpecWithChild:bubbleContentLayout background:self.bubbleNode];
    // 限制最大宽度与消息一致（75%）以保持风格统一，同时下限高度统一
    CGFloat minH = ThinkingBubbleMinHeight();
    bubbleLayout.style.maxWidth = ASDimensionMake(constrainedSize.max.width * 0.75);
    bubbleLayout.style.minHeight = ASDimensionMake(minH);
    self.bubbleNode.style.minHeight = ASDimensionMake(minH);

    // 5. 【关键】创建一个弹性的空白占位符
    ASLayoutSpec *spacer = [[ASLayoutSpec alloc] init];
    spacer.style.flexGrow = 1.0; // 允许它占据所有剩余空间

    // 6. 创建一个水平布局，用于安排整行（cell）的内容
    // 将气泡放在左边，空白占位符放在右边
    ASStackLayoutSpec *rowLayout = [ASStackLayoutSpec horizontalStackLayoutSpec];
    rowLayout.justifyContent = ASStackLayoutJustifyContentStart; // 整体内容靠左
    rowLayout.children = @[bubbleLayout, spacer];
    
    // 7. 最后，给整行增加一些外边距，让它和别的消息之间有空隙
    ASInsetLayoutSpec *finalSpec = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(5, 12, 5, 12)
                                                                          child:rowLayout];
    // 保障 cell 自身的最小高度，避免父布局裁剪
    self.style.minHeight = ASDimensionMake(minH + 10.0); // 加上外边距的冗余
    return finalSpec;
}

#pragma mark - Public

- (void)setHintText:(NSString *)text {
    NSString *t = (text ?: @"");
    if (t.length == 0) {
        self.hintTextNode.hidden = YES;
        self.hintTextNode.attributedText = nil;
        [self setNeedsLayout];
        return;
    }
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{ NSFontAttributeName: [UIFont systemFontOfSize:15 weight:UIFontWeightRegular],
                             NSForegroundColorAttributeName: [UIColor colorWithWhite:0.2 alpha:0.9],
                             NSParagraphStyleAttributeName: ps };
    self.hintTextNode.attributedText = [[NSAttributedString alloc] initWithString:t attributes:attrs];
    self.hintTextNode.hidden = NO;
    [self setNeedsLayout];
}

@end
