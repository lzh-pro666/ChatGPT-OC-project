#import "ChatDetailViewControllerV2.h"
#import <AsyncDisplayKit/ASDisplayNode+Beta.h>
#import "ThinkingNode.h"
#import "RichMessageCellNode.h"
#import "AttachmentThumbnailView.h"
#import "CoreDataManager.h"
#import "APIManager.h"
@import CoreData;
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import "OSSUploadManager.h"
#import "ImagePreviewOverlay.h"
#import "SemanticBlockParser.h"
#import <QuartzCore/QuartzCore.h>
#import "MessageContentUtils.h"

// MARK: - 常量定义
static const NSTimeInterval kLineRenderInterval = 0.5; // 逐行渲染的时间间隔（秒），统一文本/代码行节奏
static const CGFloat kAutoScrollBottomTolerance = 120.0; // 视为"接近底部"的容差像素（更宽松提高粘底响应）
static const CGFloat kContentHeightIncreaseThreshold = 10.0; // 内容高度显著增长阈值（如代码块展开触发粘底）
static const NSTimeInterval kAutoScrollDebounceSeconds = 0.02; // 自动粘底防抖时间（秒），避免频繁 setContentOffset
static const NSInteger kMaxAttachmentCount = 3; // 单条消息最大附件数量
static const CGFloat kAttachmentThumbnailWidth = 60.0; // 附件缩略图固定宽度（点）
static const CGFloat kAttachmentsRowHeight = 60.0; // 附件缩略图行的高度（点）
static const CGFloat kAttachmentsTextTopPadding = 8.0; // 缩略图行与输入框之间的顶部间距（点）

@interface ChatDetailViewControllerV2 () <UITextViewDelegate, ASTableDataSource, ASTableDelegate, UIGestureRecognizerDelegate>

// MARK: - 数据相关属性
@property (nonatomic, strong) NSMutableArray *messages; // 当前聊天的消息数据源（按时间升序）
@property (nonatomic, strong) NSMutableArray *selectedAttachments; // 存储多个附件 (UIImage 或 NSURL)

// MARK: - UI组件属性
@property (nonatomic, strong) ASTableNode *tableNode; // 消息列表节点
@property (nonatomic, strong) UIView *inputContainerView; // 底部输入容器（含背景/输入框/工具栏）
@property (nonatomic, strong) UIView *inputBackgroundView; // 输入区背景视图（圆角）
@property (nonatomic, strong) UITextView *inputTextView; // 文本输入框（1-4行自适应）
@property (nonatomic, strong) UIButton *addButton; // 添加附件按钮
@property (nonatomic, strong) UIButton *sendButton; // 发送/暂停按钮
@property (nonatomic, strong) UIStackView *thumbnailsStackView; // 管理多个缩略图

// MARK: - 约束属性
@property (nonatomic, strong) NSLayoutConstraint *inputContainerBottomConstraint; // 输入容器贴底约束（随键盘变化）
@property (nonatomic, strong) NSLayoutConstraint *thumbnailsContainerHeightConstraint; // 缩略图行高度（0 或 60）
@property (nonatomic, strong) NSLayoutConstraint *inputTextViewTopConstraint; // 输入框顶部距缩略图底部间距（0 或 8）

// MARK: - 业务逻辑属性
@property (nonatomic, strong) MediaPickerManager *mediaPickerManager;
@property (nonatomic, assign) BOOL isAIThinking; // AI 状态

// MARK: - 流式更新相关属性
@property (nonatomic, strong) NSMutableString *fullResponseBuffer; // 累积模型返回的完整文本
@property (nonatomic, weak) id currentUpdatingAINode; // 当前处于流式更新的 Cell 节点
@property (nonatomic, assign) BOOL isUIUpdatePaused; // UI更新暂停（用户滚动/减速/代码块交互期间）
@property (nonatomic, assign) BOOL isAwaitingResponse; // 当前是否等待 AI 回复（控制发送/暂停按钮）
@property (nonatomic, strong) SemanticBlockParser *semanticParser; // 流式语义块解析器
@property (nonatomic, strong) NSMutableString *semanticRenderedBuffer; // 已渲染的语义块累积文本
@property (nonatomic) dispatch_queue_t semanticQueue; // 语义解析与数据准备串行队列（后台）
@property (nonatomic, weak) ThinkingNode *currentThinkingNode; // 思考行节点引用（用于更新提示）
@property (nonatomic, copy) NSString *thinkingHintText; // 思考提示文案

// MARK: - 网络请求相关属性
@property (nonatomic, strong) NSURLSessionDataTask *currentStreamingTask; // 当前进行中的流式请求
@property (nonatomic, weak) NSManagedObject *currentUpdatingAIMessage; // 当前正在写入 CoreData 的 AI 消息对象

// MARK: - 滚动粘底属性
@property (nonatomic, assign) BOOL userIsDragging; // 用户是否正在拖动列表
@property (nonatomic, assign) BOOL codeBlockInteracting; // 代码块内横向滚动/交互中
@property (nonatomic, assign) BOOL isDecelerating; // 列表减速中（避免与系统动画竞争）

// MARK: - 多模态控制
@property (nonatomic, strong) NSArray<NSURL *> *pendingImageURLs; // 本轮待发送给模型的图片 URL 列表

// MARK: - 粘底：事件驱动 + 防抖
@property (nonatomic, strong) dispatch_block_t pendingAutoScrollTask; // 粘底任务（事件驱动 + 防抖）

// MARK: - 生命周期标记
@property (nonatomic, assign) BOOL didInitialAppear; // 首次进入窗口后再进行初始 reload/滚动
// MARK: - 键盘联动粘底控制
@property (nonatomic, assign) BOOL stickOnKeyboardChange; // 键盘出现/隐藏期间是否需要粘底（仅在接近底部时）

// MARK: - 可见性相关延迟操作
@property (nonatomic, assign) BOOL needsDeferredReload; // 延后 reload（未进 window 时不触发布局）
@property (nonatomic, assign) BOOL needsDeferredBottomScroll; // 延后滚动到底部（未进 window 时）

@end

@interface ChatDetailViewControllerV2 ()

- (NSString *)displayTitleForModelName:(NSString *)modelName;

@end

@implementation ChatDetailViewControllerV2

// MARK: - 生命周期方法
- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 1. 初始化非视图相关的属性
    self.isAIThinking = NO;
    self.isAwaitingResponse = NO;
    self.fullResponseBuffer = [NSMutableString string];
    self.selectedAttachments = [NSMutableArray array];
    
    // 2. 初始化高度缓存系统（控制器层缓存已移除，保留 Cell 内部实现）
    self.isUIUpdatePaused = NO; // 初始化UI更新暂停标志
    self.semanticParser = [[SemanticBlockParser alloc] init];
    self.semanticRenderedBuffer = [NSMutableString string];
    self.semanticQueue = dispatch_queue_create("com.chat.detail.semantic", DISPATCH_QUEUE_SERIAL);

    // 粘底滚动初始化
    self.userIsDragging = NO;
    
    // 3. 设置所有视图和它的布局约束
    [self setupViews];
    
    // 4. 初始化辅助类和加载数据
    self.mediaPickerManager = [[MediaPickerManager alloc] initWithPresenter:self];
    self.mediaPickerManager.delegate = self;
    [self fetchMessages]; // 在UI设置好后加载数据
    
    // 5. 设置通知和其他UI状态
    [self updatePlaceholderVisibility];
    [self updateSendButtonState];
    [self setupNotifications];
    
    // 6. 加载用户设置和API Key
    [self loadUserSettings];

    // 7. 初始化阿里云 OSS（迁移到单例管理器）
    [[OSSUploadManager sharedManager] setupIfNeeded];
    
    // 8. 监控表格视图内容大小变化，用于自动滚动
    [self.tableNode.view addObserver:self forKeyPath:@"contentSize" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:nil];

    // 粘底采用事件驱动 + 防抖的方式，不再使用 DisplayLink 循环
    self.pendingAutoScrollTask = nil;
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.didInitialAppear) {
        self.didInitialAppear = YES;
    }
    // 初次进入或重新可见：统一处理延迟的刷新与滚动
    if (self.needsDeferredReload) {
        self.needsDeferredReload = NO;
        [self fetchMessages];
        UITableView *tv = self.tableNode.view;
        [UIView performWithoutAnimation:^{
            [CATransaction begin];
            [CATransaction setDisableActions:YES];
            [self.tableNode reloadData];
            [tv layoutIfNeeded];
            [CATransaction commit];
        }];
    }
    if (self.needsDeferredBottomScroll) {
        self.needsDeferredBottomScroll = NO;
        [self forceScrollToBottomAnimated:NO];
    }
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];

    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
        self.currentStreamingTask = nil;
        
        // 如果AI仍在思考，则更新数据源并刷新UI
        if (self.isAIThinking) {
            self.isAIThinking = NO;
            [self.tableNode reloadData];
        }
    }
    
    // 关键：在离开页面前持久化未完成的 AI 回复，避免切回后丢失
    [self persistPartialAIMessageIfNeeded];
}

- (void)dealloc {
    // 移除KVO观察者
    @try {
        [self.tableNode.view removeObserver:self forKeyPath:@"contentSize"];
    } @catch (NSException *exception) {
        
    }

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // 确保任务被取消
    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
        self.currentStreamingTask = nil;
    }

    // 取消待执行的粘底防抖任务
    if (self.pendingAutoScrollTask) {
        dispatch_block_cancel(self.pendingAutoScrollTask);
        self.pendingAutoScrollTask = nil;
    }
}

// MARK: - 初始化设置方法
- (void)setupNotifications {
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    // 监听缩略图点击的预览请求
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleAttachmentPreview:) name:@"AttachmentPreviewRequested" object:nil];
    // 新增：逐行渲染时每行追加后保持粘底
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleRichMessageAppendLine:) name:@"RichMessageCellNodeDidAppendLine" object:nil];
    // 新增：首行追加前的粘底
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleRichMessageWillAppendFirstLine:) name:@"RichMessageCellNodeWillAppendFirstLine" object:nil];
    // 新增：监听代码块横向滚动手势，暂停自动滚动与UI更新
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_onCodeBlockPanBegan:) name:@"CodeBlockPanBegan" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_onCodeBlockPanEnded:) name:@"CodeBlockPanEnded" object:nil];
}

- (void)loadUserSettings {
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"OpenAIAPIKey"];
    if (apiKey.length > 0) {
        [[APIManager sharedManager] setApiKey:apiKey];
    } else {
        // 如果没有设置API Key，在短暂延迟后提示用户设置
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showNeedAPIKeyAlert];
        });
    }
    
    NSString *defaultPrompt = [[NSUserDefaults standardUserDefaults] stringForKey:@"DefaultSystemPrompt"];
    if (defaultPrompt.length > 0) {
        [APIManager sharedManager].defaultSystemPrompt = defaultPrompt;
    }
    
    NSString *selectedModel = [[NSUserDefaults standardUserDefaults] stringForKey:@"SelectedModelName"];
    if (selectedModel.length > 0) {
        [APIManager sharedManager].currentModelName = selectedModel;
    }
}

