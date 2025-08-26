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

// MARK: - 常量定义
// 流式富文本渲染：每次更新一行文本
static const NSTimeInterval kStreamRenderInterval = 0.0; // 0ms，每次网络数据都立即更新

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
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *nodeSizeCache; // 节点尺寸缓存
@property (nonatomic, copy) NSString *lastDisplayedSubstring; // 上次显示的文本内容，用于按行更新检测和避免重复布局
@property (nonatomic, assign) BOOL streamBusy; // 防重复/忙碌标记
@property (nonatomic, assign) BOOL isUIUpdatePaused; // 新增：UI更新暂停标志

// MARK: - 网络请求相关属性
@property (nonatomic, strong) NSURLSessionDataTask *currentStreamingTask;
@property (nonatomic, weak) NSManagedObject *currentUpdatingAIMessage; // 正在更新的AI消息对象

// MARK: - 布局优化属性
@property (nonatomic, assign) NSInteger layoutUpdateCounter;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSValue *> *heightCache; // 高度缓存：key为内容hash，value为CGSize
@property (nonatomic, assign) NSTimeInterval lastLayoutUpdateTime; // 上次布局更新的时间戳，用于防抖控制

// MARK: - 滚动粘底属性
@property (nonatomic, assign) BOOL shouldAutoScrollToBottom; // 当用户未手动上滑时，自动粘底
@property (nonatomic, assign) BOOL userIsDragging;
@property (nonatomic, assign) BOOL isNearBottom; // 新增：是否接近底部
@property (nonatomic, assign) CGFloat lastContentOffsetY; // 新增：记录上次滚动位置
@property (nonatomic, assign) NSTimeInterval lastAutoScrollTime; // 新增：滚动节流时间戳

// 上传逻辑已移动至 OSSUploadManager
// MARK: - 多模态控制
@property (nonatomic, strong) NSArray<NSURL *> *pendingImageURLs; // 本轮要发送给多模态模型的图片URL

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
    self.fullResponseBuffer = [NSMutableString string];
    self.selectedAttachments = [NSMutableArray array];
    
    // 2. 初始化高度缓存系统
    self.heightCache = [NSMutableDictionary dictionary];
    self.lastDisplayedSubstring = @"";
    self.nodeSizeCache = [NSMutableDictionary dictionary]; // 新增：初始化节点尺寸缓存
    self.isUIUpdatePaused = NO; // 新增：初始化UI更新暂停标志

    
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
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self fetchMessages];
    [self.tableNode reloadData];
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
    self.lastDisplayedSubstring = @"";
    self.streamBusy = NO;
}

- (void)dealloc {

    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // 确保任务被取消
    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
        self.currentStreamingTask = nil;
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
}

// OSS 相关实现已迁移至 OSSUploadManager

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
    
    // 菜单按钮 - 暂时保留但不设置动作
    UIButton *menuButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [menuButton setImage:[UIImage systemImageNamed:@"line.horizontal.3"] forState:UIControlStateNormal];
    menuButton.tintColor = [UIColor blackColor];
    menuButton.translatesAutoresizingMaskIntoConstraints = NO;
    [headerView addSubview:menuButton];
    
    // 标题按钮
    UIButton *titleButton = [UIButton buttonWithType:UIButtonTypeSystem];
    NSString *modelName = [[APIManager sharedManager] currentModelName];
    [titleButton setTitle:modelName forState:UIControlStateNormal];
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
    
    // 文本输入框 - 优化约束稳定性
    self.inputTextView = [[UITextView alloc] init];
    self.inputTextView.font = [UIFont systemFontOfSize:18];
    self.inputTextView.delegate = self;
    // 关键修复：启用滚动，支持超过4行后的滑动预览
    self.inputTextView.scrollEnabled = YES;
    self.inputTextView.backgroundColor = [UIColor clearColor];
    self.inputTextView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    self.inputTextView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputBackgroundView addSubview:self.inputTextView];
    
    // 占位标签
    self.placeholderLabel = [[UILabel alloc] init];
    self.placeholderLabel.text = @"  给ChatGPT发送信息";
    self.placeholderLabel.textColor = [UIColor lightGrayColor];
    self.placeholderLabel.font = [UIFont systemFontOfSize:18];
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
    [self.sendButton addTarget:self action:@selector(sendButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    
    // 2. 添加视图层级
    [self.view addSubview:self.inputContainerView];
    [self.inputContainerView addSubview:self.inputBackgroundView];
    [self.inputBackgroundView addSubview:self.placeholderLabel];
    [toolbarView addSubview:self.addButton];
    [toolbarView addSubview:self.sendButton];
    
    // 3. 激活所有约束
    // 将高度约束保存为属性，以便后续动态修改
    self.inputTextViewHeightConstraint = [self.inputTextView.heightAnchor constraintEqualToConstant:36]; // 初始高度
    
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
        
        // 占位标签 (placeholderLabel)
        [self.placeholderLabel.leadingAnchor constraintEqualToAnchor:self.inputTextView.leadingAnchor constant:5],
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
        [self scrollToBottom];
    } completion:nil];
}

