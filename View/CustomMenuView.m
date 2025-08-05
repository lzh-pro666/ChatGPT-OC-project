#import "CustomMenuView.h"

@interface CustomMenuView ()
@property (nonatomic, strong) UIView *menuContainer;
@property (nonatomic, strong) UIButton *backgroundButton;
@property (nonatomic, assign) CGPoint anchorPoint; // 用于存储动画的锚点
@end

@implementation CustomMenuView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 背景视图
        self.backgroundColor = [UIColor clearColor]; // 初始为全透明
        
        _backgroundButton = [UIButton buttonWithType:UIButtonTypeCustom];
        _backgroundButton.frame = self.bounds;
        _backgroundButton.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [_backgroundButton addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:_backgroundButton];
        
        // 菜单容器
        _menuContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 180, 135)];
        _menuContainer.backgroundColor = [UIColor whiteColor];
        _menuContainer.layer.cornerRadius = 15;
        _menuContainer.clipsToBounds = YES;
        
        _menuContainer.layer.shadowColor = [UIColor blackColor].CGColor;
        _menuContainer.layer.shadowOpacity = 0.2;
        _menuContainer.layer.shadowOffset = CGSizeMake(0, 4);
        _menuContainer.layer.shadowRadius = 10;
        
        [self addSubview:_menuContainer];
        
        [self setupMenuItems];
    }
    return self;
}

- (void)setupMenuItems {
    NSArray *items = @[@"照片", @"摄像头", @"文件"];
    NSArray *iconNames = @[@"photo.on.rectangle", @"camera", @"doc"];
    CGFloat buttonHeight = 45.0;

    for (int i = 0; i < items.count; i++) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        button.frame = CGRectMake(0, i * buttonHeight, self.menuContainer.bounds.size.width, buttonHeight);
        button.tag = i;
        [button setTitle:items[i] forState:UIControlStateNormal];
        [button setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
        button.titleLabel.font = [UIFont systemFontOfSize:17];
        
        if (@available(iOS 13.0, *)) {
            UIImage *icon = [UIImage systemImageNamed:iconNames[i]];
            [button setImage:icon forState:UIControlStateNormal];
            button.tintColor = [UIColor darkGrayColor];
        }
        
        button.titleEdgeInsets = UIEdgeInsetsMake(0, 20, 0, 0);
        button.imageEdgeInsets = UIEdgeInsetsMake(0, 15, 0, 0);
        button.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        [button addTarget:self action:@selector(menuItemTapped:) forControlEvents:UIControlEventTouchUpInside];
        [self.menuContainer addSubview:button];
        
        if (i < items.count - 1) {
            UIView *separator = [[UIView alloc] initWithFrame:CGRectMake(15, (i + 1) * buttonHeight - 0.5, self.menuContainer.bounds.size.width - 30, 0.5)];
            separator.backgroundColor = [UIColor colorWithWhite:0.85 alpha:1.0];
            [self.menuContainer addSubview:separator];
        }
    }
}


- (void)menuItemTapped:(UIButton *)sender {
    if ([self.delegate respondsToSelector:@selector(customMenuViewDidSelectItemAtIndex:)]) {
        [self.delegate customMenuViewDidSelectItemAtIndex:sender.tag];
    }
    [self dismiss];
}

#pragma mark - 显示与隐藏 (整体展开动画)

- (void)showInView:(UIView *)view atPoint:(CGPoint)point {
    // 1. 存储锚点
    self.anchorPoint = point;
    
    // 2. 将自身添加到父视图并立即设置背景色
    self.frame = view.bounds;
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0];
    [view addSubview:self];

    // 3. 计算菜单最终应该在的位置 (finalFrame)
    CGRect finalFrame = self.menuContainer.frame;
    finalFrame.origin.x = point.x - finalFrame.size.width; // 锚定右边缘
    finalFrame.origin.y = point.y - finalFrame.size.height; // 锚定下边缘

    // 边界检查
    if (finalFrame.origin.x < 10) finalFrame.origin.x = 10;
    if (finalFrame.origin.y < view.safeAreaInsets.top) finalFrame.origin.y = view.safeAreaInsets.top;
    
    // 4. 计算最终的中心点
    CGPoint finalCenter = CGPointMake(CGRectGetMidX(finalFrame), CGRectGetMidY(finalFrame));

    // 5. 准备动画的初始状态 (菜单整体)
    self.menuContainer.alpha = 0;
    self.menuContainer.center = self.anchorPoint;
    self.menuContainer.transform = CGAffineTransformMakeScale(0.1, 0.1);
    
    // 6. 执行动画到最终状态 (菜单整体)
    [UIView animateWithDuration:0.35
                          delay:0
         usingSpringWithDamping:0.7
          initialSpringVelocity:0.5
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        self.menuContainer.center = finalCenter;
        self.menuContainer.transform = CGAffineTransformIdentity;
        self.menuContainer.alpha = 1.0;
    } completion:nil];
}

- (void)dismiss {
    // 背景颜色不参与动画，立即变为透明
    self.backgroundColor = [UIColor clearColor];

    [UIView animateWithDuration:0.25
                          delay:0
                        options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        // 菜单整体回到初始状态
        self.menuContainer.center = self.anchorPoint;
        self.menuContainer.transform = CGAffineTransformMakeScale(0.1, 0.1);
        self.menuContainer.alpha = 0;
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
    }];
}

@end
