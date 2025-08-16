//
//  ResponseParsingTask.m
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant on 2024/08/13.
//

#import "ResponseParsingTask.h"
#import "ParserResult.h"
#import <UIKit/UIKit.h>

@implementation ResponseParsingTask

- (void)parseText:(NSString *)text 
       completion:(void(^)(NSArray<ParserResult *> *results))completion {
    [self parseTextWithThreshold:text threshold:64 completion:completion];
}

- (void)parseTextWithThreshold:(NSString *)text 
                     threshold:(NSInteger)threshold
                    completion:(void(^)(NSArray<ParserResult *> *results))completion {
    
    // 在后台队列进行解析，避免阻塞UI
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        
        // 检查文本长度，如果太短则直接返回简单解析结果
        if (text.length < threshold) {
            ParserResult *result = [[ParserResult alloc] initWithAttributedString:[self attributedStringForText:text]
                                                                       isCodeBlock:NO
                                                                 codeBlockLanguage:nil];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(@[result]);
                }
            });
            return;
        }
        
        // 检查是否包含代码块标记，如果有则立即解析
        BOOL containsCodeBlock = [text containsString:@"```"];
        
        // 如果包含代码块或文本长度超过阈值，进行完整解析
        if (containsCodeBlock || text.length >= threshold) {
            NSArray<ParserResult *> *results = [self performFullParsing:text];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(results);
                }
            });
        } else {
            // 简单解析，减少计算负担
            ParserResult *result = [[ParserResult alloc] initWithAttributedString:[self attributedStringForText:text]
                                                                       isCodeBlock:NO
                                                                 codeBlockLanguage:nil];
            
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) {
                    completion(@[result]);
                }
            });
        }
    });
}

+ (BOOL)shouldReparseText:(NSString *)newText 
            lastParsedText:(NSString *)lastParsedText 
                 threshold:(NSInteger)threshold {
    
    // 如果文本相同，不需要重新解析
    if ([newText isEqualToString:lastParsedText]) {
        return NO;
    }
    
    // 计算新增内容
    NSString *appendedText = @"";
    if (newText.length > lastParsedText.length && [newText hasPrefix:lastParsedText]) {
        appendedText = [newText substringFromIndex:lastParsedText.length];
    }
    
    // 如果新增内容包含完整的代码块结束标记（从未闭合变为闭合），需要重新解析
    if ([appendedText containsString:@"```"] && [lastParsedText containsString:@"```"]) {
        // 计算上次解析时代码块开始标记的数量
        NSInteger lastCodeBlockStarts = [[lastParsedText componentsSeparatedByString:@"```"] count] - 1;
        NSInteger newCodeBlockStarts = [[newText componentsSeparatedByString:@"```"] count] - 1;
        
        // 如果代码块标记数量从奇数变为偶数，说明有代码块闭合了
        if (lastCodeBlockStarts % 2 == 1 && newCodeBlockStarts % 2 == 0) {
            return YES;
        }
    }
    
    // 如果新文本新增了完整的 Markdown 结构，需要重新解析
    if ([appendedText rangeOfString:@"\n### " options:0].location != NSNotFound ||
        [appendedText rangeOfString:@"\n--- " options:0].location != NSNotFound ||
        [appendedText rangeOfString:@"\n- " options:0].location != NSNotFound ||
        [appendedText rangeOfString:@"**" options:0].location != NSNotFound) {
        return YES;
    }
    
    // 如果文本长度变化超过阈值，需要重新解析
    NSInteger lengthDifference = abs((int)(newText.length - lastParsedText.length));
    if (lengthDifference >= threshold) {
        return YES;
    }
    
    return NO;
}

