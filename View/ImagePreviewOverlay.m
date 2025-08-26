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
@property (nonatomic, strong) UIStackView *actionBar; // 顶部右侧按钮条：复制/分享/关闭
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

        _closeButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [_closeButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        _closeButton.tintColor = [UIColor whiteColor];
        _closeButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_closeButton addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];

        UIButton *copyBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [copyBtn setImage:[UIImage systemImageNamed:@"doc.on.doc.fill"] forState:UIControlStateNormal];
        copyBtn.tintColor = [UIColor whiteColor];
        copyBtn.contentEdgeInsets = UIEdgeInsetsMake(6, 6, 6, 6); // 增大点击热区
        copyBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [copyBtn.widthAnchor constraintEqualToConstant:34].active = YES;
        [copyBtn.heightAnchor constraintEqualToConstant:34].active = YES;
        [copyBtn addTarget:self action:@selector(copyImage) forControlEvents:UIControlEventTouchUpInside];

        UIButton *shareBtn = [UIButton buttonWithType:UIButtonTypeSystem];
        [shareBtn setImage:[UIImage systemImageNamed:@"square.and.arrow.up.circle.fill"] forState:UIControlStateNormal];
        shareBtn.tintColor = [UIColor whiteColor];
        shareBtn.contentEdgeInsets = UIEdgeInsetsMake(6, 6, 6, 6); // 增大点击热区
        shareBtn.translatesAutoresizingMaskIntoConstraints = NO;
        [shareBtn.widthAnchor constraintEqualToConstant:34].active = YES;
        [shareBtn.heightAnchor constraintEqualToConstant:34].active = YES;
        [shareBtn addTarget:self action:@selector(shareImage) forControlEvents:UIControlEventTouchUpInside];

        _actionBar = [[UIStackView alloc] initWithArrangedSubviews:@[copyBtn, shareBtn, _closeButton]];
        _actionBar.axis = UILayoutConstraintAxisHorizontal;
        _actionBar.spacing = 5.0; // 间隔 5px
        _actionBar.alignment = UIStackViewAlignmentCenter;
        _actionBar.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_actionBar];

        [NSLayoutConstraint activateConstraints:@[
            [_backgroundView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_backgroundView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_backgroundView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_backgroundView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            // 图片占屏幕 3/4
            [_imageView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
            [_imageView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
            [_imageView.widthAnchor constraintEqualToAnchor:self.widthAnchor multiplier:0.75],
            [_imageView.heightAnchor constraintEqualToAnchor:self.heightAnchor multiplier:0.75],

            // 顶部右侧按钮条：更贴近图片，间隔 2
            [_actionBar.topAnchor constraintEqualToAnchor:_imageView.topAnchor constant:2],
            [_actionBar.trailingAnchor constraintEqualToAnchor:_imageView.trailingAnchor constant:-2]
        ]];

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(backgroundTapped:)];
        [_backgroundView addGestureRecognizer:tap];
    }
    return self;
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
    } else if (url) {
        // 使用 PINRemoteImage 异步加载
        __weak typeof(self) weakSelf = self;
        [self.imageView pin_setImageFromURL:url completion:^(PINRemoteImageManagerResult * _Nonnull result) {
            if (result.error) {
                NSLog(@"ImagePreviewOverlay: 加载失败: %@", result.error.localizedDescription);
            }
        }];
    }

    self.alpha = 0.0;
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = 1.0;
    }];
}

- (void)dismiss {
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = 0.0;
    } completion:^(BOOL finished) {
        [self removeFromSuperview];
    }];
}

- (void)backgroundTapped:(UITapGestureRecognizer *)gr {
    [self dismiss];
}

- (void)copyImage {
    if (!self.imageView.image) { return; }
    [UIPasteboard generalPasteboard].image = self.imageView.image;
    // 轻提示：按钮短暂缩放反馈
    [self hapticAndBounceOn:self.actionBar.arrangedSubviews.firstObject];
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
        [self hapticAndBounceOn:(self.actionBar.arrangedSubviews.count > 1 ? self.actionBar.arrangedSubviews[1] : nil)];
    }
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

@end