// MARK: - UI设置方法
- (void)setupViews {
    self.view.backgroundColor = [UIColor colorWithRed:247/255.0 green:247/255.0 blue:248/255.0 alpha:1.0]; // #f7f7f8
    
    // 顶部导航
    [self setupHeader];
    
    // 输入区域
    [self setupInputArea];
    
    //初始化并添加核心UI组件（ASTableNode）
    _tableNode = [[ASTableNode alloc] initWithStyle:UITableViewStylePlain];
    _tableNode.dataSource = self;
    _tableNode.delegate = self;
    _tableNode.view.separatorStyle = UITableViewCellSeparatorStyleNone;
    
    // 配置表视图属性以确保稳定的布局
    _tableNode.view.rowHeight = UITableViewAutomaticDimension;
    _tableNode.view.estimatedRowHeight = 80.0; // 合理的估算高度
    _tableNode.view.allowsSelection = NO;
    _tableNode.view.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    _tableNode.view.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentAutomatic;
    
    // 手势可用性增强
    _tableNode.view.delaysContentTouches = NO;
    _tableNode.view.canCancelContentTouches = YES;
    _tableNode.view.panGestureRecognizer.cancelsTouchesInView = NO;
    
    // 提高手势响应优先级
    if (@available(iOS 13.4, *)) {
        _tableNode.view.panGestureRecognizer.allowedScrollTypesMask = UIScrollTypeMaskAll;
    }

    [self.view addSubnode:_tableNode];
    
    // 设置tableNode约束
    _tableNode.view.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [_tableNode.view.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:44],
        [_tableNode.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [_tableNode.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [_tableNode.view.bottomAnchor constraintEqualToAnchor:self.inputContainerView.topAnchor]
    ]];
}

