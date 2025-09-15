//
//  AIMarkdownParser.h
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, AIMarkdownBlockType) {
    AIMarkdownBlockTypeParagraph,
    AIMarkdownBlockTypeHeading,     // level: 1..6
    AIMarkdownBlockTypeCodeBlock,   // language + code
    AIMarkdownBlockTypeListItem,
    AIMarkdownBlockTypeQuote,
    AIMarkdownBlockTypeHorizontalRule
};

@interface AIMarkdownBlock : NSObject
@property (nonatomic) AIMarkdownBlockType type;
@property (nonatomic) NSInteger headingLevel;
@property (nonatomic, copy) NSString *text;       // 段落/标题文本
@property (nonatomic, copy) NSString *code;       // 代码文本
@property (nonatomic, copy) NSString *language;   // 代码语言
@end

@interface AIMarkdownParser : NSObject
- (NSArray<AIMarkdownBlock *> *)parse:(NSString *)raw;
@end

NS_ASSUME_NONNULL_END

