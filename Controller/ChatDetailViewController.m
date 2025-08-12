#import "ChatDetailViewController.h"
#import <AsyncDisplayKit/ASDisplayNode+Beta.h>
#import "ThinkingNode.h"
#import "MessageCellNode.h"
#import "AttachmentThumbnailView.h"
#import "CoreDataManager.h"
#import "APIManager.h"
@import CoreData;
#import <QuickLookThumbnailing/QuickLookThumbnailing.h>

// MARK: - 常量定义
// 每次定时器触发时显示的字数，调大此值可加快打字速度
static const NSInteger kTypingSpeedCharacterChunk = 3;
// 定时器触发间隔，调小此值可加快打字速度
static const NSTimeInterval kTypingTimerInterval = 0.05;

@interface ChatDetailViewController () <UITextViewDelegate, ASTableDataSource, ASTableDelegate>

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

// MARK: - 打字机动画相关属性
@property (nonatomic, strong) NSTimer *typingTimer;
@property (nonatomic, strong) NSMutableString *fullResponseBuffer; // 流式响应的完整文本缓冲区
@property (nonatomic, assign) NSInteger displayedTextLength; // 当前UI上已经显示的文本长度
@property (nonatomic, weak) MessageCellNode *currentUpdatingAINode; // 正在更新的AI消息节点的弱引用

// MARK: - 网络请求相关属性
@property (nonatomic, strong) NSURLSessionDataTask *currentStreamingTask;
@property (nonatomic, weak) NSManagedObject *currentUpdatingAIMessage; // 正在更新的AI消息对象

@end

@implementation ChatDetailViewController

// MARK: - 生命周期方法
- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 1. 初始化非视图相关的属性
    self.isAIThinking = NO;
    self.fullResponseBuffer = [NSMutableString string];
    self.selectedAttachments = [NSMutableArray array];
    
    // 2. 初始化并添加核心UI组件（ASTableNode）
    // 必须在setupViews之前执行，因为setupViews会为tableNode创建约束
    _tableNode = [[ASTableNode alloc] initWithStyle:UITableViewStylePlain];
    _tableNode.dataSource = self;
    _tableNode.delegate = self;
    _tableNode.view.separatorStyle = UITableViewCellSeparatorStyleNone;
    [self.view addSubnode:_tableNode];
    
    // 3. 设置所有视图和它的布局约束
    [self setupViews];
    
    // 4. 初始化辅助类和加载数据
    self.mediaPickerManager = [[MediaPickerManager alloc] initWithPresenter:self];
    self.mediaPickerManager.delegate = self;
    [self fetchMessages]; // 在UI设置好后加载数据
    
    // 5. 设置通知和其他UI状态
    [self updatePlaceholderVisibility]; // 依赖于setupViews中创建的placeholderLabel
    [self setupNotifications];
    
    // 6. 加载用户设置和API Key
    [self loadUserSettings];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self fetchMessages];
    [self.tableNode reloadData];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self stopTypingTimer];
    
    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
        self.currentStreamingTask = nil;
        
        // 如果AI仍在思考，则更新数据源并刷新UI
        if (self.isAIThinking) {
            self.isAIThinking = NO;
            [self.tableNode reloadData];
        }
    }
}

- (void)dealloc {
    [self stopTypingTimer];
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
    // 1. 创建视图
    // 容器视图 (阴影层)
    self.inputContainerView = [[UIView alloc] init];
    self.inputContainerView.backgroundColor = [UIColor clearColor];
    self.inputContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    self.inputContainerView.layer.shadowColor = [UIColor grayColor].CGColor;
    self.inputContainerView.layer.shadowOffset = CGSizeMake(0, -5);
    self.inputContainerView.layer.shadowOpacity = 0.2;
    self.inputContainerView.layer.shadowRadius = 4.0;
    
    // 背景视图 (圆角层)
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
    
    // 文本输入视图
    self.inputTextView = [[UITextView alloc] init];
    self.inputTextView.font = [UIFont systemFontOfSize:18];
    self.inputTextView.delegate = self;
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
    if (self.inputTextView.text.length == 0) return;
    
    NSString *userMessage = [self.inputTextView.text copy];
    self.inputTextView.text = @"";
    [self textViewDidChange:self.inputTextView]; // 触发输入框高度更新
    [self.inputTextView resignFirstResponder];
    
    // 使用回调的方法，确保时序正确
    [self addMessageWithText:userMessage isFromUser:YES completion:^{
        // 在用户消息插入动画完成后，再开始AI响应
        [self simulateAIResponse];
    }];
}

