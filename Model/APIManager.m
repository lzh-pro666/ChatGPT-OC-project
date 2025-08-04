#import "APIManager.h"

// OpenAI API endpoint
static NSString * const kOpenAIAPIEndpoint = @"https://xiaoai.plus/v1/chat/completions";

@interface APIManager ()

@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, strong) NSURLSession *session; // 会话需要配置代理

// 用于存储每个任务的回调和数据
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, StreamingResponseBlock> *taskCallbacks;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableString *> *taskAccumulatedData;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableData *> *taskBuffers;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *completedTaskIdentifiers; // 跟踪已完成的任务

@end

@implementation APIManager

+ (instancetype)sharedManager {
    static APIManager *sharedManager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] init];
    });
    return sharedManager;
}

- (instancetype)init {
    if (self = [super init]) {
        // 配置会话使用代理，并在主队列上回调
        NSURLSessionConfiguration *config = [NSURLSessionConfiguration defaultSessionConfiguration];
        _session = [NSURLSession sessionWithConfiguration:config 
                                                 delegate:self 
                                            delegateQueue:[NSOperationQueue mainQueue]]; 
        _defaultSystemPrompt = @"你是一个有帮助的助手。请简明扼要地回答问题。";
        _taskCallbacks = [NSMutableDictionary dictionary];
        _taskAccumulatedData = [NSMutableDictionary dictionary];
        _taskBuffers = [NSMutableDictionary dictionary];
        _completedTaskIdentifiers = [NSMutableSet set]; // 初始化 Set
        _currentModelName = @"gpt-3.5-turbo"; // 默认使用 gpt-3.5-turbo 模型
    }
    return self;
}

- (void)setApiKey:(NSString *)apiKey {
    _apiKey = apiKey;
}

- (NSURLSessionDataTask *)streamingChatCompletionWithMessages:(NSArray *)messages 
                                               streamCallback:(StreamingResponseBlock)callback {
    // 检查 API Key 是否已设置
    if (!self.apiKey || self.apiKey.length == 0) {
        NSError *error = [NSError errorWithDomain:@"com.chatgpttest2.error" 
                                             code:401 
                                         userInfo:@{NSLocalizedDescriptionKey: @"API Key 未设置"}];
        if (callback) {
            callback(nil, YES, error);
        }
        return nil;
    }
    
    // 创建请求
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kOpenAIAPIEndpoint]];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.apiKey] 
   forHTTPHeaderField:@"Authorization"];
    
    // 准备请求体
    NSDictionary *requestBody = @{
        @"model": self.currentModelName, // 使用当前设置的模型
        @"messages": messages,
        @"stream": @YES
    };
    
    NSError *jsonError;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:requestBody 
                                                       options:0 
                                                         error:&jsonError];
    
    if (jsonError) {
        if (callback) {
            callback(nil, YES, jsonError);
        }
        return nil;
    }
    
    [request setHTTPBody:jsonData];
    
    // 创建数据任务
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request];
    
    // 存储回调和初始化数据
    if (task) {  // 确保task不为nil
        NSNumber *taskIdentifier = @(task.taskIdentifier);
        if (callback) {
            self.taskCallbacks[taskIdentifier] = [callback copy];
        }
        self.taskAccumulatedData[taskIdentifier] = [NSMutableString string];
        self.taskBuffers[taskIdentifier] = [NSMutableData data];
        
        [task resume];
        return task;
    } else {
        // 任务创建失败，调用回调返回错误
        if (callback) {
            NSError *taskError = [NSError errorWithDomain:@"com.chatgpttest2.error" 
                                                    code:500 
                                                userInfo:@{NSLocalizedDescriptionKey: @"无法创建网络任务"}];
            callback(nil, YES, taskError);
        }
        return nil;
    }
}

- (void)cancelStreamingTask:(NSURLSessionDataTask *)task {
    if (task) {
        [task cancel];
        NSNumber *taskIdentifier = @(task.taskIdentifier);
        [self.taskCallbacks removeObjectForKey:taskIdentifier];
        [self.taskAccumulatedData removeObjectForKey:taskIdentifier];
        [self.taskBuffers removeObjectForKey:taskIdentifier];
    }
}

#pragma mark - NSURLSessionDataDelegate

// 收到响应头
- (void)URLSession:(NSURLSession *)session 
          dataTask:(NSURLSessionDataTask *)dataTask 
didReceiveResponse:(NSURLResponse *)response 
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (httpResponse.statusCode != 200) {
        // 如果状态码不是200，则视为错误
        NSNumber *taskIdentifier = @(dataTask.taskIdentifier);
        StreamingResponseBlock callback = self.taskCallbacks[taskIdentifier];
        
        // 取消任务，并通知调用方出错
        completionHandler(NSURLSessionResponseCancel);
        
        if (callback) {
            NSString *errorMessage = [NSString stringWithFormat:@"API 请求失败，状态码: %ld", (long)httpResponse.statusCode];
            NSError *apiError = [NSError errorWithDomain:@"com.chatgpttest2.api" 
                                                    code:httpResponse.statusCode 
                                                userInfo:@{NSLocalizedDescriptionKey: errorMessage}];
            callback(nil, YES, apiError);
        }
        // 清理资源
        [self cleanupTask:dataTask];
    } else {
        // 允许继续接收数据
        completionHandler(NSURLSessionResponseAllow);
    }
}

