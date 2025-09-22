### ChatDetailViewControllerV2 方法索引与调用关系

说明：逐一列出本文件的方法，包含用途与内部/外部调用关系（仅列出与业务相关的方法调用；UIKit 布局/属性设置等常规调用不一一列出）。

---

#### - (NSString *)displayTitleForModelName:(NSString *)modelName
- 用途: 将内部模型名映射为展示标题。
- 调用: 无。
- 被调: setupHeader, updateModelSelection:

#### - (void)viewDidLoad
- 用途: 初始化状态、UI、数据与通知；完成基本依赖初始化。
- 调用: setupViews, fetchMessages, updatePlaceholderVisibility, updateSendButtonState, setupNotifications, loadUserSettings, [[OSSUploadManager sharedManager] setupIfNeeded], KVO 注册。

#### - (void)viewDidAppear:(BOOL)animated
- 用途: 首次可见或回到前台后处理延迟的 reload/滚动。
- 调用: fetchMessages, tableNode reloadData, forceScrollToBottomAnimated:

#### - (void)viewWillDisappear:(BOOL)animated
- 用途: 离开页面时收尾，取消流式任务、持久化当前回复等。
- 调用: [[APIManager sharedManager] cancelStreamingTask:], persistPartialAIMessageIfNeeded, tableNode reloadData。

#### - (void)dealloc
- 用途: 释放资源，移除观察者，取消任务/防抖。
- 调用: removeObserver, [[APIManager sharedManager] cancelStreamingTask:], dispatch_block_cancel。

#### - (void)setupNotifications
- 用途: 注册键盘、应用生命周期、富文本渲染及代码块交互等通知。
- 调用: addObserver -> keyboardWillShow:, keyboardWillHide:, applicationWillResignActive:, applicationDidEnterBackground:, handleAttachmentPreview:, handleRichMessageAppendLine:, handleRichMessageWillAppendFirstLine:, _onCodeBlockPanBegan:, _onCodeBlockPanEnded:

#### - (void)loadUserSettings
- 用途: 读取用户设置（API Key、默认提示、模型名）并配置 APIManager；无 Key 时提示用户设置。
- 调用: [APIManager sharedManager] setApiKey:/defaultSystemPrompt/currentModelName, showNeedAPIKeyAlert。

#### - (void)setupViews
- 用途: 构建基础界面结构：头部导航/输入区域/消息列表约束。
- 调用: setupHeader, setupInputArea。

#### - (void)setupHeader
- 用途: 构建导航栏（菜单按钮、模型标题按钮、刷新按钮）。
- 调用: displayTitleForModelName:, handleMenuTap, showModelSelectionMenu:, resetAPIKey。

#### - (void)handleMenuTap
- 用途: 透传菜单点击给上层。
- 调用: [menuDelegate chatDetailDidTapMenu]。

#### - (void)setupInputArea
- 用途: 构建输入区（背景、缩略图容器、输入框、工具栏、发送/添加按钮、占位符），建立约束与高度控制。
- 调用: updateAttachmentsDisplay（通过后续事件触发）、updateSendButtonState（通过后续事件触发）。

#### - (void)fetchMessages
- 用途: 加载当前会话消息；如为空，插入欢迎语。
- 调用: [[CoreDataManager sharedManager] fetchMessagesForChat:], addMessageToChat:

#### - (NSArray *)attachmentsAtIndexPath:(NSIndexPath *)indexPath
- 用途: 解析某条消息的附件 URL 列表（思考行返回空）。
- 调用: [MessageContentUtils parseAttachmentURLsFromContent:].

#### - (void)keyboardWillShow:(NSNotification *)notification
- 用途: 键盘出现时调整输入区位置，并在接近底部时尝试粘底。
- 调用: performAutoScrollWithContext:animated:

#### - (void)keyboardWillHide:(NSNotification *)notification
- 用途: 键盘隐藏时复位输入区位置，并在接近底部时尝试粘底。
- 调用: performAutoScrollWithContext:animated:

#### - (void)addButtonTapped:(UIButton *)sender
- 用途: 展示自定义附件选择菜单。
- 调用: [CustomMenuView showInView:atPoint:], 设置 delegate。

#### - (void)sendOrPauseButtonTapped
- 用途: 根据当前状态决定发送或暂停。
- 调用: handlePauseTapped 或 sendButtonTapped。