// MARK: - ASTableDataSource & ASTableDelegate
- (NSInteger)tableNode:(ASTableNode *)tableNode numberOfRowsInSection:(NSInteger)section {
    // 如果正在思考，总行数 = 消息数 + 1 (用于ThinkingNode)
    return self.messages.count + (self.isAIThinking ? 1 : 0);
}

- (ASCellNodeBlock)tableNode:(ASTableNode *)tableNode nodeBlockForRowAtIndexPath:(NSIndexPath *)indexPath {
    // 检查当前行是否应该是ThinkingNode
    if (self.isAIThinking && indexPath.row == self.messages.count) {
        return ^{
            return [[ThinkingNode alloc] init];
        };
    }
    
    // 否则，正常显示消息节点
    NSManagedObject *messageObject = self.messages[indexPath.row];
    NSString *content = [messageObject valueForKey:@"content"];
    BOOL isFromUser = [[messageObject valueForKey:@"isFromUser"] boolValue];
    
    return ^{
        MessageCellNode *node = [[MessageCellNode alloc] initWithMessage:content isFromUser:isFromUser];
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

- (BOOL)isScrolledToBottom {
    if (!self.tableNode.view) return NO;
    
    CGFloat contentHeight = self.tableNode.view.contentSize.height;
    CGFloat viewHeight = self.tableNode.view.bounds.size.height;
    
    // 如果内容还没填满一屏，也算是在底部
    if (contentHeight < viewHeight) {
        return YES;
    }
    
    CGFloat offsetY = self.tableNode.view.contentOffset.y;
    CGFloat tolerance = 20.0; // 容差
    
    return offsetY + viewHeight >= contentHeight - tolerance;
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
}

- (void)mediaPicker:(MediaPickerManager *)picker didPickDocumentAtURL:(NSURL *)url {
    // 替换掉当前已有的附件
    if (self.selectedAttachments.count < 3) {
        [self.selectedAttachments addObject:url];
    } else {
        NSLog(@"已达到附件数量上限");
    }
    [self updateAttachmentsDisplay];
}

// MARK: - UITextViewDelegate
- (void)textViewDidChange:(UITextView *)textView {
    // 更新占位状态
    [self updatePlaceholderVisibility];
    
    // 动态调整输入框高度
    CGSize size = [textView sizeThatFits:CGSizeMake(textView.bounds.size.width, MAXFLOAT)];
    CGFloat newHeight = MIN(MAX(size.height, 36), 120);
    
    // 只有当高度变化时才更新约束
    if (self.inputTextViewHeightConstraint.constant != newHeight) {
        self.inputTextViewHeightConstraint.constant = newHeight;
        [self.view layoutIfNeeded];
        [self scrollToBottom]; // 确保滚动到底部
    }
}

- (void)updatePlaceholderVisibility {
    // 根据输入文本长度更新占位可见性
    self.placeholderLabel.hidden = self.inputTextView.text.length > 0;
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

// MARK: - AI响应与打字机动画
// 核心逻辑：AI响应与打字机动画 (已修复单次响应重复问题)
- (void)simulateAIResponse {
    // 1. 重置所有相关状态
    [self stopTypingTimer];
    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
    }
    [self.fullResponseBuffer setString:@""];
    self.currentUpdatingAIMessage = nil;
    self.currentUpdatingAINode = nil;
    self.displayedTextLength = 0;
    
    // 2. 显示"Thinking"状态
    // 步骤 1: 设置状态并计算出"思考视图"将要被插入的位置
    self.isAIThinking = YES;
    NSIndexPath *thinkingIndexPath = [NSIndexPath indexPathForRow:self.messages.count inSection:0];
    
    // 步骤 2: 执行带动画的UI更新，插入"思考视图"所在的行
    [self.tableNode performBatchUpdates:^{
        [self.tableNode insertRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationFade];
    } completion:^(BOOL finished) {
        if (finished) {
            // 使用一个微小的延迟来确保布局已经完成
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.01 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [self.tableNode scrollToRowAtIndexPath:thinkingIndexPath
                                      atScrollPosition:UITableViewScrollPositionBottom
                                              animated:YES];
            });
        }
    }];
    
    // 3. 构建历史消息并发起API请求
    NSMutableArray *messages = [self buildMessageHistory];
    __weak typeof(self) weakSelf = self;
    
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
                    [strongSelf.tableNode deleteRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationFade];
                } completion:nil];
                [strongSelf stopTypingTimer];
                return;
            }
            
            // 4. 用最新返回的完整文本直接覆盖缓冲区
            [strongSelf.fullResponseBuffer setString:partialResponse];
            
            // 5. 核心UI更新逻辑
            if (strongSelf.isAIThinking) {
                // 这是第一次收到数据
                strongSelf.isAIThinking = NO;
                
                // a. 在数据源中创建AI消息记录 (初始内容为空)
                strongSelf.currentUpdatingAIMessage = [[CoreDataManager sharedManager] addMessageToChat:strongSelf.chat content:@"" isFromUser:NO];
                [strongSelf fetchMessages]; // 重新加载数据源
                
                NSIndexPath *finalMessagePath = [NSIndexPath indexPathForRow:strongSelf.messages.count - 1 inSection:0];
                
                // b. 替换"Thinking"节点为真实的消息节点
                [strongSelf.tableNode performBatchUpdates:^{
                    [strongSelf.tableNode deleteRowsAtIndexPaths:@[thinkingIndexPath] withRowAnimation:UITableViewRowAnimationNone];
                    [strongSelf.tableNode insertRowsAtIndexPaths:@[finalMessagePath] withRowAnimation:UITableViewRowAnimationFade];
                } completion:^(BOOL finished) {
                    if(finished) {
                        // c. 获取刚刚创建的节点引用
                        strongSelf.currentUpdatingAINode = (MessageCellNode *)[strongSelf.tableNode nodeForRowAtIndexPath:finalMessagePath];
                        // d. 启动我们的打字机定时器
                        [strongSelf startTypingTimer];
                    }
                }];
            }
            
            // 6. 流结束时的处理
            if (isDone) {
                strongSelf.currentStreamingTask = nil;
            }
        });
    }];
}