- (void)keyboardWillHide:(NSNotification *)notification {
    NSTimeInterval duration = [notification.userInfo[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    UIViewAnimationCurve curve = [notification.userInfo[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    
    [UIView animateWithDuration:duration delay:0 options:(curve << 16) animations:^{
        self.inputContainerBottomConstraint.constant = 0;
        [self.view layoutIfNeeded];
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

- (void)sendButtonTapped {
    if (self.inputTextView.text.length == 0 && self.selectedAttachments.count == 0) return;
    
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
                [self simulateAIResponse];
            }];
        }];
    } else {
        // 无附件直接发送
        self.inputTextView.text = @"";
        [self textViewDidChange:self.inputTextView];
        [self.inputTextView resignFirstResponder];
        [self addMessageWithText:userMessage attachments:@[] isFromUser:YES completion:^{
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
            NSIndexPath *lastIndexPath = [NSIndexPath indexPathForRow:self.messages.count - 1 inSection:0];
            [self.tableNode scrollToRowAtIndexPath:lastIndexPath atScrollPosition:UITableViewScrollPositionBottom animated:YES];
        });
    }
}

// 立即滚动到底部，无动画
- (void)scrollToBottomImmediate {
    if (self.messages.count > 0) {
        NSIndexPath *lastIndexPath = [NSIndexPath indexPathForRow:self.messages.count - 1 inSection:0];
        [self.tableNode scrollToRowAtIndexPath:lastIndexPath atScrollPosition:UITableViewScrollPositionBottom animated:NO];
    }
}

// 新增：是否接近底部（带容差）
- (BOOL)isNearBottomWithTolerance:(CGFloat)tolerance {
    UITableView *tv = self.tableNode.view;
    CGFloat contentHeight = tv.contentSize.height;
    CGFloat viewHeight = tv.bounds.size.height;
    CGFloat offsetY = tv.contentOffset.y;
    return (offsetY + viewHeight >= contentHeight - tolerance);
}

// 新增：锚定粘底（保持底部对齐，避免"先扩展再滚动"）
- (void)anchorStickToBottomPreservingOffset {
    UITableView *tv = self.tableNode.view;
    CGFloat contentHeight = tv.contentSize.height;
    CGFloat viewHeight = tv.bounds.size.height;
    CGFloat bottomInset = tv.adjustedContentInset.bottom;
    CGFloat targetOffsetY = MAX(contentHeight - viewHeight + bottomInset, -tv.adjustedContentInset.top);
    if (isnan(targetOffsetY) || isinf(targetOffsetY)) { return; }
    [tv setContentOffset:CGPointMake(tv.contentOffset.x, targetOffsetY) animated:NO];
}

// 新增：需要时进行锚定粘底
- (void)anchorScrollToBottomIfNeeded {
    if ([self isNearBottomWithTolerance:80.0]) {
        [self scrollToBottomImmediate];
    }
}

- (BOOL)isScrolledToBottom {
    if (!self.tableNode.view) return NO;
    
    CGFloat contentHeight = self.tableNode.view.contentSize.height;
    CGFloat viewHeight = self.tableNode.view.bounds.size.height;
    
    // 如果内容还没填满一屏，也算是在底部
    if (contentHeight < viewHeight) {
        return YES;
    }
    
    CGFloat offsetY = self.tableNode.view.contentOffset.y;
    CGFloat tolerance = 50.0; // 增加容差，更宽松的底部检测
    
    BOOL isAtBottom = offsetY + viewHeight >= contentHeight - tolerance;
    
    // 更新接近底部状态
    self.isNearBottom = isAtBottom;
    
    return isAtBottom;
}

// 新增：智能滚动检测
- (BOOL)shouldPerformAutoScroll {
    // 如果用户正在拖动，不自动滚动
    if (self.userIsDragging) {
        return NO;
    }
    
    // 如果接近底部，允许自动滚动
    if (self.isNearBottom) {
        return YES;
    }
    
    // 关键改进：初始聊天时，当内容开始超出屏幕时自动滚动
    CGFloat contentHeight = self.tableNode.view.contentSize.height;
    CGFloat viewHeight = self.tableNode.view.bounds.size.height;
    CGFloat offsetY = self.tableNode.view.contentOffset.y;
    
    // 如果内容高度小于视图高度，允许自动滚动（初始状态）
    if (contentHeight <= viewHeight) {
        return YES;
    }
    
    // 关键改进：当内容开始超出屏幕底部时，自动滚动
    // 这样可以处理初始聊天时内容逐渐变长的情况
    if (offsetY + viewHeight >= contentHeight - 100) { // 100px的提前滚动阈值
        return YES;
    }
    
    return NO;
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
            NSLog(@"已达到附件数量上限");
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
        NSLog(@"已达到附件数量上限");
        }
    } else {
        // 本地文件，添加到附件数组
        if (self.selectedAttachments.count < 3) {
            [self.selectedAttachments addObject:url];
        } else {
            NSLog(@"已达到附件数量上限");
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
    
    // 关键修复：动态调整输入框高度，支持超过4行后的滑动预览
    CGSize size = [textView sizeThatFits:CGSizeMake(textView.bounds.size.width, MAXFLOAT)];
    
    // 计算行数
    NSInteger lineCount = [self calculateLineCountForTextView:textView];
    
    if (lineCount <= 4) {
        // 4行以内：自适应高度，最大120px
        CGFloat newHeight = MIN(MAX(size.height, 36), 120);
        
        // 只有当高度变化时才更新约束
        if (self.inputTextViewHeightConstraint.constant != newHeight) {
            self.inputTextViewHeightConstraint.constant = newHeight;
            [self.view layoutIfNeeded];
            [self scrollToBottom]; // 确保滚动到底部
        }
    } else {
        // 超过4行：固定高度为120px，启用滚动
        if (self.inputTextViewHeightConstraint.constant != 120) {
            self.inputTextViewHeightConstraint.constant = 120;
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
    // 有文本或附件时启用发送按钮
    BOOL hasContent = self.inputTextView.text.length > 0 || self.selectedAttachments.count > 0;
    self.sendButton.enabled = hasContent;
    self.sendButton.alpha = hasContent ? 1.0 : 0.5;
}

// 新增：计算文本视图的行数
- (NSInteger)calculateLineCountForTextView:(UITextView *)textView {
    if (!textView.text || textView.text.length == 0) {
        return 0;
    }
    
    // 使用文本容器的行数计算
    NSLayoutManager *layoutManager = textView.layoutManager;
    NSTextContainer *textContainer = textView.textContainer;
    
    // 获取文本范围
    NSRange textRange = NSMakeRange(0, layoutManager.numberOfGlyphs);
    
    // 计算行数
    NSInteger lineCount = 0;
    NSInteger index = 0;
    
    while (index < textRange.length) {
        NSRange lineRange;
        [layoutManager lineFragmentRectForGlyphAtIndex:index effectiveRange:&lineRange];
        lineCount++;
        index = NSMaxRange(lineRange);
    }
    
    return lineCount;
}

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    if ([text isEqualToString:@"\n"] && textView.text.length == 0) {
        return NO;
    }
    return YES;
}

- (BOOL)textViewShouldBeginEditing:(UITextView *)textView {
    // 开始编辑时滚动到底部
    [self scrollToBottom];
    
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
    // 步骤 1: 设置状态并计算出"思考视图"将要被插入的位置
    self.isAIThinking = YES;
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
    
    // 3. 构建历史消息，并在有图片时先进行“生成/理解”分类
    NSMutableArray *messages = [self buildMessageHistory];
    NSArray<NSURL *> *imageURLsForThisRound = self.pendingImageURLs;
    __weak typeof(self) weakSelf = self;
    if (imageURLsForThisRound.count > 0) {
        // 使用当前文本模型与端点进行分类，T=0.3
        NSLog(@"[Intent] start classification (T=0.3) using text model=%@", [APIManager sharedManager].currentModelName);
        [[APIManager sharedManager] classifyIntentWithMessages:messages temperature:0.3 completion:^(NSString * _Nullable label, NSError * _Nullable error) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            if (error) {
                NSLog(@"[Intent] classification failed: %@, fallback to 理解", error.localizedDescription);
                label = @"理解";
            }
            NSString *decision = ([label isKindOfClass:[NSString class]] && [label containsString:@"生成"]) ? @"生成" : @"理解";
            NSLog(@"[Intent] decision=%@", decision);

            if ([decision isEqualToString:@"生成"]) {
                // 图片生成：取第一张作为 base_image_url，提示词用最近用户纯文本
                NSString *userText = [strongSelf latestUserPlainText] ?: @"";
                NSString *baseURL = imageURLsForThisRound.firstObject.absoluteString ?: @"";
                NSLog(@"[ImageGen] prompt=%@ base=%@", userText, baseURL);
                // 使用与“理解”相同的 DashScope Key
                [[APIManager sharedManager] setApiKey:@"sk-ec4677b09f5a4126af3ad17d763c60ed"];
                [[APIManager sharedManager] generateImageWithPrompt:userText baseImageURL:baseURL completion:^(NSArray<NSURL *> * _Nullable imageURLs, NSError * _Nullable genErr) {
                    if (genErr || imageURLs.count == 0) {
                        NSLog(@"[ImageGen] failed: %@", genErr.localizedDescription);
                        // 移除思考视图并给出失败文案
                        strongSelf.isAIThinking = NO;
                        [strongSelf.tableNode performBatchUpdates:^{
                            [strongSelf.tableNode deleteRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationNone];
                        } completion:nil];
                        NSString *failText = @"抱歉，图片生成失败，请稍后再试。";
                        [strongSelf addMessageWithText:failText attachments:@[] isFromUser:NO completion:nil];
                        strongSelf.pendingImageURLs = nil;
                        return;
                    }
                    // 生成成功：拼装带附件链接的AI消息（文本+缩略图）
                    NSMutableString *aiText = [NSMutableString stringWithString:@"已生成图片。"]; // 文本不含链接块展示
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
                }];
                return; // 生成分支结束
            }

            // 理解：切换到多模态端点与模型，继续走原有流式路径
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
            NSLog(@"[MultiModal] model=qvq-plus images=%@", imageURLsForThisRound);

            strongSelf.currentStreamingTask = [[APIManager sharedManager] streamingChatCompletionWithMessages:messages images:nil streamCallback:^(NSString *partialResponse, BOOL isDone, NSError *error) {
                __strong typeof(weakSelf) sself = weakSelf;
                if (!sself) { return; }
                // 复用原有流式处理UI逻辑
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (error) {
                        if (error.code != NSURLErrorCancelled) {
                            NSLog(@"API Error: %@", error.localizedDescription);
                        }
                        sself.isAIThinking = NO;
                        [sself.tableNode performBatchUpdates:^{
                            [sself.tableNode deleteRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationNone];
                        } completion:nil];
                        sself.streamBusy = NO;
                        return;
                    }
                    [sself.fullResponseBuffer setString:partialResponse];
                    if (!isDone && [partialResponse isEqualToString:sself.lastDisplayedSubstring]) { return; }
                    if (sself.isUIUpdatePaused) { return; }
                    sself.lastDisplayedSubstring = [partialResponse copy];
                    if (sself.isAIThinking) {
                        sself.isAIThinking = NO;
                        sself.currentUpdatingAIMessage = [[CoreDataManager sharedManager] addMessageToChat:sself.chat content:@"" isFromUser:NO];
                        [sself fetchMessages];
                        NSIndexPath *finalMessagePath = [NSIndexPath indexPathForRow:sself.messages.count - 1 inSection:0];
                        RichMessageCellNode *richNode = [[RichMessageCellNode alloc] initWithMessage:partialResponse isFromUser:NO];
                        sself->_currentUpdatingAINode = richNode;
                        [richNode setNeedsLayout];
                        [richNode layoutIfNeeded];
                        [sself anchorScrollToBottomIfNeeded];
                        [sself performUpdatesPreservingBottom:^{
                            [UIView performWithoutAnimation:^{
                                [sself.tableNode performBatchUpdates:^{
                                    [sself.tableNode deleteRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationNone];
                                    [sself.tableNode insertRowsAtIndexPaths:@[finalMessagePath] withRowAnimation:UITableViewRowAnimationNone];
                                } completion:nil];
                            }];
                        }];
                        [sself autoStickAfterUpdate];
                    } else {
                        if ([sself->_currentUpdatingAINode respondsToSelector:@selector(updateMessageText:)]) {
                            [sself->_currentUpdatingAINode updateMessageText:partialResponse];
                        }
                        [sself performUpdatesPreservingBottom:^{
                            if ([sself->_currentUpdatingAINode respondsToSelector:@selector(updateMessageText:)]) {
                                [sself->_currentUpdatingAINode updateMessageText:partialResponse];
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
                        if ([sself->_currentUpdatingAINode isKindOfClass:[RichMessageCellNode class]]) {
                            RichMessageCellNode *richNode2 = (RichMessageCellNode *)sself->_currentUpdatingAINode;
                            [richNode2 completeStreamingUpdate];
                        }
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            [sself ensureFinalScrollAndRender];
                            [sself.tableNode.view layoutIfNeeded];
                            if (sself.messages.count > 0) {
                                NSIndexPath *lastIndexPath = [NSIndexPath indexPathForRow:sself.messages.count - 1 inSection:0];
                                [sself.tableNode scrollToRowAtIndexPath:lastIndexPath atScrollPosition:UITableViewScrollPositionBottom animated:NO];
                            }
                        });
                        sself.streamBusy = NO;
                        sself.pendingImageURLs = nil;
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
                    NSLog(@"API Error: %@", error.localizedDescription);
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
            
            // 富文本逐行显示：每次网络数据都立即更新，实现富文本逐行显示效果
            // 不再使用时间节流，改为内容变化检测
            if (!isDone && [partialResponse isEqualToString:strongSelf.lastDisplayedSubstring]) {
                return; // 内容相同，跳过此次更新
            }
            
            // 关键优化：检查UI更新是否被暂停
            if (strongSelf.isUIUpdatePaused) {
                return; // UI更新被暂停，跳过此次更新
            }
            
            // 记录富文本内容变化
            NSInteger oldLength = strongSelf.lastDisplayedSubstring.length;
            NSInteger newLength = partialResponse.length;
            
            strongSelf.lastDisplayedSubstring = [partialResponse copy];
            
            // 5. 核心UI更新逻辑（统一富文本渲染）
            if (strongSelf.isAIThinking) {
                // 这是第一次收到数据
                strongSelf.isAIThinking = NO;
                
                // a. 在数据源中创建AI消息记录 (初始内容为空)
                strongSelf.currentUpdatingAIMessage = [[CoreDataManager sharedManager] addMessageToChat:strongSelf.chat content:@"" isFromUser:NO];
                [strongSelf fetchMessages]; // 重新加载数据源
                
                NSIndexPath *finalMessagePath = [NSIndexPath indexPathForRow:strongSelf.messages.count - 1 inSection:0];
                
                // 始终使用富文本节点，保证普通文本也走富文本渲染
                RichMessageCellNode *richNode = [[RichMessageCellNode alloc] initWithMessage:partialResponse isFromUser:NO];
                strongSelf->_currentUpdatingAINode = richNode;
                [richNode setNeedsLayout];
                [richNode layoutIfNeeded];

                // 插入前：若接近底部，先锚定一次，避免"先扩展再滚动"
                [strongSelf anchorScrollToBottomIfNeeded];
                
                // 在保持底部距离的前提下完成替换，避免"先扩展再滚动"
                [strongSelf performUpdatesPreservingBottom:^{
                    [UIView performWithoutAnimation:^{
                        [strongSelf.tableNode performBatchUpdates:^{
                            [strongSelf.tableNode deleteRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationNone];
                            [strongSelf.tableNode insertRowsAtIndexPaths:@[finalMessagePath] withRowAnimation:UITableViewRowAnimationNone];
                        } completion:nil];
                    }];
                }];
                [strongSelf autoStickAfterUpdate];
            } else {
                // 继续流式更新：统一走富文本渲染路径
                UITableView *tv = strongSelf.tableNode.view;
                CGFloat oldHeight = tv.contentSize.height;
                if ([strongSelf->_currentUpdatingAINode respondsToSelector:@selector(updateMessageText:)]) {
                    [strongSelf->_currentUpdatingAINode updateMessageText:partialResponse];
                }
                
                // 继续流式更新：在保持底部距离的前提下推进，避免"先扩展再滚动"
                [strongSelf performUpdatesPreservingBottom:^{
                    if ([strongSelf->_currentUpdatingAINode respondsToSelector:@selector(updateMessageText:)]) {
                        [strongSelf->_currentUpdatingAINode updateMessageText:partialResponse];
                    }
                }];
                [strongSelf autoStickAfterUpdate];
            }
            
            // 6. 流结束时的处理
            if (isDone) {
                strongSelf.currentStreamingTask = nil;
                
                // 保存最终内容到Core Data，避免重进白泡
                if (strongSelf.currentUpdatingAIMessage) {
                    [strongSelf.currentUpdatingAIMessage setValue:strongSelf.fullResponseBuffer forKey:@"content"];
                    [[CoreDataManager sharedManager] saveContext];
                }
                
                // 确保富文本完全渲染
                if ([strongSelf->_currentUpdatingAINode isKindOfClass:[RichMessageCellNode class]]) {
                    RichMessageCellNode *richNode = (RichMessageCellNode *)strongSelf->_currentUpdatingAINode;
                    [richNode completeStreamingUpdate];
                }
                
                // 关键修复：确保最后几句话完全显示
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    // 强制滚动到底部，确保最后几句话可见
                    [strongSelf ensureFinalScrollAndRender];
                    
                    // 再次强制布局更新，确保所有内容都正确显示
                    [strongSelf.tableNode.view layoutIfNeeded];
                    
                    // 最终滚动确保可见性
                    if (strongSelf.messages.count > 0) {
                        NSIndexPath *lastIndexPath = [NSIndexPath indexPathForRow:strongSelf.messages.count - 1 inSection:0];
                        [strongSelf.tableNode scrollToRowAtIndexPath:lastIndexPath atScrollPosition:UITableViewScrollPositionBottom animated:NO];
                    }
                });
                
                // 释放忙碌标记
                strongSelf.streamBusy = NO;
                // 清空多模态图片，避免影响下一轮
                strongSelf.pendingImageURLs = nil;
            }
        });
    }];
}





// 辅助方法：生成字符串hash用于缓存key
- (NSString *)hashForString:(NSString *)string {
    if (!string || string.length == 0) {
        return @"empty";
    }
    
    // 生成基于内容长度和部分内容的简单hash
    NSInteger length = string.length;
    NSString *prefix = length > 20 ? [string substringToIndex:20] : string;
    NSString *suffix = length > 20 ? [string substringFromIndex:length - 10] : @"";
    
    return [NSString stringWithFormat:@"%ld_%@_%@", (long)length, prefix, suffix];
}



// 新增：计算并缓存节点尺寸
- (void)calculateAndCacheNodeSize:(NSString *)contentHash {
    if (!self->_currentUpdatingAINode) return;
    
    [UIView performWithoutAnimation:^{
        [self.tableNode performBatchUpdates:^{
            // 触发布局，使得当前 cell 的高度被正确计算
        } completion:^(BOOL finished) {
            // 使用动态方法调用获取 frame
            CGSize calculatedSize = CGSizeZero;
            if ([self->_currentUpdatingAINode respondsToSelector:@selector(frame)]) {
                CGRect frame = [[self->_currentUpdatingAINode valueForKey:@"frame"] CGRectValue];
                calculatedSize = frame.size;
            }
            if (calculatedSize.width > 0 && calculatedSize.height > 0) {
                self.nodeSizeCache[contentHash] = [NSValue valueWithCGSize:calculatedSize];
            }
        }];
    }];
}

// MARK: - 消息添加辅助方法
- (void)addMessageWithText:(NSString *)text
                attachments:(NSArray *)attachments
                isFromUser:(BOOL)isFromUser
                completion:(nullable void (^)(void))completion {
    NSInteger currentCount = self.messages.count;
    
    // 构建消息内容，包含附件信息
    NSString *messageContent = text;
    if (attachments.count > 0) {
        NSMutableString *contentWithAttachments = [NSMutableString stringWithString:text ?: @""];
        if (contentWithAttachments.length > 0) {
            [contentWithAttachments appendString:@"\n\n"];
        }
        [contentWithAttachments appendString:@"[附件："];
        
        for (NSInteger i = 0; i < attachments.count; i++) {
            id attachment = attachments[i];
            if (i > 0) [contentWithAttachments appendString:@", "];
            
            if ([attachment isKindOfClass:[UIImage class]]) {
                [contentWithAttachments appendString:@"图片"];
            } else if ([attachment isKindOfClass:[NSURL class]]) {
                NSURL *url = attachment;
                if ([url.scheme isEqualToString:@"http"] || [url.scheme isEqualToString:@"https"]) {
                    [contentWithAttachments appendString:@"网络图片"];
                } else {
                    [contentWithAttachments appendString:@"文件"];
                }
            }
        }
        [contentWithAttachments appendString:@"]"];
        
        messageContent = [contentWithAttachments copy];
    }
    
    [[CoreDataManager sharedManager] addMessageToChat:self.chat content:messageContent isFromUser:isFromUser];
    [self fetchMessages];
    
    if (self.messages.count > currentCount) {
        NSIndexPath *newIndexPath = [NSIndexPath indexPathForRow:self.messages.count - 1 inSection:0];
        
        // 关键优化：使用无动画插入，避免画面闪烁和气泡跳动
        [UIView performWithoutAnimation:^{
            [self.tableNode performBatchUpdates:^{
                [self.tableNode insertRowsAtIndexPaths:@[newIndexPath] withRowAnimation:UITableViewRowAnimationNone];
            } completion:^(BOOL finished) {
                // 在动画完成后滚动到底部并执行回调
                if (finished) {
                    // 关键修复：确保滚动到新添加的用户消息
                    [self.tableNode scrollToRowAtIndexPath:newIndexPath atScrollPosition:UITableViewScrollPositionBottom animated:NO];
                    
                    if (completion) {
                        completion();
                    }
                }
            }];
        }];
    }
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
        [AlertHelper showSuccessAlertOn:self withMessage:@"API Key 已保存"];
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
        [AlertHelper showSuccessAlertOn:self withMessage:@"API Key 已重置，请设置新的 API Key"];
        
        // 提示用户设置新的API Key
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showAPIKeyAlert];
        });
    }];
}