#### - (void)sendButtonTapped
- 用途: 读取输入与附件；如有附件先上传，之后追加消息并发起 AI 回复。
- 调用: [[OSSUploadManager sharedManager] uploadAttachments:completion:], updateAttachmentsDisplay, textViewDidChange:, addMessageWithText:attachments:isFromUser:completion:, enterAwaitingState, simulateAIResponse。

#### - (void)persistPartialAIMessageIfNeeded
- 用途: 在切换或离开时持久化当前未完成的 AI 内容到 Core Data。
- 调用: [currentUpdatingAIMessage setValue:forKey:], [[CoreDataManager sharedManager] saveContext]。

#### - (void)setChat:(id)chat
- 用途: 切换会话：保存当前未完成回复，重置状态，预加载新消息并滚动到底部或延期处理。
- 调用: persistPartialAIMessageIfNeeded, [[APIManager sharedManager] cancelStreamingTask:], updateAttachmentsDisplay, updateSendButtonState, [[CoreDataManager sharedManager] fetchMessagesForChat:], tableNode reloadData, forceScrollToBottomAnimated:

#### - (void)handleAttachmentPreview:(NSNotification *)note
- 用途: 显示附件预览浮层。
- 调用: [ImagePreviewOverlay presentInView:image:imageURL:].

#### - (CGPoint)_bottomContentOffsetForTable:(UITableView *)tv
- 用途: 计算粘底所需的 contentOffset。
- 调用: 无。

#### - (NSInteger)tableNode:numberOfRowsInSection:
- 用途: 返回行数，考虑思考行。
- 调用: 无。

#### - (ASCellNodeBlock)nodeBlockForRowAtIndexPath:
- 用途: 为每行构造 Cell 节点；思考行返回 ThinkingNode，消息行返回 RichMessageCellNode。
- 调用: messageAtIndexPath:, isMessageFromUserAtIndexPath:, attachmentsAtIndexPath:；RichMessageCellNode setLineRenderInterval:/setCodeLineRenderInterval:/setAttachments:。

#### - (void)scrollToBottom
- 用途: 异步请求滚动到底部。
- 调用: ensureBottomVisible:

#### - (BOOL)isNearBottomWithTolerance:
- 用途: 判断当前是否处于“接近底部”。
- 调用: 无。

#### - (void)anchorScrollToBottomIfNeeded
- 用途: 需要时请求一次粘底（事件合并/防抖）。
- 调用: shouldPerformAutoScroll, requestBottomAnchorWithContext:

#### - (void)ensureBottomVisible:(BOOL)animated
- 用途: 保证底部可见（可选动画）。
- 调用: performAutoScrollWithContext:animated:

#### - (void)handleRichMessageAppendLine:(NSNotification *)note
- 用途: 逐行渲染追加时请求粘底（合并到下一帧）。
- 调用: requestBottomAnchorWithContext:

#### - (void)updateAttachmentsDisplay
- 用途: 重建缩略图行并通过动画展开/收起，更新输入区约束与发送按钮。
- 调用: generateThumbnailForURL:completion:, updateSendButtonState。

#### - (void)deleteAttachmentAtIndex:(NSInteger)index
- 用途: 删除指定附件，更新视图与数据。
- 调用: updateAttachmentsDisplay。

#### - (void)generateThumbnailForURL:completion:
- 用途: 通过 QuickLook 生成文件缩略图。
- 调用: [QLThumbnailGenerator sharedGenerator] generateBestRepresentationForRequest:completionHandler:

#### - (void)customMenuViewDidSelectItemAtIndex:
- 用途: 响应菜单选择，弹出相应选择器。
- 调用: presentPhotoPicker/presentCameraPicker/presentFilePicker（MediaPickerManager）。

#### - (void)mediaPicker:didPickImages:
- 用途: 接收图片选择结果，更新附件与 UI。
- 调用: updateAttachmentsDisplay, updateSendButtonState。

#### - (void)mediaPicker:didPickDocumentAtURL:
- 用途: 接收文件选择结果，更新附件与 UI。
- 调用: updateAttachmentsDisplay, updateSendButtonState。