// 启动定时器
- (void)startTypingTimer {
    // 如果定时器已在运行，则无需操作
    if (self.typingTimer.isValid) {
        return;
    }
    self.typingTimer = [NSTimer scheduledTimerWithTimeInterval:kTypingTimerInterval // 0.05
                                                      target:self
                                                    selector:@selector(typeNextChunk:)
                                                    userInfo:nil
                                                     repeats:YES];
}

// 定时器每次触发时调用的方法 (最终防抖版)
- (void)typeNextChunk:(NSTimer *)timer {
    if (!self.currentUpdatingAINode || !self.currentUpdatingAIMessage) {
        [self stopTypingTimer];
        return;
    }
    
    if (self.displayedTextLength < self.fullResponseBuffer.length) {
        self.displayedTextLength += kTypingSpeedCharacterChunk;
        if (self.displayedTextLength > self.fullResponseBuffer.length) {
            self.displayedTextLength = self.fullResponseBuffer.length;
        }
        NSString *substringToShow = [self.fullResponseBuffer substringToIndex:self.displayedTextLength];
        
        // 关键改动：先更新文本，让Node知道自己需要重新布局
        [self.currentUpdatingAINode updateMessageText:substringToShow];
        
        BOOL shouldStickToBottom = [self isScrolledToBottom];
        
        if (shouldStickToBottom) {
            // 场景 A: 用户在底部
            // 终极解决方案：强制同步布局和滚动
            [UIView performWithoutAnimation:^{
                // 步骤 1: 强制TableView和它的所有子视图立即完成布局
                // 这会调用所有需要更新的Node的layoutSpecThatFits
                // 并同步更新self.tableNode.view.contentSize
                [self.tableNode.view layoutIfNeeded];
                
                // 步骤 2: 此时contentSize已经是最新的了，直接滚动到底部
                // 使用scrollToRowAtIndexPath比手动计算offset更可靠
                NSIndexPath *lastIndexPath = [NSIndexPath indexPathForRow:self.messages.count - 1 inSection:0];
                [self.tableNode scrollToRowAtIndexPath:lastIndexPath
                                      atScrollPosition:UITableViewScrollPositionBottom
                                              animated:NO];
            }];
        } else {
            // 场景 B: 用户已向上滚动
            // 同样需要强制布局，否则屏幕外的Cell高度不会更新。
            // 但我们不改变滚动位置。
            [UIView performWithoutAnimation:^{
                [self.tableNode.view layoutIfNeeded];
            }];
        }
    } else {
        if (self.currentStreamingTask == nil) {
            [self stopTypingTimer];
        }
    }
}