- (void)setupHeader {
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectZero];
    headerView.backgroundColor = [UIColor whiteColor];
    headerView.translatesAutoresizingMaskIntoConstraints = NO;
    
    // 添加模糊效果
    UIVisualEffectView *blurView = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleExtraLight]];
    blurView.translatesAutoresizingMaskIntoConstraints = NO;
    [headerView addSubview:blurView];
    
    // 菜单按钮，统一回调到上层
    UIButton *menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [menuButton setImage:[UIImage systemImageNamed:@"line.horizontal.3"] forState:UIControlStateNormal];
    menuButton.tintColor = [UIColor blackColor];
    menuButton.translatesAutoresizingMaskIntoConstraints = NO;
    [menuButton addTarget:self action:@selector(handleMenuTap) forControlEvents:UIControlEventTouchUpInside];
    [headerView addSubview:menuButton];
    
    // 标题按钮
    UIButton *titleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    NSString *modelName = [[APIManager sharedManager] currentModelName];
    NSString *displayTitle = [self displayTitleForModelName:modelName];
    [titleButton setTitle:displayTitle forState:UIControlStateNormal];
    titleButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    titleButton.tintColor = UIColor.blackColor;
    [titleButton addTarget:self action:@selector(showModelSelectionMenu:) forControlEvents:UIControlEventTouchUpInside];
    titleButton.translatesAutoresizingMaskIntoConstraints = NO;
    [headerView addSubview:titleButton];
    
    // 刷新按钮
    UIButton *refreshButton = [UIButton buttonWithType:UIButtonTypeCustom];
    [refreshButton setImage:[UIImage systemImageNamed:@"arrow.clockwise"] forState:UIControlStateNormal];
    refreshButton.tintColor = [UIColor blackColor];
    refreshButton.translatesAutoresizingMaskIntoConstraints = NO;
    [refreshButton addTarget:self action:@selector(resetAPIKey) forControlEvents:UIControlEventTouchUpInside];
    [headerView addSubview:refreshButton];
    
    // 底部分割线
    UIView *separatorLine = [[UIView alloc] initWithFrame:CGRectZero];
    separatorLine.backgroundColor = [UIColor colorWithRed:229/255.0 green:229/255.0 blue:229/255.0 alpha:1.0]; // #e5e5e5
    separatorLine.translatesAutoresizingMaskIntoConstraints = NO;
    [headerView addSubview:separatorLine];
    
    [self.view addSubview:headerView];
    
    // 设置约束
    [NSLayoutConstraint activateConstraints:@[
        [headerView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
        [headerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [headerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [headerView.heightAnchor constraintEqualToConstant:44],
        
        [blurView.topAnchor constraintEqualToAnchor:headerView.topAnchor],
        [blurView.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor],
        [blurView.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor],
        [blurView.bottomAnchor constraintEqualToAnchor:headerView.bottomAnchor],
        
        [menuButton.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor constant:16],
        [menuButton.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor],
        [menuButton.widthAnchor constraintEqualToConstant:24],
        [menuButton.heightAnchor constraintEqualToConstant:24],
        
        [titleButton.centerXAnchor constraintEqualToAnchor:headerView.centerXAnchor],
        [titleButton.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor],
        
        [refreshButton.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-16],
        [refreshButton.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor],
        [refreshButton.widthAnchor constraintEqualToConstant:24],
        [refreshButton.heightAnchor constraintEqualToConstant:24],
        
        [separatorLine.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor],
        [separatorLine.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor],
        [separatorLine.bottomAnchor constraintEqualToAnchor:headerView.bottomAnchor],
        [separatorLine.heightAnchor constraintEqualToConstant:1]
    ]];
}

- (void)handleMenuTap {
    if ([self.menuDelegate respondsToSelector:@selector(chatDetailDidTapMenu)]) {
        [self.menuDelegate chatDetailDidTapMenu];
    }
}

- (void)setupInputArea {
    self.inputContainerView = [[UIView alloc] init];
    self.inputContainerView.backgroundColor = [UIColor clearColor];
    self.inputContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.inputContainerView.layer.shadowColor = [UIColor grayColor].CGColor;
    self.inputContainerView.layer.shadowOffset = CGSizeMake(0, -5);
    self.inputContainerView.layer.shadowOpacity = 0.2;
    self.inputContainerView.layer.shadowRadius = 4.0;
    
    // 背景视图
    self.inputBackgroundView = [[UIView alloc] init];
    self.inputBackgroundView.backgroundColor = [UIColor whiteColor]; // 背景色延伸至底部
    self.inputBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    self.inputBackgroundView.layer.cornerRadius = 23.0;
    self.inputBackgroundView.layer.maskedCorners = kCALayerMinXMinYCorner | kCALayerMaxXMinYCorner;
    self.inputBackgroundView.layer.masksToBounds = YES;
    self.inputBackgroundView.userInteractionEnabled = YES;
    
    // 缩略图容器
    self.thumbnailsStackView = [[UIStackView alloc] init];
    self.thumbnailsStackView.translatesAutoresizingMaskIntoConstraints = NO;
    self.thumbnailsStackView.axis = UILayoutConstraintAxisHorizontal;
    self.thumbnailsStackView.spacing = 8.0;
    self.thumbnailsStackView.alignment = UIStackViewAlignmentCenter; // 垂直居中对齐
    self.thumbnailsStackView.clipsToBounds = NO;
    [self.inputBackgroundView addSubview:self.thumbnailsStackView];
    
    // 文本输入框 - 统一样式和约束
    self.inputTextView = [[UITextView alloc] init];
    // 统一字体大小：18pt，与气泡显示保持一致
    self.inputTextView.font = [UIFont systemFontOfSize:18];
    self.inputTextView.delegate = self;
    // 启用滚动，支持超过4行后的滑动预览
    self.inputTextView.scrollEnabled = YES;
    self.inputTextView.backgroundColor = [UIColor clearColor];
    // 统一内边距：上下12pt，左右16pt，确保与按钮对齐
    self.inputTextView.textContainerInset = UIEdgeInsetsMake(12, 16, 12, 16);
    // 统一输入字体，防止 attributed typing 导致行高/高度抖动
    self.inputTextView.typingAttributes = @{ NSFontAttributeName: self.inputTextView.font };
    self.inputTextView.translatesAutoresizingMaskIntoConstraints = NO;
    // 关闭预测与拼写候选，避免系统候选"计算"与控制台噪声
    self.inputTextView.autocorrectionType = UITextAutocorrectionTypeNo;
    self.inputTextView.spellCheckingType = UITextSpellCheckingTypeNo;
    if (@available(iOS 11.0, *)) {
        self.inputTextView.smartDashesType = UITextSmartDashesTypeNo;
        self.inputTextView.smartQuotesType = UITextSmartQuotesTypeNo;
        self.inputTextView.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    }
    self.inputTextView.autocapitalizationType = UITextAutocapitalizationTypeNone;
    self.inputTextView.inputAssistantItem.leadingBarButtonGroups = @[];
    self.inputTextView.inputAssistantItem.trailingBarButtonGroups = @[];
    // 设置最小和最大高度，确保单行时不会扩展
    self.inputTextView.textContainer.lineFragmentPadding = 0;
    self.inputTextView.textContainer.maximumNumberOfLines = 0;
    [self.inputBackgroundView addSubview:self.inputTextView];
    
    // 占位标签 - 统一字体和样式
    self.placeholderLabel = [[UILabel alloc] init];
    self.placeholderLabel.text = @"    给ChatGPT发送信息";
    self.placeholderLabel.textColor = [UIColor colorWithRed:0.6 green:0.6 blue:0.6 alpha:1.0]; // 更柔和的灰色
    self.placeholderLabel.font = [UIFont systemFontOfSize:18]; // 与输入框字体保持一致
    self.placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    
    // 工具栏
    UIView *toolbarView = [[UIView alloc] init];
    toolbarView.backgroundColor = [UIColor clearColor];
    toolbarView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputBackgroundView addSubview:toolbarView];
    
    // 添加按钮
    self.addButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.addButton setImage:[UIImage systemImageNamed:@"plus.circle"] forState:UIControlStateNormal];
    self.addButton.tintColor = [UIColor blackColor];
    [self.addButton addTarget:self action:@selector(addButtonTapped:) forControlEvents:UIControlEventTouchUpInside];
    self.addButton.translatesAutoresizingMaskIntoConstraints = NO;
    
    // 发送按钮
    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sendButton setImage:[UIImage systemImageNamed:@"arrow.up.circle.fill"] forState:UIControlStateNormal];
    self.sendButton.tintColor = [UIColor blackColor];
    [self.sendButton addTarget:self action:@selector(sendOrPauseButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    
    // 2. 添加视图层级
    [self.view addSubview:self.inputContainerView];
    [self.inputContainerView addSubview:self.inputBackgroundView];
    [self.inputBackgroundView addSubview:self.placeholderLabel];
    [toolbarView addSubview:self.addButton];
    [toolbarView addSubview:self.sendButton];
    
    // 3. 激活所有约束
    // 计算单行精确高度，确保初始状态稳定
    CGFloat lineHeight = self.inputTextView.font.lineHeight; // 与字体对应的行高
    UIEdgeInsets textInsets = self.inputTextView.textContainerInset;
    CGFloat singleLineHeight = lineHeight + textInsets.top + textInsets.bottom;
    self.inputTextViewHeightConstraint = [self.inputTextView.heightAnchor constraintEqualToConstant:singleLineHeight];
    
    // 让容器的底部对齐到屏幕的真正底部，而不是安全区
    self.inputContainerBottomConstraint = [self.inputContainerView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor];
    
    [NSLayoutConstraint activateConstraints:@[
        // 整体输入容器 (inputContainerView)
        self.inputContainerBottomConstraint,
        [self.inputContainerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.inputContainerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        
        // 背景视图 (inputBackgroundView)
        [self.inputBackgroundView.topAnchor constraintEqualToAnchor:self.inputContainerView.topAnchor constant:2],
        [self.inputBackgroundView.leadingAnchor constraintEqualToAnchor:self.inputContainerView.leadingAnchor],
        [self.inputBackgroundView.trailingAnchor constraintEqualToAnchor:self.inputContainerView.trailingAnchor],
        [self.inputBackgroundView.bottomAnchor constraintEqualToAnchor:self.inputContainerView.bottomAnchor],
        
        // 缩略图容器 (thumbnailsStackView) 的约束
        [self.thumbnailsStackView.topAnchor constraintEqualToAnchor:self.inputBackgroundView.topAnchor constant:12],
        [self.thumbnailsStackView.leadingAnchor constraintEqualToAnchor:self.inputBackgroundView.leadingAnchor constant:32],
        [self.thumbnailsStackView.trailingAnchor constraintLessThanOrEqualToAnchor:self.inputBackgroundView.trailingAnchor constant:-20],
        // 创建高度约束并保存引用，初始值为0
        (self.thumbnailsContainerHeightConstraint = [self.thumbnailsStackView.heightAnchor constraintEqualToConstant:0]),
        
        // 文本输入框 (inputTextView) 的约束
        // 它的顶部现在永远依赖于缩略图的底部
        (self.inputTextViewTopConstraint = [self.inputTextView.topAnchor constraintEqualToAnchor:self.thumbnailsStackView.bottomAnchor constant:8]),
        [self.inputTextView.leadingAnchor constraintEqualToAnchor:self.inputBackgroundView.leadingAnchor constant:20],
        [self.inputTextView.bottomAnchor constraintEqualToAnchor:self.inputContainerView.safeAreaLayoutGuide.bottomAnchor constant:-15],
        self.inputTextViewHeightConstraint,
        
        // 工具栏 (toolbarView) 的约束
        [toolbarView.trailingAnchor constraintEqualToAnchor:self.inputBackgroundView.trailingAnchor constant:-12],
        [toolbarView.widthAnchor constraintEqualToConstant:100],
        // 让工具栏的中心与输入框的中心保持垂直对齐
        [toolbarView.centerYAnchor constraintEqualToAnchor:self.inputTextView.centerYAnchor],
        [toolbarView.heightAnchor constraintEqualToAnchor:self.inputTextView.heightAnchor],
        
        // 添加按钮 (addButton)
        [self.addButton.leadingAnchor constraintEqualToAnchor:toolbarView.leadingAnchor constant:8],
        [self.addButton.centerYAnchor constraintEqualToAnchor:toolbarView.centerYAnchor],
        [self.addButton.widthAnchor constraintEqualToConstant:46],
        [self.addButton.heightAnchor constraintEqualToConstant:46],
        
        // 发送按钮 (sendButton)
        [self.sendButton.trailingAnchor constraintEqualToAnchor:toolbarView.trailingAnchor constant:-8],
        [self.sendButton.centerYAnchor constraintEqualToAnchor:toolbarView.centerYAnchor],
        [self.sendButton.widthAnchor constraintEqualToConstant:46],
        [self.sendButton.heightAnchor constraintEqualToConstant:46],
        
        [self.inputTextView.trailingAnchor constraintEqualToAnchor:toolbarView.leadingAnchor],
        
        // 占位标签 (placeholderLabel) - 精确对齐
        [self.placeholderLabel.leadingAnchor constraintEqualToAnchor:self.inputTextView.leadingAnchor constant:0],
        [self.placeholderLabel.centerYAnchor constraintEqualToAnchor:self.inputTextView.centerYAnchor]
    ]];
}

// MARK: - 数据管理方法
- (void)fetchMessages {
    self.messages = [[CoreDataManager sharedManager] fetchMessagesForChat:self.chat];
    // 如果没有消息，添加一条欢迎消息
    if (self.messages.count == 0) {
        [[CoreDataManager sharedManager] addMessageToChat:self.chat
                                                  content:@"您好！我是ChatGPT，一个AI助手。我可以帮助您解答问题，请问有什么我可以帮您的吗？"
                                               isFromUser:NO];
        self.messages = [[CoreDataManager sharedManager] fetchMessagesForChat:self.chat];
    }
}

// MARK: - 数据行访问辅助（按 indexPath 提供行内容/角色/附件）
- (NSArray *)attachmentsAtIndexPath:(NSIndexPath *)indexPath {
    // 思考行不对应消息内容
    if (self.isAIThinking && indexPath.row == self.messages.count) {
        return @[];
    }
    if (indexPath.row < 0 || indexPath.row >= self.messages.count) {
        return @[];
    }
    
    NSManagedObject *message = self.messages[indexPath.row];
    id rawContent = [message valueForKey:@"content"];
    if (![rawContent isKindOfClass:[NSString class]]) {
        return @[]; // 防御：content 可能为 NSNull / 非字符串
    }
    NSString *content = (NSString *)rawContent;
    
    return [MessageContentUtils parseAttachmentURLsFromContent:content];
}

// MARK: - 键盘处理（输入区联动 + 粘底）
- (void)keyboardWillShow:(NSNotification *)notification {
    // 监控键盘的最终位置和大小
    CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    // 键盘动画的持续时间
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    // 键盘动画的曲线类型（如缓入缓出）
    UIViewAnimationCurve curve = [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    
    BOOL wasNearBottom = [self isNearBottomWithTolerance:kAutoScrollBottomTolerance];
    self.stickOnKeyboardChange = wasNearBottom; // 仅在接近底部时记录需要粘底
    [UIView animateWithDuration:duration delay:0 options:(curve << 16) animations:^{
        self.inputContainerBottomConstraint.constant = -keyboardFrame.size.height;
        [self.view layoutIfNeeded];
        if (self.stickOnKeyboardChange) {
            [self performAutoScrollWithContext:@"keyboardWillShow" animated:NO];
        }
    } completion:nil];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    
    [UIView animateWithDuration:duration delay:0 options:(curve << 16) animations:^{
        self.inputContainerBottomConstraint.constant = 0;
        [self.view layoutIfNeeded];
        if (self.stickOnKeyboardChange) {
            [self performAutoScrollWithContext:@"keyboardWillHide" animated:NO];
        }
    } completion:^(BOOL finished) {
        self.stickOnKeyboardChange = NO; // 一次键盘周期后复位
    }];
}

// MARK: - 消息处理
- (void)addButtonTapped:(UIButton *)sender {
    CustomMenuView *menuView = [[CustomMenuView alloc] initWithFrame:self.view.bounds];
    // 将按钮的中心点从其父视图的坐标系转换到self.view的坐标系
    CGPoint centerPositionInSelfView = [sender.superview convertPoint:sender.center toView:self.view];
    menuView.delegate = self;
    [menuView showInView:self.view atPoint:CGPointMake(centerPositionInSelfView.x + 12, centerPositionInSelfView.y - 15)];
}

- (void)sendOrPauseButtonTapped {
    // 防重复点击：若按钮当前不可用直接返回
    if (!self.sendButton.enabled) { return; }
    
    if (self.isAwaitingResponse) {
        [self handlePauseTapped];
        return;
    }
    [self sendButtonTapped];
}

- (void)sendButtonTapped {
    if (self.inputTextView.text.length == 0 && self.selectedAttachments.count == 0) return;
    // 防重复点击：发送期间禁用按钮直到进入等待态UI
    self.sendButton.enabled = NO;
    
    NSString *userMessage = [self.inputTextView.text copy];
    NSArray *attachments = [self.selectedAttachments copy];

    if (attachments.count > 0) {
        // 先上传附件到 OSS，拿到 URL 后把 URL 附加到文本中（回调在主线程）
        [[OSSUploadManager sharedManager] uploadAttachments:attachments completion:^(NSArray<NSURL *> * _Nonnull uploadedURLs) {
            NSMutableString *finalMessage = [NSMutableString stringWithString:userMessage ?: @""];
            if (uploadedURLs.count > 0) {
                if (finalMessage.length > 0) {
                    [finalMessage appendString:@"\n\n"]; 
                }
                [finalMessage appendString:@"[附件链接：\n"]; // 规范化格式，便于解析
                for (NSURL *u in uploadedURLs) {
                    [finalMessage appendFormat:@"- %@\n", u.absoluteString];
                }
                [finalMessage appendString:@"]"]; 
                // 记录多模态图片（分类后再决定调用理解或生成）
                self.pendingImageURLs = uploadedURLs;
                // 仅日志预览多模态 payload
                NSMutableArray *imageParts = [NSMutableArray array];
                for (NSURL *u in uploadedURLs) {
                    [imageParts addObject:@{ @"type": @"image_url",
                                             @"image_url": @{ @"url": (u.absoluteString ?: @"") } }];
                }
                NSString *userText = [self latestUserPlainText] ?: @"";
                NSDictionary *prompt = @{ @"role": @"user",
                                           @"content": [imageParts arrayByAddingObject:@{ @"type": @"text",
                                                                                           @"text": userText }] };
                (void)prompt;
            }

            // 清空输入框和附件（已在主线程）
            self.inputTextView.text = @"";
            [self.selectedAttachments removeAllObjects];
            [self updateAttachmentsDisplay];
            [self textViewDidChange:self.inputTextView];
            [self.inputTextView resignFirstResponder];
    
            [self addMessageWithText:finalMessage attachments:@[] isFromUser:YES completion:^{
                [self enterAwaitingState];
                [self simulateAIResponse];
            }];
        }];
    } else {
        // 无附件直接发送
        self.inputTextView.text = @"";
        [self textViewDidChange:self.inputTextView];
        [self.inputTextView resignFirstResponder];
        [self addMessageWithText:userMessage attachments:@[] isFromUser:YES completion:^{
            [self enterAwaitingState];
            [self simulateAIResponse];
        }];
    }
}

// MARK: - 持久化当前未完成的 AI 回复
- (void)persistPartialAIMessageIfNeeded {
    @try {
        if (self.currentUpdatingAIMessage) {
            NSString *snapshot = [self.fullResponseBuffer copy] ?: @"";
            if (snapshot.length > 0) {
                [self.currentUpdatingAIMessage setValue:snapshot forKey:@"content"];
                [[CoreDataManager sharedManager] saveContext];
            }
        }
    } @catch (__unused NSException *e) {
    }
}

// MARK: - Chat 切换优化：在赋值时预加载并刷新，避免先返回旧界面再更新
- (void)setChat:(id)chat {
    if (_chat == chat) { return; }
    // 在切换前，先持久化当前未完成的 AI 回复
    [self persistPartialAIMessageIfNeeded];
    _chat = chat;
    // 1) 终止当前流式与思考状态
    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
        self.currentStreamingTask = nil;
    }
    self.isAIThinking = NO;
    [self.fullResponseBuffer setString:@""];
    self.currentUpdatingAIMessage = nil;
    self->_currentUpdatingAINode = nil;
    self.pendingImageURLs = nil;
    self.thinkingHintText = @"";
    self->_currentThinkingNode = nil;

    // 2) 清空底部附件与输入区状态
    if (self.selectedAttachments.count > 0) {
        [self.selectedAttachments removeAllObjects];
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateAttachmentsDisplay];
        [self updateSendButtonState];
    });

    // 3) 预加载新聊天消息
    self.messages = [[CoreDataManager sharedManager] fetchMessagesForChat:self.chat];
    // 若当前尚未在窗口层级中，则延迟到 viewDidAppear 再执行 reload/滚动
    if (self.isViewLoaded && self.tableNode) {
        if (self.view.window) {
            UITableView *tv = self.tableNode.view;
            [UIView performWithoutAnimation:^{
                [CATransaction begin];
                [CATransaction setDisableActions:YES];
                [self.tableNode reloadData];
                [tv layoutIfNeeded];
                [CATransaction commit];
            }];
            [self forceScrollToBottomAnimated:NO];
        } else {
            self.needsDeferredReload = YES;
            self.needsDeferredBottomScroll = YES;
        }
    }
}
// MARK: - 缩略图预览
- (void)handleAttachmentPreview:(NSNotification *)note {
    id imgObj = note.userInfo[@"image"];
    NSString *urlStr = note.userInfo[@"url"];
    UIImage *img = [imgObj isKindOfClass:[UIImage class]] ? (UIImage *)imgObj : nil;
    NSURL *url = (urlStr.length > 0) ? [NSURL URLWithString:urlStr] : nil;
    UIView *targetView = self.view;
    ImagePreviewOverlay *overlay = [[ImagePreviewOverlay alloc] initWithFrame:CGRectZero];
    [overlay presentInView:targetView image:img imageURL:url];
}

