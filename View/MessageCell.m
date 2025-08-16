#import "MessageCell.h"

@implementation MessageCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.backgroundColor = [UIColor colorWithRed:247/255.0 green:247/255.0 blue:248/255.0 alpha:1.0]; // #f7f7f8
    
    // 气泡视图
    self.bubbleView = [[UIView alloc] init];
    self.bubbleView.layer.cornerRadius = 16;
    self.bubbleView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.bubbleView];
    
    // 消息� �签
    self.messageLabel = [[UILabel alloc] init];
    self.messageLabel.font = [UIFont systemFontOfSize:16]; // 增大字体
    self.messageLabel.numberOfLines = 0; // � 限行数
    self.messageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.messageLabel.lineBreakMode = NSLineBreakByWordWrapping;
    
    // 增� 行间距
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.lineSpacing = 4; // 行间距
    paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
    self.messageLabel.attributedText = [[NSAttributedString alloc] initWithString:@"" 
                                                                       attributes:@{
                                                                           NSParagraphStyleAttributeName: paragraphStyle,
                                                                           NSFontAttributeName: [UIFont systemFontOfSize:16]
                                                                       }];
    
    // 为文�设置最大宽度，确保正确换行
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    self.messageLabel.preferredMaxLayoutWidth = screenWidth * 0.75 - 32; // 增� 边距
    
    [self.bubbleView addSubview:self.messageLabel];
    
    // 消息� �签在气泡内的约束，增� 内边距
    [NSLayoutConstraint activateConstraints:@[
        [self.messageLabel.topAnchor constraintEqualToAnchor:self.bubbleView.topAnchor constant:12], // 增� 顶部间距
        [self.messageLabel.leadingAnchor constraintEqualToAnchor:self.bubbleView.leadingAnchor constant:16], // 增� 左侧间距
        [self.messageLabel.trailingAnchor constraintEqualToAnchor:self.bubbleView.trailingAnchor constant:-16], // 增� 右侧间距
        [self.messageLabel.bottomAnchor constraintEqualToAnchor:self.bubbleView.bottomAnchor constant:-12] // 增� 底部间距
    ]];
}

- (void)configureWithMessage:(NSString *)message isFromUser:(BOOL)isFromUser {
    // 使用带行间距的文�显示
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.lineSpacing = 4; // 行间距
    paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
    
    self.messageLabel.attributedText = [[NSAttributedString alloc] initWithString:message 
                                                                       attributes:@{
                                                                           NSParagraphStyleAttributeName: paragraphStyle,
                                                                           NSFontAttributeName: [UIFont systemFontOfSize:16]
                                                                       }];
    
    // 为文�设置最大宽度，确保正确换行
    CGFloat screenWidth = [UIScreen mainScreen].bounds.size.width;
    self.messageLabel.preferredMaxLayoutWidth = screenWidth * 0.75 - 32;
    
    // 移除之前的约束
    [self.contentView removeConstraints:self.contentView.constraints];
    
    if (isFromUser) {
        // 用户消息� �式（右侧浅灰色）
        self.bubbleView.backgroundColor = [UIColor colorWithRed:240/255.0 green:240/255.0 blue:240/255.0 alpha:1.0]; // 浅灰色
        self.messageLabel.textColor = [UIColor blackColor];
        
        // 右下角圆角处理
        self.bubbleView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMinXMaxYCorner;
        
        // 右侧对齐约束，增� 边距
        [NSLayoutConstraint activateConstraints:@[
            [self.bubbleView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12], // 增� 顶部间距
            [self.bubbleView.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-16],
            [self.bubbleView.widthAnchor constraintLessThanOrEqualToConstant:screenWidth * 0.75],
            [self.bubbleView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12] // 增� 底部间距
        ]];
    } else {
        // AI消息� �式（左侧灰色）
        self.bubbleView.backgroundColor = [UIColor colorWithRed:233/255.0 green:236/255.0 blue:239/255.0 alpha:1.0]; // #e9ecef
        self.messageLabel.textColor = [UIColor blackColor];
        
        // 左下角圆角处理
        self.bubbleView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner | kCALayerMaxXMaxYCorner;
        
        // 左侧对齐约束，增� 边距
        [NSLayoutConstraint activateConstraints:@[
            [self.bubbleView.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:12], // 增� 顶部间距
            [self.bubbleView.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [self.bubbleView.widthAnchor constraintLessThanOrEqualToConstant:screenWidth * 0.75],
            [self.bubbleView.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-12] // 增� 底部间距
        ]];
    }
    
    // 强制立即重新布局以确保正确显示
    [self setNeedsLayout];
    [self layoutIfNeeded];
}

+ (CGFloat)heightForMessage:(NSString *)message width:(CGFloat)width {
    CGFloat maxWidth = width * 0.75 - 32; // 减去气泡内边距
    
    // 创建与实际显示相同的段落� �式
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.lineSpacing = 4; // 行间距
    paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
    
    // 计算文�高度时使用相同的属性
    NSAttributedString *attributedText = [[NSAttributedString alloc] initWithString:message 
                                                                         attributes:@{
                                                                             NSParagraphStyleAttributeName: paragraphStyle,
                                                                             NSFontAttributeName: [UIFont systemFontOfSize:16]
                                                                         }];
    
    NSStringDrawingOptions options = NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading;
    CGRect rect = [attributedText boundingRectWithSize:CGSizeMake(maxWidth, CGFLOAT_MAX)
                                               options:options
                                               context:nil];
    
    // 增� 足够的边距，确保文�完全显示
    return ceil(rect.size.height) + 60; // 显著增� 边距
}

@end 