### RichMessageCellNode 方法索引与调用关系

说明：逐一列出本文件的方法，包含用途与内部调用的方法（UIKit/基础库常规调用未完全列出）。

---

#### - (instancetype)initWithMessage:(NSString *)message isFromUser:(BOOL)isFromUser
- 用途: 初始化富文本消息节点，配置子节点与初始解析/缓存。
- 调用: parseMessage:, cachedHeightForText:width:。

#### - (void)didLoad
- 用途: 节点加载完成后的样式初始化与 displayLink 设置。
- 调用: 无（仅系统 API 与属性设置）。

#### - (ASLayoutSpec *)layoutSpecThatFits:(ASSizeRange)constrainedSize
- 用途: 计算并返回本节点的布局规格（文本/附件/气泡排列与尺寸）。
- 调用: preferredTextMaxWidth, createAttachmentThumbNode:, attributedStringForText:。

#### - (ASDisplayNode *)createAttachmentThumbNode:(id)attachment
- 用途: 为单个附件创建缩略图节点（支持本地图片与远程 URL）。
- 调用: thumbTapped:（作为点击事件回调）。

#### - (void)thumbTapped:(ASControlNode *)sender
- 用途: 发送预览通知，由控制器展示大图/预览。
- 调用: （通知中心 postNotificationName:）。

#### - (void)setAttachments:(NSArray *)attachments
- 用途: 设置/替换附件数据并请求重布局。
- 调用: forceParseMessage:（在当前消息存在时）。

#### - (void)updateParsedResults:(NSArray<ParserResult *> *)results
- 用途: 外部直接注入解析结果并触发布局更新。
- 调用: updateContentNode。

#### - (void)updateMessageText:(NSString *)newMessage
- 用途: 更新消息文本；在流式模式下直接更新文本，否则按需重新解析或增量更新。
- 调用: updateTextContentDirectly:, shouldReparseText:, forceParseMessage:, updateExistingNodesWithNewText:。

#### - (void)parseMessage:(NSString *)message
- 用途: 后台线程执行 Markdown 解析与结果转换；主线程应用解析结果。
- 调用: [AIMarkdownParser parse:], convertMarkdownBlocks:fallbackFromMessage:, updateContentNode。

#### - (void)updateContentNode
- 用途: 根据解析结果构建/复用渲染节点集合并触发布局。
- 调用: getOrCreateTextNodeForText:, getOrCreateTextNodeForAttributedString:, isCodeBlockContentChanged:forResult:, createCodeBlockNode:, immediateLayoutUpdate。

#### - (void)forceParseMessage:(NSString *)message
- 用途: 高优先级完整解析消息并在主线程刷新内容与布局。
- 调用: [AIMarkdownParser parse:], convertMarkdownBlocks:fallbackFromMessage:, updateContentNode。

#### - (NSAttributedString *)attributedStringForText:(NSString *)text
- 用途: 为纯文本应用基础段落/字体/颜色样式。
- 调用: 无。

#### - (void)applyMarkdownStyles:(NSMutableAttributedString *)attributedString
- 用途: 为富文本应用加粗/斜体/内联代码/URL/邮箱等样式。
- 调用: applyStyleWithRegex:toAttributedString:styleBlock:, applyCodeStyleWithRegex:toAttributedString:, applyURLStyleWithRegex:toAttributedString:, applyEmailStyleWithRegex:toAttributedString:。

#### - (void)applyStyleWithRegex:toAttributedString:styleBlock:
- 用途: 通用样式应用（按正则范围替换字体等样式）。
- 调用: 无。

#### - (void)applyCodeStyleWithRegex:toAttributedString:
- 用途: 应用内联代码样式（等宽字体 + 背景色）。
- 调用: 无。

#### - (void)applyURLStyleWithRegex:toAttributedString:
- 用途: 应用 URL 链接样式（可点击/下划线/颜色）。
- 调用: 无。

#### - (void)applyEmailStyleWithRegex:toAttributedString:
- 用途: 应用邮箱链接样式（mailto）。
- 调用: 无。

#### - (ASTextNode *)getOrCreateTextNodeForText:(NSString *)text
- 用途: 按文本从缓存获取或创建文本节点。
- 调用: attributedStringForText:。

#### - (ASTextNode *)getOrCreateTextNodeForAttributedString:(NSAttributedString *)attributedString
- 用途: 按富文本从缓存获取或创建文本节点。
- 调用: 无。

#### - (ASDisplayNode *)createCodeBlockNode:(ParserResult *)result
- 用途: 基于解析结果创建/复用代码块节点（AICodeBlockNode）。
- 调用: 无。

#### - (BOOL)isCodeBlockContentChanged:(ASDisplayNode *)existingNode forResult:(ParserResult *)result
- 用途: 判断代码块内容/语言是否变化以决定是否复用。
- 调用: 无（KVC 读取 AICodeBlockNode 属性）。

#### - (void)immediateLayoutUpdate
- 用途: 立即标记需要布局（合并到下一帧）。
- 调用: 无。

#### - (NSParagraphStyle *)defaultParagraphStyle
- 用途: 返回默认段落样式（行距/换行）。
- 调用: 无。

