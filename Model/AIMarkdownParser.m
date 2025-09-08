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
            return [NSString stringWithFormat:@"Paragraph: %@", self.text];
        case AIMarkdownBlockTypeHeading:
            return [NSString stringWithFormat:@"Heading H%ld: %@", (long)self.headingLevel, self.text];
        case AIMarkdownBlockTypeCodeBlock:
            return [NSString stringWithFormat:@"CodeBlock [%@]: %@", self.language, self.code];
        case AIMarkdownBlockTypeListItem:
            return [NSString stringWithFormat:@"ListItem: %@", self.text];
        case AIMarkdownBlockTypeQuote:
            return [NSString stringWithFormat:@"Quote: %@", self.text];
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
    
    // 预编译正则表达式
    static NSRegularExpression *fence = nil;
    static NSRegularExpression *heading = nil;
    static NSRegularExpression *numbered = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fence = [NSRegularExpression regularExpressionWithPattern:@"^[\\t ]*(?:```|~~~)\\s*([A-Za-z0-9+-]*)\\s*$" options:0 error:nil];
        heading = [NSRegularExpression regularExpressionWithPattern:@"^(#{1,6})\\s+(.*)$" options:0 error:nil];
        numbered = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\d+[\\.|)]\\s+" options:0 error:nil];
    });
    
    void (^flushPara)(void) = ^{
        if (para.length > 0) {
            AIMarkdownBlock *b = [AIMarkdownBlock new];
            b.type = AIMarkdownBlockTypeParagraph;
            b.text = [para copy];
            [blocks addObject:b];
            [para setString:@""];
        }
    };
    
    // 轻量启发式：若围栏块仅包裹 Markdown 结构（如标题），则降级为非代码块
    BOOL (^isLikelyNonCodeBlock)(NSString *content, NSString *language) = ^BOOL(NSString *content, NSString *language) {
        // 若语言显式指定且非plaintext，认为是代码
        if (language.length > 0 && ![[language lowercaseString] isEqualToString:@"plaintext"]) { return NO; }
        NSString *trim = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (trim.length == 0) { return YES; }
        __block NSInteger nonEmpty = 0;
        __block NSInteger headingCount = 0;
        __block BOOL hasCodeToken = NO;
        NSCharacterSet *codeChars = [NSCharacterSet characterSetWithCharactersInString:@"=;{}()<>\"\'\t"]; // 常见代码符号
        [content enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
            NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (t.length == 0) { return; }
            nonEmpty++;
            // 标题检测
            NSTextCheckingResult *mh = [heading firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
            if (mh) { headingCount++; }
            // 列表/引用（仍视为非代码结构）
            BOOL isBullet = ([t hasPrefix:@"- "] || [t hasPrefix:@"* "] || [t hasPrefix:@"+ "]);
            BOOL isQuote = [t hasPrefix:@">"];
            // 代码气息：包含典型标记或关键字
            if ([t rangeOfCharacterFromSet:codeChars].location != NSNotFound ||
                [t containsString:@"let "] || [t containsString:@"var "] ||
                [t containsString:@"func "] || [t containsString:@"class "] ||
                [t containsString:@"struct "] || [t containsString:@"print("] ||
                [t containsString:@"return "] || [t containsString:@"if "] ||
                [t containsString:@"for "] || [t containsString:@"while "]) {
                hasCodeToken = YES; *stop = YES; return;
            }
            // 纯结构性行不增加代码倾向
            (void)isBullet; (void)isQuote;
        }];
        if (hasCodeToken) { return NO; }
        // 单行且为标题；或所有非空行均为标题 -> 非代码
        if (nonEmpty == 1 && headingCount == 1) { return YES; }
        if (nonEmpty > 0 && headingCount == nonEmpty) { return YES; }
        return NO;
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
                NSString *codeContent = [buf copy] ?: @"";
                if (isLikelyNonCodeBlock(codeContent, lang ?: @"")) {
                    // 将围栏内的内容降级解析为普通块（标题或段落），避免误当作代码
                    __block NSInteger emitted = 0;
                    [codeContent enumerateLinesUsingBlock:^(NSString * _Nonnull l, BOOL * _Nonnull stop) {
                        NSString *t = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                        if (t.length == 0) { return; }
                        NSTextCheckingResult *h = [heading firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
                        if (h) {
                            NSInteger level = [[t substringWithRange:[h rangeAtIndex:1]] length];
                            NSString *title = [t substringWithRange:[h rangeAtIndex:2]];
                            AIMarkdownBlock *hb = [AIMarkdownBlock new];
                            hb.type = AIMarkdownBlockTypeHeading;
                            hb.headingLevel = level;
                            hb.text = title;
                            [blocks addObject:hb];
                            emitted++;
                        } else {
                            AIMarkdownBlock *pb = [AIMarkdownBlock new];
                            pb.type = AIMarkdownBlockTypeParagraph;
                            pb.text = t;
                            [blocks addObject:pb];
                            emitted++;
                        }
                    }];
                    NSLog(@"AIMarkdownParser: 降级围栏内容为 %ld 个非代码块", (long)emitted);
                } else {
                AIMarkdownBlock *b = [AIMarkdownBlock new];
                b.type = AIMarkdownBlockTypeCodeBlock;
                b.language = lang.length ? lang : @"plaintext";
                    b.code = codeContent;
                [blocks addObject:b];
                NSLog(@"AIMarkdownParser: 结束代码块，语言: %@，内容长度: %lu", b.language, (unsigned long)b.code.length);
                }
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
        
        // 列表与引用：将每一行作为单独块，避免合并到段落中
        NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        BOOL isBullet = ([trim hasPrefix:@"- "] || [trim hasPrefix:@"* "] || [trim hasPrefix:@"+ "]);
        BOOL isNumbered = ([numbered firstMatchInString:trim options:0 range:NSMakeRange(0, trim.length)] != nil);
        BOOL isQuote = [trim hasPrefix:@">"];
        if (isBullet || isNumbered || isQuote) {
            flushPara();
            AIMarkdownBlock *b = [AIMarkdownBlock new];
            b.type = isQuote ? AIMarkdownBlockTypeQuote : AIMarkdownBlockTypeListItem;
            b.text = line;
            [blocks addObject:b];
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
        NSString *codeContent = [buf copy];
        if (isLikelyNonCodeBlock(codeContent, lang ?: @"")) {
            // 收尾时同样进行降级处理
            __block NSInteger emitted = 0;
            [codeContent enumerateLinesUsingBlock:^(NSString * _Nonnull l, BOOL * _Nonnull stop) {
                NSString *t = [l stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (t.length == 0) { return; }
                NSTextCheckingResult *h = [heading firstMatchInString:t options:0 range:NSMakeRange(0, t.length)];
                if (h) {
                    NSInteger level = [[t substringWithRange:[h rangeAtIndex:1]] length];
                    NSString *title = [t substringWithRange:[h rangeAtIndex:2]];
                    AIMarkdownBlock *hb = [AIMarkdownBlock new];
                    hb.type = AIMarkdownBlockTypeHeading;
                    hb.headingLevel = level;
                    hb.text = title;
                    [blocks addObject:hb];
                    emitted++;
                } else {
                    AIMarkdownBlock *pb = [AIMarkdownBlock new];
                    pb.type = AIMarkdownBlockTypeParagraph;
                    pb.text = t;
                    [blocks addObject:pb];
                    emitted++;
                }
            }];
            NSLog(@"AIMarkdownParser: 结尾围栏降级为 %ld 个非代码块", (long)emitted);
        } else {
        AIMarkdownBlock *b = [AIMarkdownBlock new];
        b.type = AIMarkdownBlockTypeCodeBlock;
        b.language = lang ?: @"plaintext";
            b.code = codeContent;
        [blocks addObject:b];
        NSLog(@"AIMarkdownParser: 结尾代码块，语言: %@，内容长度: %lu", b.language, (unsigned long)b.code.length);
        }
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