// MARK: - 滚动偏移计算工具
- (CGPoint)_bottomContentOffsetForTable:(UITableView *)tv {
    if (!tv) { return CGPointZero; }
    CGFloat contentHeight = tv.contentSize.height;
    CGFloat viewHeight = tv.bounds.size.height;
    CGFloat visibleHeight = viewHeight - tv.adjustedContentInset.bottom;
    // 若内容高度不足以填满一屏，仍允许滚到“底部”（即最小偏移处），避免初次插入时无法触发滚动
    CGFloat targetOffsetY = contentHeight - visibleHeight;
    CGFloat minOffsetY = -tv.adjustedContentInset.top;
    if (isnan(targetOffsetY) || isinf(targetOffsetY)) {
        targetOffsetY = minOffsetY;
    }
    if (targetOffsetY < minOffsetY) targetOffsetY = minOffsetY;
    // 小内容时，确保至少前进一个极小距离，触发滚动路径与粘底链路
    if (fabs(tv.contentOffset.y - targetOffsetY) < 0.5 && contentHeight <= visibleHeight + 1.0) {
        targetOffsetY = MIN(minOffsetY + 0.5, minOffsetY + 1.0);
    }
    CGPoint current = tv.contentOffset;
    return CGPointMake(current.x, targetOffsetY);
}

// MARK: - ASTableDataSource & ASTableDelegate
- (NSInteger)tableNode:(ASTableNode *)tableNode numberOfRowsInSection:(NSInteger)section {
    // 如果正在思考，总行数 = 消息数 + 1 (用于ThinkingNode)
    return self.messages.count + (self.isAIThinking ? 1 : 0);
}

- (ASCellNodeBlock)tableNode:(ASTableNode *)tableNode nodeBlockForRowAtIndexPath:(NSIndexPath *)indexPath {
    __weak typeof(self) weakSelf = self;
    
    // 检查是否为思考节点
    if (self.isAIThinking && indexPath.row == self.messages.count) {
        return ^ASCellNode *{
            ThinkingNode *node = [[ThinkingNode alloc] init];
            // 应用提示文本（若存在）
            if ((self.thinkingHintText ?: @"").length > 0 && [node respondsToSelector:@selector(setHintText:)]) {
                [node setHintText:self.thinkingHintText];
            }
            self->_currentThinkingNode = node;
            return node;
        };
    }
    
    NSString *message = [self messageAtIndexPath:indexPath];
    BOOL isFromUser = [self isMessageFromUserAtIndexPath:indexPath];
    NSArray *attachments = [self attachmentsAtIndexPath:indexPath];
    
    return ^ASCellNode *{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        
        // 统一使用富文本消息气泡，并在其上追加缩略图
        ASCellNode *node;
        RichMessageCellNode *rich = [[RichMessageCellNode alloc] initWithMessage:message isFromUser:isFromUser];
        if ([rich respondsToSelector:@selector(setLineRenderInterval:)]) {
            [rich setLineRenderInterval:kLineRenderInterval];
        }
        if ([rich respondsToSelector:@selector(setCodeLineRenderInterval:)]) {
            [rich setCodeLineRenderInterval:kLineRenderInterval];
        }
        if (attachments.count > 0 && [rich respondsToSelector:@selector(setAttachments:)]) {
            [rich setAttachments:attachments];
        }
        node = rich;
        
        // 如果是当前在流式更新的 AI 节点，则记录引用
        if (!isFromUser && [strongSelf isIndexPathCurrentAINode:indexPath]) {
            strongSelf->_currentUpdatingAINode = (id)node; // 兼容接口：cachedSize、updateMessageText
        }
        return node;
    };
}

// MARK: - 滚动控制（粘底检测与执行）
- (void)scrollToBottom {
    if (self.messages.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ensureBottomVisible:YES];
        });
    }
}

// 新增：是否接近底部（带容差）
- (BOOL)isNearBottomWithTolerance:(CGFloat)tolerance {
    UITableView *tv = self.tableNode.view;
    CGFloat contentHeight = tv.contentSize.height;
    CGFloat viewHeight = tv.bounds.size.height;
    UIEdgeInsets insets = tv.adjustedContentInset;
    CGFloat bottomInset = insets.bottom;
    CGFloat topInset = insets.top;
    CGFloat offsetY = tv.contentOffset.y;
    CGFloat visibleBottomY = offsetY + viewHeight - bottomInset;
    CGFloat effectiveContentBottomY = contentHeight - bottomInset;
    BOOL near = (visibleBottomY >= effectiveContentBottomY - tolerance);
    if (near && offsetY < -topInset) { near = YES; }
    return near;
}

// 新增：需要时进行锚定粘底
- (void)anchorScrollToBottomIfNeeded {
    if ([self shouldPerformAutoScroll]) {
        [self requestBottomAnchorWithContext:@"anchorScrollToBottomIfNeeded"];
    }
}

// 统一：确保底部可见（可选动画）
- (void)ensureBottomVisible:(BOOL)animated {
    [self performAutoScrollWithContext:(animated ? @"ensureBottomVisible(animated)" : @"ensureBottomVisible(immediate)") animated:animated];
}

// 新增：逐行渲染事件，保持底部可见（智能匹配代码块高度）
- (void)handleRichMessageAppendLine:(NSNotification *)note {
    // 逐行渲染时合并到底部锚定显示，避免频繁 setContentOffset
    [self requestBottomAnchorWithContext:@"handleRichMessageAppendLine"];
}

// MARK: - 附件管理
- (void)updateAttachmentsDisplay {
    BOOL hasAttachments = self.selectedAttachments.count > 0;
    
    // 1. 先清空所有旧的缩略图
    for (UIView *view in self.thumbnailsStackView.arrangedSubviews) {
        [self.thumbnailsStackView removeArrangedSubview:view];
        [view removeFromSuperview];
    }
    
    // 2. 重新创建并添加新的缩略图 (最多3个)
    NSInteger thumbnailCount = MIN(self.selectedAttachments.count, kMaxAttachmentCount);
    for (NSInteger i = 0; i < thumbnailCount; i++) {
        id attachment = self.selectedAttachments[i];
        
        AttachmentThumbnailView *thumbnailView = [[AttachmentThumbnailView alloc] init];
        thumbnailView.tag = i;
        
        // 为每个缩略图添加固定宽度约束
        [thumbnailView.widthAnchor constraintEqualToConstant:kAttachmentThumbnailWidth].active = YES;
        
        // 配置删除按钮的回调
        __weak typeof(self) weakSelf = self;
        thumbnailView.deleteAction = ^{
            [weakSelf deleteAttachmentAtIndex:thumbnailView.tag];
        };
        
        // 配置显示的图片
        if ([attachment isKindOfClass:[UIImage class]]) {
            thumbnailView.imageView.image = attachment;
        } else if ([attachment isKindOfClass:[NSURL class]]) {
            [self generateThumbnailForURL:attachment completion:^(UIImage * _Nullable image) {
                thumbnailView.imageView.image = image ?: [UIImage systemImageNamed:@"doc.fill"];
            }];
        }
        
        [self.thumbnailsStackView addArrangedSubview:thumbnailView];
    }
    
    // 3. 用动画来"撑开"或"收起"空间
    CGFloat newHeight = hasAttachments ? kAttachmentsRowHeight : 0.0;
    CGFloat newPadding = hasAttachments ? kAttachmentsTextTopPadding : 0.0;
    
    if (self.thumbnailsContainerHeightConstraint.constant != newHeight) {
        [self.view layoutIfNeeded]; // 确保当前布局是最新的
        [UIView animateWithDuration:0.3 animations:^{
            self.thumbnailsContainerHeightConstraint.constant = newHeight;
            // 直接使用保存的顶部约束更新 constant
            self.inputTextViewTopConstraint.constant = newPadding;
            [self.view layoutIfNeeded]; // 在动画块中执行布局
        }];
    }
    
    // 更新发送按钮状态
    [self updateSendButtonState];
}

