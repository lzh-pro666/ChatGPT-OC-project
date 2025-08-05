//
//  CustomMenuView.h
//  ChatGPT-OC-Clone
//
//  Created by mac—lzh on 2025/8/4.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// 1. 定义一个代理协议
@protocol CustomMenuViewDelegate <NSObject>
- (void)customMenuViewDidSelectItemAtIndex:(NSInteger)index;
@end

@interface CustomMenuView : UIView

// 2. 添加一个弱引用的 delegate 属性
@property (nonatomic, weak) id<CustomMenuViewDelegate> delegate;

- (instancetype)initWithFrame:(CGRect)frame;
- (void)showInView:(UIView *)view atPoint:(CGPoint)point;
- (void)dismiss;

@end

NS_ASSUME_NONNULL_END