#### - (void)updateExistingNodesWithNewText:(NSString *)newText
- 用途: 在非流式模式下对末尾文本进行智能增量更新，尽量减少重排与闪烁。
- 调用: defaultParagraphStyle, isLayoutStableForText:, performDelayedLayoutUpdate。

#### - (void)performDelayedLayoutUpdate
- 用途: 节流后的 setNeedsLayout，减少弹动与主线程压力。
- 调用: 无。

#### - (BOOL)isLayoutStableForText:(NSString *)text
- 用途: 基于文本特征（代码块/标题/列表）判断布局是否稳定，用于调节更新策略。
- 调用: 无。

#### - (BOOL)shouldReparseText:(NSString *)newText
- 用途: 判断是否需要重新解析（例如闭合了代码块、出现新结构、长度突变）。
- 调用: 无。

#### - (void)completeStreamingUpdate
- 用途: 流式结束时做一次完整解析与最终无动画布局，确保最终效果稳定。
- 调用: forceParseMessage:。

#### - (void)ensureFinalFlushAfterStreamDone
- 用途: 当控制器通知流式结束时，确保触发最终一次展示刷新。
- 调用: completeStreamingUpdate。

#### - (void)clearCache
- 用途: 清空文本节点/布局缓存。
- 调用: 无。

#### - (CGFloat)cachedHeightForText:(NSString *)text width:(CGFloat)width
- 用途: 文本高度缓存与计算（用于估算/预布局）。
- 调用: attributedStringForText:。

#### - (void)clearHeightCache
- 用途: 清空高度缓存。
- 调用: 无。

#### - (void)dealloc
- 用途: 释放资源（缓存与 displayLink）。
- 调用: clearCache。

#### - (void)updateTextContentDirectly:(NSString *)newMessage
- 用途: 流式模式下直接更新富文本并请求布局。
- 调用: forceParseMessage:。

#### - (void)pauseStreamingAnimation
- 用途: 暂停逐行渲染调度。
- 调用: 无。

#### - (void)resumeStreamingAnimation
- 用途: 恢复逐行渲染调度，并在有排队任务时继续推进。
- 调用: scheduleNextLineTask（条件满足时）。

#### - (void)appendSemanticBlocks:(NSArray<NSString *> *)blocks isFinal:(BOOL)isFinal
- 用途: 追加语义块文本（逐行渲染队列），保持 currentMessage 同步。
- 调用: processNextSemanticBlockIfIdle。

#### - (NSArray<NSAttributedString *> *)lineFragmentsForAttributedString:(NSAttributedString *)attributed width:(CGFloat)width
- 用途: 使用 TextKit 将富文本按固定宽度切分为可视行。
- 调用: 无。

#### - (CGFloat)preferredTextMaxWidth
- 用途: 返回内容最大宽度（屏幕宽度 * 0.75）。
- 调用: 无。

#### - (void)buildLineTasksForBlockText:(NSString *)blockText completion:(void (^)(NSArray<NSDictionary *> *tasks))completion
- 用途: 后台按语义块生成逐行任务（文本行/代码行），并回调到主线程准备渲染。
- 调用: [AIMarkdownParser parse:], defaultParagraphStyle, lineFragmentsForAttributedString:width:。

#### - (void)processNextSemanticBlockIfIdle
- 用途: 若空闲则取出下一个语义块，生成行任务并准备调度。
- 调用: buildLineTasksForBlockText:completion:, scheduleNextLineTask。

#### - (void)scheduleNextLineTask
- 用途: 依据行类型与最小间隔调度下一条渲染任务（首行可零延迟）。
- 调用: performNextLineTask（通过 GCD 延迟调用）。

#### - (void)performNextLineTask
- 用途: 执行一条行渲染任务：文本行追加 ASTextNode，代码行追加/更新 AICodeBlockNode，并推进下一条。
- 调用: immediateLayoutUpdate（首行时）、attributedStringForText:（fallback）、performDelayedLayoutUpdate, scheduleBatchedLineNotification, scheduleNextLineTask；（外部）AICodeBlockNode setFixedContentWidth/updateCodeText。

#### - (void)setLineRenderInterval:(NSTimeInterval)lineRenderInterval
- 用途: 设置文本行渲染间隔。
- 调用: 无。

#### - (void)setCodeLineRenderInterval:(NSTimeInterval)value
- 用途: 设置代码行渲染间隔。
- 调用: 无。

#### - (void)debugRenderNodesState
- 用途: 预留调试点（当前为空实现）。
- 调用: 无。

#### - (void)scheduleBatchedLineNotification
- 用途: 打开帧级 displayLink，在下一帧批量发送“已追加一行”的通知。
- 调用: 无（设置标记并启用 displayLink）。

#### - (NSArray<ParserResult *> *)convertMarkdownBlocks:(NSArray<AIMarkdownBlock *> *)markdownBlocks fallbackFromMessage:(NSString *)message
- 用途: 将 Markdown 语义块转换为 ParserResult（文本/标题/代码块）。
- 调用: defaultParagraphStyle, applyMarkdownStyles:。

---

生成时间以当前代码为准，如有方法增删请同步更新本文档。
