//
//  ChatDetailViewControllerV2.m
//  ChatGPT-OC-Clone
//
//  Created by mac—lzh on 2025/8/12.
//

#import "ChatDetailViewControllerV2.h"
#import <AsyncDisplayKit/ASDisplayNode+Beta.h>
#import "ThinkingNode.h"
#import "RichMessageCellNode.h"
#import "MessageCellNode.h"
#import "MediaMessageCellNode.h"
#import "AttachmentThumbnailView.h"
#import "CoreDataManager.h"
#import "APIManager.h"
@import CoreData;
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>
#import <AliyunOSSiOS/OSSService.h>
#import "OSSUploadManager.h"
#import "ImagePreviewOverlay.h"
#import "SemanticBlockParser.h"
#import <QuartzCore/QuartzCore.h>


// MARK: - 常量定义

// MARK: - 测试开关
// 设置为 YES 使用 RichMessageCell（支持富文本），设置为 NO 使用 MessageCellNode（纯文本）
// 修改这个值来测试不同的节点类型，无需修改其他代码
static const BOOL kUseRichMessageCell = YES;

@interface ChatDetailViewControllerV2 () <UITextViewDelegate, ASTableDataSource, ASTableDelegate, UIGestureRecognizerDelegate>

// MARK: - 数据相关属性
@property (nonatomic, strong) NSMutableArray *messages;
@property (nonatomic, strong) NSMutableArray *selectedAttachments; // 存储多个附件 (UIImage 或 NSURL)

// MARK: - UI组件属性
@property (nonatomic, strong) ASTableNode *tableNode;
@property (nonatomic, strong) UIView *inputContainerView;
@property (nonatomic, strong) UIView *inputBackgroundView;
@property (nonatomic, strong) UITextView *inputTextView;
@property (nonatomic, strong) UIButton *addButton;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) UIStackView *thumbnailsStackView; // 管理多个缩略图

// MARK: - 约束属性
@property (nonatomic, strong) NSLayoutConstraint *inputContainerBottomConstraint;
@property (nonatomic, strong) NSLayoutConstraint *thumbnailsContainerHeightConstraint; // 控制容器高度的核心约束

// MARK: - 业务逻辑属性
@property (nonatomic, strong) MediaPickerManager *mediaPickerManager;
@property (nonatomic, assign) BOOL isAIThinking; // 驱动UI状态

// MARK: - 流式更新相关属性
@property (nonatomic, strong) NSMutableString *fullResponseBuffer; // 流式响应的完整文本缓冲区
@property (nonatomic, weak) id currentUpdatingAINode; // 兼容普通与富文本节点
@property (nonatomic, copy) NSString *lastDisplayedSubstring; // 上次显示的文本内容，用于按行更新检测和避免重复布局
@property (nonatomic, assign) BOOL streamBusy; // 防重复/忙碌标记
@property (nonatomic, assign) BOOL isUIUpdatePaused; // 新增：UI更新暂停标志
@property (nonatomic, assign) BOOL isAwaitingResponse; // 新增：是否在等待模型回复（驱动发送/暂停按钮）
@property (nonatomic, strong) SemanticBlockParser *semanticParser; // 新增：语义块解析器
@property (nonatomic, strong) NSMutableString *semanticRenderedBuffer; // 新增：已渲染的语义块累积

// MARK: - 网络请求相关属性
@property (nonatomic, strong) NSURLSessionDataTask *currentStreamingTask;
@property (nonatomic, weak) NSManagedObject *currentUpdatingAIMessage; // 正在更新的AI消息对象

// MARK: - 布局优化属性
// 已移除控制器层面的高度缓存，保留 Cell 内部高度缓存实现

// MARK: - 滚动粘底属性
@property (nonatomic, assign) BOOL shouldAutoScrollToBottom; // 当用户未手动上滑时，自动粘底
@property (nonatomic, assign) BOOL userIsDragging;
@property (nonatomic, assign) BOOL isNearBottom; // 新增：是否接近底部
@property (nonatomic, assign) CGFloat lastContentOffsetY; // 新增：记录上次滚动位置
@property (nonatomic, assign) BOOL bottomAnchorScheduled; // 新增：粘底滚动节流标志
@property (nonatomic, assign) BOOL codeBlockInteracting; // 新增：代码块内部交互中（横向拖动）
@property (nonatomic, assign) BOOL isDecelerating; // 新增：减速中，暂停自动粘底

// MARK: - 多模态控制
@property (nonatomic, strong) NSArray<NSURL *> *pendingImageURLs; // 本轮要发送给多模态模型的图片URL

// MARK: - 底部锚定合并器（减少 RunLoop 压力）
@property (nonatomic, strong) CADisplayLink *bottomAnchorLink; // 每帧合并一次粘底滚动
@property (nonatomic, assign) BOOL needsBottomAnchor; // 是否有待处理的粘底请求

// MARK: - 生命周期标记
@property (nonatomic, assign) BOOL didInitialAppear; // 首次进入窗口后再做初始 reload/滚动



@end

@implementation ChatDetailViewControllerV2
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