- (NSArray<ParserResult *> *)performFullParsing:(NSString *)text {
    NSMutableArray<ParserResult *> *results = [NSMutableArray array];
    
    // 检查代码块
    if ([text containsString:@"```"]) {
        // 使用正则表达式更精确地处理代码块
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"```([\\s\\S]*?)```" 
                                                                               options:0 
                                                                                 error:nil];
        NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text 
                                                                   options:0 
                                                                     range:NSMakeRange(0, text.length)];
        
        NSUInteger lastIndex = 0;
        
        for (NSTextCheckingResult *match in matches) {
            NSRange matchRange = match.range;
            
            // 添加代码块前的普通文本
            if (matchRange.location > lastIndex) {
                NSString *plainText = [text substringWithRange:NSMakeRange(lastIndex, matchRange.location - lastIndex)];
                if (plainText.length > 0) {
                    ParserResult *textResult = [[ParserResult alloc] initWithAttributedString:[self attributedStringForText:plainText]
                                                                                   isCodeBlock:NO
                                                                             codeBlockLanguage:nil];
                    [results addObject:textResult];
                }
            }
            
            // 添加代码块
            NSString *codeBlock = [text substringWithRange:matchRange];
            // 移除外层的 ``` 标记，保留内部内容
            NSString *innerContent = [codeBlock substringWithRange:NSMakeRange(3, codeBlock.length - 6)];
            
            ParserResult *codeResult = [[ParserResult alloc] initWithAttributedString:[self attributedStringForCodeBlock:innerContent]
                                                                           isCodeBlock:YES
                                                                     codeBlockLanguage:[self extractCodeLanguage:innerContent]];
            [results addObject:codeResult];
            
            lastIndex = NSMaxRange(matchRange);
        }
        
        // 添加最后剩余的文本（包括未闭合的代码块）
        if (lastIndex < text.length) {
            NSString *remainingText = [text substringFromIndex:lastIndex];
            
            // 检查是否包含未闭合的代码块标记
            if ([remainingText containsString:@"```"]) {
                NSRange openingRange = [remainingText rangeOfString:@"```"];
                if (openingRange.location != NSNotFound) {
                    // 先添加代码块前的文本
                    if (openingRange.location > 0) {
                        NSString *beforeCode = [remainingText substringToIndex:openingRange.location];
                        ParserResult *textResult = [[ParserResult alloc] initWithAttributedString:[self attributedStringForText:beforeCode]
                                                                                       isCodeBlock:NO
                                                                                 codeBlockLanguage:nil];
                        [results addObject:textResult];
                    }
                    
                    // 对于未闭合的代码块，作为普通文本显示，而不是跳过
                    NSString *unclosedCodeBlock = [remainingText substringFromIndex:openingRange.location];
                    ParserResult *textResult = [[ParserResult alloc] initWithAttributedString:[self attributedStringForText:unclosedCodeBlock]
                                                                                   isCodeBlock:NO
                                                                             codeBlockLanguage:nil];
                    [results addObject:textResult];
                }
            } else {
                // 普通文本
                ParserResult *textResult = [[ParserResult alloc] initWithAttributedString:[self attributedStringForText:remainingText]
                                                                               isCodeBlock:NO
                                                                         codeBlockLanguage:nil];
                [results addObject:textResult];
            }
        }
    } else {
        // 没有代码块，直接处理文本
        ParserResult *result = [[ParserResult alloc] initWithAttributedString:[self attributedStringForText:text]
                                                                   isCodeBlock:NO
                                                             codeBlockLanguage:nil];
        [results addObject:result];
    }
    
    return [results copy];
}

- (NSString *)extractCodeLanguage:(NSString *)codeBlock {
    NSArray<NSString *> *lines = [codeBlock componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    if (lines.count > 0) {
        NSString *firstLine = [lines[0] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (firstLine.length > 0) {
            return firstLine;
        }
    }
    return @"";
}

- (NSAttributedString *)attributedStringForCodeBlock:(NSString *)code {
    NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc] initWithString:code];
    
    [attributedString addAttributes:@{
        NSFontAttributeName: [UIFont fontWithName:@"Menlo" size:14],
        NSForegroundColorAttributeName: [UIColor whiteColor],
        NSBackgroundColorAttributeName: [UIColor colorWithRed:0.2 green:0.2 blue:0.2 alpha:1.0]
    } range:NSMakeRange(0, attributedString.length)];
    
    return attributedString;
}

