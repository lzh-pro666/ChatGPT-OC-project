//
//  AIMarkdownParser.m
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import "AIMarkdownParser.h"

@implementation AIMarkdownBlock

- (NSString *)description {
    switch (self.type) {
        case AIMarkdownBlockTypeParagraph:
            return [NSString stringWithFormat:@"Paragraph: %@", [self.text substringToIndex:MIN(50, self.text.length)]];
        case AIMarkdownBlockTypeHeading:
            return [NSString stringWithFormat:@"Heading H%ld: %@", (long)self.headingLevel, self.text];
        case AIMarkdownBlockTypeCodeBlock:
            return [NSString stringWithFormat:@"CodeBlock [%@]: %@", self.language, [self.code substringToIndex:MIN(50, self.code.length)]];
        case AIMarkdownBlockTypeListItem:
            return [NSString stringWithFormat:@"ListItem: %@", [self.text substringToIndex:MIN(50, self.text.length)]];
        case AIMarkdownBlockTypeQuote:
            return [NSString stringWithFormat:@"Quote: %@", [self.text substringToIndex:MIN(50, self.text.length)]];
        default:
            return @"Unknown";
    }
}

@end

@implementation AIMarkdownParser

- (NSArray<AIMarkdownBlock *> *)parse:(NSString *)raw {
    if (!raw || raw.length == 0) {
        return @[];
    }
    
    NSMutableArray *blocks = [NSMutableArray array];
    NSArray<NSString *> *lines = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    BOOL inFence = NO;
    NSString *lang = nil;
    NSMutableString *buf = nil;
    
    NSMutableString *para = [NSMutableString string];
    
    // 代码块围栏正则表达式（允许前导空格 / 制表符，兼容流式增量中缩进的围栏）
    NSRegularExpression *fence = [NSRegularExpression regularExpressionWithPattern:@"^[\\t ]*```\\s*([A-Za-z0-9+-]*)\\s*$" options:0 error:nil];
    // 标题正则表达式
    NSRegularExpression *heading = [NSRegularExpression regularExpressionWithPattern:@"^(#{1,6})\\s+(.*)$" options:0 error:nil];
    
    void (^flushPara)(void) = ^{
        if (para.length > 0) {
            AIMarkdownBlock *b = [AIMarkdownBlock new];
            b.type = AIMarkdownBlockTypeParagraph;
            b.text = [para copy];
            [blocks addObject:b];
            [para setString:@""];
        }
    };
    
    for (NSString *line in lines) {
        NSTextCheckingResult *m = [fence firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (m) {
            if (!inFence) {
                // 进入代码块
                flushPara();
                inFence = YES;
                buf = [NSMutableString string];
                NSRange langRange = [m rangeAtIndex:1];
                lang = (langRange.length > 0) ? [[line substringWithRange:langRange] lowercaseString] : @"";
                NSLog(@"AIMarkdownParser: 进入代码块，语言: %@", lang);
            } else {
                // 结束代码块
                AIMarkdownBlock *b = [AIMarkdownBlock new];
                b.type = AIMarkdownBlockTypeCodeBlock;
                b.language = lang.length ? lang : @"plaintext";
                b.code = [buf copy];
                [blocks addObject:b];
                NSLog(@"AIMarkdownParser: 结束代码块，语言: %@，内容长度: %lu", b.language, (unsigned long)b.code.length);
                inFence = NO;
                lang = nil;
                buf = nil;
            }
            continue;
        }
        
        if (inFence) {
            [buf appendString:line];
            [buf appendString:@"\n"];
            continue;
        }
        
        NSTextCheckingResult *h = [heading firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (h) {
            flushPara();
            NSInteger level = [line substringWithRange:[h rangeAtIndex:1]].length;
            NSString *title = [line substringWithRange:[h rangeAtIndex:2]];
            AIMarkdownBlock *b = [AIMarkdownBlock new];
            b.type = AIMarkdownBlockTypeHeading;
            b.headingLevel = level;
            b.text = title;
            [blocks addObject:b];
            NSLog(@"AIMarkdownParser: 创建标题 H%ld: %@", (long)level, title);
            continue;
        }
        
        if (line.length == 0) {
            flushPara();
        } else {
            if (para.length) [para appendString:@"\n"];
            [para appendString:line];
        }
    }
    
    // 结尾处理
    if (inFence && buf.length) {
        AIMarkdownBlock *b = [AIMarkdownBlock new];
        b.type = AIMarkdownBlockTypeCodeBlock;
        b.language = lang ?: @"plaintext";
        b.code = [buf copy];
        [blocks addObject:b];
        NSLog(@"AIMarkdownParser: 结尾代码块，语言: %@，内容长度: %lu", b.language, (unsigned long)b.code.length);
    } else {
        flushPara();
    }
    
    NSLog(@"AIMarkdownParser: 解析完成，共 %lu 个块", (unsigned long)blocks.count);
    for (NSInteger i = 0; i < blocks.count; i++) {
        NSLog(@"AIMarkdownParser: 块 %ld: %@", (long)i, blocks[i]);
    }
    
    return blocks;
}

@end

