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

// 使用同步队列来保护对字典的访问
@property (nonatomic, strong) dispatch_queue_t stateAccessQueue;

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
        // 创建一个专用于网络回调的后台队列
        NSOperationQueue *delegateQueue = [[NSOperationQueue alloc] init];
        delegateQueue.maxConcurrentOperationCount = 1; // 保证任务按顺序执行
        _session = [NSURLSession sessionWithConfiguration:config
                                                 delegate:self
                                            delegateQueue:delegateQueue];
        _stateAccessQueue = dispatch_queue_create("com.yourapp.apiManager.stateQueue", DISPATCH_QUEUE_SERIAL);
        _defaultSystemPrompt = @"你是一个具有同理心的中文 ai 助手";
        _taskCallbacks = [NSMutableDictionary dictionary];
        _taskAccumulatedData = [NSMutableDictionary dictionary];
        _taskBuffers = [NSMutableDictionary dictionary];
        _completedTaskIdentifiers = [NSMutableSet set];
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
        // 保护对共享状态字典的写入操作
        dispatch_sync(self.stateAccessQueue, ^{
            if (callback) {
                self.taskCallbacks[taskIdentifier] = [callback copy];
            }
            self.taskAccumulatedData[taskIdentifier] = [NSMutableString string];
            self.taskBuffers[taskIdentifier] = [NSMutableData data];
            // 同样保护 Set，即使是移除操作也算写入
            [self.completedTaskIdentifiers removeObject:taskIdentifier];
        });
        
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

/**
 @brief 发起一个流式的聊天机器人请求，可选支持多模态（图文混合）。
 @param messages 对话历史记录数组。
 @param images 可选的图片数组。如果为 nil 或空，则为纯文本请求。
 @param callback 流式响应的回调 block。
 @return 用于控制任务的 NSURLSessionDataTask 对象。
 */
- (NSURLSessionDataTask *)streamingChatCompletionWithMessages:(NSArray *)messages
                                                       images:(nullable NSArray<UIImage *> *)images
                                               streamCallback:(StreamingResponseBlock)callback {
                                               
    // 检查 API Key 是否已设置
    if (!self.apiKey || self.apiKey.length == 0) {
        NSError *error = [NSError errorWithDomain:@"com.yourapp.api"
                                             code:401
                                         userInfo:@{NSLocalizedDescriptionKey: @"API Key 未设置"}];
        if (callback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(nil, YES, error);
            });
        }
        return nil;
    }
    
    // 动态构建请求体
    NSArray *payloadMessages; // 用于最终承载发送给 API 的 messages 数据

    // 判断是否为多模态请求
    if (images && images.count > 0) {
        NSMutableArray *mutableMessages = [messages mutableCopy];
        NSMutableDictionary *lastMessage = [[mutableMessages lastObject] mutableCopy];
        
        if (lastMessage && [lastMessage[@"content"] isKindOfClass:[NSString class]]) {
            NSString *originalText = lastMessage[@"content"];
            
            // 创建一个新的 content 数组，用于存放文本和图片
            NSMutableArray *newContentParts = [NSMutableArray array];
            
            // 添加文本部分
            [newContentParts addObject:@{
                @"type": @"text",
                @"text": originalText ?: @"" // 保证文本不为nil
            }];
            
            // 循环添加所有图片部分
            for (UIImage *image in images) {
                NSString *base64String = [self base64StringFromImage:image];
                if (base64String) {
                    NSString *imageUrlString = [NSString stringWithFormat:@"data:image/jpeg;base64,%@", base64String];
                    [newContentParts addObject:@{
                        @"type": @"image_url",
                        @"image_url": @{ @"url": imageUrlString }
                    }];
                }
            }
            
            // 用新的 content 数组替换旧的 content 字符串
            lastMessage[@"content"] = newContentParts;
            
            // 更新 messages 数组
            [mutableMessages removeLastObject];
            [mutableMessages addObject:lastMessage];
            
            payloadMessages = [mutableMessages copy];
        } else {
            payloadMessages = messages;
        }
    } else {
        // --- 纯文本请求逻辑 ---
        payloadMessages = messages;
    }

    // 3. 准备请求体
    // 注意：多模态请求需要使用支持视觉功能的模型，如 "gpt-4-vision-preview"
    NSDictionary *requestBody = @{
        @"model": self.currentModelName,
        @"messages": payloadMessages,
        @"stream": @YES
    };
    
    // =================================================================
    // --- 后续流程保持不变 ---
    // =================================================================
    
    // 4. 创建请求
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kOpenAIAPIEndpoint]];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", self.apiKey] forHTTPHeaderField:@"Authorization"];
    
    // 5. 序列化 JSON
    NSError *jsonError;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:requestBody
                                                       options:0
                                                         error:&jsonError];
    
    if (jsonError) {
        if (callback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(nil, YES, jsonError);
            });
        }
        return nil;
    }
    
    [request setHTTPBody:jsonData];
    
    // 6. 创建数据任务
    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:request];
    
    // 7. 存储回调和初始化数据
    if (task) {
        NSNumber *taskIdentifier = @(task.taskIdentifier);
        // 线程安全地存储任务状态
        dispatch_sync(self.stateAccessQueue, ^{
            if (callback) {
                self.taskCallbacks[taskIdentifier] = [callback copy];
            }
            self.taskAccumulatedData[taskIdentifier] = [NSMutableString string];
            self.taskBuffers[taskIdentifier] = [NSMutableData data];
            [self.completedTaskIdentifiers removeObject:taskIdentifier];
        });
        
        [task resume];
        return task;
    } else {
        // 8. 任务创建失败，调用回调返回错误
        if (callback) {
            NSError *taskError = [NSError errorWithDomain:@"com.yourapp.api"
                                                     code:500
                                                 userInfo:@{NSLocalizedDescriptionKey: @"无法创建网络任务"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(nil, YES, taskError);
            });
        }
        return nil;
    }
}

