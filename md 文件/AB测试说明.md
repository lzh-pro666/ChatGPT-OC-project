# ChatGPT-OC-Clone AB测试说明

## 概述
主控制器 `MainViewController` 现在支持AB测试功能，可以在 `ChatDetailViewController`（原版本）和 `ChatDetailViewControllerV2`（V2版本）之间切换。

## 使用方法

### 1. 静态设置（编译时）
在 `MainViewController.m` 的 `viewDidLoad` 方法中修改 `useV2Controller` 的值：

```objc
// 在viewDidLoad方法中
self.useV2Controller = NO;  // 使用原版本
// 或者
self.useV2Controller = YES; // 使用V2版本
```

### 2. 动态切换（运行时）
可以通过调用 `switchToVersion:` 方法在运行时动态切换版本：

```objc
// 切换到V2版本
[mainViewController switchToVersion:YES];

// 切换到原版本
[mainViewController switchToVersion:NO];
```

## 功能特性

1. **自动日志记录**：切换版本时会在控制台输出日志，方便调试
2. **状态保持**：切换版本时会保持当前的聊天状态
3. **智能检测**：如果尝试切换到当前已使用的版本，会自动跳过
4. **完整支持**：两个版本的所有功能都完全支持，包括菜单按钮、聊天选择等

## 控制台日志示例

```
[AB测试] 使用ChatDetailViewController
[AB测试] 已切换到V2版本
[AB测试] 使用ChatDetailViewControllerV2
```

## 注意事项

- 默认使用原版本（`ChatDetailViewController`）
- 切换版本时会重新初始化界面，但会保持当前聊天数据
- 两个版本的控制器都需要正确实现 `chat` 属性
- 建议在测试时观察控制台日志以确认版本切换成功

## 测试建议

1. 分别测试两个版本的基本功能
2. 测试版本切换时的状态保持
3. 测试菜单按钮在两个版本中的工作情况
4. 观察性能差异（如果有的话）