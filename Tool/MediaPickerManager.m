//
//  MediaPickerManager.m
//  ChatGPT-OC-Clone
//
//  Created by mac—lzh on 2025/8/5.
//

#import "MediaPickerManager.h"



// 1. 在类扩展中，让 Manager 自己遵守所有相关的协议
@interface MediaPickerManager () <PHPickerViewControllerDelegate, UIImagePickerControllerDelegate, UINavigationControllerDelegate, UIDocumentPickerDelegate>

// 2. 持有用于 present 的 ViewController
@property (nonatomic, weak) UIViewController *presenter;

@end

@implementation MediaPickerManager

- (instancetype)initWithPresenter:(UIViewController *)presenter {
    self = [super init];
    if (self) {
        _presenter = presenter;
    }
    return self;
}

#pragma mark - Public Methods

- (void)presentPhotoPicker {
    PHPickerConfiguration *config = [[PHPickerConfiguration alloc] init];
    config.selectionLimit = 3; // 可选择多个
    config.filter = [PHPickerFilter imagesFilter];
    
    PHPickerViewController *picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self; // 将代理设置为自己
    [self.presenter presentViewController:picker animated:YES completion:nil];
}

- (void)presentCameraPicker {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    switch (status) {
        case AVAuthorizationStatusAuthorized:
            [self presentImagePickerWithSourceType:UIImagePickerControllerSourceTypeCamera];
            break;
        case AVAuthorizationStatusNotDetermined: {
            [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (granted) {
                        [self presentImagePickerWithSourceType:UIImagePickerControllerSourceTypeCamera];
                    }
                });
            }];
            break;
        }
        case AVAuthorizationStatusDenied:
        case AVAuthorizationStatusRestricted:
            // 调用 AlertHelper 来显示权限弹窗
            [AlertHelper showPermissionAlertOn:self.presenter for:@"相机"];
            break;
    }
}

- (void)presentFilePicker {
    // kUTTypeItem 允许选择所有类型的文件
    NSArray *documentTypes = @[(NSString *)kUTTypeItem];
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:documentTypes inMode:UIDocumentPickerModeImport];
    picker.delegate = self; // 将代理设置为自己
    picker.modalPresentationStyle = UIModalPresentationFullScreen;
    [self.presenter presentViewController:picker animated:YES completion:nil];
}

#pragma mark - Private Helper

- (void)presentImagePickerWithSourceType:(UIImagePickerControllerSourceType)sourceType {
    if (![UIImagePickerController isSourceTypeAvailable:sourceType]) {
        NSLog(@"数据源不可用: %ld", (long)sourceType);
        return;
    }
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.delegate = self;
    picker.sourceType = sourceType;
    [self.presenter presentViewController:picker animated:YES completion:nil];
}


#pragma mark - PHPickerViewControllerDelegate

- (void)picker:(PHPickerViewController *)picker didFinishPicking:(NSArray<PHPickerResult *> *)results {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if (results.count == 0) {
        if ([self.delegate respondsToSelector:@selector(mediaPickerDidCancel:)]) {
            [self.delegate mediaPickerDidCancel:self];
        }
        return;
    }
    
    __block NSMutableArray<UIImage *> *selectedImages = [NSMutableArray array];
    __block NSInteger loadedCount = 0;
    
    for (PHPickerResult *result in results) {
        if ([result.itemProvider canLoadObjectOfClass:[UIImage class]]) {
            [result.itemProvider loadObjectOfClass:[UIImage class] completionHandler:^(__kindof id<NSObject> _Nullable object, NSError * _Nullable error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if ([object isKindOfClass:[UIImage class]]) {
                        [selectedImages addObject:(UIImage *)object];
                    }
                    loadedCount++;
                    // 当所有图片都处理完毕后，通过代理回调
                    if (loadedCount == results.count) {
                        if ([self.delegate respondsToSelector:@selector(mediaPicker:didPickImages:)]) {
                            [self.delegate mediaPicker:self didPickImages:[selectedImages copy]];
                        }
                    }
                });
            }];
        } else {
            loadedCount++;
        }
    }
}

#pragma mark - UIImagePickerControllerDelegate (for Camera)

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    [picker dismissViewControllerAnimated:YES completion:nil];
    UIImage *image = info[UIImagePickerControllerOriginalImage];
    if (image) {
        if ([self.delegate respondsToSelector:@selector(mediaPicker:didPickImages:)]) {
            // 将单� 图片放入数组中回调
            [self.delegate mediaPicker:self didPickImages:@[image]];
        }
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
    if ([self.delegate respondsToSelector:@selector(mediaPickerDidCancel:)]) {
        [self.delegate mediaPickerDidCancel:self];
    }
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    [controller dismissViewControllerAnimated:YES completion:nil];
    NSURL *selectedURL = urls.firstObject;
    if (selectedURL) {
        if ([self.delegate respondsToSelector:@selector(mediaPicker:didPickDocumentAtURL:)]) {
            [self.delegate mediaPicker:self didPickDocumentAtURL:selectedURL];
        }
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    [controller dismissViewControllerAnimated:YES completion:nil];
    if ([self.delegate respondsToSelector:@selector(mediaPickerDidCancel:)]) {
        [self.delegate mediaPickerDidCancel:self];
    }
}

@end
