//
//  ImagePreviewOverlay.m
//  ChatGPT-OC-Clone
//

#import "ImagePreviewOverlay.h"
#import <PINRemoteImage/PINRemoteImage.h>

@interface ImagePreviewOverlay ()
@property (nonatomic, strong) UIView *backgroundView;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *duplicateButton;
@property (nonatomic, strong) UIButton *shareButton;
@property (nonatomic, strong) UIStackView *actionBar; // 顶部右侧按钮条：复制/分享/关闭
@property (nonatomic, strong) NSLayoutConstraint *actionBarTopConstraint;
@property (nonatomic, strong) NSLayoutConstraint *actionBarTrailingConstraint;
@property (nonatomic, assign) BOOL isImageLoaded;
@end

@implementation ImagePreviewOverlay

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];

        _backgroundView = [[UIView alloc] initWithFrame:CGRectZero];
        _backgroundView.backgroundColor = [[UIColor lightGrayColor] colorWithAlphaComponent:0.8];
        _backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_backgroundView];

        _imageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _imageView.contentMode = UIViewContentModeScaleAspectFit;
        _imageView.layer.cornerRadius = 12.0;
        _imageView.layer.masksToBounds = YES;
        _imageView.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_imageView];

        // 创建统一样式的按钮
        _closeButton = [self createActionButtonWithImage:@"xmark.circle.fill" action:@selector(dismiss)];
        _duplicateButton = [self createActionButtonWithImage:@"doc.on.doc.fill" action:@selector(copyImage)];
        _shareButton = [self createActionButtonWithImage:@"square.and.arrow.up.circle.fill" action:@selector(shareImage)];

        // 创建按钮容器
        _actionBar = [[UIStackView alloc] initWithArrangedSubviews:@[_duplicateButton, _shareButton, _closeButton]];
        _actionBar.axis = UILayoutConstraintAxisHorizontal;
        _actionBar.spacing = 12.0; // 增加按钮间距
        _actionBar.alignment = UIStackViewAlignmentCenter;
        _actionBar.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_actionBar];

        // 设置约束
        [NSLayoutConstraint activateConstraints:@[
            [_backgroundView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_backgroundView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_backgroundView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_backgroundView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            // 图片约束 - 初始设置为屏幕的3/4，后续会根据图片实际尺寸调整
            [_imageView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_imageView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_imageView.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor multiplier:0.9],
            [_imageView.heightAnchor constraintLessThanOrEqualToAnchor:self.heightAnchor multiplier:0.8]
        ]];
        
        // 保存按钮约束的引用，以便后续动态调整
        _actionBarTopConstraint = [_actionBar.topAnchor constraintEqualToAnchor:_imageView.topAnchor constant:16];
        _actionBarTrailingConstraint = [_actionBar.trailingAnchor constraintEqualToAnchor:_imageView.trailingAnchor constant:-16];
        
        [NSLayoutConstraint activateConstraints:@[
            _actionBarTopConstraint,
            _actionBarTrailingConstraint
        ]];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(backgroundTapped:)];
        [_backgroundView addGestureRecognizer:tap];
        
        // 监听设备旋转
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(deviceOrientationDidChange:)
                                                     name:UIDeviceOrientationDidChangeNotification
                                                   object:nil];
    }
    return self;
}

#pragma mark - Button Creation

- (UIButton *)createActionButtonWithImage:(NSString *)imageName action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setImage:[UIImage systemImageNamed:imageName] forState:UIControlStateNormal];
    
    // 统一的样式设计
    button.tintColor = [UIColor whiteColor];
    button.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.6];
    button.layer.cornerRadius = 17;
    button.contentEdgeInsets = UIEdgeInsetsMake(8, 8, 8, 8);
    
    // 添加阴影效果，提高可见性
    button.layer.shadowColor = [UIColor blackColor].CGColor;
    button.layer.shadowOffset = CGSizeMake(0, 2);
    button.layer.shadowRadius = 4;
    button.layer.shadowOpacity = 0.3;
    
    // 设置按钮尺寸
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.widthAnchor constraintEqualToConstant:34].active = YES;
    [button.heightAnchor constraintEqualToConstant:34].active = YES;
    
    // 添加点击事件
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    
    return button;
}

- (void)presentInView:(UIView *)parent image:(UIImage *)image imageURL:(NSURL *)url {
    self.translatesAutoresizingMaskIntoConstraints = NO;
    [parent addSubview:self];
    [NSLayoutConstraint activateConstraints:@[
        [self.topAnchor constraintEqualToAnchor:parent.topAnchor],
        [self.leadingAnchor constraintEqualToAnchor:parent.leadingAnchor],
        [self.trailingAnchor constraintEqualToAnchor:parent.trailingAnchor],
        [self.bottomAnchor constraintEqualToAnchor:parent.bottomAnchor]
    ]];

    if (image) {
        self.imageView.image = image;
        [self adjustLayoutForImage:image];
    } else if (url) {
        // 使用 PINRemoteImage 异步加载
        __weak typeof(self) weakSelf = self;
        [self.imageView pin_setImageFromURL:url completion:^(PINRemoteImageManagerResult * _Nonnull result) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (strongSelf) {
                if (result.error) {
                    NSLog(@"ImagePreviewOverlay: 加载失败: %@", result.error.localizedDescription);
                } else if (result.image) {
                    [strongSelf adjustLayoutForImage:result.image];
                }
            }
        }];
    }

    self.alpha = 0.0;
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = 1.0;
    }];
}