- (void)showModelSelectionMenu:(UIButton *)sender {
    NSArray *models = @[@"gpt-3.5-turbo", @"gpt-4o"]; // 模型列表可以从配置或APIManager获取
    [AlertHelper showModelSelectionMenuOn:self withModels:models selectionHandler:^(NSString *selectedModel) {
        [self updateModelSelection:selectedModel button:sender];
    }];
}

- (void)updateModelSelection:(NSString *)modelName button:(UIButton *)button {
    // 更新APIManager中的模型名称
    [APIManager sharedManager].currentModelName = modelName;
    
    // 更新按钮标题
    [button setTitle:modelName forState:UIControlStateNormal];
    
    // 保存选择到UserDefaults
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
}

- (void)scrollViewDidScroll:(UIScrollView *)scrollView {
    // 智能滚动状态管理
    CGFloat contentHeight = scrollView.contentSize.height;
    CGFloat viewHeight = scrollView.bounds.size.height;
    CGFloat offsetY = scrollView.contentOffset.y;
    CGFloat tolerance = 50.0; // 容差
    BOOL nearBottom = (offsetY + viewHeight >= contentHeight - tolerance);
    
    // 更新接近底部状态
    self.isNearBottom = nearBottom;
    
    if (!self.userIsDragging) {
        // 用户没有主动拖动，可能是程序自动滚动
        self.shouldAutoScrollToBottom = nearBottom;
    } else {
        // 用户正在拖动
        CGFloat deltaY = offsetY - self.lastContentOffsetY;
        
        // 如果用户向上滚动（离开底部），取消自动滚动
        if (deltaY > 10 && !nearBottom) {
            self.shouldAutoScrollToBottom = NO;
            NSLog(@"用户向上滚动，取消自动滚动");
        }
        // 如果用户向下滚动到接近底部，恢复自动滚动
        else if (deltaY < -10 && nearBottom) {
            self.shouldAutoScrollToBottom = YES;
            NSLog(@"用户向下滚动到底部，恢复自动滚动");
        }
        
        self.lastContentOffsetY = offsetY;
    }
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    self.userIsDragging = NO;
    
    // 拖动结束后，如果接近底部，恢复自动滚动
    if (self.isNearBottom) {
        self.shouldAutoScrollToBottom = YES;
        NSLog(@"拖动结束，接近底部，恢复自动滚动");
    }
    
    // 关键优化：用户停止拖动时，恢复UI更新
    if (!decelerate) {
        [self resumeUIUpdates];
    }
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    // 减速结束后，如果接近底部，恢复自动滚动
    if (self.isNearBottom) {
        self.shouldAutoScrollToBottom = YES;
        NSLog(@"减速结束，接近底部，恢复自动滚动");
    }
    
    // 关键优化：减速结束后，恢复UI更新
    [self resumeUIUpdates];
}