// MARK: - 生命周期方法
- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 1. 初始化非视图相关的属性
    self.isAIThinking = NO;
    self.isAwaitingResponse = NO;
    self.fullResponseBuffer = [NSMutableString string];
    self.selectedAttachments = [NSMutableArray array];
    
    // 2. 初始化高度缓存系统（控制器层缓存已移除，保留 Cell 内部实现）
    self.lastDisplayedSubstring = @"";
    self.isUIUpdatePaused = NO; // 新增：初始化UI更新暂停标志
    self.semanticParser = [[SemanticBlockParser alloc] init];
    self.semanticRenderedBuffer = [NSMutableString string];

    
    // 粘底滚动初始化
    self.shouldAutoScrollToBottom = YES;
    self.userIsDragging = NO;
    self.isNearBottom = YES; // 初始状态设为接近底部，确保初始聊天时能自动滚动
    
    // 3. 初始化并添加核心UI组件（ASTableNode）
    // 必须在setupViews之前执行，因为setupViews会为tableNode创建约束
    _tableNode = [[ASTableNode alloc] initWithStyle:UITableViewStylePlain];
    _tableNode.dataSource = self;
    _tableNode.delegate = self;
    _tableNode.view.separatorStyle = UITableViewCellSeparatorStyleNone;
    
    // 关键改进：配置表视图属性以确保稳定的布局
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
    // 不限制触点数量，避免影响双指滚动等系统手势
    // _tableNode.view.panGestureRecognizer.delegate = self; // 禁止：系统要求其 delegate 必须为 scrollView 本身
    
    [self.view addSubnode:_tableNode];
    
    // 4. 设置所有视图和它的布局约束
    [self setupViews];
    
    // 5. 初始化辅助类和加载数据
    self.mediaPickerManager = [[MediaPickerManager alloc] initWithPresenter:self];
    self.mediaPickerManager.delegate = self;
    [self fetchMessages]; // 在UI设置好后加载数据
    
    // 6. 设置通知和其他UI状态
    [self updatePlaceholderVisibility];
    [self updateSendButtonState];
    [self setupNotifications];
    
    // 7. 加载用户设置和API Key
    [self loadUserSettings];

    // 8. 初始化阿里云 OSS（迁移到单例管理器）
    [[OSSUploadManager sharedManager] setupIfNeeded];
    
    // 9. 监控表格视图内容大小变化，用于自动滚动
    [self.tableNode.view addObserver:self forKeyPath:@"contentSize" options:NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld context:nil];

    // 初始化底部锚定合并器：以帧为单位合并滚动请求，降低 RunLoop 压力
    self.needsBottomAnchor = NO;
    self.bottomAnchorLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(_onBottomAnchorTick:)];
    // 使用 CommonModes 确保在滑动中也能运行
    [self.bottomAnchorLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    self.bottomAnchorLink.paused = YES; // 按需激活
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    // 等待首次进入窗口后再 reload，避免未在 window 层级时的额外布局
    if (self.didInitialAppear) {
        [self fetchMessages];
        [self.tableNode reloadData];
    }
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (!self.didInitialAppear) {
        self.didInitialAppear = YES;
        [self fetchMessages];
        [self.tableNode reloadData];
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
    
    // 重置动画与渲染状态
    // 控制器层面的 lastDisplayedSubstring 已不再使用
    self.streamBusy = NO;
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

    // 释放显示链接
    [self.bottomAnchorLink invalidate];
    self.bottomAnchorLink = nil;
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
    NSDictionary *displayMap = @{ @"gpt-5": @"GPT-5", @"gpt-4.1": @"GPT-4.1", @"gpt-4o": @"GPT-4o" };
    NSString *displayTitle = displayMap[modelName] ?: modelName;
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
    self.inputBackgroundView.backgroundColor = [UIColor systemGray6Color]; // 背景色延伸至底部
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
        [self.inputBackgroundView.topAnchor constraintEqualToAnchor:self.inputContainerView.topAnchor],
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
        [self.inputTextView.topAnchor constraintEqualToAnchor:self.thumbnailsStackView.bottomAnchor constant:8],
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

// 新增：获取消息的附件信息
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
    
    // 从规范化的文本中解析附件链接块：[附件链接：\n- url\n- url\n]
    if (content.length == 0) return @[];
    NSRange start = [content rangeOfString:@"[附件链接："];
    if (start.location == NSNotFound) return @[];
    NSRange end = [content rangeOfString:@"]" options:0 range:NSMakeRange(start.location, content.length - start.location)];
    if (end.location == NSNotFound || end.location <= start.location) return @[];

    NSString *block = [content substringWithRange:NSMakeRange(start.location, end.location - start.location)];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    [block enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
        NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trim hasPrefix:@"-"]) {
            NSString *candidate = [[trim substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSURL *u = [NSURL URLWithString:candidate];
            if (u && ([@"http" isEqualToString:u.scheme] || [@"https" isEqualToString:u.scheme])) {
                [urls addObject:u];
            }
        }
    }];
    return [urls copy];
}

