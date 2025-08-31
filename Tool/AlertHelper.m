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
            textField.tag = 1; // 标记为已有 API Key，避免不修改也提示格式错误
        }
    }];

    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        UITextField *textField = alert.textFields.firstObject;
        NSString *apiKey = textField.text;

        // 如果是未修改过的已有Key的掩码形式，则直接返回
        if (textField.tag == 1 && ![apiKey hasPrefix:@"sk-"]) {
            return;
        }

        // 简单格式验证
        if (apiKey.length > 10 && [apiKey hasPrefix:@"sk-"]) {
            if (saveHandler) {
                saveHandler(apiKey);
            }
        } else {
            [self showAlertOn:presenter withTitle:@"错误" message:@"API Key 格式不正确，请输入有效的 API Key" buttonTitle:@"确定"];
        }
    }]];

    [presenter presentViewController:alert animated:YES completion:nil];
}

+ (void)showAlertOn:(UIViewController *)presenter withTitle:(NSString *)title message:(NSString *)message buttonTitle:(NSString *)buttonTitle {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                     message:message
                                                              preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:buttonTitle style:UIAlertActionStyleDefault handler:nil]];
    [presenter presentViewController:alert animated:YES completion:nil];
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

+ (void)showActionMenuOn:(UIViewController *)presenter
                   title:(nullable NSString *)title
                  actions:(NSArray<NSDictionary<NSString *, void (^)(void)> *> *)actions
              cancelTitle:(NSString *)cancelTitle {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:title
                                                                              message:nil
                                                                       preferredStyle:UIAlertControllerStyleActionSheet];
    
    // 添加操作按钮
    for (NSDictionary *actionDict in actions) {
        NSString *actionTitle = actionDict.allKeys.firstObject;
        void (^actionHandler)(void) = actionDict.allValues.firstObject;
        
        if (actionTitle && actionHandler) {
            UIAlertAction *action = [UIAlertAction actionWithTitle:actionTitle 
                                                             style:UIAlertActionStyleDefault 
                                                           handler:^(UIAlertAction * _Nonnull action) {
                actionHandler();
            }];
            [alertController addAction:action];
        }
    }

    // 添加取消按钮
    [alertController addAction:[UIAlertAction actionWithTitle:cancelTitle style:UIAlertActionStyleCancel handler:nil]];

    // iPad 需要设置 popover 的锚点
    UIPopoverPresentationController *popover = alertController.popoverPresentationController;
    if (popover) {
        popover.sourceView = presenter.view;
        popover.sourceRect = presenter.view.bounds;
        popover.permittedArrowDirections = UIPopoverArrowDirectionAny;
    }

    [presenter presentViewController:alertController animated:YES completion:nil];
}

+ (void)showPermissionAlertOn:(UIViewController *)presenter for:(NSString *)permissionName {
    NSString *appName = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleName"];
    NSString *title = [NSString stringWithFormat:@"\"%@\"权限未开启", permissionName];
    NSString *message = [NSString stringWithFormat:@"请在iPhone的\"设置 > %@\"中允许访问%@。", appName, permissionName];
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title message:message preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"知道了" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"去设置" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        [[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString] options:@{} completionHandler:nil];
    }]];
    
    [presenter presentViewController:alert animated:YES completion:nil];
}

@end
