//
//  OSSUploadManager.h
//  ChatGPT-OC-Clone
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface OSSUploadManager : NSObject

+ (instancetype)sharedManager;

// 初始化（内部完成 OSSClient 配置）
- (void)setupIfNeeded;

// 上传本地图片或文件 URL，完成回调在主线程
- (void)uploadAttachments:(NSArray *)attachments
               completion:(void(^)(NSArray<NSURL *> *uploadedURLs))completion;

@end

NS_ASSUME_NONNULL_END



