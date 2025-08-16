//
//  ParserResult.h
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant on 2024/08/13.
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/**
 * 解析结果模型
 * 用于存储文本解析后的结果
 */
@interface ParserResult : NSObject

/**
 * 解析后的富文本字符串
 */
@property (nonatomic, strong) NSAttributedString *attributedString;

/**
 * 是否为代码块
 */
@property (nonatomic, assign) BOOL isCodeBlock;

/**
 * 代码块语言（可选）
 */
@property (nonatomic, copy, nullable) NSString *codeBlockLanguage;

/**
 * 初始化解析结果
 * @param attributedString 富文本字符串
 * @param isCodeBlock 是否为代码块
 * @param codeBlockLanguage 代码块语言
 * @return 解析结果对象
 */
- (instancetype)initWithAttributedString:(NSAttributedString *)attributedString
                              isCodeBlock:(BOOL)isCodeBlock
                        codeBlockLanguage:(nullable NSString *)codeBlockLanguage;

@end

NS_ASSUME_NONNULL_END
