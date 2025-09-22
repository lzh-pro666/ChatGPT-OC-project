//
//  AttachmentScrollNode.m
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import "AttachmentScrollNode.h"
#import <AsyncDisplayKit/ASScrollNode.h>
#import <AsyncDisplayKit/ASImageNode.h>
#import <AsyncDisplayKit/ASNetworkImageNode.h>
#import <AsyncDisplayKit/ASControlNode.h>

@interface AttachmentScrollNode ()
@property (nonatomic, strong) NSArray *attachments;
@property (nonatomic, assign) BOOL isFromUser;
@property (nonatomic, strong) ASScrollNode *scrollNode;
@property (nonatomic, assign) CGFloat displayWidth;
@property (nonatomic, assign) CGFloat imageSize;
@property (nonatomic, assign) CGFloat imageSpacing;

// 防重复点击相关属性
@property (nonatomic, assign) NSTimeInterval lastClickTime;
@property (nonatomic, assign) BOOL isClickProcessing;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSNumber *> *clickTimeCache;
@end

@implementation AttachmentScrollNode

- (instancetype)initWithAttachments:(NSArray *)attachments isFromUser:(BOOL)isFromUser {
    self = [super init];
    if (self) {
        _attachments = [attachments copy];
        _isFromUser = isFromUser;
        _imageSize = 120.0; // 单张图片的尺寸
        _imageSpacing = 8.0; // 图片之间的间隔
        _displayWidth = 180.0; // 默认显示1.5张图片的宽度 (120 * 1.5)
        
        // 初始化防重复点击相关属性
        _lastClickTime = 0;
        _isClickProcessing = NO;
        _clickTimeCache = [NSMutableDictionary dictionary];
        
        // 自动管理子节点
        self.automaticallyManagesSubnodes = YES;
        
        [self setupScrollView];
    }
    return self;
}

- (void)setupScrollView {
    // 创建滚动容器（将被弃用，不再在业务中使用）
    self.scrollNode = [[ASScrollNode alloc] init];
    self.scrollNode.scrollableDirections = ASScrollDirectionHorizontalDirections;
    self.scrollNode.automaticallyManagesSubnodes = YES;
    self.scrollNode.automaticallyManagesContentSize = YES;
    
    // 设置滚动视图的样式（需要在 didLoad 中设置）
    // 这些属性需要在视图加载后才能访问
    
    // 定义一次 weakSelf，供两个 block 使用
    __weak typeof(self) weakSelf = self;
    
    // 直接在 scrollNode 上定义布局，作为内容生成器
    self.scrollNode.layoutSpecBlock = ^ASLayoutSpec * _Nonnull(__kindof ASDisplayNode * _Nonnull node, ASSizeRange sizeRange) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return [ASLayoutSpec new];
        
        NSMutableArray *imageNodes = [NSMutableArray array];
        for (NSInteger i = 0; i < strongSelf.attachments.count; i++) {
            id attachment = strongSelf.attachments[i];
            ASDisplayNode *imageNode = [strongSelf createImageNodeForAttachment:attachment];
            if (imageNode) {
                [imageNodes addObject:imageNode];
            }
        }
        if (imageNodes.count == 0) {
            return [ASLayoutSpec new];
        }
        ASStackLayoutSpec *stackSpec = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionHorizontal
                                                                               spacing:strongSelf.imageSpacing
                                                                        justifyContent:ASStackLayoutJustifyContentStart
                                                                            alignItems:ASStackLayoutAlignItemsStart
                                                                              children:imageNodes];
        return stackSpec;
    };
}

