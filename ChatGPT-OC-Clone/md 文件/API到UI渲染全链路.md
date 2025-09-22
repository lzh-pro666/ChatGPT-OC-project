### 从 API 请求到 UI 渲染的流式全链路（ChatDetailViewControllerV2 → APIManager → SemanticBlockParser → RichMessageCellNode）

本文聚焦“请求 API → 收到流式回复 → 富文本渲染到 UI”的完整链路，梳理关键方法、数据流向与所用技术。涉及组件：`ChatDetailViewControllerV2`、`APIManager`、`SemanticBlockParser`、`RichMessageCellNode`、`CoreDataManager`、`ASTableNode`。

---

## 总览
- 控制器发起流式请求（SSE）
- API 层按帧解析/节流回调“全量文本”
- 控制器后台语义分块 → 主线程增量渲染
- 首包切换“思考行”为“答案行”并绑定当前 AI 节点
- 富文本节点按“语义块→行”逐步追加，保持粘底
- 完成/错误收尾并持久化

---

## 1) 控制器发起流式请求（SSE）
入口：用户消息入库并插入 UI 后，`ChatDetailViewControllerV2` 进入等待态并插入 `ThinkingNode`，随后构建历史消息，分支处理多模态并发起文本对话流。

- 思考态与历史构建：`simulateAIResponse`
- 多模态意图分类（可选）：`[[APIManager sharedManager] classifyIntentWithMessages: ...]`
- 文本对话流：
  - 纯文本或“理解”分支：`[[APIManager sharedManager] streamingChatCompletionWithMessages:images:nil streamCallback:^...]`
  - 或按调用级别指定 baseURL/model/key：`streamingChatCompletionWithMessages:model:baseURL:apiKey:streamCallback:`

关键状态（控制器持有）：
- `self.currentStreamingTask`：当前 SSE 任务
- `self.fullResponseBuffer`：累计模型的“全量文本”快照
- `self.semanticParser`：`SemanticBlockParser` 实例
- `self.semanticQueue`：解析/准备数据的串行队列（后台）
- `self.isAIThinking`、`self._currentUpdatingAINode`、`self.currentUpdatingAIMessage`

---

## 2) API 层：SSE 流与节流回调（APIManager）
`APIManager` 负责：构造请求（`Accept: text/event-stream`）、维持任务状态、在 `NSURLSessionDataDelegate` 中解析 SSE、节流 UI 回调。

要点：
- 每个任务维护字典状态：回调、缓冲区、累计文本、完成标记
- `didReceiveData:` 中以 `\n\n` 或 `\r\n\r\n` 分隔事件，提取 `data:` 行，解析 JSON 并获取 `choices[0].delta.content`
- 将增量内容线程安全地追加到“累计文本”中
- 通过 `dispatch_source_t` 定时器每 ~16ms 触发一次回调（防抖/节流），避免高频 UI 抖动
- 收到 `[DONE]` 或任务完成时做最终回调与清理

最终回调签名（主线程触发）：
- `^(NSString *partialResponse, BOOL isDone, NSError *error)`
  - `partialResponse`：当前“全量文本”快照
  - `isDone`：本轮是否结束
  - `error`：错误对象（含 HTTP 非 200、网络异常等）

---

## 3) 控制器：后台语义分块 → 主线程应用
控制器在回调中采用“后台准备、主线程渲染”的模式：

- 后台（`semanticQueue`）：
  - 将回调的 `partialResponse` 作为“全量文本”写入 `fullResponseBuffer`
  - 当未暂停 UI 更新时，调用 `SemanticBlockParser.consumeFullText:isDone:` 计算“新增语义块”数组（保证分块边界稳定：标题/列表/段落/围栏代码）

- 主线程：
  - `ui_applyPreparedBlocks:isDone:thinkingIndexPath:` 将块增量写入 UI：
    - 若仍处于 `isAIThinking`（首包）：
      - 在 `CoreData` 插入一条“空 AI 消息”（占位持久化）
      - 插入新行（答案行），移除思考行，记录 `_currentUpdatingAINode`
      - 将第一批语义块追加到该节点
    - 否则：直接将语义块继续追加到 `_currentUpdatingAINode`
  - `isDone` 时：将 `fullResponseBuffer` 写回 `currentUpdatingAIMessage.content` 并 `saveContext`

暂停策略：
- 若用户滚动/代码块横向滚动导致 `isUIUpdatePaused=YES`，非完成帧不做 UI 应用，待恢复后继续。

---

## 4) 富文本节点：语义块 → 可视行增量渲染（RichMessageCellNode）
控制器只负责把“语义块”喂给当前 AI 节点；节点内部负责把每个块切分为“可视行”并逐行渲染：

