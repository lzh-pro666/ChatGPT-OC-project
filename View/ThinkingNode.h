#import <AsyncDisplayKit/AsyncDisplayKit.h>

NS_ASSUME_NONNULL_BEGIN

// 作为表� �可用的单元节点
@interface ThinkingNode : ASCellNode

- (void)startAnimating;
- (void)stopAnimating;

// 可选：在思考气泡内显示提示文本，比如“当前正在进行图片理解/图片生成”
- (void)setHintText:(NSString *)text;

@end

NS_ASSUME_NONNULL_END