- (ASDisplayNode *)createImageNodeForAttachment:(id)attachment {
    ASDisplayNode *imageNode = nil;
    
    if ([attachment isKindOfClass:[UIImage class]]) {
        ASImageNode *imgNode = [[ASImageNode alloc] init];
        imgNode.image = attachment;
        imgNode.contentMode = UIViewContentModeScaleAspectFill;
        imgNode.clipsToBounds = YES;
        imgNode.cornerRadius = 8.0;
        imgNode.style.width = ASDimensionMake(self.imageSize);
        imgNode.style.height = ASDimensionMake(self.imageSize);
        imgNode.userInteractionEnabled = YES;
        
        // 添加点击事件
        [(ASControlNode *)imgNode addTarget:self action:@selector(imageTapped:) forControlEvents:ASControlNodeEventTouchUpInside];
        imgNode.accessibilityLabel = @"local-image";
        
        imageNode = imgNode;
        
    } else if ([attachment isKindOfClass:[NSURL class]]) {
        ASNetworkImageNode *netNode = [[ASNetworkImageNode alloc] init];
        netNode.URL = attachment;
        netNode.contentMode = UIViewContentModeScaleAspectFill;
        netNode.clipsToBounds = YES;
        netNode.cornerRadius = 8.0;
        netNode.placeholderFadeDuration = 0.1;
        netNode.placeholderColor = [UIColor systemGray5Color];
        netNode.style.width = ASDimensionMake(self.imageSize);
        netNode.style.height = ASDimensionMake(self.imageSize);
        netNode.userInteractionEnabled = YES;
        
        // 添加点击事件
        [(ASControlNode *)netNode addTarget:self action:@selector(imageTapped:) forControlEvents:ASControlNodeEventTouchUpInside];
        netNode.accessibilityLabel = @"remote-url";
        netNode.accessibilityValue = ((NSURL *)attachment).absoluteString;
        
        imageNode = netNode;
    }
    
    return imageNode;
}

- (void)didLoad {
    [super didLoad];
    
    // 设置滚动视图的属性
    if (self.scrollNode.view) {
        UIScrollView *scrollView = self.scrollNode.view;
        scrollView.showsHorizontalScrollIndicator = NO;
        scrollView.showsVerticalScrollIndicator = NO;
        scrollView.bounces = YES;
        scrollView.alwaysBounceHorizontal = YES;
        scrollView.decelerationRate = UIScrollViewDecelerationRateFast;
        scrollView.delaysContentTouches = NO;
        scrollView.canCancelContentTouches = YES;
        scrollView.directionalLockEnabled = YES;
        if (scrollView.panGestureRecognizer) {
            scrollView.panGestureRecognizer.cancelsTouchesInView = YES;
            scrollView.panGestureRecognizer.delaysTouchesBegan = NO;
            scrollView.panGestureRecognizer.delaysTouchesEnded = NO;
        }
        // 仅确保不引入额外延迟，不强制禁用 cancelsTouchesInView，避免阻断滚动开始
        for (UIGestureRecognizer *recognizer in scrollView.gestureRecognizers) {
            recognizer.delaysTouchesBegan = NO;
            recognizer.delaysTouchesEnded = NO;
        }
        scrollView.scrollEnabled = YES;
        scrollView.userInteractionEnabled = YES;
    }
}

// 不再需要手动更新 contentSize，交给 ASScrollNode 管理

- (void)imageTapped:(ASControlNode *)sender {
    // 防重复点击逻辑
    NSTimeInterval currentTime = [[NSDate date] timeIntervalSince1970];
    NSString *senderKey = [NSString stringWithFormat:@"%p", sender];
    
    // 检查是否正在处理点击
    if (self.isClickProcessing) {
        NSLog(@"[AttachmentScrollNode] 点击正在处理中，忽略重复点击");
        return;
    }
    
    // 检查点击间隔（防抖）
    NSNumber *lastClickTimeNumber = self.clickTimeCache[senderKey];
    if (lastClickTimeNumber && (currentTime - lastClickTimeNumber.doubleValue) < 0.5) {
        NSLog(@"[AttachmentScrollNode] 点击间隔太短，忽略重复点击");
        return;
    }
    
    // 更新点击时间缓存
    self.clickTimeCache[senderKey] = @(currentTime);
    self.lastClickTime = currentTime;
    self.isClickProcessing = YES;
    
    NSLog(@"[AttachmentScrollNode] 处理图片点击事件");
    
    // 添加触觉反馈
    UIImpactFeedbackGenerator *feedbackGenerator = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [feedbackGenerator impactOccurred];
    
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    
    if ([sender isKindOfClass:[ASNetworkImageNode class]]) {
        ASNetworkImageNode *netNode = (ASNetworkImageNode *)sender;
        NSString *urlStr = netNode.accessibilityValue;
        if (urlStr.length > 0) {
            info[@"url"] = urlStr;
        }
    } else if ([sender isKindOfClass:[ASImageNode class]]) {
        ASImageNode *imgNode = (ASImageNode *)sender;
        if (imgNode.image) {
            info[@"image"] = imgNode.image;
        }
    }
    
    // 发送通知
    [[NSNotificationCenter defaultCenter] postNotificationName:@"AttachmentPreviewRequested"
                                                        object:self
                                                      userInfo:info];
    
    // 延迟重置点击处理状态
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.isClickProcessing = NO;
    });
}