- (void)deleteAttachmentAtIndex:(NSInteger)index {
    // 安全检查，确保索引有效
    if (index >= self.selectedAttachments.count) {
        return;
    }
    
    // 获取对应的缩略图视图
    AttachmentThumbnailView *thumbnailToRemove = nil;
    for (UIView *view in self.thumbnailsStackView.arrangedSubviews) {
        if ([view isKindOfClass:[AttachmentThumbnailView class]] && view.tag == index) {
            thumbnailToRemove = (AttachmentThumbnailView *)view;
            break;
        }
    }
    
    // 如果找不到对应的视图，直接刷新UI后返回
    if (!thumbnailToRemove) {
        [self.selectedAttachments removeObjectAtIndex:index];
        [self updateAttachmentsDisplay]; // 使用完整刷新作为后备方案
        return;
    }
    
    // 从数据源中删除
    [self.selectedAttachments removeObjectAtIndex:index];
    
    // 判断是否是最后一个附件
    if (self.selectedAttachments.count == 0) {
        // 是最后一个，执行淡出 + 收起容器的两步动画
        [UIView animateWithDuration:0.2 animations:^{
            thumbnailToRemove.alpha = 0;
        } completion:^(BOOL finished) {
            [self.thumbnailsStackView removeArrangedSubview:thumbnailToRemove];
            [thumbnailToRemove removeFromSuperview];
            
            // 此时附件数组已空，调用此方法会触发收起容器的动画
            [self updateAttachmentsDisplay];
        }];
    } else {
        // 不是最后一个，让其立即消失，并让StackView处理其余视图的移动动画
        [UIView animateWithDuration:0.25 animations:^{
            // 视图立即从StackView中移除
            [self.thumbnailsStackView removeArrangedSubview:thumbnailToRemove];
            [thumbnailToRemove removeFromSuperview];
        } completion:^(BOOL finished) {
            // 动画结束后，更新剩余视图的tag，以确保它与数据源中的新索引保持一致
            for (NSInteger i = 0; i < self.thumbnailsStackView.arrangedSubviews.count; i++) {
                UIView *view = self.thumbnailsStackView.arrangedSubviews[i];
                view.tag = i;
            }
        }];
    }
}

// 异步从文件URL生成缩略图的辅助方法
- (void)generateThumbnailForURL:(NSURL *)url completion:(void (^)(UIImage * _Nullable image))completion {
    CGFloat scale = [UIScreen mainScreen].scale;
    CGSize size = CGSizeMake(120, 120); // 请求一个稍大尺寸的缩略图以保证清晰度
    
    QLThumbnailGenerationRequest *request = [[QLThumbnailGenerationRequest alloc] initWithFileAtURL:url size:size scale:scale representationTypes:QLThumbnailGenerationRequestRepresentationTypeAll];
    
    [[QLThumbnailGenerator sharedGenerator] generateBestRepresentationForRequest:request completionHandler:^(QLThumbnailRepresentation * _Nullable thumbnail, NSError * _Nullable error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) {
                completion(thumbnail.UIImage);
            }
        });
    }];
}

// MARK: - CustomMenuViewDelegate
- (void)customMenuViewDidSelectItemAtIndex:(NSInteger)index {
    switch (index) {
        case 0: // 照片
            [self.mediaPickerManager presentPhotoPicker];
            break;
        case 1: // 摄像头
            [self.mediaPickerManager presentCameraPicker];
            break;
        case 2: // 文件
            [self.mediaPickerManager presentFilePicker];
            break;
    }
}

// MARK: - MediaPickerManagerDelegate
- (void)mediaPicker:(MediaPickerManager *)picker didPickImages:(NSArray<UIImage *> *)images {
    // 遍历选中的图片，添加到附件数组，直到达到上限
    for (UIImage *image in images) {
        if (self.selectedAttachments.count < kMaxAttachmentCount) {
            [self.selectedAttachments addObject:image];
        } else {
            // 超出上限：忽略其余选择
            break;
        }
    }
    [self updateAttachmentsDisplay];
    [self updateSendButtonState];
}

- (void)mediaPicker:(MediaPickerManager *)picker didPickDocumentAtURL:(NSURL *)url {
    // 检查是否为网络图片URL
    if ([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"]) {
        // 项目不支持网络图片作为附件，直接返回
        return;
    }
    // 本地文件添加到附件数组（受上限限制）
    if (self.selectedAttachments.count < kMaxAttachmentCount) {
        [self.selectedAttachments addObject:url];
    }
    [self updateAttachmentsDisplay];
    [self updateSendButtonState];
}

// MARK: - UITextViewDelegate
- (void)textViewDidChange:(UITextView *)textView {
    // 更新占位状态
    [self updatePlaceholderVisibility];
    
    // 更新发送按钮状态
    [self updateSendButtonState];
    
    // 使用 sizeThatFits 进行 1～4 行自适应高度
    CGFloat lineHeight = self.inputTextView.font.lineHeight;
    UIEdgeInsets insets = textView.textContainerInset;
    CGFloat singleLineHeight = lineHeight + insets.top + insets.bottom;
    CGFloat maxHeight = lineHeight * 4 + insets.top + insets.bottom;

    CGFloat availableWidth = textView.bounds.size.width;
    if (availableWidth <= 0) { availableWidth = textView.frame.size.width; }
    if (availableWidth <= 0) { availableWidth = MAX(self.view.bounds.size.width - 100.0, 100.0); }

    CGSize fitting = [textView sizeThatFits:CGSizeMake(availableWidth, CGFLOAT_MAX)];
    CGFloat desired = MAX(singleLineHeight, MIN(fitting.height, maxHeight));

    if (fabs(self.inputTextViewHeightConstraint.constant - desired) > 0.5) {
        self.inputTextViewHeightConstraint.constant = desired;
        [self.view layoutIfNeeded];
        [self scrollToBottom];
    } else if (desired >= maxHeight) {
        // 达到最大高度时，确保内容可见
        [self scrollToBottom];
    }
}

- (void)updatePlaceholderVisibility {
    // 根据输入文本长度更新占位可见性
    self.placeholderLabel.hidden = self.inputTextView.text.length > 0;
}

- (void)updateSendButtonState {
    // 等待回复时切换为暂停按钮，不受内容输入影响
    if (self.isAwaitingResponse) {
        [self.sendButton setImage:[UIImage systemImageNamed:@"pause.circle.fill"] forState:UIControlStateNormal];
        self.sendButton.enabled = YES;
        self.sendButton.alpha = 1.0;
        return;
    }
    // 非等待态：依据输入/附件启用发送
    BOOL hasContent = self.inputTextView.text.length > 0 || self.selectedAttachments.count > 0;
    [self.sendButton setImage:[UIImage systemImageNamed:@"arrow.up.circle.fill"] forState:UIControlStateNormal];
    self.sendButton.enabled = hasContent;
    self.sendButton.alpha = hasContent ? 1.0 : 0.5;
}

// 删除 calculateLineCountForTextView:，改为 sizeThatFits
- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    if ([text isEqualToString:@"\n"] && textView.text.length == 0) {
        return NO;
    }
    return YES;
}

- (BOOL)textViewShouldBeginEditing:(UITextView *)textView {
    // 开始编辑时滚动到底部
    [self forceScrollToBottomAnimated:NO];
    return YES;
}

