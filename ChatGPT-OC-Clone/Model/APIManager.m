#import "APIManager.h"

// 默认 API endpoint（仅作为缺省值，不在运行时修改全局变量）
static NSString * kDefaultAPIEndpoint = @"https://xiaoai.plus/v1/chat/completions";
static const NSTimeInterval kUIThrottleIntervalSeconds = 0.016; // ~60fps

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

// 基础配置（线程安全访问）
@property (nonatomic, copy) NSString *overriddenBaseURL; // 如果为空则使用默认端点

// UI 回调节流
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, dispatch_source_t> *taskThrottleTimers;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *tasksWithPendingUpdate;

@end

@implementation APIManager
// BaseURL 切换接口（不修改全局静态变量，避免并发竞态）
- (void)setBaseURL:(NSString *)baseURLString {
    dispatch_sync(self.stateAccessQueue, ^{
        self.overriddenBaseURL = (baseURLString.length > 0) ? [baseURLString copy] : nil;
    });
}

- (NSString *)currentBaseURL {
    __block NSString *url = nil;
    dispatch_sync(self.stateAccessQueue, ^{
        url = self.overriddenBaseURL ?: kDefaultAPIEndpoint;
    });
    return url;
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
        _taskThrottleTimers = [NSMutableDictionary dictionary];
        _tasksWithPendingUpdate = [NSMutableSet set];
        _currentModelName = @"gpt-4o"; // 默认使用 gpt-4o 文本模型
    }
    return self;
}

- (void)setApiKey:(NSString *)apiKey {
    dispatch_sync(self.stateAccessQueue, ^{
        self-> _apiKey = [apiKey copy];
    });
}

- (NSString *)currentApiKey {
    __block NSString *key;
    dispatch_sync(self.stateAccessQueue, ^{
        key = self-> _apiKey;
    });
    return key;
}

#pragma mark - UI Throttle Helpers

// 确保为任务创建或更新节流定时器
- (void)ensureThrottleTimerForTaskIdentifier:(NSNumber *)taskIdentifier {
    dispatch_sync(self.stateAccessQueue, ^{
        if (self.taskThrottleTimers[taskIdentifier] != nil) {
            return;
        }
        dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        uint64_t intervalNs = (uint64_t)(kUIThrottleIntervalSeconds * NSEC_PER_SEC);
        dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, intervalNs), intervalNs, (uint64_t)(0.002 * NSEC_PER_SEC));
        __weak typeof(self) weakSelf = self;
        dispatch_source_set_event_handler(timer, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) { return; }
            __block BOOL shouldEmit = NO;
            __block StreamingResponseBlock cb = nil;
            __block NSString *snapshot = nil;
            __block BOOL isCompleted = NO;
            dispatch_sync(strongSelf.stateAccessQueue, ^{
                if ([strongSelf.tasksWithPendingUpdate containsObject:taskIdentifier]) {
                    [strongSelf.tasksWithPendingUpdate removeObject:taskIdentifier];
                    shouldEmit = YES;
                }
                cb = strongSelf.taskCallbacks[taskIdentifier];
                isCompleted = [strongSelf.completedTaskIdentifiers containsObject:taskIdentifier];
                NSMutableString *acc = strongSelf.taskAccumulatedData[taskIdentifier];
                snapshot = [acc copy];
            });
            if (shouldEmit && cb && !isCompleted) {
                cb(snapshot, NO, nil);
            }
        });
        self.taskThrottleTimers[taskIdentifier] = timer;
        dispatch_resume(timer);
    });
}

// 取消任务的节流定时器
- (void)cancelThrottleTimerForTaskIdentifier:(NSNumber *)taskIdentifier {
    dispatch_sync(self.stateAccessQueue, ^{
        dispatch_source_t timer = self.taskThrottleTimers[taskIdentifier];
        if (timer) {
            dispatch_source_cancel(timer);
            [self.taskThrottleTimers removeObjectForKey:taskIdentifier];
        }
        [self.tasksWithPendingUpdate removeObject:taskIdentifier];
    });
}

#pragma mark - Intent Classification (生成/理解)

- (void)classifyIntentWithMessages:(NSArray *)messages
                       temperature:(double)temperature
                         completion:(IntentClassificationBlock)completion {
    NSString *apiKeySnapshot = [self currentApiKey];
    if (!apiKeySnapshot || apiKeySnapshot.length == 0) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, [NSError errorWithDomain:@"com.yourapp.api" code:401 userInfo:@{NSLocalizedDescriptionKey:@"API Key 未设置"}]); });
        return;
    }
    NSMutableArray *payload = [messages mutableCopy];
    NSString *clsPrompt = @"请你根据用户当前的聊天{用户输入的消息和聊天历史}，判断当前用户想要执行图片生成还是图片理解任务的百分比，根据百分比做最终回复，限制回复只能为\"生成\"或\"理解\"";
    [payload insertObject:@{ @"role": @"system", @"content": clsPrompt } atIndex:0];

    // 固定使用 gpt-4o 进行意图分类，避免受用户顶部文本模型影响
    NSDictionary *body = @{ @"model": @"gpt-4o",
                            @"messages": payload,
                            @"temperature": @(MAX(0.0, MIN(2.0, temperature))) };
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self currentBaseURL]]];
    [req setHTTPMethod:@"POST"];
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKeySnapshot] forHTTPHeaderField:@"Authorization"];
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
    NSString *apiKeySnapshot = [self currentApiKey];
    if (!apiKeySnapshot || apiKeySnapshot.length == 0) {
        if (completion) dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, [NSError errorWithDomain:@"com.yourapp.api" code:401 userInfo:@{NSLocalizedDescriptionKey:@"API Key 未设置"}]); });
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
    [req setValue:[NSString stringWithFormat:@"Bearer %@", apiKeySnapshot] forHTTPHeaderField:@"Authorization"];
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
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, apiErr);
            });
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
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion([urls copy], nil);
        });
    }];
    [task resume];
}

