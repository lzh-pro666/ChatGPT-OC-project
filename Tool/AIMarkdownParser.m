//
//  AIMarkdownParser.m
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import "AIMarkdownParser.h"
#import "ChatGPT_OC_Clone-Swift.h"

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
        case AIMarkdownBlockTypeHorizontalRule:
            return @"HorizontalRule";
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
    
    // 优先使用 Down(cmark) 解析（通过 Swift 桥），失败时回退到旧实现
    @try {
        NSArray<NSDictionary *> *downBlocks = [[MarkdownParserBridge shared] parseToBlocks:raw];
        if ([downBlocks isKindOfClass:[NSArray class]] && downBlocks.count > 0) {
            NSMutableArray<AIMarkdownBlock *> *out = [NSMutableArray arrayWithCapacity:downBlocks.count];
            for (NSDictionary *obj in downBlocks) {
                if (![obj isKindOfClass:[NSDictionary class]]) { continue; }
                NSString *type = obj[@"type"];
                AIMarkdownBlock *b = [AIMarkdownBlock new];
                if ([type isEqualToString:@"heading"]) {
                    b.type = AIMarkdownBlockTypeHeading;
                    b.headingLevel = [obj[@"level"] integerValue];
                    b.text = obj[@"text"] ?: @"";
                } else if ([type isEqualToString:@"paragraph"]) {
                    b.type = AIMarkdownBlockTypeParagraph;
                    b.text = obj[@"text"] ?: @"";
                } else if ([type isEqualToString:@"code"]) {
                    b.type = AIMarkdownBlockTypeCodeBlock;
                    b.language = obj[@"language"] ?: @"";
                    b.code = obj[@"code"] ?: @"";
                } else if ([type isEqualToString:@"hr"]) {
                    b.type = AIMarkdownBlockTypeHorizontalRule;
                } else if ([type isEqualToString:@"quote"]) {
                    b.type = AIMarkdownBlockTypeQuote;
                    b.text = obj[@"text"] ?: @"";
                } else if ([type isEqualToString:@"listItem"]) {
                    b.type = AIMarkdownBlockTypeListItem;
                    b.text = obj[@"text"] ?: @"";
                } else {
                    b.type = AIMarkdownBlockTypeParagraph;
                    b.text = obj[@"text"] ?: @"";
                }
                [out addObject:b];
            }
            if (out.count > 0) {
                return out; }
        }
    } @catch (__unused NSException *ex) {
        // fall back
    }
    
    NSMutableArray *blocks = [NSMutableArray array];
    // 相邻去重辅助：仅在相邻块完全相同时跳过追加
    void (^appendBlock)(AIMarkdownBlock *) = ^(AIMarkdownBlock *b) {
        AIMarkdownBlock *prev = [blocks lastObject];
        if (prev && prev.type == b.type) {
            switch (b.type) {
                case AIMarkdownBlockTypeParagraph: {
                    if ((prev.text ?: @"").length > 0 && [prev.text isEqualToString:(b.text ?: @"")]) { return; }
                    break;
                }
                case AIMarkdownBlockTypeHeading: {
                    if (prev.headingLevel == b.headingLevel && [prev.text ?: @"" isEqualToString:b.text ?: @""]) { return; }
                    break;
                }
                case AIMarkdownBlockTypeCodeBlock: {
                    if ([prev.language ?: @"" isEqualToString:b.language ?: @""] && [prev.code ?: @"" isEqualToString:b.code ?: @""]) { return; }
                    break;
                }
                case AIMarkdownBlockTypeListItem: {
                    if ([prev.text ?: @"" isEqualToString:b.text ?: @""]) { return; }
                    break;
                }
                case AIMarkdownBlockTypeQuote: {
                    if ([prev.text ?: @"" isEqualToString:b.text ?: @""]) { return; }
                    break;
                }
                case AIMarkdownBlockTypeHorizontalRule: {
                    // 连续多条 HR 仅保留一条
                    return; // 若上一个也是 HR，则直接跳过
                }
                default: break;
            }
        }
        [blocks addObject:b];
    };
    NSArray<NSString *> *lines = [raw componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
    BOOL inFence = NO;
    NSString *lang = nil;
    NSMutableString *buf = nil;
    
    NSMutableString *para = [NSMutableString string];

    // 规范化：若标题以中文数字序号开头且缺少“、”，自动补上（例："四控制流" -> "四、控制流"）
    NSString* (^normalizeHeadingTitle)(NSString *) = ^NSString* (NSString *title) {
        if (title.length == 0) return title;
        // 已有分隔符则不处理
        if ([title hasPrefix:@"一、"] || [title hasPrefix:@"二、"] || [title hasPrefix:@"三、"] ||
            [title hasPrefix:@"四、"] || [title hasPrefix:@"五、"] || [title hasPrefix:@"六、"] ||
            [title hasPrefix:@"七、"] || [title hasPrefix:@"八、"] || [title hasPrefix:@"九、"] ||
            [title hasPrefix:@"十、"]) {
            return title;
        }
        // 若是中文序号后面直接接文字（非空白/标点），插入 “、”
        static NSRegularExpression *cnNumNoDelim = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            cnNumNoDelim = [NSRegularExpression regularExpressionWithPattern:@"^(一|二|三|四|五|六|七|八|九|十)(?=\\S)" options:0 error:nil];
        });
        NSTextCheckingResult *m = [cnNumNoDelim firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];
        if (m) {
            // 仅当第二个字符不是常见分隔符时插入
            unichar second = (title.length >= 2) ? [title characterAtIndex:1] : 0;
            if (second && second != L'、' && second != L'.' && second != L'．' && second != L'，' && second != L',' && second != L' ' ) {
                NSString *prefix = [title substringToIndex:1];
                NSString *rest = [title substringFromIndex:1];
                return [NSString stringWithFormat:@"%@、%@", prefix, rest];
            }
        }
        return title;
    };

    // 移除前导空白行（仅空白/换行的整行），用于代码块防止多余空白间隔
    NSString* (^removeLeadingBlankLines)(NSString *) = ^NSString* (NSString *s) {
        if (s.length == 0) return s;
        NSArray<NSString *> *lines = [s componentsSeparatedByString:@"\n"];
        NSInteger start = 0;
        NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        while (start < (NSInteger)lines.count) {
            NSString *ln = lines[(NSUInteger)start];
            if ([[ln stringByTrimmingCharactersInSet:ws] length] == 0) {
                start++;
            } else {
                break;
            }
        }
        if (start <= 0) return s;
        NSArray<NSString *> *remain = [lines subarrayWithRange:NSMakeRange((NSUInteger)start, lines.count - (NSUInteger)start)];
        return [remain componentsJoinedByString:@"\n"];
    };
    // 移除段落末尾的空白行，避免代码块前出现空白间隔
    NSString* (^trimTrailingBlankLines)(NSString *) = ^NSString* (NSString *s) {
        if (s.length == 0) return s;
        NSMutableArray<NSString *> *lines = [[s componentsSeparatedByString:@"\n"] mutableCopy];
        NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        while (lines.count > 0) {
            NSString *last = [lines lastObject];
            if ([[last stringByTrimmingCharactersInSet:ws] length] == 0) {
                [lines removeLastObject];
            } else {
                break;
            }
        }
        return [lines componentsJoinedByString:@"\n"];
    };
    
    // 预编译正则表达式
    static NSRegularExpression *fence = nil;
    static NSRegularExpression *heading = nil;
    static NSRegularExpression *numbered = nil;
    static NSRegularExpression *inlineFenceAfterText = nil; // 处理同一行末尾的 ```lang
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        fence = [NSRegularExpression regularExpressionWithPattern:@"^[\\t ]*(?:```|~~~)\\s*([A-Za-z0-9+-]*)\\s*$" options:0 error:nil];
        heading = [NSRegularExpression regularExpressionWithPattern:@"^(#{1,6})\\s+(.*)$" options:0 error:nil];
        numbered = [NSRegularExpression regularExpressionWithPattern:@"^\\s*\\d+[\\.|)]\\s+" options:0 error:nil];
        inlineFenceAfterText = [NSRegularExpression regularExpressionWithPattern:@"^(.*?)(?:```|~~~)\\s*([A-Za-z0-9+-]*)\\s*$" options:0 error:nil];
    });
    
    BOOL (^isCodeLike)(NSString *) = ^BOOL(NSString *text) {
        if (text.length == 0) return NO;
        NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
        NSInteger codeSignals = 0;
        NSInteger nonEmpty = 0;
        for (NSString *ln in lines) {
            NSString *t = [ln stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (t.length == 0) continue; nonEmpty++;
            if ([t containsString:@"{"] || [t containsString:@"}"] ||
                [t hasPrefix:@"case "] || [t hasPrefix:@"default:"] ||
                [t hasPrefix:@"switch "] || [t hasPrefix:@"for "] || [t hasPrefix:@"while "] ||
                [t hasPrefix:@"if "] || [t hasPrefix:@"else"] ||
                [t containsString:@"let "] || [t containsString:@"var "] ||
                [t containsString:@"print("] ) {
                codeSignals++;
            }
        }
        return (nonEmpty >= 2 && codeSignals >= 2);
    };
    void (^flushPara)(void) = ^{
        if (para.length > 0) {
            NSString *paragraphText = [para copy];
            paragraphText = trimTrailingBlankLines(paragraphText);
            if (isCodeLike(paragraphText)) {
                AIMarkdownBlock *cb = [AIMarkdownBlock new];
                cb.type = AIMarkdownBlockTypeCodeBlock;
                cb.language = @"plaintext";
                cb.code = removeLeadingBlankLines(paragraphText);
                appendBlock(cb);
            } else {
                AIMarkdownBlock *b = [AIMarkdownBlock new];
                b.type = AIMarkdownBlockTypeParagraph;
                b.text = paragraphText;
                appendBlock(b);
            }
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
                // NSLog(@"AIMarkdownParser: 进入代码块，语言: %@", lang);
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
                            title = normalizeHeadingTitle(title);
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
                    // NSLog(@"AIMarkdownParser: 降级围栏内容为 %ld 个非代码块", (long)emitted);
                } else {
                AIMarkdownBlock *b = [AIMarkdownBlock new];
                b.type = AIMarkdownBlockTypeCodeBlock;
                b.language = lang.length ? lang : @"plaintext";
                    b.code = codeContent;
                appendBlock(b);
                // NSLog(@"AIMarkdownParser: 结束代码块，语言: %@，内容长度: %lu", b.language, (unsigned long)b.code.length);
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
        
        // 处理标题：允许省略空格形式，如 ###3. 函数 / ###3.函数
        NSTextCheckingResult *h = [heading firstMatchInString:line options:0 range:NSMakeRange(0, line.length)];
        if (h) {
            flushPara();
            NSInteger level = [line substringWithRange:[h rangeAtIndex:1]].length;
            NSString *title = [line substringWithRange:[h rangeAtIndex:2]];
            title = normalizeHeadingTitle(title);
            // 修复：若标题行末尾携带围栏 ```lang，则分割为标题 + 开启围栏
            NSTextCheckingResult *ih = [inlineFenceAfterText firstMatchInString:title options:0 range:NSMakeRange(0, title.length)];
            if (ih) {
                NSString *before = [title substringWithRange:[ih rangeAtIndex:1]] ?: @"";
                NSString *ilang = ([ih rangeAtIndex:2].length > 0) ? [[title substringWithRange:[ih rangeAtIndex:2]] lowercaseString] : @"";
                title = [before stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                // 先落地标题块
                AIMarkdownBlock *hb = [AIMarkdownBlock new];
                hb.type = AIMarkdownBlockTypeHeading;
                hb.headingLevel = level;
                hb.text = title;
                appendBlock(hb);
                // NSLog(@"AIMarkdownParser: 创建标题 H%ld: %@", (long)level, title);
                // 再开启围栏（下一行开始采集代码）
                inFence = YES;
                buf = [NSMutableString string];
                lang = ilang ?: @"";
                continue;
            }
            AIMarkdownBlock *b = [AIMarkdownBlock new];
            b.type = AIMarkdownBlockTypeHeading;
            b.headingLevel = level;
            b.text = title;
            appendBlock(b);
            // NSLog(@"AIMarkdownParser: 创建标题 H%ld: %@", (long)level, title);
            continue;
        }
        
        // 列表与引用：将每一行作为单独块，避免合并到段落中
        NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        // 水平分隔线：--- 或 *** 或 ___ （三个及以上）
        if ([trim rangeOfString:@"^-{3,}$" options:NSRegularExpressionSearch].location != NSNotFound ||
            [trim rangeOfString:@"^\*{3,}$" options:NSRegularExpressionSearch].location != NSNotFound ||
            [trim rangeOfString:@"^_{3,}$" options:NSRegularExpressionSearch].location != NSNotFound) {
            flushPara();
            AIMarkdownBlock *rule = [AIMarkdownBlock new];
            rule.type = AIMarkdownBlockTypeHorizontalRule;
            appendBlock(rule);
            continue;
        }
        BOOL isBullet = ([trim hasPrefix:@"- "] || [trim hasPrefix:@"* "] || [trim hasPrefix:@"+ "]);
        BOOL isNumbered = ([numbered firstMatchInString:trim options:0 range:NSMakeRange(0, trim.length)] != nil);
        BOOL isQuote = [trim hasPrefix:@">"];
        if (isBullet || isNumbered || isQuote) {
            flushPara();
            AIMarkdownBlock *b = [AIMarkdownBlock new];
            b.type = isQuote ? AIMarkdownBlockTypeQuote : AIMarkdownBlockTypeListItem;
            b.text = line;
            appendBlock(b);
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
                    title = normalizeHeadingTitle(title);
                    AIMarkdownBlock *hb = [AIMarkdownBlock new];
                    hb.type = AIMarkdownBlockTypeHeading;
                    hb.headingLevel = level;
                    hb.text = title;
                    appendBlock(hb);
                    emitted++;
                } else {
                    AIMarkdownBlock *pb = [AIMarkdownBlock new];
                    pb.type = AIMarkdownBlockTypeParagraph;
                    pb.text = t;
                    appendBlock(pb);
                    emitted++;
                }
            }];
            // NSLog(@"AIMarkdownParser: 结尾围栏降级为 %ld 个非代码块", (long)emitted);
        } else {
        AIMarkdownBlock *b = [AIMarkdownBlock new];
        b.type = AIMarkdownBlockTypeCodeBlock;
        b.language = lang ?: @"plaintext";
            b.code = codeContent;
        appendBlock(b);
        // NSLog(@"AIMarkdownParser: 结尾代码块，语言: %@，内容长度: %lu", b.language, (unsigned long)b.code.length);
        }
    } else {
        flushPara();
    }
    
    // NSLog(@"AIMarkdownParser: 解析完成，共 %lu 个块", (unsigned long)blocks.count);
    // for (NSInteger i = 0; i < blocks.count; i++) {
    //     NSLog(@"AIMarkdownParser: 块 %ld: %@", (long)i, blocks[i]);
    // }
    
    return blocks;
}

@end