#### - (void)textViewDidChange:
- 用途: 同步占位符/发送按钮，按 sizeThatFits 进行 1～4 行高度自适应，并在需要时粘底。
- 调用: updatePlaceholderVisibility, updateSendButtonState, scrollToBottom。

#### - (void)updatePlaceholderVisibility
- 用途: 控制占位文字显隐。
- 调用: 无。

#### - (void)updateSendButtonState
- 用途: 根据等待状态与输入/附件是否存在控制发送按钮外观与可用性。
- 调用: 无。

#### - (BOOL)textView:shouldChangeTextInRange:replacementText:
- 用途: 阻止空输入时的换行。
- 调用: 无。

#### - (BOOL)textViewShouldBeginEditing:
- 用途: 开始编辑时强制滚动到底部。
- 调用: forceScrollToBottomAnimated:

#### - (void)simulateAIResponse
- 用途: 发起与模型的流式交互；思考占位 ->（可选）图片意图分类 -> 文本/多模态流式 -> 逐块渲染 -> 收尾持久化。
- 调用（关键）: enterAwaitingState, tableNode insertRows/deleteRows, buildMessageHistory, [[APIManager sharedManager] classifyIntentWithMessages:completion:], [[APIManager sharedManager] streamingChatCompletionWithMessages:... streamCallback:], [[APIManager sharedManager] generateImageWithPrompt:... completion:], anchorScrollToBottomIfNeeded, performUpdatesPreservingBottom, transitionThinkingToAnswerAndAppendBlocks:isFinal:toNode:, appendBlocks:isFinal:toNode:, [[CoreDataManager sharedManager] addMessageToChat:...], [[CoreDataManager sharedManager] saveContext], exitAwaitingState。

#### - (void)addMessageWithText:attachments:isFromUser:completion:
- 用途: 将消息写入 Core Data，并直接追加到内存数据源与表格末尾。
- 调用: [[CoreDataManager sharedManager] addMessageToChat:], tableNode performBatchUpdates/insertRows, scrollToBottom（无动画版本）。

#### - (NSMutableArray *)buildMessageHistory
- 用途: 构造用于调用模型的历史消息（系统提示 + 近 8 条消息）。
- 调用: [APIManager sharedManager].defaultSystemPrompt, self.messages 遍历。

#### - (NSString *)latestUserPlainText
- 用途: 提取最近一条用户消息的纯文本（去掉附件块）。
- 调用: [MessageContentUtils displayTextByStrippingAttachmentBlock:].

#### - (void)showAPIKeyAlert
- 用途: 弹出设置 API Key 的对话框并保存。
- 调用: [AlertHelper showAPIKeyAlertOn:withSaveHandler:], [[APIManager sharedManager] setApiKey:], [AlertHelper showAlertOn:withTitle:message:buttonTitle:].

#### - (void)showNeedAPIKeyAlert
- 用途: 当未设置 API Key 时提示用户设置。
- 调用: [AlertHelper showNeedAPIKeyAlertOn:withSettingHandler:], showAPIKeyAlert。

#### - (void)resetAPIKey
- 用途: 清除并重置保存的 API Key。
- 调用: [AlertHelper showConfirmationAlertOn:... confirmationHandler:], [[APIManager sharedManager] setApiKey:], showAPIKeyAlert。

#### - (void)enterAwaitingState / - (void)exitAwaitingState
- 用途: 进入/退出等待回复状态，联动发送按钮展示。
- 调用: updateSendButtonState。

#### - (void)handlePauseTapped
- 用途: 主动终止当前回复；若仍处思考行则移除并插入“未完成”提示；若已开始流式则持久化已有内容。
- 调用: [[APIManager sharedManager] cancelStreamingTask:], tableNode deleteRows, addMessageWithText:attachments:isFromUser:completion:, [[CoreDataManager sharedManager] saveContext], tableNode reloadData, exitAwaitingState。

#### - (NSString *)displayTitleForModelName:(NSString *)modelName
- 用途: 模型名到展示名的映射函数（重复列于顶部声明）。
- 调用: 无。

#### - (void)applicationDidEnterBackground:
- 用途: 后台化时取消流式任务。
- 调用: [[APIManager sharedManager] cancelStreamingTask:].

#### - (void)applicationWillResignActive:
- 用途: 退活前持久化未完成回复。
- 调用: persistPartialAIMessageIfNeeded。

