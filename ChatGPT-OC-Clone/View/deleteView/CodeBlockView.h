//
//  CodeBlockView.h
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CodeBlockView : UIView

@property (nonatomic, strong) UITextView *codeTextView;
@property (nonatomic, strong) UILabel *languageLabel;
@property (nonatomic, strong) UIButton *codeCopyButton;

- (instancetype)initWithCode:(NSString *)code language:(nullable NSString *)language;

@end

NS_ASSUME_NONNULL_END
