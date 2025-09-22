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
 * @brief 显示一个通用的提示弹窗。
 * @param presenter 用于呈现弹窗的视图控制器。
 * @param title 弹窗标题。
 * @param message 弹窗消息。
 * @param buttonTitle 按钮标题。
 */
+ (void)showAlertOn:(UIViewController *)presenter 
          withTitle:(NSString *)title 
            message:(NSString *)message 
       buttonTitle:(NSString *)buttonTitle;

/**
 * @brief 显示一个确认操作的弹窗。
 * @param presenter 用于呈现弹窗的视图控制器。
 * @param title 弹窗标题。
 * @param message 弹窗消息。
 * @param confirmTitle 确认按钮的标题。
 * @param confirmationHandler 用户点击确认按钮后的回调。
 */
+ (void)showConfirmationAlertOn:(UIViewController *)presenter
                      withTitle:(NSString *)title
                        message:(NSString *)message
                   confirmTitle:(NSString *)confirmTitle
            confirmationHandler:(void (^)(void))confirmationHandler;

/**
 * @brief 显示操作菜单 (ActionSheet)。
 * @param presenter 用于呈现弹窗的视图控制器。
 * @param title 弹窗标题。
 * @param actions 操作按钮数组，每个元素包含标题和回调。
 * @param cancelTitle 取消按钮标题。
 */
+ (void)showActionMenuOn:(UIViewController *)presenter
                   title:(nullable NSString *)title
                  actions:(NSArray<NSDictionary<NSString *, void (^)(void)> *> *)actions
              cancelTitle:(NSString *)cancelTitle;

/**
 * @brief 显示权限未开启的提示。
 * @param presenter 用于呈现弹窗的视图控制器。
 * @param permissionName 权限名称, 例如 "相机" 或 "照片"。
 */
+ (void)showPermissionAlertOn:(UIViewController *)presenter for:(NSString *)permissionName;

@end

NS_ASSUME_NONNULL_END