- (void)dismiss {
    // 移除通知监听
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = 0.0;
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
    }];
}

- (void)backgroundTapped:(UITapGestureRecognizer *)gr {
    [self dismiss];
}

#pragma mark - Layout Adjustment

- (void)adjustLayoutForImage:(UIImage *)image {
    if (!image) return;
    
    self.isImageLoaded = YES;
    
    // 获取屏幕尺寸
    CGSize screenSize = [UIScreen mainScreen].bounds.size;
    CGFloat screenWidth = screenSize.width;
    CGFloat screenHeight = screenSize.height;
    
    // 计算图片的宽高比
    CGFloat imageAspectRatio = image.size.width / image.size.height;
    CGFloat screenAspectRatio = screenWidth / screenHeight;
    
    // 计算图片在屏幕上的实际显示尺寸
    CGSize displaySize;
    if (imageAspectRatio > screenAspectRatio) {
        // 图片更宽，以宽度为准
        displaySize.width = screenWidth * 0.9;
        displaySize.height = displaySize.width / imageAspectRatio;
    } else {
        // 图片更高，以高度为准
        displaySize.height = screenHeight * 0.8;
        displaySize.width = displaySize.height * imageAspectRatio;
    }
    
    // 确保图片不会超出屏幕边界
    if (displaySize.width > screenWidth * 0.9) {
        displaySize.width = screenWidth * 0.9;
        displaySize.height = displaySize.width / imageAspectRatio;
    }
    if (displaySize.height > screenHeight * 0.8) {
        displaySize.height = screenHeight * 0.8;
        displaySize.width = displaySize.height * imageAspectRatio;
    }
    
    // 计算图片在屏幕上的实际位置
    CGFloat imageX = (screenWidth - displaySize.width) / 2;
    CGFloat imageY = (screenHeight - displaySize.height) / 2;
    
    // 动态调整按钮位置
    [self adjustButtonPositionForImageFrame:CGRectMake(imageX, imageY, displaySize.width, displaySize.height)];
    
    // 更新图片约束
    [self updateImageConstraintsWithSize:displaySize];
}

- (void)adjustButtonPositionForImageFrame:(CGRect)imageFrame {
    // 计算按钮应该放置的位置
    CGFloat buttonY = imageFrame.origin.y + 16; // 距离图片顶部16点
    CGFloat buttonX = imageFrame.origin.x + imageFrame.size.width - 16; // 距离图片右边16点
    
    // 获取按钮容器的宽度
    [self.actionBar layoutIfNeeded];
    CGFloat buttonBarWidth = self.actionBar.frame.size.width;
    
    // 确保按钮不会超出屏幕左边界
    if (buttonX - buttonBarWidth < 16) {
        buttonX = 16 + buttonBarWidth;
    }
    
    // 确保按钮不会超出屏幕顶部
    if (buttonY < 50) { // 考虑状态栏高度
        buttonY = 50;
    }
    
    // 更新按钮约束
    self.actionBarTopConstraint.constant = buttonY - imageFrame.origin.y;
    self.actionBarTrailingConstraint.constant = -(imageFrame.origin.x + imageFrame.size.width - buttonX);
    
    // 添加动画效果
    [UIView animateWithDuration:0.3 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        [self layoutIfNeeded];
    } completion:nil];
}

- (void)updateImageConstraintsWithSize:(CGSize)size {
    // 移除旧的尺寸约束
    for (NSLayoutConstraint *constraint in self.imageView.constraints) {
        if (constraint.firstAttribute == NSLayoutAttributeWidth || constraint.firstAttribute == NSLayoutAttributeHeight) {
            [self.imageView removeConstraint:constraint];
        }
    }
    
    // 添加新的尺寸约束
    [NSLayoutConstraint activateConstraints:@[
        [self.imageView.widthAnchor constraintEqualToConstant:size.width],
        [self.imageView.heightAnchor constraintEqualToConstant:size.height]
    ]];
}

- (void)copyImage {
    if (!self.imageView.image) { return; }
    [UIPasteboard generalPasteboard].image = self.imageView.image;
    // 轻提示：按钮短暂缩放反馈
    [self hapticAndBounceOn:self.duplicateButton];
}

- (void)shareImage {
    if (!self.imageView.image) return;
    UIActivityViewController *vc = [[UIActivityViewController alloc] initWithActivityItems:@[self.imageView.image] applicationActivities:nil];
    UIResponder *responder = self.nextResponder;
    while (responder && ![responder isKindOfClass:[UIViewController class]]) {
        responder = responder.nextResponder;
    }
    UIViewController *presenter = (UIViewController *)responder;
    if (presenter) {
        [presenter presentViewController:vc animated:YES completion:nil];
        [self hapticAndBounceOn:self.shareButton];
    }
}

#pragma mark - Device Orientation

- (void)deviceOrientationDidChange:(NSNotification *)notification {
    // 延迟执行，等待旋转动画完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.isImageLoaded && self.imageView.image) {
            [self adjustLayoutForImage:self.imageView.image];
        }
    });
}

#pragma mark - Feedback
- (void)hapticAndBounceOn:(UIView *)v {
    if (!v) return;
    // 轻微震动
    UIImpactFeedbackGenerator *gen = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
    [gen impactOccurred];
    // 轻微缩放动画
    [UIView animateWithDuration:0.06 animations:^{ v.transform = CGAffineTransformMakeScale(0.88, 0.88); } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.06 animations:^{ v.transform = CGAffineTransformIdentity; }];
    }];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end