// MARK: - 键盘处理
- (void)keyboardWillShow:(NSNotification *)notification {
    // 监控键盘的最终位置和大小
    CGRect keyboardFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    // 键盘动画的持续时间
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    // 键盘动画的曲线类型（如缓入缓出）
    UIViewAnimationCurve curve = [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    
    [UIView animateWithDuration:duration delay:0 options:(curve << 16) animations:^{
        self.inputContainerBottomConstraint.constant = -keyboardFrame.size.height;
        [self.view layoutIfNeeded];
        [self forceScrollToBottomAnimated:NO];
    } completion:nil];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    
    [UIView animateWithDuration:duration delay:0 options:(curve << 16) animations:^{
        self.inputContainerBottomConstraint.constant = 0;
        [self.view layoutIfNeeded];
        [self forceScrollToBottomAnimated:NO];
    } completion:nil];
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
                NSLog(@"[MultiModal Prompt/Preview] payload=%@", prompt);
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
            return [[ThinkingNode alloc] init];
        };
    }
    
    NSString *message = [self messageAtIndexPath:indexPath];
    BOOL isFromUser = [self isMessageFromUserAtIndexPath:indexPath];
    NSArray *attachments = [self attachmentsAtIndexPath:indexPath];
    
    return ^ASCellNode *{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        
        ASCellNode *node;
        
        // 优先使用富文本消息气泡，并在其上追加缩略图，保证文本一定显示
        if (kUseRichMessageCell) {
            RichMessageCellNode *rich = [[RichMessageCellNode alloc] initWithMessage:message isFromUser:isFromUser];
            // 设置默认的逐行渲染间隔（可按需调整）
            if ([rich respondsToSelector:@selector(setLineRenderInterval:)]) {
                [rich setLineRenderInterval:0.15]; // 150ms/行，延缓渲染速度
            }
            if (attachments.count > 0 && [rich respondsToSelector:@selector(setAttachments:)]) {
                [rich setAttachments:attachments];
            }
            node = rich;
        } else if (attachments.count > 0) {
            // 纯文本样式下也支持多媒体气泡
            node = [[MediaMessageCellNode alloc] initWithMessage:message isFromUser:isFromUser attachments:attachments];
        } else {
            // 使用普通文本单元格
            node = [[MessageCellNode alloc] initWithMessage:message isFromUser:isFromUser];
        }
        
        // 如果是当前在流式更新的 AI 节点，则记录引用
        if (!isFromUser && [strongSelf isIndexPathCurrentAINode:indexPath]) {
            strongSelf->_currentUpdatingAINode = (id)node; // 兼容接口：cachedSize、updateMessageText
        }
        return node;
    };
}

// MARK: - 滚动控制
- (void)scrollToBottom {
    if (self.messages.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self ensureBottomVisible:YES];
        });
    }
}

