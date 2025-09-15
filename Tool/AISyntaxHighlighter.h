//
//  AISyntaxHighlighter.h
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AICodeTheme : NSObject
@property (nonatomic, strong) UIColor *bg;        // 代码块背景
@property (nonatomic, strong) UIColor *border;
@property (nonatomic, strong) UIColor *text;
@property (nonatomic, strong) UIColor *keyword;
@property (nonatomic, strong) UIColor *typeName;
@property (nonatomic, strong) UIColor *string;
@property (nonatomic, strong) UIColor *number;
@property (nonatomic, strong) UIColor *comment;
+ (AICodeTheme *)defaultTheme;
@end

@interface AISyntaxHighlighter : NSObject
@property (nonatomic, strong) AICodeTheme *theme;
@property (nonatomic, strong) NSCache<NSString *, NSAttributedString *> *cache; // key: lang+hash

- (instancetype)initWithTheme:(AICodeTheme *)theme;
- (NSAttributedString *)highlightCode:(NSString *)code language:(NSString *)lang fontSize:(CGFloat)fontSize;
@end

NS_ASSUME_NONNULL_END