- (NSURLSessionDataTask *)streamingChatCompletionWithMessages:(NSArray *)messages 
                                               streamCallback:(StreamingResponseBlock)callback {
    // 检查 API Key 是否已设置
    NSString *apiKeySnapshot = [self currentApiKey];
    if (!apiKeySnapshot || apiKeySnapshot.length == 0) {
        NSError *error = [NSError errorWithDomain:@"com.chatgpttest2.error" 
                                             code:401 
                                         userInfo:@{NSLocalizedDescriptionKey: @"API Key 未设置"}];
        if (callback) {
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(nil, YES, error);
            });
        }
        return nil;
    }
    
    // 创建请求
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self currentBaseURL]]];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKeySnapshot] 
   forHTTPHeaderField:@"Authorization"];
    
    // 准备请求体
    NSDictionary *requestBody = @{
        @"model": self.currentModelName, // 使用当前设置的模型（文本：gpt-5；多模态：qvq-plus）
        @"messages": messages,
        @"stream": @YES
    };
    
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
            [self.completedTaskIdentifiers removeObject:taskIdentifier];
            [self.tasksWithPendingUpdate removeObject:taskIdentifier];
        });
        [self ensureThrottleTimerForTaskIdentifier:taskIdentifier];
        
        [task resume];
        return task;
    } else {
        // 任务创建失败，调用回调返回错误
        if (callback) {
            NSError *taskError = [NSError errorWithDomain:@"com.chatgpttest2.error" 
                                                     code:500 
                                                 userInfo:@{NSLocalizedDescriptionKey: @"无法创建网络任务"}];
            dispatch_async(dispatch_get_main_queue(), ^{
                callback(nil, YES, taskError);
            });
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
    NSString *apiKeySnapshot = [self currentApiKey];
    if (!apiKeySnapshot || apiKeySnapshot.length == 0) {
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
            
            // 添加 文本部分
            [newContentParts addObject:@{
                @"type": @"text",
                @"text": originalText ?: @""
            }];
            
            // 循环添加 所有图片部分（已在base64StringFromImage内部做缩放压缩）
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
        // 纯文本请求
        payloadMessages = messages;
    }

    // 3. 准备请求体
    NSDictionary *requestBody = @{
        @"model": self.currentModelName, // 文本：gpt-5，多模态：qvq-plus
        @"messages": payloadMessages,
        @"stream": @YES
    };
    
    // 4. 创建请求
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[self currentBaseURL]]];
    [request setHTTPMethod:@"POST"];
    [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [request setValue:[NSString stringWithFormat:@"Bearer %@", apiKeySnapshot] forHTTPHeaderField:@"Authorization"];
    
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
        [self ensureThrottleTimerForTaskIdentifier:taskIdentifier];
        
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
        
        // 停止节流计时器
        [self cancelThrottleTimerForTaskIdentifier:taskIdentifier];
        
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

    // 3. 定义 SSE 事件分隔符，兼容 \n\n 与 \r\n\r\n
    const char *delimiterLF = "\n\n";
    const char *delimiterCRLF = "\r\n\r\n";
    NSData *delimiterLFData = [NSData dataWithBytes:delimiterLF length:strlen(delimiterLF)];
    NSData *delimiterCRLFData = [NSData dataWithBytes:delimiterCRLF length:strlen(delimiterCRLF)];

    // 4. 循环处理缓冲区中的完整 SSE 事件
    while (YES) {
        // 查找下一个分隔符的位置，选择最早出现的一个
        NSRange lfRange = [buffer rangeOfData:delimiterLFData options:0 range:NSMakeRange(0, buffer.length)];
        NSRange crlfRange = [buffer rangeOfData:delimiterCRLFData options:0 range:NSMakeRange(0, buffer.length)];

        NSRange delimiterRange = lfRange.location == NSNotFound ? crlfRange : (crlfRange.location == NSNotFound ? lfRange : (lfRange.location < crlfRange.location ? lfRange : crlfRange));

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

        // 规范化换行，按行解析单个事件；收集所有 data: 行
        NSString *normalized = [eventString stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"];
        NSArray<NSString *> *lines = [normalized componentsSeparatedByString:@"\n"];
        NSMutableArray<NSString *> *dataLines = [NSMutableArray array];
        for (NSString *line in lines) {
            NSString *trimmedLine = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if (trimmedLine.length == 0) { continue; }
            if ([trimmedLine hasPrefix:@":"]) { continue; } // 注释
            NSRange range = [trimmedLine rangeOfString:@"data:" options:NSCaseInsensitiveSearch];
            if (range.location == 0) {
                NSString *payload = [trimmedLine substringFromIndex:(range.location + range.length)];
                payload = [payload stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (payload.length > 0) { [dataLines addObject:payload]; }
            }
        }

        if (dataLines.count == 0) { continue; }
        NSString *joinedPayload = [dataLines componentsJoinedByString:@"\n"]; // 多行 data 拼接

        NSString *doneCheck = [joinedPayload stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([doneCheck isEqualToString:@"[DONE]"]) {
            // 标记完成
            dispatch_sync(self.stateAccessQueue, ^{
                [self.completedTaskIdentifiers addObject:taskIdentifier];
            });
            // 最终回调使用不可变快照
            __block StreamingResponseBlock cbFinal = nil;
            __block NSString *snapshot = nil;
            dispatch_sync(self.stateAccessQueue, ^{
                cbFinal = self.taskCallbacks[taskIdentifier];
                snapshot = [self.taskAccumulatedData[taskIdentifier] copy];
            });
            if (cbFinal) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    cbFinal(snapshot, YES, nil);
                });
            }
            [self cancelThrottleTimerForTaskIdentifier:taskIdentifier];
            break; // 已完成
        }

        // 解析 JSON 数据
        NSError *jsonError = nil;
        NSData *jsonData = [joinedPayload dataUsingEncoding:NSUTF8StringEncoding];
        id jsonObj = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&jsonError];
        if (jsonError || !jsonObj) { NSLog(@"JSON parsing error: %@", jsonError.localizedDescription); continue; }
        if (![jsonObj isKindOfClass:[NSDictionary class]]) { continue; }
        NSDictionary *jsonDict = (NSDictionary *)jsonObj;
        NSArray *choices = jsonDict[@"choices"];
        if (![choices isKindOfClass:[NSArray class]] || choices.count == 0) { continue; }
        id deltaObj = choices[0][@"delta"];
        if (![deltaObj isKindOfClass:[NSDictionary class]]) { continue; }
        NSDictionary *delta = (NSDictionary *)deltaObj;
        id contentObj = delta[@"content"]; // 兼容 NSNull
        if ([contentObj isKindOfClass:[NSString class]]) {
            NSString *content = (NSString *)contentObj;
            // 只在 stateAccessQueue 上修改可变字符串
            dispatch_sync(self.stateAccessQueue, ^{
                NSMutableString *acc = self.taskAccumulatedData[taskIdentifier];
                [acc appendString:content];
                [self.tasksWithPendingUpdate addObject:taskIdentifier];
            });
            // 确保定时器存在
            [self ensureThrottleTimerForTaskIdentifier:taskIdentifier];
        }
    }

    __block BOOL isComplete = NO;
    dispatch_sync(self.stateAccessQueue, ^{
        isComplete = [self.completedTaskIdentifiers containsObject:taskIdentifier];
    });
    if (isComplete) {
        [buffer setLength:0];
        return;
    }
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
                    callback([accumulatedContent copy], YES, error);
                });
            }
        } else {
            // 如果没有错误，并且之前没有收到 [DONE] 事件，则认为完成 (容错)
            dispatch_async(dispatch_get_main_queue(), ^{
                callback([accumulatedContent copy], YES, nil);
            });
            
        }
    }
    
    // 清理与此任务相关的资源
    [self cleanupTask:task];
}