- (void)updateAttachments:(NSArray *)attachments {
    self.attachments = [attachments copy];
    [self setNeedsLayout];
}

- (void)setDisplayWidth:(CGFloat)displayWidth {
    _displayWidth = displayWidth;
    [self setNeedsLayout];
}

// 根据屏幕宽度动态调整图片大小
- (void)adjustImageSizeForScreenWidth:(CGFloat)screenWidth {
    // 基于屏幕宽度计算合适的图片大小
    // 确保1.5张图片的显示宽度不超过屏幕宽度的80%
    CGFloat maxDisplayWidth = screenWidth * 0.8;
    CGFloat calculatedImageSize = (maxDisplayWidth - self.imageSpacing * 0.5) / 1.5;
    
    // 设置合理的图片大小范围
    self.imageSize = MAX(80, MIN(calculatedImageSize, 150));
    [self setNeedsLayout];
}

- (ASLayoutSpec *)layoutSpecThatFits:(ASSizeRange)constrainedSize {
    if (self.attachments.count == 0) {
        return [ASLayoutSpec new];
    }
    
    // 计算1.5张照片的显示宽度
    CGFloat displayWidth = self.imageSize * 1.5 + self.imageSpacing * 0.5; // 1.5张图片 + 0.5个间隔
    
    // 计算所有图片的总宽度（包括间隔）
    CGFloat totalContentWidth = self.attachments.count * self.imageSize + (self.attachments.count - 1) * self.imageSpacing;
    
    // 滚动视图的显示宽度：如果内容宽度大于1.5张图片宽度，则显示1.5张图片宽度，否则显示全部内容
    CGFloat scrollViewWidth;
    if (totalContentWidth > displayWidth) {
        // 内容超过1.5张图片，显示1.5张图片宽度，允许滚动
        scrollViewWidth = MIN(displayWidth, constrainedSize.max.width);
    } else {
        // 内容不超过1.5张图片，显示全部内容，不需要滚动
        scrollViewWidth = MIN(totalContentWidth, constrainedSize.max.width);
    }
    
    // 调试日志
    NSLog(@"[AttachmentScrollNode] attachments=%lu, imageSize=%.1f, displayWidth=%.1f, totalContentWidth=%.1f, scrollViewWidth=%.1f, canScroll=%@", 
          (unsigned long)self.attachments.count, self.imageSize, displayWidth, totalContentWidth, scrollViewWidth, 
          (totalContentWidth > displayWidth) ? @"YES" : @"NO");
    
    // 设置滚动节点的尺寸
    self.scrollNode.style.width = ASDimensionMake(scrollViewWidth);
    self.scrollNode.style.height = ASDimensionMake(self.imageSize);
    
    // 关键修复：确保内容节点有足够的宽度来容纳所有图片
    // 交由 scrollNode.automaticallyManagesContentSize 根据布局自动计算
    
    return [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsZero child:self.scrollNode];
}

- (void)layoutDidFinish {
    [super layoutDidFinish];
    
    // 确保滚动视图的交互区域正确
    if (self.scrollNode.view) {
        self.scrollNode.view.userInteractionEnabled = YES;
        self.scrollNode.view.scrollEnabled = YES;
        
        // 确保所有子视图都可以接收触摸事件
        for (UIView *subview in self.scrollNode.view.subviews) {
            subview.userInteractionEnabled = YES;
        }
    }
}

#pragma mark - 防重复点击管理

// 清理点击缓存，防止内存泄漏
- (void)clearClickCache {
    [self.clickTimeCache removeAllObjects];
    self.isClickProcessing = NO;
}

- (void)dealloc {
    [self clearClickCache];
}

@end
