//
//  MessageContentUtils.h
//  ChatGPT-OC-Clone
//
//  Utility helpers for message content parsing and display normalization.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MessageContentUtils : NSObject

/// Parse attachment URLs from a normalized content block like:
/// [附件链接：\n- http://...\n- https://...\n]
/// Returns an array of NSURL instances. Non-HTTP(S) lines are ignored.
+ (NSArray<NSURL *> *)parseAttachmentURLsFromContent:(NSString *)content;

/// Strip the trailing attachment block for display purpose only, leaving the main text.
/// If no attachment block found, returns the original content trimmed.
+ (NSString *)displayTextByStrippingAttachmentBlock:(NSString *)content;

@end

NS_ASSUME_NONNULL_END


