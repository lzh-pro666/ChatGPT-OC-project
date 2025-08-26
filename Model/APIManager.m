#import "APIManager.h"

// 默认 API endpoint（可被覆盖）
static NSString * kAPIEndpoint = @"https://xiaoai.plus/v1/chat/completions";

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
// BaseURL 切换接口
- (void)setBaseURL:(NSString *)baseURLString {
    if (baseURLString.length > 0) {
        kAPIEndpoint = [baseURLString copy];
    }
}

- (NSString *)currentBaseURL {
    return kAPIEndpoint;
}

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
        _defaultSystemPrompt = @"你是一个具有同理心的中文 AI 助手";
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

#pragma mark - Intent Classification (生成/理解)

- (void)classifyIntentWithMessages:(NSArray *)messages
                       temperature:(double)temperature
                         completion:(IntentClassificationBlock)completion {
    if (!self.apiKey || self.apiKey.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"com.yourapp.api" code:401 userInfo:@{NSLocalizedDescriptionKey:@"API Key 未设置"}]);
        return;
    }
    NSMutableArray *payload = [messages mutableCopy];
    NSString *clsPrompt = @"请你根据用户当前的聊天{用户输入的消息和聊天历史}，判断当前用户想要执行图片生成还是图片理解任务的百分比，根据百分比做最终回复，限制回复只能为\"生成\"或\"理解\"";
    [payload insertObject:@{ @"role": @"system", @"content": clsPrompt } atIndex:0];

    NSDictionary *body = @{ @"model": (self.currentModelName ?: @"gpt-3.5-turbo"),
                            @"messages": payload,
                            @"temperature": @(MAX(0.0, MIN(2.0, temperature))) };
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kAPIEndpoint]];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", self.apiKey] forHTTPHeaderField:@"Authorization"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [req setHTTPBody:data];

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req completionHandler:^(NSData * _Nullable d, NSURLResponse * _Nullable r, NSError * _Nullable e) {
        if (e) { dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, e); }); return; }
        NSDictionary *obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSString *label = nil;
        if ([obj isKindOfClass:[NSDictionary class]]) {
            NSArray *choices = obj[@"choices"];
            if ([choices isKindOfClass:[NSArray class]] && choices.count > 0) {
                NSDictionary *msg = choices[0][@"message"];
                id contentObj = msg[@"content"];
                if ([contentObj isKindOfClass:[NSString class]]) {
                    NSString *text = [(NSString *)contentObj stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    label = ([text containsString:@"生成"]) ? @"生成" : @"理解";
                }
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(label, nil); });
    }];
    [task resume];
}

#pragma mark - Image Generation (图片生成)