// MARK: - AI流式响应
// 核心逻辑：AI流式响应处理 (已修复单次响应重复问题)
- (void)simulateAIResponse {
    // 复位流式状态
    // 1. 重置所有相关状态
    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
    }
    [self.fullResponseBuffer setString:@""];
    self.currentUpdatingAIMessage = nil;
    self.currentUpdatingAINode = nil;
    
    // 2. 显示"Thinking"状态
    // 重置语义解析器以开始新的流
    [self.semanticParser reset];
    [self.semanticRenderedBuffer setString:@""];
    // 步骤 1: 设置状态并计算出"思考视图"将要被插入的位置
    self.isAIThinking = YES;
    // 若有待处理图片，先设置占位提示（分类后会更新为生成/理解）
    if (self.pendingImageURLs.count > 0) {
        self.thinkingHintText = @"正在分析图片意图…";
    } else {
        self.thinkingHintText = @"正在思考…";
    }
    [self enterAwaitingState];
    NSIndexPath *thinkingIndexPath = [NSIndexPath indexPathForRow:self.messages.count inSection:0];
    
    // 步骤 2: 执行带动画的UI更新，插入"思考视图"所在的行
    [self.tableNode performBatchUpdates:^{
        [self.tableNode insertRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationNone];
    } completion:^(BOOL finished) {
        if (finished) {
            // 使用一个微小的延迟来确保布局已经完成
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                // 无动画直接贴到底部，避免插入瞬间抖动
                [self.tableNode scrollToRowAtIndexPath:thinkingIndexPath
                                      atScrollPosition:UITableViewScrollPositionBottom
                                              animated:NO];
            });
        }
    }];
    
    // 3. 构建历史消息，并在有图片时先进行"生成/理解"分类
    NSMutableArray *messages = [self buildMessageHistory];
    NSArray<NSURL *> *imageURLsForThisRound = self.pendingImageURLs;
    __weak typeof(self) weakSelf = self;
    if (imageURLsForThisRound.count > 0) {
        // 固定使用 gpt-4o 进行图片功能意图分类（与默认文本模型区分开），T=0.3
        
        [[APIManager sharedManager] classifyIntentWithMessages:messages temperature:0.3 completion:^(NSString * _Nullable label, NSError * _Nullable error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                label = @"理解";
            }
            NSString *decision = ([label isKindOfClass:[NSString class]] && [label containsString:@"生成"]) ? @"生成" : @"理解";
            
            // 使用调用级别配置，避免修改全局默认设置

            if ([decision isEqualToString:@"生成"]) {
                // 更新思考提示为"图片生成"
                self.thinkingHintText = @"当前正在进行图片生成";
                if (self->_currentThinkingNode && [self->_currentThinkingNode respondsToSelector:@selector(setHintText:)]) {
                    [self->_currentThinkingNode setHintText:self.thinkingHintText];
                }
                // 图片生成：取第一张作为 base_image_url，提示词用最近用户纯文本
                NSString *userText = [strongSelf latestUserPlainText] ?: @"";
                NSString *baseURL = imageURLsForThisRound.firstObject.absoluteString ?: @"";
                
                // 直接使用调用级别的 DashScope Key，不修改全局设置
                [[APIManager sharedManager] generateImageWithPrompt:userText baseImageURL:baseURL apiKey:@"sk-ec4677b09f5a4126af3ad17d763c60ed" completion:^(NSArray<NSURL *> * _Nullable imageURLs, NSError * _Nullable genErr) {
                    if (genErr || imageURLs.count == 0) {
                        // 移除思考视图并给出失败文案
                        strongSelf.isAIThinking = NO;
                        [strongSelf.tableNode performBatchUpdates:^{
                            [strongSelf.tableNode deleteRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationNone];
                        } completion:nil];
                        NSString *failText = @"抱歉，图片生成失败，请稍后再试。";
                        [strongSelf addMessageWithText:failText attachments:@[] isFromUser:NO completion:nil];
                        strongSelf.pendingImageURLs = nil;
                        // 恢复发送按钮状态
                        [strongSelf exitAwaitingState];
                        return;
                    }
                    // 生成成功：拼装带附件链接的AI消息（文本+缩略图）
                    NSMutableString *aiText = [NSMutableString stringWithString:@"已生成图片。"];
                    [aiText appendString:@"\n\n[附件链接：\n"]; 
                    for (NSURL *u in imageURLs) {
                        [aiText appendFormat:@"- %@\n", u.absoluteString];
                    }
                    [aiText appendString:@"]"]; 

                    // 移除思考视图，插入最终AI消息
                    strongSelf.isAIThinking = NO;
                    [strongSelf.tableNode performBatchUpdates:^{
                        [strongSelf.tableNode deleteRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationNone];
                    } completion:nil];
                    [strongSelf addMessageWithText:aiText attachments:@[] isFromUser:NO completion:nil];
                    strongSelf.pendingImageURLs = nil;
                    // 恢复发送按钮状态
                    [strongSelf exitAwaitingState];
                }];
                return; // 生成分支结束
            }

            // 理解：使用 DashScope 兼容模式端点与 qvq-plus 模型（按调用级别传入）
            // 更新思考提示为"图片理解"
            self.thinkingHintText = @"当前正在进行图片理解";
            if (self->_currentThinkingNode && [self->_currentThinkingNode respondsToSelector:@selector(setHintText:)]) {
                [self->_currentThinkingNode setHintText:self.thinkingHintText];
            }
            NSString *dashscopeBaseURL = @"https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions";
            NSString *dashscopeKey = @"sk-ec4677b09f5a4126af3ad17d763c60ed";

            // 将最后一条用户消息替换为 image_url + text 的数组
            NSInteger lastUserIndex = -1;
            for (NSInteger i = messages.count - 1; i >= 0; i--) {
                NSDictionary *m = messages[i];
                if ([[m valueForKey:@"role"] isKindOfClass:[NSString class]] && [[m valueForKey:@"role"] isEqualToString:@"user"]) {
                    lastUserIndex = i; break;
                }
            }
            NSMutableArray *contentParts = [NSMutableArray array];
            for (NSURL *u in imageURLsForThisRound) {
                NSString *urlStr = [u isKindOfClass:[NSURL class]] ? (u.absoluteString ?: @"") : @"";
                if (urlStr.length > 0) {
                    [contentParts addObject:@{ @"type": @"image_url", @"image_url": @{ @"url": urlStr } }];
                }
            }
            NSString *userText2 = [strongSelf latestUserPlainText] ?: @"";
            [contentParts addObject:@{ @"type": @"text", @"text": userText2 }];
            if (lastUserIndex >= 0) {
                NSDictionary *old = messages[lastUserIndex];
                NSMutableDictionary *userMsg = [old mutableCopy];
                userMsg[@"content"] = contentParts;
                messages[lastUserIndex] = [userMsg copy];
            } else {
                [messages addObject:@{ @"role": @"user", @"content": contentParts }];
            }
            
            strongSelf.currentStreamingTask = [[APIManager sharedManager] streamingChatCompletionWithMessages:messages model:@"qvq-plus" baseURL:dashscopeBaseURL apiKey:dashscopeKey streamCallback:^(NSString *partialResponse, BOOL isDone, NSError *error) {
                __strong typeof(weakSelf) sself = weakSelf;
                if (!sself) { return; }
                // 后台准备 → 主线程渲染
                dispatch_async(sself.semanticQueue, ^{
                    if (error) {
                        dispatch_async(dispatch_get_main_queue(), ^{
                            [sself ui_handleTextStreamError:error thinkingIndexPath:thinkingIndexPath];
                        });
                        return;
                    }
                    [sself.fullResponseBuffer setString:(partialResponse ?: @"")];
                    if (sself.isUIUpdatePaused && !isDone) { return; }
                    NSArray<NSString *> *preparedBlocks = [sself.semanticParser consumeFullText:(partialResponse ?: @"") isDone:isDone];
                    if (preparedBlocks.count == 0) { return; }
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [sself ui_applyPreparedBlocks:preparedBlocks isDone:isDone thinkingIndexPath:thinkingIndexPath];
                        if (isDone) {
                            sself.currentStreamingTask = nil;
                            if (sself.currentUpdatingAIMessage) {
                                [sself.currentUpdatingAIMessage setValue:sself.fullResponseBuffer forKey:@"content"];
                                [[CoreDataManager sharedManager] saveContext];
                            }
                            sself.pendingImageURLs = nil;
                            [sself exitAwaitingState];
                            if (sself.isUIUpdatePaused) { sself.isUIUpdatePaused = NO; }
                        }
                    });
                });
            }];
        }];
        return; // 已进入分类分支
    }

    // 无图片：按现状直接走文本流式
    self.currentStreamingTask = [[APIManager sharedManager] streamingChatCompletionWithMessages:messages images:nil streamCallback:^(NSString *partialResponse, BOOL isDone, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }

        // 后台串行队列：准备数据（不触碰 UI）
        dispatch_async(strongSelf.semanticQueue, ^{
            // 错误无需准备数据，直接切回主线程处理
            if (error) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    [strongSelf ui_handleTextStreamError:error thinkingIndexPath:thinkingIndexPath];
                });
                return;
            }

            // 覆盖全量缓冲区
            [strongSelf.fullResponseBuffer setString:(partialResponse ?: @"")];
            // UI 暂停：未结束前跳过推进
            if (strongSelf.isUIUpdatePaused && !isDone) { return; }

            // 语义分块（仅在完成块时推进）
            NSArray<NSString *> *preparedBlocks = [strongSelf.semanticParser consumeFullText:(partialResponse ?: @"") isDone:isDone];
            if (preparedBlocks.count == 0) { return; }

            // 主线程：应用渲染
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf ui_applyPreparedBlocks:preparedBlocks isDone:isDone thinkingIndexPath:thinkingIndexPath];

                // 完结收尾（不做额外 UI 干预）
                if (isDone) {
                    strongSelf.currentStreamingTask = nil;
                    if (strongSelf.currentUpdatingAIMessage) {
                        [strongSelf.currentUpdatingAIMessage setValue:strongSelf.fullResponseBuffer forKey:@"content"];
                        [[CoreDataManager sharedManager] saveContext];
                    }
                    strongSelf.pendingImageURLs = nil;
                    [strongSelf exitAwaitingState];
                }
            });
        });
    }];
}

// MARK: - 流式回调：主线程 UI 应用（无业务计算）
- (void)ui_applyPreparedBlocks:(NSArray<NSString *> *)blocks isDone:(BOOL)isDone thinkingIndexPath:(NSIndexPath *)thinkingIndexPath {
    if (blocks.count == 0) { return; }
    NSString *displayText = [blocks componentsJoinedByString:@""];
    [self.semanticRenderedBuffer appendString:displayText];

    if (self.isAIThinking) {
        // 首块：先插入空 AI 行，再把块从“思考”切换到“答案”
        self.currentUpdatingAIMessage = [[CoreDataManager sharedManager] addMessageToChat:self.chat content:@"" isFromUser:NO];
        [self fetchMessages];
        NSIndexPath *finalMessagePath = [NSIndexPath indexPathForRow:self.messages.count - 1 inSection:0];
        [self anchorScrollToBottomIfNeeded];
        [self performUpdatesPreservingBottom:^{
            [UIView performWithoutAnimation:^{
                [self.tableNode performBatchUpdates:^{
                    [self.tableNode insertRowsAtIndexPaths:@[finalMessagePath] withRowAnimation:UITableViewRowAnimationNone];
                } completion:^(BOOL finished) {
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        id node = self->_currentUpdatingAINode;
                        if (finished) {
                            [self transitionThinkingToAnswerAndAppendBlocks:blocks isFinal:isDone toNode:node];
                        }
                    });
                }];
            }];
        }];
        [self anchorScrollToBottomIfNeeded];
    } else {
        [self performUpdatesPreservingBottom:^{
            [self appendBlocks:blocks isFinal:isDone toNode:self->_currentUpdatingAINode];
        }];
        [self anchorScrollToBottomIfNeeded];
    }
}

// MARK: - 流式回调：主线程错误处理（无业务计算）
- (void)ui_handleTextStreamError:(NSError *)error thinkingIndexPath:(NSIndexPath *)thinkingIndexPath {
    if (!error) { return; }
    if (error.code == NSURLErrorCancelled) {
        // 取消：移除思考行并静默结束
        self.isAIThinking = NO;
        [self.tableNode performBatchUpdates:^{
            [self.tableNode deleteRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationNone];
        } completion:nil];
        return;
    }

    if (self.isAIThinking) {
        // 首包错误：移除思考行并插入错误消息
        self.isAIThinking = NO;
        [self.tableNode performBatchUpdates:^{
            [self.tableNode deleteRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationNone];
        } completion:nil];
        NSString *errText = [NSString stringWithFormat:@"抱歉，本次回复失败：%@（%ld）", error.localizedDescription ?: @"未知错误", (long)error.code];
        [self addMessageWithText:errText attachments:@[] isFromUser:NO completion:nil];
        [self anchorScrollToBottomIfNeeded];
        [self exitAwaitingState];
    } else {
        // 后续包错误：在已渲染内容末尾追加错误提示并持久化
        NSString *suffix = [NSString stringWithFormat:@"\n\n[错误] 本次回复已中断：%@（%ld）", error.localizedDescription ?: @"未知错误", (long)error.code];
        [self performUpdatesPreservingBottom:^{
            [self appendBlocks:@[suffix] isFinal:YES toNode:self->_currentUpdatingAINode];
        }];
        [self anchorScrollToBottomIfNeeded];
        if (self.currentUpdatingAIMessage) {
            NSString *finalContent = [NSString stringWithFormat:@"%@%@", (self.fullResponseBuffer ?: @""), suffix];
            [self.currentUpdatingAIMessage setValue:finalContent forKey:@"content"];
            [[CoreDataManager sharedManager] saveContext];
        }
        [self exitAwaitingState];
    }
    self.currentStreamingTask = nil;
    self.pendingImageURLs = nil;
}


