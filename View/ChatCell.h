#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface ChatCell : UITableViewCell

@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *dateLabel;

- (void)setTitle:(NSString *)title date:(NSDate *)date;

@end

NS_ASSUME_NONNULL_END 