- (void)generateImageWithPrompt:(NSString *)prompt
                   baseImageURL:(NSString *)baseImageURL
                     completion:(ImageGenerationBlock)completion {
    if (!self.apiKey || self.apiKey.length == 0) {
        if (completion) completion(nil, [NSError errorWithDomain:@"com.yourapp.api" code:401 userInfo:@{NSLocalizedDescriptionKey:@"API Key 未设置"}]);
        return;
    }
    // 新接口与格式
    NSString *genEndpoint = @"https://dashscope.aliyuncs.com/api/v1/services/aigc/multimodal-generation/generation";
    NSDictionary *messageContent = @{ @"role": @"user",
                                      @"content": @[ @{ @"image": (baseImageURL ?: @"") },
                                                      @{ @"text": (prompt ?: @"") } ] };
    NSDictionary *body = @{ @"model": @"qwen-image-edit",
                            @"input": @{ @"messages": @[ messageContent ] },
                            @"parameters": @{ @"negative_prompt": @"",
                                               @"watermark": @NO } };
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:genEndpoint]];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", self.apiKey] forHTTPHeaderField:@"Authorization"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [req setHTTPBody:data];

    // 调试日志
    NSLog(@"[ImageGen][Request] endpoint=%@ body=%@", genEndpoint, body);

    NSURLSessionDataTask *task = [self.session dataTaskWithRequest:req completionHandler:^(NSData * _Nullable d, NSURLResponse * _Nullable r, NSError * _Nullable e) {
        if (e) { dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, e); }); return; }
        NSDictionary *obj = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSLog(@"[ImageGen][Response] %@", obj);
        // 错误结构：{"code":"InvalidParameter","message":"..."}
        if ([obj isKindOfClass:[NSDictionary class]] && obj[@"code"]) {
            NSString *code = obj[@"code"] ?: @"Unknown";
            NSString *msg = obj[@"message"] ?: @"Unknown error";
            NSError *apiErr = [NSError errorWithDomain:@"com.yourapp.api" code:422 userInfo:@{NSLocalizedDescriptionKey:[NSString stringWithFormat:@"[%@] %@", code, msg]}];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, apiErr); });
            return;
        }

        // 成功结构：output.choices[0].message.content[0].image
        NSMutableArray<NSURL *> *urls = [NSMutableArray array];
        if ([obj isKindOfClass:[NSDictionary class]]) {
            NSDictionary *output = obj[@"output"];
            NSArray *choices = [output isKindOfClass:[NSDictionary class]] ? output[@"choices"] : nil;
            if ([choices isKindOfClass:[NSArray class]] && choices.count > 0) {
                NSDictionary *choice0 = choices.firstObject;
                NSDictionary *message = [choice0 isKindOfClass:[NSDictionary class]] ? choice0[@"message"] : nil;
                NSArray *contents = [message isKindOfClass:[NSDictionary class]] ? message[@"content"] : nil;
                if ([contents isKindOfClass:[NSArray class]] && contents.count > 0) {
                    for (NSDictionary *c in contents) {
                        NSString *img = c[@"image"];
                        if ([img isKindOfClass:[NSString class]] && img.length > 0) {
                            NSURL *u = [NSURL URLWithString:img];
                            if (u) { [urls addObject:u]; }
                        }
                    }
                }
            }
        }
        if (urls.count == 0) {
            NSError *pe = [NSError errorWithDomain:@"com.yourapp.api" code:500 userInfo:@{NSLocalizedDescriptionKey:@"未从响应中解析到图片URL"}];
            dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion(nil, pe); });
            return;
        }
        dispatch_async(dispatch_get_main_queue(), ^{ if (completion) completion([urls copy], nil); });
    }];
    [task resume];
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
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kAPIEndpoint]];
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
            // 同� �保护 Set，即使是移除操作也算写入
            [self.completedTaskIdentifiers removeObject:taskIdentifier];
        });
        
        [task resume];
        return task;
    } else {
        // 任务创建失败，调用回调返回错误
        if (callback) {
            NSError *taskError = [NSError errorWithDomain:@"com.chatgpttest2.error" 
                                                    code:500 
                                                userInfo:@{NSLocalizedDescriptionKey: @"� 法创建网络任务"}];
            callback(nil, YES, taskError);
        }
        return nil;
    }
}

