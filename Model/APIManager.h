#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^StreamingResponseBlock)(NSString * _Nullable partialResponse, BOOL isDone, NSError * _Nullable error);

// 遵循 NSURLSessionDataDelegate 协议
@interface APIManager : NSObject <NSURLSessionDataDelegate>

// 默认的系统 Prompt
@property (nonatomic, copy) NSString *defaultSystemPrompt;

@property (nonatomic, copy) NSString *currentModelName;

// 流式请求 ChatGPT API
- (NSURLSessionDataTask *)streamingChatCompletionWithMessages:(NSArray *)messages 
                                               streamCallback:(StreamingResponseBlock)callback;

// 设置 API Key
- (void)setApiKey:(NSString *)apiKey;

// 用于取消任务
- (void)cancelStreamingTask:(NSURLSessionDataTask *)task;

+ (instancetype)sharedManager;
@end

NS_ASSUME_NONNULL_END 