- `appendSemanticBlocks:isFinal:`：将块入队并开启处理
- 后台用 `AIMarkdownParser` 解析块，生成该块的“逐行任务”（文本行/代码行）
- 主线程调度：`scheduleNextLineTask` → `performNextLineTask`
  - 首行追加前发送 `RichMessageCellNodeWillAppendFirstLine`，控制器据此“移除思考行+粘底”
  - 文本行：创建 `ASTextNode` 追加；代码行：复用/创建 `AICodeBlockNode` 并追加
  - 每行完成后合并下一帧发送 `RichMessageCellNodeDidAppendLine`，控制器据此粘底

节点模式：
- 流式阶段 `isStreamingMode=YES`，轻量更新与无动画布局，保证手势响应
- 完成阶段 `completeStreamingUpdate` 强制完整解析与无动画最终布局，确保富文本效果一致

---

## 5) 粘底与交互
- 逐行事件：控制器在 `handleRichMessageWillAppendFirstLine:` 与 `handleRichMessageAppendLine:` 中执行“锚定到底部”（在用户未主动上滑时）
- 代码块横向滚动期间：暂停粘底与 UI 更新（控制器通知 Cell `pauseStreamingAnimation`），结束后 `resumeStreamingAnimation` 并继续推进

---

## 6) 错误与取消处理
- 取消（`NSURLErrorCancelled`）：移除思考行，静默结束
- 首包错误：移除思考行并插入一条错误消息（AI 气泡），退出等待态
- 后续错误：在已渲染的末尾追加错误提示后缀并持久化，退出等待态
- API 层对 HTTP 非 200 也会构造错误回调（并清理定时器/状态）

---

## 7) 数据流向（API → UI）
- APIManager（SSE）
  → 每 ~16ms 节流回调（全量文本快照）
  → ChatDetailViewControllerV2（后台语义分块→主线程 UI 应用）
  → 首包：CoreData 插入空 AI 消息 + ASTableNode 插入答案行 + 移除思考行
  → `_currentUpdatingAINode` 追加“语义块→行”
  → 富文本节点逐行渲染 + 逐行通知粘底
  → 完成：写回 CoreData 并保存

---

## 8) 关键方法速查（按调用顺序）
- 控制器发起与编排：
  - `simulateAIResponse`
  - `ui_applyPreparedBlocks:isDone:thinkingIndexPath:`
  - `appendBlocks:isFinal:toNode:`、`transitionThinkingToAnswerAndAppendBlocks:isFinal:toNode:`
  - 逐行事件：`handleRichMessageWillAppendFirstLine:`、`handleRichMessageAppendLine:`
- API（SSE）：
  - `streamingChatCompletionWithMessages:images:streamCallback:`（或 per-call 变体）
  - `URLSession:dataTask:didReceiveData:`（SSE 解析与累计）
  - 定时器节流回调（~16ms）
- 语义分块：
  - `SemanticBlockParser.consumeFullText:isDone:`
- 富文本节点：
  - `appendSemanticBlocks:isFinal:` → `processNextSemanticBlockIfIdle`
  - `buildLineTasksForBlockText:completion:`（后台生成行任务）
  - `scheduleNextLineTask` → `performNextLineTask`（首行事件、文本/代码行追加、逐行通知）
  - `pauseStreamingAnimation` / `resumeStreamingAnimation` / `completeStreamingUpdate`
- 持久化：
  - `CoreDataManager addMessageToChat` / `saveContext`

---

## 9) 用到的技术
- **SSE 流式**：`Accept: text/event-stream`，逐事件解析，`choices[].delta.content` 增量拼接
- **节流/并发**：`dispatch_source_t` 定时器主线程节流；后台串行队列做语义分块；主线程做 UI 应用
- **Texture（AsyncDisplayKit）**：`ASTableNode` 批量插入、无动画贴底；`ASCellNode` 异步布局
- **Markdown/代码块**：`AIMarkdownParser` + `AICodeBlockNode`，支持围栏代码与行级追加
- **语义分块**：保证块边界稳定，避免半句/半段抖动
- **CoreData**：AI 首包即刻插入空消息，完成或中断时写回，支持恢复
- **交互友好**：代码块横向滚动暂停 UI 推进，逐行通知与粘底防抖

---

## 10) 典型时序（概要）
1. APIManager（SSE）→ 节流回调“全量文本”
2. Controller 后台 `consumeFullText` → 得到“新增语义块”
3. 主线程：
   - 首包：CoreData 插入空 AI 消息 → ASTableNode 插入答案行 → 移除思考行
   - 继续：将块喂给 `_currentUpdatingAINode`
4. Cell 将块切行并逐行渲染；逐行事件驱动粘底
5. 结束：保存最终文本到 CoreData；Cell 做完整解析与最终布局





