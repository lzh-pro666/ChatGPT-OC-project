// ThinkingNode.m
#import "ThinkingNode.h"

@interface ThinkingNode ()
// 新增一个“气泡”节点
@property (nonatomic, strong) ASDisplayNode *bubbleNode;
@property (nonatomic, strong) NSArray<ASDisplayNode *> *dotNodes;
@end

@implementation ThinkingNode

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
    
    // 1. 创建一个水平布局来排列三个小圆点
    ASStackLayoutSpec *dotsLayout = [ASStackLayoutSpec horizontalStackLayoutSpec];
    dotsLayout.spacing = 8;
    dotsLayout.children = self.dotNodes;
    
    // 2. 将圆点布局包裹起来，给它增加内边距（padding）
    // 这决定了圆点距离气泡边缘的距离
    ASInsetLayoutSpec *bubbleContentLayout = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(18, 16, 18, 16) child:dotsLayout];
    
    // 3. 【关键】将内容（步骤2的结果）和气泡背景组合起来
    // ASBackgroundLayoutSpec 将 bubbleContentLayout 放在上层，将 bubbleNode 作为背景
    // 气泡的最终大小将由 bubbleContentLayout 的大小决定
    ASBackgroundLayoutSpec *bubbleLayout = [ASBackgroundLayoutSpec backgroundLayoutSpecWithChild:bubbleContentLayout background:self.bubbleNode];

    // 4. 【关键】创建一个弹性的空白占位符
    ASLayoutSpec *spacer = [[ASLayoutSpec alloc] init];
    spacer.style.flexGrow = 1.0; // 允许它占据所有剩余空间

    // 5. 创建一个水平布局，用于安排整行（cell）的内容
    // 将气泡放在左边，空白占位符放在右边
    ASStackLayoutSpec *rowLayout = [ASStackLayoutSpec horizontalStackLayoutSpec];
    rowLayout.justifyContent = ASStackLayoutJustifyContentStart; // 整体内容靠左
    rowLayout.children = @[bubbleLayout, spacer];
    
    // 6. 最后，给整行增加一些外边距，让它和别的消息之间有空隙
    return [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(5, 12, 5, 12)
                                                   child:rowLayout];
}

@end