/**
 @brief 发起一个流式的聊天机器人请求，可选支持多模态（图文混合）。
 @param messages 对话历史记录数组。
 @param images 可选的图片数组。如果为 nil 或空，则为纯文�请求。
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
            
            // 创建一个新的 content 数组，用于存放文�和图片
            NSMutableArray *newContentParts = [NSMutableArray array];
            
            // 添� 文�部分
            [newContentParts addObject:@{
                @"type": @"text",
                @"text": originalText ?: @"" // 保证文�不为nil
            }];
            
            // 循环添� 所有图片部分
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
            
            // 用新的 content 数组替换旧的 content 字�串
            lastMessage[@"content"] = newContentParts;
            
            // 更新 messages 数组
            [mutableMessages removeLastObject];
            [mutableMessages addObject:lastMessage];
            
            payloadMessages = [mutableMessages copy];
        } else {
            payloadMessages = messages;
        }
    } else {
        // --- 纯文�请求逻辑 ---
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
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:kAPIEndpoint]];
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
                                                 userInfo:@{NSLocalizedDescriptionKey: @"� 法创建网络任务"}];
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
        NSString *errorMessage = [NSString stringWithFormat:@"API 请求失败，状态� �: %ld", (long)httpResponse.statusCode];
        NSError *apiError = [NSError errorWithDomain:@"com.yourapp.api" code:httpResponse.statusCode userInfo:@{NSLocalizedDescriptionKey: errorMessage}];

        // --- 逻辑优化 ---
        // 1. 立即� �记任务为完成，并获取回调
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

// 收到数据 (优化后版�)
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

    // 2. 将新收到的数据追� 到缓冲区
    [buffer appendData:data];

    // 3. 定义 SSE 事件分隔� (两个换行�)
    const char *delimiter = "\n\n";
    NSData *delimiterData = [NSData dataWithBytes:delimiter length:strlen(delimiter)];

    // 4. 循环处理缓冲区中的完整 SSE 事件
    while (YES) {
        // 查找�一个分隔�的位置
        NSRange delimiterRange = [buffer rangeOfData:delimiterData options:0 range:NSMakeRange(0, buffer.length)];

        // 如果找不到分隔�，说明当前缓冲区中没有一个完整的事件，退出循环，等待更多数据
        if (delimiterRange.location == NSNotFound) {
            break;
        }

        // --- 找到一个完整的事件 ---

        // 提取事件数据 (从开头到分隔�之前)
        NSUInteger eventLength = delimiterRange.location;
        NSData *eventData = [buffer subdataWithRange:NSMakeRange(0, eventLength)];

        // 从缓冲区中移除已处理的事件数据和分隔�
        NSUInteger processedLength = eventLength + delimiterRange.length;
        [buffer replaceBytesInRange:NSMakeRange(0, processedLength) withBytes:NULL length:0];

        // 将事件数据�换为字�串进行解析
        NSString *eventString = [[NSString alloc] initWithData:eventData encoding:NSUTF8StringEncoding];
        
        // 如果解� �失败，跳过这个事件
        if (!eventString) {
            continue;
        }

        // 按行解析单个事件
        NSArray *lines = [eventString componentsSeparatedByString:@"\n"];
        for (NSString *line in lines) {
            if ([line hasPrefix:@"data:"]) {
                NSString *jsonDataString = [line substringFromIndex:6];
                NSString *trimmedData = [jsonDataString stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];

                // 检查是否是流结束的� �志
                if ([trimmedData isEqualToString:@"[DONE]"]) {
                    // � �记任务已通过 [DONE] 正常完成
                    // 保护对 Set 的写入操作
                    dispatch_sync(self.stateAccessQueue, ^{
                        [self.completedTaskIdentifiers addObject:taskIdentifier];
                    });
                    //[self.completedTaskIdentifiers addObject:taskIdentifier];
                    
                    // 触发最终成功回调
                    dispatch_async(dispatch_get_main_queue(), ^{
                        callback(accumulatedContent, YES, nil);
                    });
                    
                    // 已完成，� 需再解析此事件的后续行
                    break;
                }

                // 解析 JSON 数据
                NSError *jsonError;
                NSData *jsonData = [jsonDataString dataUsingEncoding:NSUTF8StringEncoding];
                NSDictionary *jsonObj = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];

                if (jsonError) {
                    // JSON 解析失败，可以� �据需要选择忽略或报告错误
                    NSLog(@"JSON parsing error: %@", jsonError.localizedDescription);
                    continue;
                }
                
                // 从 JSON 中提取内容
                if (![jsonObj isKindOfClass:[NSDictionary class]]) {
                    continue;
                }
                NSArray *choices = jsonObj[@"choices"];
                if ([choices isKindOfClass:[NSArray class]] && choices.count > 0) {
                    id deltaObj = choices[0][@"delta"];
                    if (![deltaObj isKindOfClass:[NSDictionary class]]) {
                        continue;
                    }
                    NSDictionary *delta = (NSDictionary *)deltaObj;
                    id contentObj = delta[@"content"]; // 兼容 NSNull
                    if ([contentObj isKindOfClass:[NSString class]]) {
                        NSString *content = (NSString *)contentObj;
                        [accumulatedContent appendString:content];
                        // 触发增量回调，报告部分结果
                        dispatch_async(dispatch_get_main_queue(), ^{
                            callback(accumulatedContent, NO, nil);
                        });
                    } else {
                        // 忽略 reasoning_content 或 NSNull 等非字符串字段
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
    
    // 检查是否已经通过 [DONE] � �记为完成
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

// 将UIImage�换为Base64字�串
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