// 将UIImage转换为Base64字符串
- (NSString *)base64StringFromImage:(UIImage *)image {
    if (!image) { return nil; }
    CGFloat maxDimension = 1536.0; // 最长边限制（可按需调整）
    CGSize size = image.size;
    CGFloat scale = 1.0;
    CGFloat maxSide = MAX(size.width, size.height);
    if (maxSide > maxDimension && maxSide > 0) {
        scale = maxDimension / maxSide;
    }
    CGSize targetSize = CGSizeMake(floor(size.width * scale), floor(size.height * scale));
    UIImage *resultImage = image;
    if (scale < 1.0) {
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
        fmt.scale = 1.0;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:targetSize format:fmt];
        resultImage = [renderer imageWithActions:^(UIGraphicsImageRendererContext * _Nonnull context) {
            [image drawInRect:CGRectMake(0, 0, targetSize.width, targetSize.height)];
        }];
    }
    CGFloat jpegQuality = (maxSide > 3000.0 ? 0.6 : 0.7);
    @autoreleasepool {
        NSData *imageData = UIImageJPEGRepresentation(resultImage, jpegQuality);
        return [imageData base64EncodedStringWithOptions:0];
    }
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
        dispatch_source_t timer = self.taskThrottleTimers[taskIdentifier];
        if (timer) {
            dispatch_source_cancel(timer);
            [self.taskThrottleTimers removeObjectForKey:taskIdentifier];
        }
        [self.tasksWithPendingUpdate removeObject:taskIdentifier];
    });
}


@end