// 立即滚动到底部，无动画
- (void)scrollToBottomImmediate {
    if (self.messages.count > 0) {
        [self ensureBottomVisible:NO];
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

// 新增：锚定粘底（保持底部对齐，避免"先扩展再滚动"）


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

- (void)throttledEnsureBottomVisible {
    [self requestBottomAnchorWithContext:@"throttledEnsureBottomVisible"];
}

// 新增：内容高度显著变化时的即时滚动（针对代码块扩展）


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
    NSInteger thumbnailCount = MIN(self.selectedAttachments.count, 3);
    for (NSInteger i = 0; i < thumbnailCount; i++) {
        id attachment = self.selectedAttachments[i];
        
        AttachmentThumbnailView *thumbnailView = [[AttachmentThumbnailView alloc] init];
        thumbnailView.tag = i;
        
        // 为每个缩略图添加固定宽度约束
        [thumbnailView.widthAnchor constraintEqualToConstant:60].active = YES;
        
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
    CGFloat newHeight = hasAttachments ? 60.0 : 0.0;
    CGFloat newPadding = hasAttachments ? 8.0 : 0.0;
    
    if (self.thumbnailsContainerHeightConstraint.constant != newHeight) {
        [self.view layoutIfNeeded]; // 确保当前布局是最新的
        [UIView animateWithDuration:0.3 animations:^{
            self.thumbnailsContainerHeightConstraint.constant = newHeight;
            // 找到inputTextView的顶部约束并更新constant
            for (NSLayoutConstraint *constraint in self.inputBackgroundView.constraints) {
                if (constraint.firstItem == self.inputTextView && constraint.firstAttribute == NSLayoutAttributeTop) {
                    constraint.constant = newPadding;
                    break;
                }
            }
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
        if (self.selectedAttachments.count < 3) {
            [self.selectedAttachments addObject:image];
        } else {
            // 可选：在这里给用户一个提示，如 "最多只能添加3个附件"
            
            break;
        }
    }
    [self updateAttachmentsDisplay];
    [self updateSendButtonState];
}

- (void)mediaPicker:(MediaPickerManager *)picker didPickDocumentAtURL:(NSURL *)url {
    // 检查是否为网络图片URL
    if ([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"]) {
        // 网络图片，直接添加到附件数组
    if (self.selectedAttachments.count < 3) {
        [self.selectedAttachments addObject:url];
    } else {
        
        }
    } else {
        // 本地文件，添加到附件数组
        if (self.selectedAttachments.count < 3) {
            [self.selectedAttachments addObject:url];
        } else {
            
        }
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
    
    // 关键修复：防止第一行输入时高度扩展，确保单行时保持固定高度
    NSInteger lineCount = [self calculateLineCountForTextView:textView];
    
    // 使用精确的行高计算，确保与初始设置一致
    CGFloat lineHeight = self.inputTextView.font.lineHeight; // 与字体大小保持一致
    UIEdgeInsets insets = textView.textContainerInset;
    CGFloat singleLineHeight = lineHeight + insets.top + insets.bottom;
    
    if (lineCount <= 1) {
        // 单行或空行：保持固定高度，不扩展
        if (self.inputTextViewHeightConstraint.constant != singleLineHeight) {
            self.inputTextViewHeightConstraint.constant = singleLineHeight;
            [self.view layoutIfNeeded];
        }
    } else if (lineCount <= 4) {
        // 2-4行：动态调整高度
        CGFloat newHeight = ceil(lineHeight * lineCount) + insets.top + insets.bottom;
        // 确保最小高度为单行高度，最大高度为4行高度
        newHeight = MAX(singleLineHeight, MIN(newHeight, lineHeight * 4 + insets.top + insets.bottom));
        
        if (self.inputTextViewHeightConstraint.constant != newHeight) {
            self.inputTextViewHeightConstraint.constant = newHeight;
            [self.view layoutIfNeeded];
            [self scrollToBottom]; // 确保滚动到底部
        }
    } else {
        // 超过4行：固定高度为4行高度，启用滚动
        CGFloat maxHeight = lineHeight * 4 + insets.top + insets.bottom;
        if (self.inputTextViewHeightConstraint.constant != maxHeight) {
            self.inputTextViewHeightConstraint.constant = maxHeight;
            [self.view layoutIfNeeded];
        }
        
        // 确保滚动到底部，让用户看到最新输入的内容
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

// 新增：计算文本视图的行数 - 优化版本
- (NSInteger)calculateLineCountForTextView:(UITextView *)textView {
    if (!textView) { return 0; }
    if (!textView.text || textView.text.length == 0) {
        return 0;
    }
    
    // 使用固定的行高，与字体大小保持一致
    CGFloat lineHeight = textView.font.lineHeight; // 与字体大小保持一致
    UIEdgeInsets insets = textView.textContainerInset;
    
    // 计算可用宽度
    CGFloat availableWidth = MAX(textView.bounds.size.width - insets.left - insets.right, 1.0);
    if (availableWidth <= 0) {
        availableWidth = MAX(textView.frame.size.width - insets.left - insets.right, 1.0);
    }
    
    // 使用文本容器进行精确计算
    NSTextContainer *textContainer = textView.textContainer;
    NSLayoutManager *layoutManager = textView.layoutManager;
    NSTextStorage *textStorage = textView.textStorage;
    
    if (textContainer && layoutManager && textStorage) {
        // 设置文本容器的宽度
        textContainer.size = CGSizeMake(availableWidth, CGFLOAT_MAX);
        textContainer.lineFragmentPadding = 0;
        
        // 计算实际的行数
        NSRange glyphRange = [layoutManager glyphRangeForTextContainer:textContainer];
        if (glyphRange.length > 0) {
            NSInteger lineCount = 0;
            NSRange lineRange;
            for (NSInteger glyphIndex = glyphRange.location; glyphIndex < NSMaxRange(glyphRange); glyphIndex = NSMaxRange(lineRange)) {
                CGRect lineRect = [layoutManager lineFragmentUsedRectForGlyphAtIndex:glyphIndex effectiveRange:&lineRange];
                if (lineRect.size.height > 0) {
                    lineCount++;
                }
            }
            return MAX(1, lineCount);
        }
    }
    
    // 备用方案：基于内容高度计算
    CGFloat contentHeight = textView.contentSize.height - insets.top - insets.bottom;
    if (contentHeight > 0) {
        NSInteger lines = (NSInteger)ceil(MAX(contentHeight, lineHeight) / lineHeight);
        return MAX(1, lines);
    }
    
    // 最终备用方案：基于字符数估算
    CGFloat approxCharWidth = lineHeight * 0.6; // 字符宽度约为字体大小的0.6倍
    CGFloat approxCharsPerLine = MAX(floor(availableWidth / approxCharWidth), 1.0);
    NSInteger approxLines = MAX(1, (NSInteger)ceil((double)textView.text.length / (double)approxCharsPerLine));
    return approxLines;
}

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    if ([text isEqualToString:@"\n"] && textView.text.length == 0) {
        return NO;
    }
    return YES;
}

- (BOOL)textViewShouldBeginEditing:(UITextView *)textView {
    // 开始编辑时滚动到底部
    [self forceScrollToBottomAnimated:NO];
    
    // 显式调用成为第一响应者
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.inputTextView becomeFirstResponder];
    });
    
    return YES;
}



// MARK: - AI流式响应
// 核心逻辑：AI流式响应处理 (已修复单次响应重复问题)
- (void)simulateAIResponse {

    
    // 复位流式状态
    self.streamBusy = NO;
    self.lastDisplayedSubstring = @"";
    
    // 1. 重置所有相关状态

    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
    }
    [self.fullResponseBuffer setString:@""];
    self.currentUpdatingAIMessage = nil;
    self->_currentUpdatingAINode = nil;

    
    // 2. 显示"Thinking"状态
    // 重置语义解析器以开始新的流
    [self.semanticParser reset];
    [self.semanticRenderedBuffer setString:@""];
    // 步骤 1: 设置状态并计算出"思考视图"将要被插入的位置
    self.isAIThinking = YES;
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
            
            // 统一在进入分支前抓取旧配置，两个分支共用（完成或失败均恢复）
            NSString *prevModel = [APIManager sharedManager].currentModelName ?: @"";
            NSString *prevBaseURL = [[APIManager sharedManager] currentBaseURL] ?: @"";
            NSString *prevApiKey = [[APIManager sharedManager] currentApiKey] ?: @"";

            if ([decision isEqualToString:@"生成"]) {
                // 图片生成：取第一张作为 base_image_url，提示词用最近用户纯文本
                NSString *userText = [strongSelf latestUserPlainText] ?: @"";
                NSString *baseURL = imageURLsForThisRound.firstObject.absoluteString ?: @"";
                
                // 使用与"理解"相同的 DashScope Key
                [[APIManager sharedManager] setApiKey:@"sk-ec4677b09f5a4126af3ad17d763c60ed"];
                [[APIManager sharedManager] generateImageWithPrompt:userText baseImageURL:baseURL completion:^(NSArray<NSURL *> * _Nullable imageURLs, NSError * _Nullable genErr) {
                    if (genErr || imageURLs.count == 0) {
                        // 移除思考视图并给出失败文案
                        strongSelf.isAIThinking = NO;
                        [strongSelf.tableNode performBatchUpdates:^{
                            [strongSelf.tableNode deleteRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationNone];
                        } completion:nil];
                        NSString *failText = @"抱歉，图片生成失败，请稍后再试。";
                        [strongSelf addMessageWithText:failText attachments:@[] isFromUser:NO completion:nil];
                        strongSelf.pendingImageURLs = nil;
                        // 恢复用户原始配置
                        [[APIManager sharedManager] setBaseURL:prevBaseURL];
                        [[APIManager sharedManager] setApiKey:prevApiKey];
                        [APIManager sharedManager].currentModelName = prevModel;
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
                    // 恢复用户原始配置
                    [[APIManager sharedManager] setBaseURL:prevBaseURL];
                    [[APIManager sharedManager] setApiKey:prevApiKey];
                    [APIManager sharedManager].currentModelName = prevModel;
                }];
                return; // 生成分支结束
            }

            // 理解：切换到多模态端点与模型（qvq-plus），并确保使用流式
            [[APIManager sharedManager] setBaseURL:@"https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"]; 
            [[APIManager sharedManager] setApiKey:@"sk-ec4677b09f5a4126af3ad17d763c60ed"];
            [APIManager sharedManager].currentModelName = @"qvq-plus";

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
            

            strongSelf.currentStreamingTask = [[APIManager sharedManager] streamingChatCompletionWithMessages:messages images:nil streamCallback:^(NSString *partialResponse, BOOL isDone, NSError *error) {
                __strong typeof(weakSelf) sself = weakSelf;
                if (!sself) { return; }
                // 复用原有流式处理UI逻辑
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error) {
                        if (error.code != NSURLErrorCancelled) {
                            
                        }
                        sself.isAIThinking = NO;
                        [sself.tableNode performBatchUpdates:^{
                            [sself.tableNode deleteRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationNone];
                        } completion:nil];
                        sself.streamBusy = NO;
                        // 出错时恢复到用户的文本聊天配置
                        [[APIManager sharedManager] setBaseURL:prevBaseURL];
                        [[APIManager sharedManager] setApiKey:prevApiKey];
                        [APIManager sharedManager].currentModelName = prevModel;
                        return;
                    }
                    [sself.fullResponseBuffer setString:partialResponse];
                    if (sself.isUIUpdatePaused) { return; }
                    NSArray<NSString *> *newBlocks = [sself.semanticParser consumeFullText:partialResponse isDone:isDone];
                    if (newBlocks.count == 0) { return; }
                    NSString *displayText = [newBlocks componentsJoinedByString:@""];
                    
                    // 累积到渲染缓冲，避免只显示本次块
                    [sself.semanticRenderedBuffer appendString:displayText];
                    NSString *accumulated = [sself.semanticRenderedBuffer copy];
                    if (sself.isAIThinking) {
                        sself.currentUpdatingAIMessage = [[CoreDataManager sharedManager] addMessageToChat:sself.chat content:@"" isFromUser:NO];
                        [sself fetchMessages];
                        NSIndexPath *finalMessagePath = [NSIndexPath indexPathForRow:sself.messages.count - 1 inSection:0];
                        [sself anchorScrollToBottomIfNeeded];
                        [sself performUpdatesPreservingBottom:^{
                            [UIView performWithoutAnimation:^{
                                [sself.tableNode performBatchUpdates:^{
                                    [sself.tableNode insertRowsAtIndexPaths:@[finalMessagePath] withRowAnimation:UITableViewRowAnimationNone];
                                } completion:^(BOOL finished) {
                                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                        id node = sself->_currentUpdatingAINode;
                                        if (finished && [node respondsToSelector:@selector(appendSemanticBlocks:isFinal:)]) {
                                    // 在开始渲染前，立即移除 Thinking 行
                                    if (sself.isAIThinking) {
                                        sself.isAIThinking = NO;
                                        NSInteger thinkingRow = sself.messages.count; // thinking 在消息末尾
                                        NSIndexPath *currentThinkingPath = [NSIndexPath indexPathForRow:thinkingRow inSection:0];
                                        [sself.tableNode performBatchUpdates:^{
                                            [sself.tableNode deleteRowsAtIndexPaths:@[currentThinkingPath] withRowAnimation:UITableViewRowAnimationNone];
                                        } completion:nil];
                                        
                                    }
                                    
                                    // 然后开始渲染语义块
                                            [node appendSemanticBlocks:newBlocks isFinal:isDone];
                                            if ([node respondsToSelector:@selector(setNeedsLayout)]) {
                                                [node setNeedsLayout];
                                            }
                                            // 减少同步布局，依赖帧级合并器
                                            [sself anchorScrollToBottomIfNeeded];
                                        }
                                    });
                                }];
                            }];
                        }];
                        [sself autoStickAfterUpdate];
                    } else {
                        [sself performUpdatesPreservingBottom:^{
                            if ([sself->_currentUpdatingAINode respondsToSelector:@selector(appendSemanticBlocks:isFinal:)]) {
                                [sself->_currentUpdatingAINode appendSemanticBlocks:newBlocks isFinal:isDone];
                            } else if ([sself->_currentUpdatingAINode respondsToSelector:@selector(updateMessageText:)]) {
                                // 兼容旧节点：退回到累计文本更新
                                [sself->_currentUpdatingAINode updateMessageText:accumulated];
                            }
                        }];
                        [sself autoStickAfterUpdate];
                    }
                    if (isDone) {
                        sself.currentStreamingTask = nil;
                        if (sself.currentUpdatingAIMessage) {
                            [sself.currentUpdatingAIMessage setValue:sself.fullResponseBuffer forKey:@"content"];
                            [[CoreDataManager sharedManager] saveContext];
                        }
                        sself.streamBusy = NO;
                        sself.pendingImageURLs = nil;
                        // 恢复配置，仅做状态变更，不做任何 UI 操作
                        [[APIManager sharedManager] setBaseURL:prevBaseURL];
                        [[APIManager sharedManager] setApiKey:prevApiKey];
                        [APIManager sharedManager].currentModelName = prevModel;
                        [sself exitAwaitingState];
                    }
                });
            }];
        }];
        return; // 已进入分类分支
    }

    // 无图片：按现状直接走文本流式
    self.currentStreamingTask = [[APIManager sharedManager] streamingChatCompletionWithMessages:messages images:nil streamCallback:^(NSString *partialResponse, BOOL isDone, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }
        
        dispatch_async(dispatch_get_main_queue(), ^{
            if (error) {
                if (error.code != NSURLErrorCancelled) {
                    
                }
                strongSelf.isAIThinking = NO;
                [strongSelf.tableNode performBatchUpdates:^{
                    [strongSelf.tableNode deleteRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationNone];
                } completion:nil];

                strongSelf.streamBusy = NO;

                return;
            }
            
            // 4. 用最新返回的完整文本直接覆盖缓冲区
            [strongSelf.fullResponseBuffer setString:partialResponse];
            
            // 关键优化：检查UI更新是否被暂停
            if (strongSelf.isUIUpdatePaused) {
                return; // UI更新被暂停，跳过此次更新
            }
            
            // 使用语义块解析器：仅在完成一个块时推送到UI
NSArray<NSString *> *newBlocks = [strongSelf.semanticParser consumeFullText:partialResponse isDone:isDone];
if (newBlocks.count == 0) { return; }
NSString *displayText = [newBlocks componentsJoinedByString:@""];
// 
// 累积本轮新块
[strongSelf.semanticRenderedBuffer appendString:displayText];
NSString *accumulated = [strongSelf.semanticRenderedBuffer copy];
            
            // 5. 核心UI更新逻辑（统一富文本渲染）
            if (strongSelf.isAIThinking) {
                // 这是第一次收到数据
                
                // a. 在数据源中创建AI消息记录 (初始内容为空)
                strongSelf.currentUpdatingAIMessage = [[CoreDataManager sharedManager] addMessageToChat:strongSelf.chat content:@"" isFromUser:NO];
                [strongSelf fetchMessages]; // 重新加载数据源
                
                NSIndexPath *finalMessagePath = [NSIndexPath indexPathForRow:strongSelf.messages.count - 1 inSection:0];
                
                // 始终使用富文本节点，保证普通文本也走富文本渲染
                // 插入前：若接近底部，先锚定一次，避免"先扩展再滚动"
                [strongSelf anchorScrollToBottomIfNeeded];
                
                // 在保持底部距离的前提下完成替换，避免"先扩展再滚动"
                [strongSelf performUpdatesPreservingBottom:^{
                    [UIView performWithoutAnimation:^{
                        [strongSelf.tableNode performBatchUpdates:^{
                            [strongSelf.tableNode insertRowsAtIndexPaths:@[finalMessagePath] withRowAnimation:UITableViewRowAnimationNone];
                        } completion:^(BOOL finished) {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                                id node = strongSelf->_currentUpdatingAINode;
                                if (finished && [node respondsToSelector:@selector(appendSemanticBlocks:isFinal:)]) {
                                    // 在开始渲染前，立即移除 Thinking 行
                                    if (strongSelf.isAIThinking) {
                                        strongSelf.isAIThinking = NO;
                                        NSInteger thinkingRow = strongSelf.messages.count; // thinking 在消息末尾
                                        NSIndexPath *currentThinkingPath = [NSIndexPath indexPathForRow:thinkingRow inSection:0];
                                        [strongSelf.tableNode performBatchUpdates:^{
                                            [strongSelf.tableNode deleteRowsAtIndexPaths:@[currentThinkingPath] withRowAnimation:UITableViewRowAnimationNone];
                                        } completion:nil];
                                        
                                    }
                                    
                                    // 然后开始渲染语义块
                                    [node appendSemanticBlocks:newBlocks isFinal:isDone];
                                    if ([node respondsToSelector:@selector(setNeedsLayout)]) {
                                        [node setNeedsLayout];
                                    }
                                    // 减少同步布局，依赖帧级合并器
                                    [strongSelf anchorScrollToBottomIfNeeded];
                                }
                            });
                        }];
                    }];
                }];
                [strongSelf autoStickAfterUpdate];
            } else {
                // 继续流式更新：统一走富文本渲染路径
                UITableView *tv = strongSelf.tableNode.view;
                CGFloat oldHeight = tv.contentSize.height;
                
                // 继续流式更新：在保持底部距离的前提下推进，避免"先扩展再滚动"
                [strongSelf performUpdatesPreservingBottom:^{
                            if ([strongSelf->_currentUpdatingAINode respondsToSelector:@selector(appendSemanticBlocks:isFinal:)]) {
                                [strongSelf->_currentUpdatingAINode appendSemanticBlocks:newBlocks isFinal:isDone];
                            } else if ([strongSelf->_currentUpdatingAINode respondsToSelector:@selector(updateMessageText:)]) {
                                // 兼容旧节点：退回到累计文本更新
                                [strongSelf->_currentUpdatingAINode updateMessageText:accumulated];
                    }
                }];
                [strongSelf autoStickAfterUpdate];
            }
            
            // 6. 流结束时的处理（不做 UI，避免影响显示节奏）
            if (isDone) {
                strongSelf.currentStreamingTask = nil;
                
                // 保存最终内容到Core Data，避免重进白泡
                if (strongSelf.currentUpdatingAIMessage) {
                    [strongSelf.currentUpdatingAIMessage setValue:strongSelf.fullResponseBuffer forKey:@"content"];
                    [[CoreDataManager sharedManager] saveContext];
                }
                
                // 释放忙碌标记
                strongSelf.streamBusy = NO;
                // 清空多模态图片，避免影响下一轮
                strongSelf.pendingImageURLs = nil;
                [strongSelf exitAwaitingState];
            }
        });
    }];
}







