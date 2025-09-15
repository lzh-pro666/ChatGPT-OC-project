//
//  AISyntaxHighlighter.m
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import "AISyntaxHighlighter.h"
#import "ChatGPT_OC_Clone-Swift.h"

@implementation AICodeTheme

+ (AICodeTheme *)defaultTheme {
    AICodeTheme *t = [AICodeTheme new];
    
    // 使用浅色主题（适合当前UI）
    t.bg = [UIColor colorWithWhite:0.98 alpha:1.0];
    t.border = [UIColor colorWithWhite:0.90 alpha:1.0];
    t.text = [UIColor colorWithWhite:0.15 alpha:1.0];
    t.keyword = [UIColor colorWithRed:0.56 green:0.15 blue:0.75 alpha:1.0];
    t.typeName = [UIColor colorWithRed:0.15 green:0.35 blue:0.75 alpha:1.0];
    t.string = [UIColor colorWithRed:0.80 green:0.20 blue:0.25 alpha:1.0];
    t.number = [UIColor colorWithRed:0.00 green:0.45 blue:0.30 alpha:1.0];
    t.comment = [UIColor colorWithWhite:0.55 alpha:1.0];
    
    return t;
}

@end

@implementation AISyntaxHighlighter

- (instancetype)initWithTheme:(AICodeTheme *)theme {
    if (self = [super init]) {
        _theme = theme;
        _cache = [NSCache new];
        _cache.countLimit = 100; // 限制缓存数量
    }
    return self;
}

- (NSAttributedString *)highlightCode:(NSString *)code language:(NSString *)lang fontSize:(CGFloat)fontSize {
    if (!code || code.length == 0) {
        return [[NSAttributedString alloc] initWithString:@""];
    }
    
    NSString *cacheKey = [NSString stringWithFormat:@"%@:%lu", lang ?: @"plaintext", (unsigned long)code.hash];
    NSAttributedString *cached = [self.cache objectForKey:cacheKey];
    if (cached) {
        NSLog(@"AISyntaxHighlighter: 使用缓存的高亮结果，语言: %@", lang);
        return cached;
    }
    // 使用 Highlightr（Swift 桥）
    NSAttributedString *att = [[CodeHighlighterBridge shared] highlightWithCode:code language:lang fontSize:fontSize];
    if (!att) {
        UIFont *mono = [UIFont monospacedSystemFontOfSize:fontSize weight:UIFontWeightRegular];
        att = [[NSAttributedString alloc] initWithString:code attributes:@{ NSFontAttributeName: mono, NSForegroundColorAttributeName: self.theme.text }];
    }
    [self.cache setObject:att forKey:cacheKey];
    return att;
}

// 语言特定的高亮规则
- (NSArray<NSDictionary *> *)rulesForLanguage:(NSString *)lang {
    UIColor *kw = self.theme.keyword;
    UIColor *str = self.theme.string;
    UIColor *num = self.theme.number;
    UIColor *com = self.theme.comment;
    UIColor *type = self.theme.typeName;
    
    if ([lang isEqualToString:@"swift"]) {
        NSString *kwds = @"\\b(class|struct|enum|protocol|extension|func|let|var|if|else|for|while|repeat|switch|case|default|break|continue|return|import|guard|defer|in|do|try|catch|throw|throws|init|self|super|where|as|is|nil|true|false)\\b";
        return @[
            @{@"p": @"//.*?$", @"c": com, @"o": @(NSRegularExpressionAnchorsMatchLines)},
            @{@"p": @"/\\*[\\s\\S]*?\\*/", @"c": com, @"o": @(0)},
            @{@"p": @"\"(\\\\.|[^\"\\\\])*\"", @"c": str, @"o": @(0)},
            @{@"p": kwds, @"c": kw, @"o": @(0)},
            @{@"p": @"\\b[A-Z][A-Za-z0-9_]*\\b", @"c": type, @"o": @(0)},
            @{@"p": @"\\b\\d+(?:\\.\\d+)?\\b", @"c": num, @"o": @(0)}
        ];
    } else if ([lang isEqualToString:@"objective-c"] || [lang isEqualToString:@"objc"]) {
        NSString *kwds = @"\\b(@interface|@implementation|@end|@property|@synthesize|@dynamic|@protocol|@optional|@required|id|instancetype|void|int|float|double|BOOL|if|else|for|while|switch|case|default|break|continue|return|typedef|struct|enum|sizeof|static|extern|const|volatile|__block)\\b";
        return @[
            @{@"p": @"//.*?$", @"c": com, @"o": @(NSRegularExpressionAnchorsMatchLines)},
            @{@"p": @"/\\*[\\s\\S]*?\\*/", @"c": com, @"o": @(0)},
            @{@"p": @"@\"(\\\\.|[^\"\\\\])*\"", @"c": str, @"o": @(0)},
            @{@"p": kwds, @"c": kw, @"o": @(0)},
            @{@"p": @"\\b[A-Z][A-Za-z0-9_]*\\b", @"c": type, @"o": @(0)},
            @{@"p": @"\\b\\d+(?:\\.\\d+)?\\b", @"c": num, @"o": @(0)}
        ];
    } else if ([lang isEqualToString:@"json"]) {
        return @[
            @{@"p": @"\"(\\\\.|[^\"\\\\])*\"", @"c": str, @"o": @(0)},
            @{@"p": @"\\b\\d+(?:\\.\\d+)?\\b", @"c": num, @"o": @(0)},
            @{@"p": @"\\b(true|false|null)\\b", @"c": kw, @"o": @(0)}
        ];
    } else if ([lang isEqualToString:@"python"]) {
        NSString *kwds = @"\\b(class|def|if|elif|else|for|while|try|except|finally|with|import|from|as|return|yield|break|continue|pass|raise|assert|lambda|None|True|False)\\b";
        return @[
            @{@"p": @"#.*?$", @"c": com, @"o": @(NSRegularExpressionAnchorsMatchLines)},
            @{@"p": @"\"\"\"[\\s\\S]*?\"\"\"", @"c": com, @"o": @(0)},
            @{@"p": @"\"(\\\\.|[^\"\\\\])*\"", @"c": str, @"o": @(0)},
            @{@"p": @"'(\\\\.|[^'\\\\])*'", @"c": str, @"o": @(0)},
            @{@"p": kwds, @"c": kw, @"o": @(0)},
            @{@"p": @"\\b\\d+(?:\\.\\d+)?\\b", @"c": num, @"o": @(0)}
        ];
    }
    
    // 默认规则：仅注释
    return @[@{@"p": @"//.*?$", @"c": com, @"o": @(NSRegularExpressionAnchorsMatchLines)}];
}

@end

