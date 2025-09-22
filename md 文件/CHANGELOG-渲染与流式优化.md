### 2025-09-06 渲染与流式优化变更

- 改善“拖动果冻感”：
  - 在 `AICodeBlockNode` 的增量更新中移除了同步 `layoutIfNeeded`，新增异步宽度计算，减少主线程卡顿。
  - 在 `RichMessageCellNode` 的 `immediateLayoutUpdate` 中仅使用 `setNeedsLayout`，避免同步布局引起的抖动。
  - `AICodeBlockNode` 监听内部横向拖动，向控制器广播开始/结束事件，控制器据此暂停自动粘底与UI更新。
- 语义块分割与Markdown解析：
  - `AIMarkdownParser` 预编译正则（fence/heading/numbered），避免每次解析重复创建正则。
  - 保持现有语义分割策略（围栏代码、标题、列表/引用、段落、单行）并清理空白块。
- 占位符与流式状态：
  - 流式期间不再渲染纯文本占位符（仅在非流式下启用）。
  - 流式追加时不维护 `lastParsedText/Length`，避免触发非必要的完整解析路径。
- 自动滚动协调：
  - 控制器新增 `codeBlockInteracting` 标记；代码块横向滚动时自动滚动与UI更新被暂停，交互结束后恢复。

影响：
- 代码块渲染与横向滚动更顺滑，拖动过程中不再出现“果冻”现象。
- 流式逐行渲染保持稳定，避免占位符文本与代码块双重显示。
- Markdown 解析耗时降低，主线程更平稳。

文件涉及：
- `View/AICodeBlockNode.m`
- `View/RichMessageCellNode.m`
- `Model/AIMarkdownParser.m`
- `Controller/ChatDetailViewControllerV2.m` 