#import "ChatCell.h"

@implementation ChatCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        [self setupViews];
    }
    return self;
}

- (void)setupViews {
    // 标题标签
    self.titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    self.titleLabel.textColor = [UIColor blackColor];
    self.titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.titleLabel];
    
    // 日期标签
    self.dateLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    self.dateLabel.font = [UIFont systemFontOfSize:14];
    self.dateLabel.textColor = [UIColor colorWithWhite:0.4 alpha:1.0]; // #666
    self.dateLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:self.dateLabel];
    
    self.contentView.backgroundColor = [UIColor whiteColor];
    // 设置约束
    [NSLayoutConstraint activateConstraints:@[
        [self.titleLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:16],
        [self.titleLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:25],
        [self.titleLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-25],
        
        [self.dateLabel.topAnchor constraintEqualToAnchor:self.titleLabel.bottomAnchor constant:4],
        [self.dateLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:25],
        [self.dateLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-25],
        [self.dateLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-16]
    ]];
    
    // 自定义选中状态背景
    UIView *selectedBackgroundView = [[UIView alloc] init];
    selectedBackgroundView.backgroundColor = [UIColor colorWithRed:247/255.0 green:247/255.0 blue:248/255.0 alpha:1.0]; // #f7f7f8
    self.selectedBackgroundView = selectedBackgroundView;
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated {
    [super setSelected:selected animated:animated];
    
    if (selected) {
        self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
    } else {
        self.titleLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightMedium];
    }
}

- (void)setTitle:(NSString *)title date:(NSDate *)date {
    self.titleLabel.text = title;
    
    NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
    NSDate *now = [NSDate date];
    NSCalendar *calendar = [NSCalendar currentCalendar];
    
    NSDateComponents *components = [calendar components:NSCalendarUnitDay fromDate:date toDate:now options:0];
    
    if (components.day == 0) {
        // 今天
        formatter.dateFormat = @"今天 HH:mm";
    } else if (components.day == 1) {
        // 昨天
        formatter.dateFormat = @"昨天 HH:mm";
    } else if (components.day < 7) {
        // 最近一周
        formatter.dateFormat = @"EEEE HH:mm";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"zh_CN"];
    } else {
        // 更久远
        formatter.dateFormat = @"M月d日";
    }
    
    self.dateLabel.text = [formatter stringFromDate:date];
}

@end 