// 简化 cancelStreamingTask
- (void)cancelStreamingTask:(NSURLSessionDataTask *)task {
    if (task) {
        // 只需调用 cancel，后续的清理会自动在 didCompleteWithError 中进行
        [task cancel];
    }
}

#pragma mark - NSURLSessionDataDelegate

// 优化后的 didReceiveResponse
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler {
    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    if (httpResponse.statusCode != 200) {
        NSNumber *taskIdentifier = @(dataTask.taskIdentifier);
        NSString *errorMessage = [NSString stringWithFormat:@"API 请求失败，状态码: %ld", (long)httpResponse.statusCode];
        NSError *apiError = [NSError errorWithDomain:@"com.yourapp.api" code:httpResponse.statusCode userInfo:@{NSLocalizedDescriptionKey: errorMessage}];

        // --- 逻辑优化 ---
        // 1. 立即标记任务为完成，并获取回调
        __block StreamingResponseBlock callback;
        dispatch_sync(self.stateAccessQueue, ^{
            [self.completedTaskIdentifiers addObject:taskIdentifier];
            callback = self.taskCallbacks[taskIdentifier];
        });

        // 2. 如果有回调，立即报告错误
        if (callback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(nil, YES, apiError);
            });
        }
        
        // 3. 最后取消任务
        completionHandler(NSURLSessionResponseCancel);
    } else {
        completionHandler(NSURLSessionResponseAllow);
    }
}