// 在流式过程中，若应粘底，则直接拉到底部（无动画，避免抖动）
- (void)stickToBottomIfNeeded {
    if (!self.shouldAutoScrollToBottom) return;
    [self.tableNode.view layoutIfNeeded];
    [self scrollToBottomImmediate];
}

// 新增：高性能滚动到底部方法
- (void)scrollToBottomWithThrottling {
    [self scrollToBottom];
}

// 新增：确保最终滚动和富文本渲染完成
- (void)ensureFinalScrollAndRender {
    if (self.messages.count == 0) return;
    NSIndexPath *lastIndexPath = [NSIndexPath indexPathForRow:self.messages.count - 1 inSection:0];
    [UIView performWithoutAnimation:^{
        [self.tableNode scrollToRowAtIndexPath:lastIndexPath atScrollPosition:UITableViewScrollPositionBottom animated:NO];
    }];
}

// 新增：获取当前AI节点的索引路径
- (NSIndexPath *)getCurrentAINodeIndexPath {
    if (!self.currentUpdatingAIMessage || !self->_currentUpdatingAINode) {
        return nil;
    }
    
    // 在消息数组中查找当前更新的AI消息
    for (NSInteger i = 0; i < self.messages.count; i++) {
        NSManagedObject *message = self.messages[i];
        if ([message.objectID isEqual:self.currentUpdatingAIMessage.objectID]) {
            return [NSIndexPath indexPathForRow:i inSection:0];
        }
    }
    
    return nil;
}

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