#### - (void)scrollViewWillBeginDragging:
- 用途: 用户开始拖动时暂停 UI 更新并取消待执行的粘底任务。
- 调用: pauseUIUpdates, dispatch_block_cancel。

#### - (void)scrollViewDidEndDragging:willDecelerate:
- 用途: 结束拖动；若不减速则恢复 UI 更新；记录减速状态。
- 调用: resumeUIUpdates。

#### - (void)scrollViewDidEndDecelerating:
- 用途: 结束减速，恢复 UI 更新。
- 调用: resumeUIUpdates。

#### - (ASSizeRange)tableNode:constrainedSizeForRowAtIndexPath:
- 用途: 为每行提供稳定的宽度范围，利于正确计算高度。
- 调用: 无。

#### - (NSString *)messageAtIndexPath:
- 用途: 取出并处理一条消息的可展示文本（剥离附件块）。
- 调用: [MessageContentUtils displayTextByStrippingAttachmentBlock:].

#### - (BOOL)isMessageFromUserAtIndexPath:
- 用途: 判断消息是否来自用户。
- 调用: 无。

#### - (BOOL)isIndexPathCurrentAINode:
- 用途: 判断某行是否为当前正在更新的 AI 消息。
- 调用: 比较 message.objectID 与 currentUpdatingAIMessage.objectID。

#### - (BOOL)gestureRecognizer:shouldRecognizeSimultaneouslyWithGestureRecognizer:
- 用途: 允许与子视图手势同时识别，保证代码块等可滚动。
- 调用: 无。

#### - (void)performUpdatesPreservingBottom:
- 用途: 在保持底部可见的前提下批量更新 UI（下一帧统一粘底）。
- 调用: shouldPerformAutoScroll, requestBottomAnchorWithContext:

#### - (void)pauseUIUpdates / - (void)resumeUIUpdates
- 用途: 暂停/恢复 UI 更新与富文本节点的逐行动画。
- 调用: RichMessageCellNode pauseStreamingAnimation/resumeStreamingAnimation（若实现）。

#### - (void)performAutoScrollWithContext: / - (void)performAutoScrollWithContext:animated:
- 用途: 执行一次粘底滚动（可选动画）。
- 调用: shouldPerformAutoScroll, _bottomContentOffsetForTable:。

#### - (void)requestBottomAnchorWithContext:
- 用途: 事件驱动的粘底请求（防抖合并）。
- 调用: performAutoScrollWithContext:animated:

#### - (BOOL)shouldPerformAutoScroll
- 用途: 统一判定是否应自动粘底（用户拖动/减速/代码块交互/接近底部等条件）。
- 调用: isNearBottomWithTolerance:

#### - (void)observeValueForKeyPath:ofObject:change:context:
- 用途: 监听 contentSize 变化，内容高度显著增长时尝试粘底。
- 调用: requestBottomAnchorWithContext:

#### - (void)_onCodeBlockPanBegan: / - (void)_onCodeBlockPanEnded:
- 用途: 代码块横向滚动开始/结束时暂停/恢复 UI 更新。
- 调用: pauseUIUpdates, resumeUIUpdates。

#### - (void)handleRichMessageWillAppendFirstLine:
- 用途: 在首行即将渲染时请求粘底。
- 调用: requestBottomAnchorWithContext:

#### - (void)forceScrollToBottomAnimated:
- 用途: 无条件滚动到底部（跳过 shouldPerformAutoScroll 判定）。
- 调用: _bottomContentOffsetForTable:。

#### - (void)removeThinkingRowIfNeeded
- 用途: 若存在思考行则将其移除。
- 调用: tableNode deleteRows。

#### - (void)appendBlocks:isFinal:toNode:
- 用途: 向当前富文本节点追加渲染块；兼容旧接口 fallback。
- 调用: [node appendSemanticBlocks:isFinal:] 或 [node updateMessageText:], anchorScrollToBottomIfNeeded。

#### - (void)transitionThinkingToAnswerAndAppendBlocks:isFinal:toNode:
- 用途: 从思考行切换到答复行并继续块渲染。
- 调用: removeThinkingRowIfNeeded, appendBlocks:isFinal:toNode:

---

生成时间以当前代码为准，如有方法增删请同步更新本文档。
