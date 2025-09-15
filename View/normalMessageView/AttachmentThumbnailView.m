#import "AttachmentThumbnailView.h"

@interface AttachmentThumbnailView ()
@property (nonatomic, strong) UIImageView *mutableImageView;
@property (nonatomic, strong) UIButton *deleteButton;
@end

@implementation AttachmentThumbnailView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.translatesAutoresizingMaskIntoConstraints = NO;
        self.layer.cornerRadius = 8.0;
        self.clipsToBounds = YES;

        _mutableImageView = [[UIImageView alloc] initWithFrame:CGRectZero];
        _mutableImageView.translatesAutoresizingMaskIntoConstraints = NO;
        _mutableImageView.contentMode = UIViewContentModeScaleAspectFill;

        _deleteButton = [UIButton buttonWithType:UIButtonTypeSystem];
        _deleteButton.translatesAutoresizingMaskIntoConstraints = NO;
        [_deleteButton setImage:[UIImage systemImageNamed:@"xmark.circle.fill"] forState:UIControlStateNormal];
        _deleteButton.tintColor = [UIColor colorWithWhite:0 alpha:0.7];
        [_deleteButton addTarget:self action:@selector(handleDelete) forControlEvents:UIControlEventTouchUpInside];

        [self addSubview:_mutableImageView];
        [self addSubview:_deleteButton];

        [NSLayoutConstraint activateConstraints:@[
            [_mutableImageView.topAnchor constraintEqualToAnchor:self.topAnchor],
            [_mutableImageView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
            [_mutableImageView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
            [_mutableImageView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],

            [_deleteButton.topAnchor constraintEqualToAnchor:self.topAnchor constant:2],
            [_deleteButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-2],
            [_deleteButton.widthAnchor constraintEqualToConstant:20],
            [_deleteButton.heightAnchor constraintEqualToConstant:20]
        ]];
    }
    return self;
}

- (UIImageView *)imageView {
    return _mutableImageView;
}

- (void)handleDelete {
    if (self.deleteAction) {
        self.deleteAction();
    }
}

@end


