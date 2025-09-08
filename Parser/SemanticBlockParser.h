#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface SemanticBlockParser : NSObject

// Reset internal state (pending buffer, indices, flags)
- (void)reset;

// Consume the latest full text (not delta). The parser computes delta internally
// and returns newly completed semantic blocks since last call.
// When isDone is YES, remaining pending buffer will be flushed as the final block.
- (NSArray<NSString *> *)consumeFullText:(NSString *)fullText isDone:(BOOL)isDone;

@end

NS_ASSUME_NONNULL_END 