// 新增：获取当前AI消息cell的frame（相对tableView）
- (CGRect)currentAICellFrameInTable {
    NSIndexPath *path = [self getCurrentAINodeIndexPath];
    if (!path) return CGRectNull;
    UITableView *tv = self.tableNode.view;
    UITableViewCell *cell = [tv cellForRowAtIndexPath:path];
    if (!cell) {
        [tv layoutIfNeeded];
        cell = [tv cellForRowAtIndexPath:path];
    }
    if (!cell) return CGRectNull;
    return [tv convertRect:cell.frame fromView:tv];
}

// 新增：基于AI气泡底部与table底部的智能滚动判断
- (BOOL)shouldSmartAutoScrollForCurrentAI {
    CGRect frame = [self currentAICellFrameInTable];
    if (CGRectIsNull(frame)) return NO;
    UITableView *tv = self.tableNode.view;
    CGFloat tableBottomY = tv.contentOffset.y + tv.bounds.size.height - tv.adjustedContentInset.bottom;
    CGFloat cellBottomY = CGRectGetMaxY(frame);
    CGFloat tolerance = 24.0; // 允许24pt容差
    return (cellBottomY <= tableBottomY + tolerance);
}

// 新增：尝试执行一次智能粘底（带节流）
- (void)performSmartStickIfNeeded {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (now - self.lastAutoScrollTime < 0.05) return; // 50ms节流
    self.lastAutoScrollTime = now;
    if ([self shouldSmartAutoScrollForCurrentAI]) {
        [self anchorStickToBottomPreservingOffset];
    }
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
    
    // 关键优化：使用同步更新，避免延迟导致的滚动问题
    UITableView *tv = self.tableNode.view;
    [tv layoutIfNeeded];
    
    NSIndexPath *path = [self getCurrentAINodeIndexPath];
    if (path) {
        [UIView performWithoutAnimation:^{
            [self.tableNode scrollToRowAtIndexPath:path atScrollPosition:UITableViewScrollPositionBottom animated:NO];
        }];
    } else {
        [self anchorStickToBottomPreservingOffset];
    }
}

// 新增：在近底部时，保持底部对齐地执行更新（避免先扩展再滚动）
- (void)performUpdatesPreservingBottom:(dispatch_block_t)updates {
    if (!updates) return;
    UITableView *tv = self.tableNode.view;
    BOOL nearBottom = [self isNearBottomWithTolerance:120.0];
    if (!nearBottom) {
        updates();
        return;
    }
    
    // 关键优化：同步执行更新和滚动，避免"先扩展再滚动"
    [UIView performWithoutAnimation:^{
        // 1. 执行更新
        updates();
        
        // 2. 立即布局
        [tv layoutIfNeeded];
        
        // 3. 同步滚动，保持底部对齐
        CGFloat visibleHeight = tv.bounds.size.height - tv.adjustedContentInset.bottom;
        CGFloat targetOffsetY = tv.contentSize.height - visibleHeight;
        CGFloat minOffsetY = -tv.adjustedContentInset.top; // 顶部容错
        
        if (targetOffsetY < minOffsetY) targetOffsetY = minOffsetY;
        
        // 4. 立即设置滚动位置，实现同步效果
        [tv setContentOffset:CGPointMake(tv.contentOffset.x, targetOffsetY) animated:NO];
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

@end