// 收到数据 (优化后版本)
- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
        
    // 1. 获取与此任务相关的状态信息
    NSNumber *taskIdentifier = @(dataTask.taskIdentifier);
    // 从字典中安全地获取回调、累积内容和缓冲区，为了在 block 外部使用，需要用 __block 修饰
    __block StreamingResponseBlock callback;
    __block NSMutableString *accumulatedContent;
    __block NSMutableData *buffer;

    // 在一个同步块中，获取所有需要的状态对象
    dispatch_sync(self.stateAccessQueue, ^{
        callback = self.taskCallbacks[taskIdentifier];
        accumulatedContent = self.taskAccumulatedData[taskIdentifier];
        buffer = self.taskBuffers[taskIdentifier];
    });
    

    // 如果找不到任务信息，说明任务可能已被取消或已完成，直接取消并返回
    if (!callback || !accumulatedContent || !buffer) {
        [dataTask cancel];
        // 由于任务已被取消，didCompleteWithError 会被调用，清理工作将在那里进行
        return;
    }

    // 2. 将新收到的数据追加到缓冲区
    [buffer appendData:data];

    // 3. 定义 SSE 事件分隔符 (两个换行符)
    const char *delimiter = "\n\n";
    NSData *delimiterData = [NSData dataWithBytes:delimiter length:strlen(delimiter)];

    // 4. 循环处理缓冲区中的完整 SSE 事件
    while (YES) {
        // 查找第一个分隔符的位置
        NSRange delimiterRange = [buffer rangeOfData:delimiterData options:0 range:NSMakeRange(0, buffer.length)];

        // 如果找不到分隔符，说明当前缓冲区中没有一个完整的事件，退出循环，等待更多数据
        if (delimiterRange.location == NSNotFound) {
            break;
        }

        // --- 找到一个完整的事件 ---

        // 提取事件数据 (从开头到分隔符之前)
        NSUInteger eventLength = delimiterRange.location;
        NSData *eventData = [buffer subdataWithRange:NSMakeRange(0, eventLength)];

        // 从缓冲区中移除已处理的事件数据和分隔符
        NSUInteger processedLength = eventLength + delimiterRange.length;
        [buffer replaceBytesInRange:NSMakeRange(0, processedLength) withBytes:NULL length:0];

        // 将事件数据转换为字符串进行解析
        NSString *eventString = [[NSString alloc] initWithData:eventData encoding:NSUTF8StringEncoding];
        
        // 如果解码失败，跳过这个事件
        if (!eventString) {
            continue;
        }

        // 按行解析单个事件
        NSArray *lines = [eventString componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            if ([line hasPrefix:@"data:"]) {
                NSString *jsonDataString = [line substringFromIndex:6];
                NSString *trimmedData = [jsonDataString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

                // 检查是否是流结束的标志
                if ([trimmedData isEqualToString:@"[DONE]"]) {
                    // 标记任务已通过 [DONE] 正常完成
                    // 保护对 Set 的写入操作
                    dispatch_sync(self.stateAccessQueue, ^{
                        [self.completedTaskIdentifiers addObject:taskIdentifier];
                    });
                    //[self.completedTaskIdentifiers addObject:taskIdentifier];
                    
                    // 触发最终成功回调
                    dispatch_async(dispatch_get_main_queue(), ^{
                        callback(accumulatedContent, YES, nil);
                    });
                    
                    // 已完成，无需再解析此事件的后续行
                    break;
                }

                // 解析 JSON 数据
                NSError *jsonError;
                NSData *jsonData = [jsonDataString dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *jsonObj = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];

                if (jsonError) {
                    // JSON 解析失败，可以根据需要选择忽略或报告错误
                    NSLog(@"JSON parsing error: %@", jsonError.localizedDescription);
                    continue;
                }
                
                // 从 JSON 中提取内容
                NSArray *choices = jsonObj[@"choices"];
                if (choices.count > 0) {
                    NSDictionary *delta = choices[0][@"delta"];
                    NSString *content = delta[@"content"];
                    if (content) {
                        [accumulatedContent appendString:content];
                        
                        // 触发增量回调，报告部分结果
                        dispatch_async(dispatch_get_main_queue(), ^{
                            callback(accumulatedContent, NO, nil);
                        });
                    }
                }
            }
        } // for line in lines

        __block BOOL isComplete = NO;
            dispatch_sync(self.stateAccessQueue, ^{
                isComplete = [self.completedTaskIdentifiers containsObject:taskIdentifier];
            });
            if (isComplete) {
                [buffer setLength:0];
                break;
            }
    } // while (YES)
}


// 任务完成
- (void)URLSession:(NSURLSession *)session 
              task:(NSURLSessionTask *)task 
didCompleteWithError:(nullable NSError *)error {
    NSNumber *taskIdentifier = @(task.taskIdentifier);
    
    // 检查是否已经通过 [DONE] 标记为完成
    __block StreamingResponseBlock callback;
    __block NSMutableString *accumulatedContent;
    __block BOOL alreadyCompleted;

    // 在一个同步块中，获取所有需要的状态
    dispatch_sync(self.stateAccessQueue, ^{
        callback = self.taskCallbacks[taskIdentifier];
        accumulatedContent = self.taskAccumulatedData[taskIdentifier];
        alreadyCompleted = [self.completedTaskIdentifiers containsObject:taskIdentifier];
    });
    
    if (callback && !alreadyCompleted) { // 只有在未完成时才需要处理
        if (error) {
            // 如果是取消操作 (NSURLErrorCancelled)，则不应报告错误
            if (error.code != NSURLErrorCancelled) {
                // 切换回主线程执行回调
                dispatch_async(dispatch_get_main_queue(), ^{
                    callback(accumulatedContent, YES, error);
                });
            }
        } else {
            // 如果没有错误，并且之前没有收到 [DONE] 事件，则认为完成 (容错)
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(accumulatedContent, YES, nil);
            });
            
        }
    }
    
    // 清理与此任务相关的资源
    [self cleanupTask:task];
}

// 将UIImage转换为Base64字符串
- (NSString *)base64StringFromImage:(UIImage *)image {
    // 为了性能，可以适当压缩图片质量和尺寸
    NSData *imageData = UIImageJPEGRepresentation(image, 0.7); // 0.7 是压缩质量
    return [imageData base64EncodedStringWithOptions:NSDataBase64EncodingEndLineWithLineFeed];
}

// 清理任务资源
- (void)cleanupTask:(NSURLSessionTask *)task {
    NSNumber *taskIdentifier = @(task.taskIdentifier);
    // 保护所有对字典和 Set 的修改操作
    dispatch_sync(self.stateAccessQueue, ^{
        [self.taskCallbacks removeObjectForKey:taskIdentifier];
        [self.taskAccumulatedData removeObjectForKey:taskIdentifier];
        [self.taskBuffers removeObjectForKey:taskIdentifier];
        [self.completedTaskIdentifiers removeObject:taskIdentifier];
    });
}


@end
