//
//  AICodeBlockNode.m
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import "AICodeBlockNode.h"
#import "AISyntaxHighlighter.h"
#import <AsyncDisplayKit/ASButtonNode.h>

@interface AICodeBlockNode ()
@property (nonatomic, copy) NSString *code;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, assign) BOOL isFromUser;
@property (nonatomic, strong) AISyntaxHighlighter *highlighter;
@property (nonatomic, strong) ASDisplayNode *header;
@property (nonatomic, strong) ASTextNode *langNode;
@property (nonatomic, strong) ASButtonNode *duplicateButton;
@property (nonatomic, strong) ASTextNode *codeNode;
@end

@implementation AICodeBlockNode

- (instancetype)initWithCode:(NSString *)code 
                    language:(NSString *)lang 
                  isFromUser:(BOOL)isFromUser {
    if (self = [super init]) {
        _code = [code copy];
        _language = lang.length ? lang : @"plaintext";
        _isFromUser = isFromUser;
        _highlighter = [[AISyntaxHighlighter alloc] initWithTheme:[AICodeTheme defaultTheme]];
        
        self.automaticallyManagesSubnodes = YES;
        self.backgroundColor = [UIColor colorWithWhite:0.98 alpha:1.0];
        self.cornerRadius = 12.0;
        self.clipsToBounds = YES;
        self.borderColor = [UIColor colorWithWhite:0.90 alpha:1.0].CGColor;
        self.borderWidth = 0.5;
        
        // 关键：让代码块在父容器中拉伸占满宽度
        self.style.flexGrow = 1;
        self.style.flexShrink = 1;
        
        // 语言标签
        _langNode = [ASTextNode new];
        _langNode.attributedText = [[NSAttributedString alloc] initWithString:_language.uppercaseString
            attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold],
                NSForegroundColorAttributeName: [UIColor secondaryLabelColor]
            }];
        
        // 复制按钮
        _duplicateButton = [ASButtonNode new];
        [_duplicateButton setTitle:@"复制" withFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] withColor:[UIColor labelColor] forState:UIControlStateNormal];
        [_duplicateButton addTarget:self action:@selector(onCopy) forControlEvents:ASControlNodeEventTouchUpInside];
        
        // 头部容器
        _header = [ASDisplayNode new];
        _header.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:0.7];
        
        // 代码文本节点
        _codeNode = [ASTextNode new];
        _codeNode.maximumNumberOfLines = 0;
        _codeNode.truncationMode = NSLineBreakByClipping;
        
        // 应用语法高亮
        NSAttributedString *highlightedCode = [_highlighter highlightCode:_code language:_language fontSize:14];
        _codeNode.attributedText = highlightedCode;
        
        NSLog(@"AICodeBlockNode: 创建代码块，语言: %@，内容长度: %lu", _language, (unsigned long)_code.length);
    }
    return self;
}

- (void)onCopy {
    if (_code.length) {
        [UIPasteboard generalPasteboard].string = _code;
        NSLog(@"AICodeBlockNode: 代码已复制到剪贴板");
        
        // 显示复制成功反馈
        [_duplicateButton setTitle:@"已复制" withFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] withColor:[UIColor systemGreenColor] forState:UIControlStateNormal];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self->_duplicateButton setTitle:@"复制" withFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] withColor:[UIColor labelColor] forState:UIControlStateNormal];
        });
    }
}

- (ASLayoutSpec *)layoutSpecThatFits:(ASSizeRange)constrainedSize {
    // 头部行：语言标签 + 复制按钮
    ASStackLayoutSpec *headerRow = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionHorizontal
                                                                           spacing:8
                                                                    justifyContent:ASStackLayoutJustifyContentSpaceBetween
                                                                        alignItems:ASStackLayoutAlignItemsCenter
                                                                          children:@[_langNode, _duplicateButton]];
    headerRow.style.height = ASDimensionMake(32);
    
    // 头部容器
    ASInsetLayoutSpec *headerInset = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(4, 12, 4, 12) child:headerRow];
    
    // 代码内容容器
    ASInsetLayoutSpec *codeInset = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(8, 12, 8, 12) child:_codeNode];
    
    // 垂直堆叠：头部 + 代码
    ASStackLayoutSpec *verticalStack = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionVertical
                                                                               spacing:0
                                                                        justifyContent:ASStackLayoutJustifyContentStart
                                                                            alignItems:ASStackLayoutAlignItemsStretch
                                                                              children:@[headerInset, codeInset]];
    
    return verticalStack;
}

@end