// 收到数据
- (void)URLSession:(NSURLSession *)session 
          dataTask:(NSURLSessionDataTask *)dataTask 
didReceiveData:(NSData *)data {
    NSNumber *taskIdentifier = @(dataTask.taskIdentifier);
    StreamingResponseBlock callback = self.taskCallbacks[taskIdentifier];
    NSMutableString *accumulatedContent = self.taskAccumulatedData[taskIdentifier];
    NSMutableData *buffer = self.taskBuffers[taskIdentifier];
    
    if (!callback || !accumulatedContent || !buffer) {
        [dataTask cancel]; // 如果找不到相关信息，取消任务
        [self cleanupTask:dataTask];
        return;
    }
    
    if ([self.completedTaskIdentifiers containsObject:taskIdentifier]) {
        return; // 如果已经完成，则忽略后续可能到达的数据
    }
    
    [buffer appendData:data];
    
    // 处理缓冲区中的SSE事件
    NSString *bufferString = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding];
    
    // SSE事件以两个换行符分隔
    NSArray *eventStrings = [bufferString componentsSeparatedByString:@"\n\n"];
    
    NSUInteger processedLength = 0;
    
    for (NSString *eventString in eventStrings) {
        if (eventString.length == 0) continue;
        
        // 检查这是否是一个完整的事件（以\n\n结尾）
        BOOL isCompleteEvent = [bufferString containsString:[NSString stringWithFormat:@"%@\n\n", eventString]];
        if (!isCompleteEvent && ![eventString containsString:@"data: [DONE]"]) {
            // 不是完整事件，等待更多数据
            break;
        }

        processedLength += eventString.length + 2; // +2 for \n\n
        // 处理单个事件
        NSArray *lines = [eventString componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            if ([line hasPrefix:@"data:"]) {
                NSString *jsonDataString = [line substringFromIndex:6];
                
                // 更稳妥地检查 [DONE]
                NSString *trimmedData = [jsonDataString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if ([trimmedData isEqualToString:@"[DONE]"]) { 
                    // 标记任务完成
                    [self.completedTaskIdentifiers addObject:taskIdentifier];
                    
                    // 触发最终回调
                    callback(accumulatedContent, YES, nil);
                    // 不再处理此事件后续行，并准备移除已处理数据
                    break; 
                } else {
                    NSError *jsonError;
                    NSData *jsonData = [jsonDataString dataUsingEncoding:NSUTF8StringEncoding];
                    NSDictionary *jsonObj = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];
                    
                    if (!jsonError) {
                        NSArray *choices = jsonObj[@"choices"];
                        if (choices.count > 0) {
                            NSDictionary *choice = choices[0];
                            NSDictionary *delta = choice[@"delta"];
                            NSString *content = delta[@"content"];
                            
                            if (content) {
                                [accumulatedContent appendString:content];
                                // 检查任务是否已完成（避免在 [DONE] 后还发送 NO）
                                if (![self.completedTaskIdentifiers containsObject:taskIdentifier]) {
                                    callback(accumulatedContent, NO, nil);
                                }
                            }
                        }
                    }
                }
            }
        }
         // 如果在循环中检测到完成，跳出外层循环
        if ([self.completedTaskIdentifiers containsObject:taskIdentifier]) {
            break;
        }
    }
    
    // 移除已处理的数据
    if (processedLength > 0 && processedLength <= buffer.length) {
        [buffer replaceBytesInRange:NSMakeRange(0, processedLength) withBytes:NULL length:0];
    }
}

// 任务完成
- (void)URLSession:(NSURLSession *)session 
              task:(NSURLSessionTask *)task 
didCompleteWithError:(nullable NSError *)error {
    NSNumber *taskIdentifier = @(task.taskIdentifier);
    
    // 检查是否已经通过 [DONE] 标记为完成
    BOOL alreadyCompleted = [self.completedTaskIdentifiers containsObject:taskIdentifier];
    
    StreamingResponseBlock callback = self.taskCallbacks[taskIdentifier];
    NSMutableString *accumulatedContent = self.taskAccumulatedData[taskIdentifier];
    
    if (callback && !alreadyCompleted) { // 只有在未完成时才需要处理
        if (error) {
            // 如果是取消操作 (NSURLErrorCancelled)，则不应报告错误
            if (error.code != NSURLErrorCancelled) {
                callback(accumulatedContent, YES, error); 
            }
        } else {
            // 如果没有错误，并且之前没有收到 [DONE] 事件，则认为完成 (容错)
            callback(accumulatedContent, YES, nil);
        }
    }
    
    // 清理与此任务相关的资源
    [self cleanupTask:task];
}

// 清理任务资源
- (void)cleanupTask:(NSURLSessionTask *)task {
    NSNumber *taskIdentifier = @(task.taskIdentifier);
    [self.taskCallbacks removeObjectForKey:taskIdentifier];
    [self.taskAccumulatedData removeObjectForKey:taskIdentifier];
    [self.taskBuffers removeObjectForKey:taskIdentifier];
    [self.completedTaskIdentifiers removeObject:taskIdentifier]; // 清理完成状态
}

@end 