// MARK: - 消息添加与历史构建
- (void)addMessageWithText:(NSString *)text
                attachments:(NSArray *)attachments
                isFromUser:(BOOL)isFromUser
                completion:(nullable void (^)(void))completion {
    // 1) 直接使用文本；附件已在发送前上传并以 [附件链接：] 形式附加
    NSString *messageContent = text;

    // 2) 直接在数据源数组尾部追加（避免 reloadData 和重复 fetch）
    NSManagedObject *inserted = [[CoreDataManager sharedManager] addMessageToChat:self.chat content:messageContent isFromUser:isFromUser];
    if (!self.messages) { self.messages = [NSMutableArray array]; }
    if (![self.messages isKindOfClass:[NSMutableArray class]]) {
        self.messages = [[self.messages mutableCopy] ?: [NSMutableArray array] mutableCopy];
    }
    NSUInteger insertRow = self.messages.count;
    [(NSMutableArray *)self.messages addObject:inserted];
    NSIndexPath *newIndexPath = [NSIndexPath indexPathForRow:insertRow inSection:0];

    // 3) 仅插入最后一行，禁止整表刷新；使用无动画，避免闪烁/抖动
    [UIView performWithoutAnimation:^{
        // 调用 nodeBlockForRowAtIndexPath 使用 richmessagenode 进行更新数据
        [self.tableNode performBatchUpdates:^{
            [self.tableNode insertRowsAtIndexPaths:@[newIndexPath] withRowAnimation:UITableViewRowAnimationNone];
        } completion:^(BOOL finished) {
            if (finished) {
                // 4) 强制贴底（无动画），确保新消息出现在底部
                [self.tableNode scrollToRowAtIndexPath:newIndexPath atScrollPosition:UITableViewScrollPositionBottom animated:NO];
                if (completion) { completion(); }
            }
        }];
    }];
}

// 辅助方法，用于构建消息历史
- (NSMutableArray *)buildMessageHistory {
    NSMutableArray *messages = [NSMutableArray array];
    
    // 添加系统提示，包含文件格式支持信息
    NSString *systemPrompt = [APIManager sharedManager].defaultSystemPrompt ?: @"";
    if (systemPrompt.length > 0) {
        // 在系统提示中添加文件格式支持说明
        NSString *enhancedPrompt = [NSString stringWithFormat:@"%@\n\n支持的文件格式：\n- 图片：JPG、PNG、GIF、WebP等常见图片格式\n- 网络图片：支持HTTP/HTTPS链接的图片\n- 文档：PDF、TXT、DOC、DOCX等文档格式\n\n当用户发送包含附件的消息时，请根据附件内容提供相应的帮助和建议。", systemPrompt];
        
        [messages addObject:@{
            @"role": @"system",
            @"content": enhancedPrompt
        }];
    } else {
        // 如果没有默认系统提示，创建一个包含文件格式支持的提示
        NSString *defaultPrompt = @"您好！我是ChatGPT，一个AI助手。我可以帮助您解答问题，分析图片和文档内容。\n\n支持的文件格式：\n- 图片：JPG、PNG、GIF、WebP等常见图片格式\n- 网络图片：支持HTTP/HTTPS链接的图片\n- 文档：PDF、TXT、DOC、DOCX等文档格式\n\n当您发送包含附件的消息时，我会根据附件内容提供相应的帮助和建议。请问有什么我可以帮您的吗？";
        
        [messages addObject:@{
            @"role": @"system",
            @"content": defaultPrompt
        }];
    }
    
    // 添加历史消息（最多4轮对话，即8条消息）
    NSInteger messageCount = self.messages.count;
    NSInteger startIndex = MAX(0, messageCount - 8);
    
    for (NSInteger i = startIndex; i < messageCount; i++) {
        NSManagedObject *message = self.messages[i];
        id raw = [message valueForKey:@"content"];
        NSString *content = [raw isKindOfClass:[NSString class]] ? (NSString *)raw : @"";
        BOOL isFromUser = [[message valueForKey:@"isFromUser"] boolValue];
        
        [messages addObject:@{
            @"role": isFromUser ? @"user" : @"assistant",
            @"content": content
        }];
    }
    
    return messages;
}

// 提取最近一条用户消息的纯文本（去除附件链接块）
- (NSString *)latestUserPlainText {
    for (NSInteger i = self.messages.count - 1; i >= 0; i--) {
        NSManagedObject *msg = self.messages[i];
        BOOL isFromUser = [[msg valueForKey:@"isFromUser"] boolValue];
        if (isFromUser) {
            id raw = [msg valueForKey:@"content"];
            NSString *content = [raw isKindOfClass:[NSString class]] ? (NSString *)raw : @"";
            content = [MessageContentUtils displayTextByStrippingAttachmentBlock:content];
            return content;
        }
    }
    return @"";
}

// MARK: - 弹窗和提示
- (void)showAPIKeyAlert {
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"OpenAIAPIKey"];
    [AlertHelper showAPIKeyAlertOn:self withCurrentKey:apiKey withSaveHandler:^(NSString *newKey) {
        // 保存API Key
        [[NSUserDefaults standardUserDefaults] setObject:newKey forKey:@"OpenAIAPIKey"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        // 设置API Manager的API Key
        [[APIManager sharedManager] setApiKey:newKey];
        
        // 显示成功提示
        [AlertHelper showAlertOn:self withTitle:@"成功" message:@"API Key 已保存" buttonTitle:@"确定"];
    }];
}

- (void)showNeedAPIKeyAlert {
    [AlertHelper showNeedAPIKeyAlertOn:self withSettingHandler:^{
        [self showAPIKeyAlert]; // 调用下一个弹窗
    }];
}

- (void)resetAPIKey {
    [AlertHelper showConfirmationAlertOn:self
                               withTitle:@"重置 API Key"
                                 message:@"确定要重置当前的 API Key 吗？"
                            confirmTitle:@"重置"
                     confirmationHandler:^{
        // 清除保存的API Key
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"OpenAIAPIKey"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        // 清空API Manager中的API Key
        [[APIManager sharedManager] setApiKey:@""];
        
        // 显示成功提示
        [AlertHelper showAlertOn:self withTitle:@"成功" message:@"API Key 已重置，请设置新的 API Key" buttonTitle:@"确定"];
        
        // 提示用户设置新的API Key
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showAPIKeyAlert];
        });
    }];
}

// MARK: - 发送/暂停按钮状态与逻辑
- (void)enterAwaitingState {
    self.isAwaitingResponse = YES;
    // 切换按钮为暂停并启用
    [self updateSendButtonState];
}

- (void)exitAwaitingState {
    self.isAwaitingResponse = NO;
    // 恢复按钮为发送图标，并按输入状态更新可用性
    [self updateSendButtonState];
}

- (void)handlePauseTapped {
    // 停止流式任务
    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
        self.currentStreamingTask = nil;
    }
    
    // 情形1：仍处于思考视图（尚未产生AI消息）
    if (self.isAIThinking) {
        self.isAIThinking = NO;
        NSIndexPath *thinkingPath = [NSIndexPath indexPathForRow:self.messages.count inSection:0];
        [self.tableNode performBatchUpdates:^{
            [self.tableNode deleteRowsAtIndexPaths:@[thinkingPath] withRowAnimation:UITableViewRowAnimationNone];
        } completion:nil];
        [self addMessageWithText:@"当前回复未思考未完成" attachments:@[] isFromUser:NO completion:nil];
        [self exitAwaitingState];
        return;
    }
    
    // 情形2：已经进入流式显示，但未结束 -> 保存当前已接收未完整显示的内容
    if (self.currentUpdatingAIMessage) {
        NSString *partial = self.fullResponseBuffer.length > 0 ? [self.fullResponseBuffer copy] : @"";
        [self.currentUpdatingAIMessage setValue:partial forKey:@"content"];
        [[CoreDataManager sharedManager] saveContext];
        [self.tableNode reloadData];
    }
    
    [self exitAwaitingState];
}

// MARK: - 模型的映射和选择
// 统一模型显示标题映射
- (NSString *)displayTitleForModelName:(NSString *)modelName {
    NSDictionary *displayMap = @{ @"gpt-5": @"GPT-5", @"gpt-4.1": @"GPT-4.1", @"gpt-4o": @"GPT-4o" };
    NSString *displayTitle = displayMap[modelName];
    return displayTitle ?: modelName;
}

-(void)showModelSelectionMenu:(UIButton *)sender {
    NSArray *models = @[@"gpt-5", @"gpt-4.1", @"gpt-4o"]; // 支持的模型
    
    // 构建操作数组
    NSMutableArray *actions = [NSMutableArray array];
    for (NSString *model in models) {
        [actions addObject:@{
            model: ^{
                [self updateModelSelection:model button:sender];
            }
        }];
    }
    
    [AlertHelper showActionMenuOn:self title:@"选择模型" actions:actions cancelTitle:@"取消"];
}

-(void)updateModelSelection:(NSString *)modelName button:(UIButton *)button {
    [APIManager sharedManager].currentModelName = modelName;
    NSString *displayTitle = [self displayTitleForModelName:modelName];
    [button setTitle:displayTitle forState:UIControlStateNormal];
    [[NSUserDefaults standardUserDefaults] setObject:modelName forKey:@"SelectedModelName"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// MARK: - 应用程序状态通知处理

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    // 应用进入后台
    // 确保取消任何正在进行的任务
    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
        self.currentStreamingTask = nil;
    }
}

- (void)applicationWillResignActive:(NSNotification *)notification {
    [self persistPartialAIMessageIfNeeded];
}

// MARK: - UIScrollViewDelegate 维护粘底状态
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    self.userIsDragging = YES;
    
    // 关键优化：用户开始滑动时，暂停所有UI更新
    [self pauseUIUpdates];

    // 取消本帧待处理的自动粘底，避免与用户手势抢夺
    if (self.pendingAutoScrollTask) {
        dispatch_block_cancel(self.pendingAutoScrollTask);
        self.pendingAutoScrollTask = nil;
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    self.userIsDragging = NO;
    if (!decelerate) {
        [self resumeUIUpdates];
    }
    // 标记减速状态
    self.isDecelerating = decelerate;
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    [self resumeUIUpdates];
    self.isDecelerating = NO;
}

