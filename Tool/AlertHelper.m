//
//  AlertHelper.m
//  ChatGPT-OC-Clone
//
//  Created by mac—lzh on 2025/8/5.
//

#import "AlertHelper.h"

@implementation AlertHelper

+ (void)showNeedAPIKeyAlertOn:(UIViewController *)presenter
             withSettingHandler:(void (^)(void))settingHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"需要设置 API Key"
                                                                     message:@"使用 ChatGPT 功能需要设置有效的 OpenAI API Key。立即设置吗？"
                                                              preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"稍后" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"立即设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        if (settingHandler) {
            settingHandler();
        }
    }]];

    [presenter presentViewController:alert animated:YES completion:nil];
}

+ (void)showAPIKeyAlertOn:(UIViewController *)presenter
           withCurrentKey:(nullable NSString *)currentKey
          withSaveHandler:(void (^)(NSString *newKey))saveHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"设置 API Key"
                                                                     message:@"请输入您的 OpenAI API Key"
                                                              preferredStyle:UIAlertControllerStyleAlert];

    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"sk-...";
        textField.secureTextEntry = YES;
        if (currentKey.length > 8) {
            NSString *prefix = [currentKey substringToIndex:4];
            NSString *suffix = [currentKey substringFromIndex:currentKey.length - 4];
            textField.text = [NSString stringWithFormat:@"%@•••••%@", prefix, suffix];
            textField.tag = 1; // � �记为已有 API Key，避免不修改也提示� �式错误
        }
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        UITextField *textField = alert.textFields.firstObject;
        NSString *apiKey = textField.text;

        // 如果是未修改过的已有Key的掩� �形式，则直接返回
        if (textField.tag == 1 && ![apiKey hasPrefix:@"sk-"]) {
            return;
        }

        // 简单� �式� �验
        if (apiKey.length > 10 && [apiKey hasPrefix:@"sk-"]) {
            if (saveHandler) {
                saveHandler(apiKey);
            }
        } else {
            [self showErrorAlertOn:presenter withMessage:@"API Key � �式不正确，请输入有效的 API Key"];
        }
    }]];

    [presenter presentViewController:alert animated:YES completion:nil];
}

+ (void)showErrorAlertOn:(UIViewController *)presenter withMessage:(NSString *)message {
    [self showAlertOn:presenter withTitle:@"错误" message:message buttonTitle:@"确定"];
}

+ (void)showSuccessAlertOn:(UIViewController *)presenter withMessage:(NSString *)message {
    [self showAlertOn:presenter withTitle:@"成功" message:message buttonTitle:@"确定"];
}

+ (void)showConfirmationAlertOn:(UIViewController *)presenter
                      withTitle:(NSString *)title
                        message:(NSString *)message
                   confirmTitle:(NSString *)confirmTitle
            confirmationHandler:(void (^)(void))confirmationHandler {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:confirmTitle style:UIAlertActionStyleDestructive handler:^(UIAlertAction * _Nonnull action) {
        if (confirmationHandler) {
            confirmationHandler();
        }
    }]];

    [presenter presentViewController:alert animated:YES completion:nil];
}

+ (void)showModelSelectionMenuOn:(UIViewController *)presenter
                      withModels:(NSArray<NSString *> *)models
              selectionHandler:(void (^)(NSString *selectedModel))selectionHandler {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"选择模型"
                                                                                message:nil
                                                                         preferredStyle:UIAlertControllerStyleActionSheet];
    
    for (NSString *modelName in models) {
        [alertController addAction:[UIAlertAction actionWithTitle:modelName style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
            if (selectionHandler) {
                selectionHandler(action.title);
            }
        }]];
    }

    [alertController addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];

    [presenter presentViewController:alertController animated:YES completion:nil];
}

+ (void)showPermissionAlertOn:(UIViewController *)presenter for:(NSString *)permissionName {
    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
    NSString *title = [NSString stringWithFormat:@"“%@”权限未开启", permissionName];
    NSString *message = [NSString stringWithFormat:@"请在iPhone的“设置 > %@”中允许访问%@。", appName, permissionName];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"去设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
    }]];
    
    [presenter presentViewController:alert animated:YES completion:nil];
}


#pragma mark - Private Helper

// 内部私有方法，用于简化成功和错误弹窗的创建
+ (void)showAlertOn:(UIViewController *)presenter withTitle:(NSString *)title message:(NSString *)message buttonTitle:(NSString *)buttonTitle {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:buttonTitle style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
}

@end
