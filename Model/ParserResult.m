//
//  ParserResult.m
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant on 2024/08/13.
//

#import "ParserResult.h"

@implementation ParserResult

- (instancetype)initWithAttributedString:(NSAttributedString *)attributedString
                              isCodeBlock:(BOOL)isCodeBlock
                        codeBlockLanguage:(nullable NSString *)codeBlockLanguage {
    self = [super init];
    if (self) {
        _attributedString = attributedString;
        _isCodeBlock = isCodeBlock;
        _codeBlockLanguage = [codeBlockLanguage copy];
    }
    return self;
}

- (instancetype)init {
    return [self initWithAttributedString:[[NSAttributedString alloc] init]
                               isCodeBlock:NO
                         codeBlockLanguage:nil];
}

@end