// 停止并清理定时器
- (void)stopTypingTimer {
    if (self.typingTimer) {
        [self.typingTimer invalidate];
        self.typingTimer = nil;
        
        // 定时器停止时，意味着动画结束。确保最终的完整文本被保存到CoreData。
        if (self.currentUpdatingAIMessage && self.fullResponseBuffer.length > 0) {
            // 获取当前CoreData中的值
            NSString *currentSavedText = [self.currentUpdatingAIMessage valueForKey:@"content"];
            // 只有当需要更新时才执行保存，避免不必要的操作
            if (![currentSavedText isEqualToString:self.fullResponseBuffer]) {
                [self.currentUpdatingAIMessage setValue:self.fullResponseBuffer forKey:@"content"];
                [[CoreDataManager sharedManager] saveContext];
            }
        }
        
        // 清理对节点的引用
        self.currentUpdatingAINode = nil;
    }
}

// MARK: - 消息添加辅助方法
- (void)addMessageWithText:(NSString *)text
                isFromUser:(BOOL)isFromUser
                completion:(nullable void (^)(void))completion {
    NSInteger currentCount = self.messages.count;
    [[CoreDataManager sharedManager] addMessageToChat:self.chat content:text isFromUser:isFromUser];
    [self fetchMessages];
    
    if (self.messages.count > currentCount) {
        NSIndexPath *newIndexPath = [NSIndexPath indexPathForRow:self.messages.count - 1 inSection:0];
        
        // 使用performBatchUpdates来确保操作的原子性和动画的流畅性
        [self.tableNode performBatchUpdates:^{
            [self.tableNode insertRowsAtIndexPaths:@[newIndexPath] withRowAnimation:UITableViewRowAnimationFade];
        } completion:^(BOOL finished) {
            // 在动画完成后滚动到底部并执行回调
            [self scrollToBottom];
            if (completion) {
                completion();
            }
        }];
    }
}

// 辅助方法，用于构建消息历史
- (NSMutableArray *)buildMessageHistory {
    NSMutableArray *messages = [NSMutableArray array];
    
    // 添加系统提示
    if ([APIManager sharedManager].defaultSystemPrompt.length > 0) {
        [messages addObject:@{
            @"role": @"system",
            @"content": [APIManager sharedManager].defaultSystemPrompt
        }];
    }
    
    // 添加历史消息（最多4轮对话，即8条消息）
    NSInteger messageCount = self.messages.count;
    NSInteger startIndex = MAX(0, messageCount - 8);
    
    for (NSInteger i = startIndex; i < messageCount; i++) {
        NSManagedObject *message = self.messages[i];
        NSString *content = [message valueForKey:@"content"];
        BOOL isFromUser = [[message valueForKey:@"isFromUser"] boolValue];
        
        [messages addObject:@{
            @"role": isFromUser ? @"user" : @"assistant",
            @"content": content
        }];
    }
    
    return messages;
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

// MARK: - 应用程序状态通知处理
- (void)applicationWillResignActive:(NSNotification *)notification {
    // 应用即将进入非活动状态（如来电、短信等）
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

@end