// 新增：获取当前AI节点的索引路径
// 提供稳定的测量约束，保证节点在预期宽度下计算高度
- (ASSizeRange)tableNode:(ASTableNode *)tableNode constrainedSizeForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 优先使用已经布局过的宽度
    CGFloat contentWidth = CGRectGetWidth(tableNode.view.bounds);
    
    // 回退1：如果此时 view 还未布局，尝试使用 node 自身的 bounds
    if (contentWidth <= 0) {
        contentWidth = CGRectGetWidth(tableNode.bounds);
    }
    
    // 回退2：如果依然为0，使用屏幕宽度作为兜底
    if (contentWidth <= 0) {
        contentWidth = CGRectGetWidth([UIScreen mainScreen].bounds);
    }
    
    // 扣除安全区（若可用）
    CGFloat safeInsetSum = 0;
    if (@available(iOS 11.0, *)) {
        UIEdgeInsets safeInsets = tableNode.view.safeAreaInsets;
        safeInsetSum = safeInsets.left + safeInsets.right;
    }
    
    // 我们在 layoutSpec 中使用了左右各 12 的外边距，这里同步扣除
    CGFloat horizontalMargins = 24.0;
    
    // 计算最终宽度，并保证始终为正
    CGFloat finalWidth = contentWidth - safeInsetSum - horizontalMargins;
    if (finalWidth < 1.0) {
        // 如果扣除安全区后不合理，则仅扣除边距
        finalWidth = contentWidth - horizontalMargins;
    }
    if (finalWidth < 1.0) {
        // 最终兜底，确保为正值
        finalWidth = 1.0;
    }
    
    CGSize min = CGSizeMake(finalWidth, 1);
    CGSize max = CGSizeMake(finalWidth, CGFLOAT_MAX);
    return ASSizeRangeMake(min, max);
}

- (NSString *)messageAtIndexPath:(NSIndexPath *)indexPath {
    // 思考行不对应消息内容
    if (self.isAIThinking && indexPath.row == self.messages.count) {
        return @"";
    }
    if (indexPath.row < 0 || indexPath.row >= self.messages.count) {
        return @"";
    }
    NSManagedObject *message = self.messages[indexPath.row];
    id rawContent = [message valueForKey:@"content"];
    NSString *content = [rawContent isKindOfClass:[NSString class]] ? (NSString *)rawContent : @"";
    return [MessageContentUtils displayTextByStrippingAttachmentBlock:content];
}

- (BOOL)isMessageFromUserAtIndexPath:(NSIndexPath *)indexPath {
    // 思考行视为AI
    if (self.isAIThinking && indexPath.row == self.messages.count) {
        return NO;
    }
    if (indexPath.row < 0 || indexPath.row >= self.messages.count) {
        return NO;
    }
    NSManagedObject *message = self.messages[indexPath.row];
    NSNumber *isFromUser = [message valueForKey:@"isFromUser"];
    return isFromUser.boolValue;
}

- (BOOL)isIndexPathCurrentAINode:(NSIndexPath *)indexPath {
    // 仅当 indexPath 对应当前正在更新的 AI 消息时返回 YES
    if (!self.currentUpdatingAIMessage) { return NO; }
    if (indexPath.row < 0 || indexPath.row >= self.messages.count) { return NO; }
    NSManagedObject *message = self.messages[indexPath.row];
    // 更稳妥地比较 objectID，避免不同上下文导致的指针不相等
    return [message.objectID isEqual:self.currentUpdatingAIMessage.objectID];
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // 允许与子视图（如代码块里的scroll/长按）同时识别，避免"滑不动"
    return YES;
}

// 新增：在近底部时，保持底部对齐地执行更新（避免先扩展再滚动）
- (void)performUpdatesPreservingBottom:(dispatch_block_t)updates {
    if (!updates) return;
    UITableView *tv = self.tableNode.view;
    BOOL shouldStick = [self shouldPerformAutoScroll];
    [UIView performWithoutAnimation:^{
        updates();
        // 避免同步布局；由 displayLink 合并器在下一帧统一处理
        if (shouldStick) {
            [self requestBottomAnchorWithContext:@"performUpdatesPreservingBottom"]; // 合并到下一帧
        }
    }];
}

// 新增：暂停UI更新
- (void)pauseUIUpdates {
    self.isUIUpdatePaused = YES;
    
    // 暂停富文本节点的动画
    if (self->_currentUpdatingAINode && [self->_currentUpdatingAINode isKindOfClass:[RichMessageCellNode class]]) {
        RichMessageCellNode *richNode = (RichMessageCellNode *)self->_currentUpdatingAINode;
        if ([richNode respondsToSelector:@selector(pauseStreamingAnimation)]) {
            [richNode performSelector:@selector(pauseStreamingAnimation)];
        }
    }
}

// 新增：恢复UI更新
- (void)resumeUIUpdates {
    self.isUIUpdatePaused = NO;
    
    // 恢复富文本节点的动画
    if (self->_currentUpdatingAINode && [self->_currentUpdatingAINode isKindOfClass:[RichMessageCellNode class]]) {
        RichMessageCellNode *richNode = (RichMessageCellNode *)self->_currentUpdatingAINode;
        if ([richNode respondsToSelector:@selector(resumeStreamingAnimation)]) {
            [richNode performSelector:@selector(resumeStreamingAnimation)];
        }
    }
}

// MARK: - 统一的自动滚动协调器

// 新增：统一的自动滚动协调器（非动画版本委托到带动画实现）
- (void)performAutoScrollWithContext:(NSString *)context {
    [self performAutoScrollWithContext:context animated:NO];
}

- (void)performAutoScrollWithContext:(NSString *)context animated:(BOOL)animated {
    CFTimeInterval __t0 = 0; CFTimeInterval __dt = 0;

    if (![self shouldPerformAutoScroll]) { return; }
    UITableView *tv = self.tableNode.view;
    if (!tv) { return; }
    if (!tv.window) { return; } // 未进入窗口，避免提前布局与滚动
    // 避免强制布局，直接根据当前 contentSize 计算目标偏移
    CGPoint currentOffset = tv.contentOffset;
    CGPoint targetOffset = [self _bottomContentOffsetForTable:tv];

    if (fabs(currentOffset.y - targetOffset.y) < 1.0) { return; }

    [tv setContentOffset:targetOffset animated:animated];
    (void)__t0; (void)__dt;
}

#pragma mark - 事件驱动 + 防抖粘底

- (void)requestBottomAnchorWithContext:(NSString *)context {
    if (![self shouldPerformAutoScroll]) { return; }
    if (self.pendingAutoScrollTask) { return; }
    __weak typeof(self) weakSelf = self;
    self.pendingAutoScrollTask = dispatch_block_create(0, ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }
        strongSelf.pendingAutoScrollTask = nil;
        [strongSelf performAutoScrollWithContext:context animated:NO];
    });
    // 防抖（可按需调整）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kAutoScrollDebounceSeconds * NSEC_PER_SEC)), dispatch_get_main_queue(), self.pendingAutoScrollTask);
}

// 粘底滚动已统一由帧级合并器处理，移除节流版本接口

// 新增：智能滚动检测
- (BOOL)shouldPerformAutoScroll {
    if (self.userIsDragging) { 
        return NO; 
    }
    // 当输入框处于编辑状态时，若用户不在底部，则不强行粘底，避免"点输入框后滑动又被拉回底部"
    if ([self.inputTextView isFirstResponder] && ![self isNearBottomWithTolerance:40.0]) {
        return NO;
    }
    // 减速中：避免与系统减速动画竞争
    if (self.isDecelerating) {
        return NO;
    }
    
    if (self.codeBlockInteracting) {
        return NO;
    }
    
    UITableView *tv = self.tableNode.view;
    if (!tv) { 
        return NO; 
    }
    CGFloat contentHeight = tv.contentSize.height;
    CGFloat viewHeight = tv.bounds.size.height;
    CGFloat currentOffset = tv.contentOffset.y;
    
    // 如果内容还没填满一屏，也仅在接近底部时才允许自动滚动
    if (contentHeight <= viewHeight + 1.0) { 
        return [self isNearBottomWithTolerance:kAutoScrollBottomTolerance];
    }
    
    // 更宽松的底部检测，提高响应性
    BOOL nearBottom = [self isNearBottomWithTolerance:kAutoScrollBottomTolerance];
    
    return nearBottom;
}

// MARK: - 内容大小监控
- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"contentSize"] && object == self.tableNode.view) {
        CGSize oldSize = [change[NSKeyValueChangeOldKey] CGSizeValue];
        CGSize newSize = [change[NSKeyValueChangeNewKey] CGSizeValue];
        
        // 检测内容高度的显著增长（通常由代码块扩展引起）
        CGFloat heightIncrease = newSize.height - oldSize.height;
        if (heightIncrease > kContentHeightIncreaseThreshold) { // 高度增长超过阈值
            [self requestBottomAnchorWithContext:@"contentSizeChanged"];
        }
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

// 新增：代码块横向拖动开始/结束
- (void)_onCodeBlockPanBegan:(NSNotification *)note {
    self.codeBlockInteracting = YES;
    [self pauseUIUpdates];
}

- (void)_onCodeBlockPanEnded:(NSNotification *)note {
    self.codeBlockInteracting = NO;
    [self resumeUIUpdates];
}

- (void)handleRichMessageWillAppendFirstLine:(NSNotification *)note {
    [self requestBottomAnchorWithContext:@"handleRichMessageWillAppendFirstLine"]; 
}

// 新增：强制滚动到底部（无条件，不经过 shouldPerformAutoScroll 判断）
- (void)forceScrollToBottomAnimated:(BOOL)animated {
    UITableView *tv = self.tableNode.view;
    if (!tv) { return; }
    if (!tv.window) { return; } // 未进入窗口，避免提前布局与滚动
    
    [tv layoutIfNeeded];
    
    CGPoint currentOffset = tv.contentOffset;
    CGPoint targetOffset = [self _bottomContentOffsetForTable:tv];
    
    [tv setContentOffset:targetOffset animated:animated];
}

#pragma mark - 思考行与块渲染辅助

- (void)removeThinkingRowIfNeeded {
    if (self.isAIThinking) {
        self.isAIThinking = NO;
        NSInteger thinkingRow = self.messages.count;
        NSIndexPath *currentThinkingPath = [NSIndexPath indexPathForRow:thinkingRow inSection:0];
        [self.tableNode performBatchUpdates:^{
            [self.tableNode deleteRowsAtIndexPaths:@[currentThinkingPath] withRowAnimation:UITableViewRowAnimationNone];
        } completion:nil];
    }
}

- (void)appendBlocks:(NSArray<NSString *> *)blocks isFinal:(BOOL)isDone toNode:(id)node {
    if ([node respondsToSelector:@selector(appendSemanticBlocks:isFinal:)]) {
        [node appendSemanticBlocks:blocks isFinal:isDone];
        if ([node respondsToSelector:@selector(setNeedsLayout)]) {
            [node setNeedsLayout];
        }
        [self anchorScrollToBottomIfNeeded];
    } else if ([node respondsToSelector:@selector(updateMessageText:)]) {
        NSString *accumulated = [self.semanticRenderedBuffer copy];
        [node updateMessageText:accumulated];
    }
}

- (void)transitionThinkingToAnswerAndAppendBlocks:(NSArray<NSString *> *)blocks isFinal:(BOOL)isDone toNode:(id)node {
    [self removeThinkingRowIfNeeded];
    [self appendBlocks:blocks isFinal:isDone toNode:node];
}

@end


