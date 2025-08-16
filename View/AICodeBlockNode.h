//
//  AICodeBlockNode.h
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import <AsyncDisplayKit/AsyncDisplayKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AICodeBlockNode : ASDisplayNode

- (instancetype)initWithCode:(NSString *)code 
                    language:(NSString *)lang 
                  isFromUser:(BOOL)isFromUser;

@end

NS_ASSUME_NONNULL_END

