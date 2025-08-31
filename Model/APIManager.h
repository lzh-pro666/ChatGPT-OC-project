#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^StreamingResponseBlock)(NSString * _Nullable partialResponse, BOOL isDone, NSError * _Nullable error);
typedef void (^IntentClassificationBlock)(NSString * _Nullable label, NSError * _Nullable error);
typedef void (^ImageGenerationBlock)(NSArray<NSURL *> * _Nullable imageURLs, NSError * _Nullable error);

// 遵循 NSURLSessionDataDelegate 协议
@interface APIManager : NSObject <NSURLSessionDataDelegate>

// 默认的系统 Prompt
@property (nonatomic, copy) NSString *defaultSystemPrompt;

@property (nonatomic, copy) NSString *currentModelName;

// 可切换的 BaseURL（默认 OpenAI 兼容端点）
- (void)setBaseURL:(NSString *)baseURLString;
- (NSString *)currentBaseURL;

// 流式请求 ChatGPT API
- (NSURLSessionDataTask *)streamingChatCompletionWithMessages:(NSArray *)messages 
                                               streamCallback:(StreamingResponseBlock)callback;
// 流式请求 ChatGPT API(含图片)
- (NSURLSessionDataTask *)streamingChatCompletionWithMessages:(NSArray *)messages
                                                       images:(nullable NSArray<UIImage *> *)images
                                               streamCallback:(StreamingResponseBlock)callback;

// 设置 API Key
- (void)setApiKey:(NSString *)apiKey;
// 获取当前 API Key（只读）
- (NSString *)currentApiKey;

// 用于取消任务
- (void)cancelStreamingTask:(NSURLSessionDataTask *)task;

+ (instancetype)sharedManager;

// 意图分类：返回 @"生成" 或 @"理解"
- (void)classifyIntentWithMessages:(NSArray *)messages
                       temperature:(double)temperature
                         completion:(IntentClassificationBlock)completion;

// 图片生成：基于提示与底图 URL 生成图片结果 URL 列表
- (void)generateImageWithPrompt:(NSString *)prompt
                   baseImageURL:(NSString *)baseImageURL
                     completion:(ImageGenerationBlock)completion;
@end

NS_ASSUME_NONNULL_END 