- (NSAttributedString *)attributedStringForText:(NSString *)text {
    NSMutableAttributedString *attributedString = [[NSMutableAttributedString alloc] initWithString:text];
    
    // 创建段落样式，与 RichMessageCellNode 保持一致
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.lineSpacing = 5;
    paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
    
    // 应用基础样式，与 RichMessageCellNode 保持一致
    [attributedString addAttributes:@{
        NSParagraphStyleAttributeName: paragraphStyle,
        NSFontAttributeName: [UIFont systemFontOfSize:17],
        NSForegroundColorAttributeName: [UIColor blackColor]
    } range:NSMakeRange(0, attributedString.length)];
    
    // 先处理块级样式：标题、分割线、列表
    [self applyHeadingStyle:attributedString];
    [self applyHorizontalRuleStyle:attributedString];
    [self applyListStyle:attributedString];
    
    // 再处理行内样式：粗体、斜体、行内代码
    [self applyBoldStyle:attributedString];
    [self applyItalicStyle:attributedString];
    [self applyInlineCodeStyle:attributedString];
    
    return attributedString;
}

// 标题样式：支持 # 到 ######，示例中主要用到 ###
- (void)applyHeadingStyle:(NSMutableAttributedString *)attributedString {
    NSString *text = attributedString.string;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^\\s*(#{1,6})\\s+(.+)$" options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    
    for (NSInteger i = matches.count - 1; i >= 0; i--) {
        NSTextCheckingResult *match = matches[i];
        NSRange hashesRange = [match rangeAtIndex:1];
        NSRange contentRange = [match rangeAtIndex:2];
        NSInteger level = hashesRange.length; // 1-6
        
        CGFloat size = 22.0; // H1
        if (level == 2) size = 20.0;
        else if (level == 3) size = 18.0;
        else if (level == 4) size = 17.0;
        else if (level == 5) size = 16.0;
        else if (level >= 6) size = 15.0;
        
        NSMutableParagraphStyle *p = [[NSMutableParagraphStyle alloc] init];
        p.lineSpacing = 6;
        p.lineBreakMode = NSLineBreakByWordWrapping;
        p.paragraphSpacingBefore = 6;
        p.paragraphSpacing = 6;
        
        NSAttributedString *replacement = [[NSAttributedString alloc] initWithString:[text substringWithRange:contentRange] attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:size weight:UIFontWeightSemibold],
            NSParagraphStyleAttributeName: p,
            NSForegroundColorAttributeName: [UIColor blackColor]
        }];
        [attributedString replaceCharactersInRange:match.range withAttributedString:replacement];
        text = attributedString.string; // 更新文本以保证后续索引正确
    }
}

// 分割线样式：将独立一行的 --- 渲染为灰色分隔符
- (void)applyHorizontalRuleStyle:(NSMutableAttributedString *)attributedString {
    NSString *text = attributedString.string;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^\\s*-{3,}\\s*$" options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    
    for (NSInteger i = matches.count - 1; i >= 0; i--) {
        NSTextCheckingResult *match = matches[i];
        NSMutableParagraphStyle *p = [[NSMutableParagraphStyle alloc] init];
        p.paragraphSpacingBefore = 4;
        p.paragraphSpacing = 8;
        p.alignment = NSTextAlignmentCenter;
        
        NSString *line = @"────────────"; // 视觉分隔
        NSAttributedString *replacement = [[NSAttributedString alloc] initWithString:line attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:14 weight:UIFontWeightRegular],
            NSForegroundColorAttributeName: [UIColor systemGrayColor],
            NSParagraphStyleAttributeName: p
        }];
        [attributedString replaceCharactersInRange:match.range withAttributedString:replacement];
    }
}