// MARK: - 消息添加辅助方法
- (void)addMessageWithText:(NSString *)text
                attachments:(NSArray *)attachments
                isFromUser:(BOOL)isFromUser
                completion:(nullable void (^)(void))completion {
    // 1) 直接使用文本；附件已在发送前上传并以 [附件链接：] 形式附加
    NSString *messageContent = text;

    // 2) 直接在数据源数组尾部追加（避免 reloadData）
    [[CoreDataManager sharedManager] addMessageToChat:self.chat content:messageContent isFromUser:isFromUser];
    NSManagedObject *last = [[[CoreDataManager sharedManager] fetchMessagesForChat:self.chat] lastObject];
    if (!self.messages) { self.messages = [NSMutableArray array]; }
    if (![self.messages isKindOfClass:[NSMutableArray class]]) {
        self.messages = [[self.messages mutableCopy] ?: [NSMutableArray array] mutableCopy];
    }
    if (last) { [(NSMutableArray *)self.messages addObject:last]; }
    NSIndexPath *newIndexPath = [NSIndexPath indexPathForRow:self.messages.count - 1 inSection:0];

    // 3) 仅插入最后一行，禁止整表刷新；使用无动画，避免闪烁/抖动
    [UIView performWithoutAnimation:^{
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
            NSRange marker = [content rangeOfString:@"[附件链接："];
            if (marker.location != NSNotFound) {
                content = [content substringToIndex:marker.location];
            }
            return [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
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
    NSDictionary *displayMap = @{ @"gpt-5": @"GPT-5", @"gpt-4.1": @"GPT-4.1", @"gpt-4o": @"GPT-4o" };
    NSString *displayTitle = displayMap[modelName] ?: modelName;
    [button setTitle:displayTitle forState:UIControlStateNormal];
    [[NSUserDefaults standardUserDefaults] setObject:modelName forKey:@"SelectedModelName"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

// 移除网络图片 URL 入口

// MARK: - 应用程序状态通知处理
- (void)applicationWillResignActive:(NSNotification *)notification {
    // 应用即将进入非活动状态（Come from电、短信等）
    // 可以在这里添加需要的处理逻辑
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    // 应用进入后台
    // 确保取消任何正在进行的任务
    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
        self.currentStreamingTask = nil;
    }
}

// MARK: - UIScrollViewDelegate 维护粘底状态
- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    self.userIsDragging = YES;
    self.lastContentOffsetY = scrollView.contentOffset.y;
    
    // 关键优化：用户开始滑动时，暂停所有UI更新
    [self pauseUIUpdates];

    // 取消本帧待处理的自动粘底，避免与用户手势抢夺
    self.needsBottomAnchor = NO;
    self.bottomAnchorLink.paused = YES;
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    CGFloat contentHeight = scrollView.contentSize.height;
    CGFloat viewHeight = scrollView.bounds.size.height;
    CGFloat offsetY = scrollView.contentOffset.y;
    BOOL nearBottom = (offsetY + viewHeight >= contentHeight - 80.0);
    self.isNearBottom = nearBottom;
    if (!self.userIsDragging) {
        self.shouldAutoScrollToBottom = nearBottom;
    } else {
        self.lastContentOffsetY = offsetY;
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    self.userIsDragging = NO;
    self.shouldAutoScrollToBottom = self.isNearBottom;
    if (!decelerate) {
        [self resumeUIUpdates];
    }
    // 标记减速状态
    self.isDecelerating = decelerate;
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    self.shouldAutoScrollToBottom = self.isNearBottom;
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
    // 仅用于显示：去掉尾部的附件链接块，不影响存储与AI上下文
    NSRange marker = [content rangeOfString:@"[附件链接："];
    if (marker.location != NSNotFound) {
        content = [content substringToIndex:marker.location];
        content = [content stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    return content;
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

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRequireFailureOfGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // table 的 pan 不需要等待子视图失败，优先响应滚动
    if (gestureRecognizer == self.tableNode.view.panGestureRecognizer) {
        return NO;
    }
    return NO;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldBeRequiredToFailByGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    // 不强制 table pan 失败
    return NO;
}

// 新增：在布局完成后统一执行自动粘底（若接近底部）
- (void)autoStickAfterUpdate {
    if (![self shouldPerformAutoScroll]) return;
    [self requestBottomAnchorWithContext:@"autoStickAfterUpdate"];
}

// 新增：在近底部时，保持底部对齐地执行更新（避免先扩展再滚动）
- (void)performUpdatesPreservingBottom:(dispatch_block_t)updates {
    if (!updates) return;
    UITableView *tv = self.tableNode.view;
    CGPoint beforeOffset = tv.contentOffset;
    CGFloat beforeContentHeight = tv.contentSize.height;
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

// 新增：统一的自动滚动协调器
- (void)performAutoScrollWithContext:(NSString *)context {
    if (![self shouldPerformAutoScroll]) { 
        return; 
    }
    
    
    UITableView *tv = self.tableNode.view;
    if (!tv) { return; }
    if (!tv.window) { return; } // 未进入窗口，避免提前布局与滚动
    
    // 强制布局，确保内容大小是最新的
    [tv layoutIfNeeded];
    
    CGFloat contentHeight = tv.contentSize.height;
    CGFloat viewHeight = tv.bounds.size.height;
    CGFloat visibleHeight = viewHeight - tv.adjustedContentInset.bottom;
    CGFloat targetOffsetY = contentHeight - visibleHeight;
    CGFloat minOffsetY = -tv.adjustedContentInset.top;
    
    if (isnan(targetOffsetY) || isinf(targetOffsetY)) { 
        return; 
    }
    if (targetOffsetY < minOffsetY) targetOffsetY = minOffsetY;
    
    CGPoint currentOffset = tv.contentOffset;
    CGPoint targetOffset = CGPointMake(currentOffset.x, targetOffsetY);

    // 距离阈值：若目标与当前小于 1pt，跳过，避免无意义设置干扰手势
    if (fabs(currentOffset.y - targetOffset.y) < 1.0) { return; }

    [tv setContentOffset:targetOffset animated:NO];
}

- (void)performAutoScrollWithContext:(NSString *)context animated:(BOOL)animated {
    if (![self shouldPerformAutoScroll]) {
        return;
    }
    UITableView *tv = self.tableNode.view;
    if (!tv) { return; }
    if (!tv.window) { return; } // 未进入窗口，避免提前布局与滚动
    [tv layoutIfNeeded];
    CGFloat contentHeight = tv.contentSize.height;
    CGFloat viewHeight = tv.bounds.size.height;
    CGFloat visibleHeight = viewHeight - tv.adjustedContentInset.bottom;
    CGFloat targetOffsetY = contentHeight - visibleHeight;
    CGFloat minOffsetY = -tv.adjustedContentInset.top;
    if (isnan(targetOffsetY) || isinf(targetOffsetY)) { return; }
    if (targetOffsetY < minOffsetY) targetOffsetY = minOffsetY;
    CGPoint currentOffset = tv.contentOffset;
    CGPoint targetOffset = CGPointMake(currentOffset.x, targetOffsetY);

    if (fabs(currentOffset.y - targetOffset.y) < 1.0) { return; }

    [tv setContentOffset:targetOffset animated:animated];
}

#pragma mark - Bottom Anchor Coalescer

- (void)requestBottomAnchorWithContext:(NSString *)context {
    if (![self shouldPerformAutoScroll]) { return; }
    self.needsBottomAnchor = YES;
    self.bottomAnchorLink.paused = NO; // 激活到下一帧
}

- (void)_onBottomAnchorTick:(CADisplayLink *)link {
    if (!self.needsBottomAnchor) {
        link.paused = YES;
        return;
    }
    self.needsBottomAnchor = NO;
    [self performAutoScrollWithContext:@"displayLinkTick" animated:NO];
}

// 新增：节流版本的自动滚动
- (void)throttledAutoScrollWithContext:(NSString *)context {
    // 改为显示链接合并：避免频繁 setContentOffset 干扰滑动手势
    [self requestBottomAnchorWithContext:context ?: @"throttledAutoScrollWithContext"];
 }

// 新增：智能滚动检测
- (BOOL)shouldPerformAutoScroll {
    if (self.userIsDragging) { 
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
        return [self isNearBottomWithTolerance:120.0];
    }
    
    // 更宽松的底部检测，提高响应性
    BOOL nearBottom = [self isNearBottomWithTolerance:120.0];
    
    return nearBottom;
}

// MARK: - 内容大小监控

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary<NSKeyValueChangeKey,id> *)change context:(void *)context {
    if ([keyPath isEqualToString:@"contentSize"] && object == self.tableNode.view) {
        CGSize oldSize = [change[NSKeyValueChangeOldKey] CGSizeValue];
        CGSize newSize = [change[NSKeyValueChangeNewKey] CGSizeValue];
        
        // 检测内容高度的显著增长（通常由代码块扩展引起）
        CGFloat heightIncrease = newSize.height - oldSize.height;
        if (heightIncrease > 10.0) { // 高度增长超过10px
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
    
    CGFloat contentHeight = tv.contentSize.height;
    CGFloat viewHeight = tv.bounds.size.height;
    CGFloat visibleHeight = viewHeight - tv.adjustedContentInset.bottom;
    CGFloat targetOffsetY = contentHeight - visibleHeight;
    CGFloat minOffsetY = -tv.adjustedContentInset.top;
    
    if (isnan(targetOffsetY) || isinf(targetOffsetY)) {
        return;
    }
    if (targetOffsetY < minOffsetY) targetOffsetY = minOffsetY;
    
    CGPoint currentOffset = tv.contentOffset;
    CGPoint targetOffset = CGPointMake(currentOffset.x, targetOffsetY);
    
    [tv setContentOffset:targetOffset animated:animated];
}

@end


