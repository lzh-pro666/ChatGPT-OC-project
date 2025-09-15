//
//  CodeBlockView.m
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import "CodeBlockView.h"

@interface CodeBlockView ()
@property (nonatomic, copy) NSString *code;
@property (nonatomic, copy, nullable) NSString *language;
@end

@implementation CodeBlockView

- (instancetype)initWithCode:(NSString *)code language:(nullable NSString *)language {
    self = [super init];
    if (self) {
        // 避免与外部约束系统冲突：由上层决定大小时，不让 autoresizingMask 转为约束
        self.translatesAutoresizingMaskIntoConstraints = NO;
        _code = [code copy];
        _language = [language copy];
        [self setupViews];
    }
    return self;
}
 
- (void)setupViews {
    self.backgroundColor = [UIColor colorWithRed:0.95 green:0.95 blue:0.95 alpha:1.0];
    self.layer.cornerRadius = 8;
    self.layer.masksToBounds = YES;
    
    // 语言标签
    self.languageLabel = [[UILabel alloc] init];
    self.languageLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightMedium];
    self.languageLabel.textColor = [UIColor darkGrayColor];
    self.languageLabel.text = self.language ?: @"code";
    self.languageLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.languageLabel setContentHuggingPriority:UILayoutPriorityDefaultHigh forAxis:UILayoutConstraintAxisHorizontal];
    [self.languageLabel setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self addSubview:self.languageLabel];
    
    // 复制按钮
    self.codeCopyButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.codeCopyButton setImage:[UIImage systemImageNamed:@"doc.on.doc"] forState:UIControlStateNormal];
    self.codeCopyButton.tintColor = [UIColor systemBlueColor];
    [self.codeCopyButton addTarget:self action:@selector(copyButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    self.codeCopyButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.codeCopyButton setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self.codeCopyButton setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [self addSubview:self.codeCopyButton];
    
    // 代码文本视图
    self.codeTextView = [[UITextView alloc] init];
    self.codeTextView.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    self.codeTextView.textColor = [UIColor blackColor];
    self.codeTextView.backgroundColor = [UIColor clearColor];
    self.codeTextView.editable = NO;
    self.codeTextView.selectable = YES;
    self.codeTextView.text = self.code;
    // 让文本视图根据内容自适应高度，避免滚动与外部约束冲突
    self.codeTextView.scrollEnabled = NO;
    self.codeTextView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.codeTextView setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [self.codeTextView setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisVertical];
    [self addSubview:self.codeTextView];
    
    // 设置约束
    [NSLayoutConstraint activateConstraints:@[
        // 语言标签
        [self.languageLabel.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [self.languageLabel.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        // 防止与复制按钮重叠
        [self.languageLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.codeCopyButton.leadingAnchor constant:-8],
        
        // 复制按钮
        [self.codeCopyButton.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
        [self.codeCopyButton.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [self.codeCopyButton.widthAnchor constraintEqualToConstant:24],
        [self.codeCopyButton.heightAnchor constraintEqualToConstant:24],
        
        // 代码文本视图
        [self.codeTextView.topAnchor constraintEqualToAnchor:self.languageLabel.bottomAnchor constant:4],
        [self.codeTextView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:12],
        [self.codeTextView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-12],
        [self.codeTextView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8]
    ]];
}

// 为 Texture 测量提供尺寸，避免显示高度为 0 导致看起来“空白”
- (CGSize)sizeThatFits:(CGSize)constrainedSize {
    CGFloat width = constrainedSize.width > 0 ? constrainedSize.width : [UIScreen mainScreen].bounds.size.width * 0.75;
    CGFloat contentWidth = MAX(0.0, width - 24.0); // 左右各 12 内边距
    
    // 顶部区域高度：8(top) + labelHeight + 4(间距)
    CGFloat labelHeight = ceil(self.languageLabel.font.lineHeight);
    CGFloat topArea = 8.0 + labelHeight + 4.0;
    
    // 文本高度
    CGSize textSize = [self.codeTextView sizeThatFits:CGSizeMake(contentWidth, CGFLOAT_MAX)];
    CGFloat bottomArea = 8.0; // bottom inset
    
    CGFloat height = topArea + textSize.height + bottomArea;
    return CGSizeMake(width, ceil(height));
}

- (void)copyButtonTapped {
    UIPasteboard *pasteboard = [UIPasteboard generalPasteboard];
    pasteboard.string = self.code;
    
    // 显示复制成功反馈
    [self.codeCopyButton setImage:[UIImage systemImageNamed:@"checkmark.circle.fill"] forState:UIControlStateNormal];
    self.codeCopyButton.tintColor = [UIColor systemGreenColor];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self.codeCopyButton setImage:[UIImage systemImageNamed:@"doc.on.doc"] forState:UIControlStateNormal];
        self.codeCopyButton.tintColor = [UIColor systemBlueColor];
    });
}

@end
