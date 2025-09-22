# API 与 UI 优化变更说明

## 背景
- 项目为 ChatGPT iOS 聊天 App（Texture 实现），默认文本模型来自顶部栏选择（默认 gpt-4o）。
- 发送带图消息时，需要先使用 gpt-4o 进行“生成/理解”分类，然后：
  - 图片理解：走 DashScope 兼容 OpenAI 的聊天接口（qvq-plus）。
  - 图片生成：走 DashScope 图片生成接口（qwen-image-edit）。
- 目标：图片理解/生成的调用与默认聊天配置解耦，不覆盖全局 `baseURL/apiKey/model`，避免串扰。

## 主要改动

### 1) API 分离（按调用级别传参）
文件：`Model/APIManager.h/.m`
- 新增按调用级别传参的流式方法（不污染全局设置）：
  - `streamingChatCompletionWithMessages:model:baseURL:apiKey:streamCallback:`
- 新增按调用级别传参的图片生成方法：
  - `generateImageWithPrompt:baseImageURL:apiKey:completion:`
- 保留原有方法以兼容默认聊天：
  - `streamingChatCompletionWithMessages:images:streamCallback:`（走全局设置）
  - `generateImageWithPrompt:baseImageURL:completion:`（走全局 Key）
- `classifyIntentWithMessages` 固定请求体中 `model=gpt-4o`，走当前 `currentBaseURL/currentApiKey`，不受顶部栏模型影响。

效果：
- 普通聊天继续使用全局设置；
- 图片理解/生成场景改为“每次调用直连指定端点+Key”，不再改写全局值。

### 2) 控制器调用改造
文件：`Controller/ChatDetailViewControllerV2.m`
- 带图消息时：
  - 先 `classifyIntentWithMessages`（gpt-4o）。
  - 若“生成”：直接调用 `generateImageWithPrompt:baseImageURL:apiKey:`（DashScope Key）
  - 若“理解”：调用 `streamingChatCompletionWithMessages:model:baseURL:apiKey:` 直连 DashScope 兼容接口（qvq-plus）。
- 删除了原先“切换全局 baseURL/apiKey/model，结束后恢复”的代码，改为按调用级别传参。

### 3) 思考视图可显示提示文案
文件：`View/ThinkingNode.h/.m`, `ChatDetailViewControllerV2.m`
- 为 `ThinkingNode` 新增 `setHintText:`，在思考气泡内展示一行提示文本。
- 发送带图消息时：
  - 初始显示“正在分析图片意图…”。
  - 分类后更新为“当前正在进行图片生成”或“当前正在进行图片理解”。

### 4) 发送按钮状态恢复
文件：`ChatDetailViewControllerV2.m`
- 修复图片生成完成后未恢复发送按钮的问题：
  - 在生成成功或失败的回调中调用 `exitAwaitingState` 恢复按钮图标与可用性。

### 5) 切换聊天界面时的闪动优化
文件：`ChatDetailViewControllerV2.m`, `MainViewController.m`
- 在 `ChatDetailViewControllerV2` 中重写 `setChat:`：
  - 终止当前流与思考状态，清空输入与附件，预加载新聊天数据并 `reloadData`，`forceScrollToBottomAnimated:NO`。
- 在 `MainViewController.didSelectChat:` 中：
  - 先调用 `applyChat:`（触发上述预刷新），再 `popToRootViewControllerAnimated:YES`，避免“先返回旧界面，再刷新成新聊天”的视觉跳变。

## 使用说明（数据流）
- 普通聊天：
  - 构建 `messages` → `streamingChatCompletionWithMessages:images:nil:...`（走全局配置）→ SSE 流式渲染。
- 带图聊天：
  - 上传附件 → 附加为规范化“附件链接”显示 → `classifyIntentWithMessages`（gpt-4o）→
    - 生成：`generateImageWithPrompt:baseImageURL:apiKey:` → 返回图片 URL 列表 → 插入 AI 消息。
    - 理解：构造 `{image_url,text}` 内容 → `streamingChatCompletionWithMessages:model:baseURL:apiKey:`（qvq-plus）→ 流式渲染。

## 影响面
- 不改变默认聊天的全局设置；
- 多模态任务完全独立配置；
- 切换聊天时界面切换更顺滑；
- 发送带图消息时的思考态更明确（提示当前任务类型）；
- 生成任务结束后发送按钮状态即时恢复。
