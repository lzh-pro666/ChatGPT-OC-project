//
//  ResponseParsingTask.h
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant on 2024/08/13.
//

#import <Foundation/Foundation.h>

@class ParserResult;

NS_ASSUME_NONNULL_BEGIN

/**
 * 通用文本解析任务类
 * 用于优化文本解析性能，减少UI阻塞
 * 适用于任何需要实时解析文本的场景
 */
@interface ResponseParsingTask : NSObject

/**
 * 异步解析文本，减少UI阻塞
 * @param text 要解析的文本
 * @param completion 解析完成回调
 */
- (void)parseText:(NSString *)text 
       completion:(void(^)(NSArray<ParserResult *> *results))completion;

/**
 * 批量解析文本，减少解析次数
 * @param text 要解析的文本
 * @param threshold 解析阈值
 * @param completion 解析完成回调
 */
- (void)parseTextWithThreshold:(NSString *)text 
                     threshold:(NSInteger)threshold
                    completion:(void(^)(NSArray<ParserResult *> *results))completion;

/**
 * 检查是否需要重新解析
 * @param newText 新文本
 * @param lastParsedText 上次解析的文本
 * @param threshold 解析阈值
 * @return 是否需要重新解析
 */
+ (BOOL)shouldReparseText:(NSString *)newText 
            lastParsedText:(NSString *)lastParsedText 
                 threshold:(NSInteger)threshold;

@end

NS_ASSUME_NONNULL_END
