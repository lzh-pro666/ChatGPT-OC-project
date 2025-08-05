//
//  AlertHelper.h
//  ChatGPT-OC-Clone
//
//  Created by mac—lzh on 2025/8/5.
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface AlertHelper : NSObject

/**
 * @brief 显示需要设置 API Key 的提示。
 * @param presenter 用于呈现弹窗的视图控制器。
 * @param settingHandler 用户点击 "立即设置" 时的回调。
 */
+ (void)showNeedAPIKeyAlertOn:(UIViewController *)presenter
             withSettingHandler:(void (^)(void))settingHandler;

/**
 * @brief 显示用于输入/修改 API Key 的弹窗。
 * @param presenter 用于呈现弹窗的视图控制器。
 * @param currentKey 当前已保存的 API Key (可为 nil)，用于在输入框中显示提示。
 * @param saveHandler 用户点击 "保存" 并输入有效 Key 后的回调，返回新的 Key。
 */
+ (void)showAPIKeyAlertOn:(UIViewController *)presenter
           withCurrentKey:(nullable NSString *)currentKey
           withSaveHandler:(void (^)(NSString *newKey))saveHandler;

/**
 * @brief 显示一个通用的错误提示弹窗。
 * @param presenter 用于呈现弹窗的视图控制器。
 * @param message 错误消息内容。
 */
+ (void)showErrorAlertOn:(UIViewController *)presenter withMessage:(NSString *)message;

/**
 * @brief 显示一个通用的成功提示弹窗。
 * @param presenter 用于呈现弹窗的视图控制器。
 * @param message 成功消息内容。
 */
+ (void)showSuccessAlertOn:(UIViewController *)presenter withMessage:(NSString *)message;

/**
 * @brief 显示一个确认操作的弹窗 (例如重置、删除等)。
 * @param presenter 用于呈现弹窗的视图控制器。
 * @param title 弹窗标题。
 * @param message 弹窗消息。
 * @param confirmTitle 确认按钮的标题 (通常是 "重置", "删除" 等)。
 * @param confirmationHandler 用户点击确认按钮后的回调。
 */
+ (void)showConfirmationAlertOn:(UIViewController *)presenter
                      withTitle:(NSString *)title
                        message:(NSString *)message
                   confirmTitle:(NSString *)confirmTitle
            confirmationHandler:(void (^)(void))confirmationHandler;

/**
 * @brief 显示模型选择菜单 (ActionSheet)。
 * @param presenter 用于呈现弹窗的视图控制器。
 * @param models 可供选择的模型名称列表。
 * @param selectionHandler 用户选择一个模型后的回调。
 */
+ (void)showModelSelectionMenuOn:(UIViewController *)presenter
                      withModels:(NSArray<NSString *> *)models
              selectionHandler:(void (^)(NSString *selectedModel))selectionHandler;

/**
 * @brief 显示权限未开启的提示。
 * @param presenter 用于呈现弹窗的视图控制器。
 * @param permissionName 权限名称, 例如 "相机" 或 "照片"。
 */
+ (void)showPermissionAlertOn:(UIViewController *)presenter for:(NSString *)permissionName;

@end

NS_ASSUME_NONNULL_END
