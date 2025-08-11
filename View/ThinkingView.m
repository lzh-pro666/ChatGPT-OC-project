#import "ThinkingView.h"

@interface ThinkingView ()

@property (nonatomic, strong) NSArray<UIView *> *dots;

@end

@implementation ThinkingView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupView];
    }
    return self;
}

- (void)setupView {
    self.backgroundColor = [UIColor colorWithRed:233/255.0 green:236/255.0 blue:239/255.0 alpha:1.0]; // #e9ecef
    self.layer.cornerRadius = 16;
    self.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
    self.clipsToBounds = YES;
    
    NSMutableArray *dots = [NSMutableArray arrayWithCapacity:3];
    
    for (int i = 0; i < 3; i++) {
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
        dot.backgroundColor = [UIColor colorWithWhite:0.4 alpha:0.6]; // #666 with opacity
        dot.layer.cornerRadius = 4;
        [self addSubview:dot];
        [dots addObject:dot];
    }
    
    self.dots = dots;
    
    // 排列点的位置
    [self layoutDots];
}

- (void)layoutDots {
    CGFloat dotSpacing = 8;
    CGFloat totalWidth = self.dots.count * 8 + (self.dots.count - 1) * dotSpacing;
    CGFloat startX = (self.bounds.size.width - totalWidth) / 2;
    CGFloat centerY = self.bounds.size.height / 2;
    
    for (int i = 0; i < self.dots.count; i++) {
        UIView *dot = self.dots[i];
        dot.center = CGPointMake(startX + i * (8 + dotSpacing) + 4, centerY);
    }
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self layoutDots];
}

- (void)startAnimating {
    [self.dots enumerateObjectsUsingBlock:^(UIView * _Nonnull dot, NSUInteger idx, BOOL * _Nonnull stop) {
        // 重置动画
        [dot.layer removeAllAnimations];
        
        // 创建缩放动画
        CAKeyframeAnimation *scaleAnimation = [CAKeyframeAnimation animationWithKeyPath:@"transform.scale"];
        scaleAnimation.values = @[@0.6, @1.0, @0.6];
        scaleAnimation.keyTimes = @[@0, @0.4, @1.0];
        scaleAnimation.duration = 1.4;
        scaleAnimation.repeatCount = HUGE_VALF;
        
        // 设置延迟，使三个点交错动画
        CFTimeInterval delay = idx * 0.16;
        scaleAnimation.beginTime = CACurrentMediaTime() + delay;
        
        // 添� 动画
        [dot.layer addAnimation:scaleAnimation forKey:@"thinking"];
    }];
}

- (void)stopAnimating {
    [self.dots enumerateObjectsUsingBlock:^(UIView * _Nonnull dot, NSUInteger idx, BOOL * _Nonnull stop) {
        [dot.layer removeAllAnimations];
    }];
}

@end 