// 列表样式：将行首 - 或 * 转换为 • 并保留内容
- (void)applyListStyle:(NSMutableAttributedString *)attributedString {
    NSString *text = attributedString.string;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^\\s*[-*]\\s+(.+)$" options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    
    for (NSInteger i = matches.count - 1; i >= 0; i--) {
        NSTextCheckingResult *match = matches[i];
        NSRange contentRange = [match rangeAtIndex:1];
        NSString *content = [text substringWithRange:contentRange];
        NSString *bulletLine = [NSString stringWithFormat:@"• %@", content];
        
        NSMutableParagraphStyle *p = [[NSMutableParagraphStyle alloc] init];
        p.lineSpacing = 5;
        p.headIndent = 18; // 悬挂缩进
        p.firstLineHeadIndent = 0;
        
        NSAttributedString *replacement = [[NSAttributedString alloc] initWithString:bulletLine attributes:@{
            NSFontAttributeName: [UIFont systemFontOfSize:17],
            NSParagraphStyleAttributeName: p,
            NSForegroundColorAttributeName: [UIColor blackColor]
        }];
        [attributedString replaceCharactersInRange:match.range withAttributedString:replacement];
        text = attributedString.string;
    }
}
- (void)applyBoldStyle:(NSMutableAttributedString *)attributedString {
    NSString *text = attributedString.string;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\*\\*(.*?)\\*\\*" options:0 error:nil];
    
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    
    // 从后往前替换，避免索引变化
    for (NSInteger i = matches.count - 1; i >= 0; i--) {
        NSTextCheckingResult *match = matches[i];
        NSRange fullRange = match.range;
        NSRange contentRange = [match rangeAtIndex:1];
        
        if (contentRange.location != NSNotFound) {
            NSString *content = [text substringWithRange:contentRange];
            NSAttributedString *replacement = [[NSAttributedString alloc] initWithString:content attributes:@{
                NSFontAttributeName: [UIFont boldSystemFontOfSize:17]
            }];
            
            [attributedString replaceCharactersInRange:fullRange withAttributedString:replacement];
        }
    }
}

- (void)applyItalicStyle:(NSMutableAttributedString *)attributedString {
    NSString *text = attributedString.string;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\*(.*?)\\*" options:0 error:nil];
    
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    
    // 从后往前替换，避免索引变化
    for (NSInteger i = matches.count - 1; i >= 0; i--) {
        NSTextCheckingResult *match = matches[i];
        NSRange fullRange = match.range;
        NSRange contentRange = [match rangeAtIndex:1];
        
        if (contentRange.location != NSNotFound) {
            NSString *content = [text substringWithRange:contentRange];
            NSAttributedString *replacement = [[NSAttributedString alloc] initWithString:content attributes:@{
                NSFontAttributeName: [UIFont italicSystemFontOfSize:17]
            }];
            
            [attributedString replaceCharactersInRange:fullRange withAttributedString:replacement];
        }
    }
}

- (void)applyInlineCodeStyle:(NSMutableAttributedString *)attributedString {
    NSString *text = attributedString.string;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"`(.*?)`" options:0 error:nil];
    
    NSArray<NSTextCheckingResult *> *matches = [regex matchesInString:text options:0 range:NSMakeRange(0, text.length)];
    
    // 从后往前替换，避免索引变化
    for (NSInteger i = matches.count - 1; i >= 0; i--) {
        NSTextCheckingResult *match = matches[i];
        NSRange fullRange = match.range;
        NSRange contentRange = [match rangeAtIndex:1];
        
        if (contentRange.location != NSNotFound) {
            NSString *content = [text substringWithRange:contentRange];
            NSAttributedString *replacement = [[NSAttributedString alloc] initWithString:content attributes:@{
                NSFontAttributeName: [UIFont fontWithName:@"Menlo" size:16],
                NSBackgroundColorAttributeName: [UIColor systemGray6Color]
            }];
            
            [attributedString replaceCharactersInRange:fullRange withAttributedString:replacement];
        }
    }
}

@end
