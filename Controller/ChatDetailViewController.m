#import "ChatDetailViewController.h"
#import "MessageCell.h"
#import "ThinkingView.h"
#import "CoreDataManager.h"
#import "APIManager.h"
@import CoreData;


@interface ChatDetailViewController () <UITableViewDelegate, UITableViewDataSource, UITextViewDelegate>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray *messages;
@property (nonatomic, strong) UIView *inputContainerView;
@property (nonatomic, strong) UIView *inputBackgroundView;
@property (nonatomic, strong) UITextView *inputTextView;
@property (nonatomic, strong) UIButton *addButton;
@property (nonatomic, strong) UIButton *sendButton;
@property (nonatomic, strong) NSLayoutConstraint *inputContainerBottomConstraint;
@property (nonatomic, strong) ThinkingView *thinkingView;
@property (nonatomic, assign) BOOL isThinking;

// 添加属性来持有当前的流式任务
@property (nonatomic, strong) NSURLSessionDataTask *currentStreamingTask;

// 添加属性来持有正在更新的 AI 消息对象
@property (nonatomic, weak) NSManagedObject *currentUpdatingAIMessage;

// 添加属性来保存上一次的回复内容，用于计算增量
@property (nonatomic, copy) NSString *lastResponseContent;

// 添加逐字打印相关属性
@property (nonatomic, strong) NSMutableString *typingBuffer; // 保存待显示的文本缓冲区
@property (nonatomic, strong) NSTimer *typingTimer; // 打字定时器
@property (nonatomic, assign) NSTimeInterval typingSpeed; // 打字速度(秒)

@end

@implementation ChatDetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupViews];
    [self fetchMessages];
    
    // 设置键盘通知
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
    
    // 添加应用程序状态通知
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationWillResignActive:) name:UIApplicationWillResignActiveNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(applicationDidEnterBackground:) name:UIApplicationDidEnterBackgroundNotification object:nil];
    
    // 初始化占位符状态
    [self updatePlaceholderVisibility];
    
    // 初始化逐字打印相关属性
    self.typingBuffer = [NSMutableString string];
    self.typingSpeed = 0.03; // 固定打字速度为每字符0.03秒
    
    // 加载保存的 API Key
    NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"OpenAIAPIKey"];
    if (apiKey.length > 0) {
        [[APIManager sharedManager] setApiKey:apiKey];
    } else {
        // 如果没有设置 API Key，提示用户设置
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showNeedAPIKeyAlert];
        });
    }
    
    // 加载保存的默认提示词
    NSString *defaultPrompt = [[NSUserDefaults standardUserDefaults] stringForKey:@"DefaultSystemPrompt"];
    if (defaultPrompt.length > 0) {
        [APIManager sharedManager].defaultSystemPrompt = defaultPrompt;
    }
    
    // 加载保存的模型选择
    NSString *selectedModel = [[NSUserDefaults standardUserDefaults] stringForKey:@"SelectedModelName"];
    if (selectedModel.length > 0) {
        [APIManager sharedManager].currentModelName = selectedModel;
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self fetchMessages];
    [self.tableView reloadData];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    // 当视图即将消失时，清空打印缓冲区并显示全部内容
    [self flushTypingBuffer];
    
    // 当视图即将消失时，取消当前的流式任务
    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
        self.currentStreamingTask = nil;
        [self hideThinkingStatus]; // 隐藏思考状态
    }
}

- (void)setupViews {
    self.view.backgroundColor = [UIColor colorWithRed:247/255.0 green:247/255.0 blue:248/255.0 alpha:1.0]; // #f7f7f8
    
    // 顶部导航栏
    [self setupHeader];
    
    // 聊天消息表格
    [self setupTableView];
    
    // 输入区域
    [self setupInputArea];
    
    // 思考状态动画视图
    self.thinkingView = [[ThinkingView alloc] initWithFrame:CGRectZero];
    self.thinkingView.translatesAutoresizingMaskIntoConstraints = NO;
    self.thinkingView.hidden = YES;
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

- (void)setupTableView {
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.tableView.backgroundColor = [UIColor colorWithRed:247/255.0 green:247/255.0 blue:248/255.0 alpha:1.0]; // #f7f7f8
    [self.tableView registerClass:[MessageCell class] forCellReuseIdentifier:@"MessageCell"];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    self.tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [self.view addSubview:self.tableView];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:44],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
}

- (void)setupInputArea {
    // 创建输入容器视图
    self.inputContainerView = [[UIView alloc] init];
    self.inputContainerView.backgroundColor = [UIColor clearColor];
    self.inputContainerView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.inputContainerView];
    
    // 创建输入背景视图
    self.inputBackgroundView = [[UIView alloc] init];
    self.inputBackgroundView.backgroundColor = [UIColor systemGray6Color];
    self.inputBackgroundView.layer.cornerRadius = 18.0;
    self.inputBackgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainerView addSubview:self.inputBackgroundView];
    
    // 创建输入文本视图
    self.inputTextView = [[UITextView alloc] init];
    self.inputTextView.font = [UIFont systemFontOfSize:15];
    self.inputTextView.delegate = self;
    self.inputTextView.scrollEnabled = YES;
    self.inputTextView.layer.cornerRadius = 18.0;
    self.inputTextView.textContainerInset = UIEdgeInsetsMake(8, 8, 8, 8);
    self.inputTextView.backgroundColor = [UIColor clearColor];
    self.inputTextView.translatesAutoresizingMaskIntoConstraints = NO;
    self.inputTextView.userInteractionEnabled = YES;
    
    // 添加点击手势以确保点击输入框时成为第一响应者
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleInputTextViewTap:)];
    tapGesture.cancelsTouchesInView = NO;
    [self.inputTextView addGestureRecognizer:tapGesture];
    
    // 添加输入框到背景视图
    [self.inputBackgroundView addSubview:self.inputTextView];
    
    // 创建占位符标签
    self.placeholderLabel = [[UILabel alloc] init];
    self.placeholderLabel.text = @" 给ChatGPT发送信息";
    self.placeholderLabel.textColor = [UIColor lightGrayColor];
    self.placeholderLabel.font = [UIFont systemFontOfSize:16];
    self.placeholderLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputBackgroundView addSubview:self.placeholderLabel];
    
    // 设置占位符标签的约束
    [NSLayoutConstraint activateConstraints:@[
        [self.placeholderLabel.leadingAnchor constraintEqualToAnchor:self.inputTextView.leadingAnchor constant:5],
        [self.placeholderLabel.topAnchor constraintEqualToAnchor:self.inputTextView.topAnchor constant:8],
    ]];
    
    // 设置输入框的高度约束
    self.inputTextViewHeightConstraint = [self.inputTextView.heightAnchor constraintEqualToConstant:36];
    self.inputTextViewHeightConstraint.active = YES;

    // 确保tableView底部连接到inputContainer顶部
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.inputContainerView.topAnchor],
    ]];
    
    // 创建工具栏
    UIView *toolbarView = [[UIView alloc] init];
    toolbarView.backgroundColor = [UIColor clearColor];
    toolbarView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.inputContainerView addSubview:toolbarView];
    
    // 创建添加按钮
    self.addButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.addButton setImage:[UIImage systemImageNamed:@"plus.circle"] forState:UIControlStateNormal];
    self.addButton.tintColor = [UIColor blackColor];
    self.addButton.translatesAutoresizingMaskIntoConstraints = NO;
    [toolbarView addSubview:self.addButton];
    
    // 创建发送按钮
    self.sendButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.sendButton setImage:[UIImage systemImageNamed:@"arrow.up.circle.fill"] forState:UIControlStateNormal];
    self.sendButton.tintColor = [UIColor blackColor];
    self.sendButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.sendButton addTarget:self action:@selector(sendButtonTapped) forControlEvents:UIControlEventTouchUpInside];
    [toolbarView addSubview:self.sendButton];
    
    self.inputBackgroundView.userInteractionEnabled = YES;
    
    // 设置约束
    self.inputContainerBottomConstraint = [self.inputContainerView.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor];
    
    [NSLayoutConstraint activateConstraints:@[
        // 输入容器视图约束
        self.inputContainerBottomConstraint,
        [self.inputContainerView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:16],
        [self.inputContainerView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        
        // 输入背景视图约束
        [self.inputBackgroundView.topAnchor constraintEqualToAnchor:self.inputContainerView.topAnchor constant:8],
        [self.inputBackgroundView.leadingAnchor constraintEqualToAnchor:self.inputContainerView.leadingAnchor constant:16],
        [self.inputBackgroundView.trailingAnchor constraintEqualToAnchor:toolbarView.leadingAnchor constant:-8],
        [self.inputBackgroundView.bottomAnchor constraintEqualToAnchor:self.inputContainerView.bottomAnchor constant:-8],
        
        // 工具栏约束
        [toolbarView.topAnchor constraintEqualToAnchor:self.inputContainerView.topAnchor constant:8],
        [toolbarView.trailingAnchor constraintEqualToAnchor:self.inputContainerView.trailingAnchor constant:-16],
        [toolbarView.bottomAnchor constraintEqualToAnchor:self.inputContainerView.bottomAnchor constant:-8],
        [toolbarView.widthAnchor constraintEqualToConstant:90],
        
        // 添加按钮约束
        [self.addButton.leadingAnchor constraintEqualToAnchor:toolbarView.leadingAnchor constant:8],
        [self.addButton.centerYAnchor constraintEqualToAnchor:toolbarView.centerYAnchor],
        [self.addButton.widthAnchor constraintEqualToConstant:36],
        [self.addButton.heightAnchor constraintEqualToConstant:36],
        
        // 发送按钮约束
        [self.sendButton.trailingAnchor constraintEqualToAnchor:toolbarView.trailingAnchor constant:-8],
        [self.sendButton.centerYAnchor constraintEqualToAnchor:toolbarView.centerYAnchor],
        [self.sendButton.widthAnchor constraintEqualToConstant:36],
        [self.sendButton.heightAnchor constraintEqualToConstant:36],
        
        // 输入文本视图约束
        [self.inputTextView.topAnchor constraintEqualToAnchor:self.inputBackgroundView.topAnchor],
        [self.inputTextView.leadingAnchor constraintEqualToAnchor:self.inputBackgroundView.leadingAnchor constant:20],
        [self.inputTextView.trailingAnchor constraintEqualToAnchor:self.inputBackgroundView.trailingAnchor],
        [self.inputTextView.bottomAnchor constraintEqualToAnchor:self.inputBackgroundView.bottomAnchor],
        self.inputTextViewHeightConstraint,
    ]];
}

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

- (void)dealloc {
    // 停止定时器
    [self stopTypingAnimation];
    
    // 移除通知
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    
    // 确保任务被取消
    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
        self.currentStreamingTask = nil;
    }
}

#pragma mark - Keyboard Handling

- (void)keyboardWillShow:(NSNotification *)notification {
    // 监听键盘的最终位置和大小
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

#pragma mark - Message Handling

- (void)sendButtonTapped {
    if (self.inputTextView.text.length == 0) {
        return;
    }
    
    // 获取用户消息
    NSString *userMessage = [self.inputTextView.text copy];
    
    // 清空输入框 (在添加消息前清空，减少UI操作间隔)
    self.inputTextView.text = @"";
    self.placeholderLabel.hidden = NO;
    self.inputTextViewHeightConstraint.constant = 40;
    [self.view layoutIfNeeded]; // 立即更新输入框布局
    
    // 隐藏键盘
    [self.inputTextView resignFirstResponder];
    
    // 添加用户消息（内部包含滚动到底部）
    [self addMessageWithText:userMessage isFromUser:YES];
    
    // 确保滚动到底部，准备显示思考状态
    [self scrollToBottomImmediate];
    
    // 使用短延迟确保消息显示后再开始AI响应
    // 这样可以分离两个操作，减少同时进行的视觉更新
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        // 开始AI响应
        [self simulateAIResponse];
    });
}

- (void)showThinkingStatus {
    self.isThinking = YES;
    
    // 移除旧的思考视图，如果有的话
    for (UIView *subview in self.tableView.subviews) {
        if ([subview isKindOfClass:[ThinkingView class]]) {
            [subview removeFromSuperview];
        }
    }
    
    // 先滚动到底部
    [self scrollToBottomImmediate];
    
    // 创建思考视图
    self.thinkingView = [[ThinkingView alloc] initWithFrame:CGRectZero];
    self.thinkingView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.tableView addSubview:self.thinkingView];
    
    // 计算位置 - 在tableView内容的底部
    CGFloat bottomPadding = 10.0f;
    CGFloat contentHeight = self.tableView.contentSize.height;
    
    // 使用自动布局约束固定思考视图的位置
    [NSLayoutConstraint activateConstraints:@[
        [self.thinkingView.leadingAnchor constraintEqualToAnchor:self.tableView.leadingAnchor constant:16],
        [self.thinkingView.topAnchor constraintEqualToAnchor:self.tableView.contentLayoutGuide.topAnchor constant:contentHeight + bottomPadding],
        [self.thinkingView.widthAnchor constraintEqualToConstant:100],
        [self.thinkingView.heightAnchor constraintEqualToConstant:40]
    ]];
    
    // 开始动画
    [self.thinkingView startAnimating];
    
    // 调整tableView内容大小，确保思考视图可见
    CGFloat extraSpace = 60; // 额外空间
    CGFloat newContentHeight = contentHeight + self.thinkingView.frame.size.height + extraSpace;
    
    // 为tableView添加额外的内容高度
    UIEdgeInsets contentInset = self.tableView.contentInset;
    contentInset.bottom = self.thinkingView.frame.size.height + extraSpace;
    self.tableView.contentInset = contentInset;
    
    // 确保滚动到包含思考视图的位置
    CGPoint bottomOffset = CGPointMake(0, newContentHeight - self.tableView.bounds.size.height + self.tableView.contentInset.bottom);
    [self.tableView setContentOffset:bottomOffset animated:NO];
}

- (void)hideThinkingStatus {
    self.isThinking = NO;
    [self.thinkingView stopAnimating];
    [self.thinkingView removeFromSuperview];
    
    // 恢复tableView的内容偏移
    UIEdgeInsets contentInset = self.tableView.contentInset;
    contentInset.bottom = 0;
    self.tableView.contentInset = contentInset;
    
    // 确保滚动到底部
    dispatch_async(dispatch_get_main_queue(), ^{
        [self scrollToBottomImmediate];
    });
}

- (void)scrollToBottom {
    if (self.messages.count > 0) {
        // 使用延迟确保在tableView完成重新加载数据后再滚动
        dispatch_async(dispatch_get_main_queue(), ^{
            NSIndexPath *lastIndexPath = [NSIndexPath indexPathForRow:self.messages.count - 1 inSection:0];
            
            // 获取表格当前内容高度与可见区域的差值，判断是跳跃式滚动还是平滑滚动
            CGFloat contentHeight = self.tableView.contentSize.height;
            CGFloat visibleHeight = self.tableView.bounds.size.height;
            CGFloat currentOffset = self.tableView.contentOffset.y;
            CGFloat bottomOffset = contentHeight - visibleHeight;
            CGFloat distanceFromBottom = bottomOffset - currentOffset;
            
            // 如果已经接近底部，使用平滑动画
            if (distanceFromBottom < 100) {
                [self.tableView scrollToRowAtIndexPath:lastIndexPath 
                                     atScrollPosition:UITableViewScrollPositionBottom 
                                             animated:YES];
            } else {
                // 否则使用无动画跳转，避免长距离滚动带来的延迟感
                [self.tableView scrollToRowAtIndexPath:lastIndexPath 
                                     atScrollPosition:UITableViewScrollPositionBottom 
                                             animated:NO];
            }
        });
    }
}

// 立即滚动到底部，无动画
- (void)scrollToBottomImmediate {
    if (self.messages.count > 0) {
        NSIndexPath *lastIndexPath = [NSIndexPath indexPathForRow:self.messages.count - 1 inSection:0];
        [self.tableView scrollToRowAtIndexPath:lastIndexPath atScrollPosition:UITableViewScrollPositionBottom animated:NO];
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.messages.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    MessageCell *cell = [tableView dequeueReusableCellWithIdentifier:@"MessageCell" forIndexPath:indexPath];
    
    NSManagedObject *message = self.messages[indexPath.row];
    NSString *content = [message valueForKey:@"content"];
    BOOL isFromUser = [[message valueForKey:@"isFromUser"] boolValue];
    [cell configureWithMessage:content isFromUser:isFromUser];
    
    return cell;
}

#pragma mark - UITableViewDelegate

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSManagedObject *message = self.messages[indexPath.row];
    NSString *content = [message valueForKey:@"content"];
    BOOL isFromUser = [[message valueForKey:@"isFromUser"] boolValue];
    
    // 获取基础高度
    CGFloat baseHeight = [MessageCell heightForMessage:content width:tableView.bounds.size.width];
    
    // 对AI生成的长内容提供更多空间
    if (!isFromUser && content.length > 200) {
        // 针对长文本，额外增加内容长度相关的高度
        CGFloat extraHeight = MIN(40, content.length / 100 * 5); // 每100字符最多增加5pt，但不超过40pt
        return baseHeight + extraHeight;
    }
    
    // 普通消息使用基础高度即可
    return baseHeight;
}

#pragma mark - UITextViewDelegate

- (void)textViewDidChange:(UITextView *)textView {
    // 更新占位符状态
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
    // 根据输入文本长度更新占位符可见性
    self.placeholderLabel.hidden = self.inputTextView.text.length > 0;
}

- (BOOL)textView:(UITextView *)textView shouldChangeTextInRange:(NSRange)range replacementText:(NSString *)text {
    if ([text isEqualToString:@"\n"] && textView.text.length == 0) {
        return NO;
    }
    return YES;
}

- (void)simulateAIResponse {
    // 如果已有任务在进行，先取消
    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
        self.currentStreamingTask = nil;
    }
    
    // 停止当前的打字动画并清空缓冲区
    [self stopTypingAnimation];
    [self.typingBuffer setString:@""];
    
    // 显示思考状态
    [self showThinkingStatus];
    
    // 重置上一次的回复内容
    self.lastResponseContent = @"";
    
    // 构建消息历史记录
    NSMutableArray *messages = [NSMutableArray array];
    
    // 添加系统提示
    [messages addObject:@{
        @"role": @"system",
        @"content": [APIManager sharedManager].defaultSystemPrompt
    }];
    
    // 添加历史消息（最多4轮对话）
    NSInteger messageCount = self.messages.count;
    NSInteger startIndex = MAX(0, messageCount - 8); // 最多取最近8条消息(4轮对话)
    
    for (NSInteger i = startIndex; i < messageCount; i++) {
        NSManagedObject *message = self.messages[i];
        NSString *content = [message valueForKey:@"content"];
        BOOL isFromUser = [[message valueForKey:@"isFromUser"] boolValue];
        
        [messages addObject:@{
            @"role": isFromUser ? @"user" : @"assistant",
            @"content": content
        }];
    }
    
    // 使用 API 进行请求，并保存任务对象
    self.currentStreamingTask = [[APIManager sharedManager] streamingChatCompletionWithMessages:messages 
                                                                               streamCallback:^(NSString *partialResponse, BOOL isDone, NSError *error) {
        if (error) {
            // 处理错误
            [self hideThinkingStatus];
            
            // 显示错误消息
            NSString *errorMessage = [NSString stringWithFormat:@"API 错误: %@", error.localizedDescription];
            [self addMessageWithText:errorMessage isFromUser:NO];
            self.currentStreamingTask = nil; // 清理任务引用
            self.currentUpdatingAIMessage = nil; // 清理AI消息引用
            self.lastResponseContent = @""; // 重置
            [self stopTypingAnimation]; // 停止打字动画
            [self.typingBuffer setString:@""]; // 清空缓冲区
            return;
        }
        
        // 计算增量内容
        NSString *incrementalContent = @"";
        if (partialResponse.length >= self.lastResponseContent.length) {
            incrementalContent = [partialResponse substringFromIndex:self.lastResponseContent.length];
            // 更新上一次的内容
            self.lastResponseContent = [partialResponse copy];
        } else {
            // 异常情况：新内容比旧内容短，直接使用新内容
            incrementalContent = partialResponse;
            self.lastResponseContent = [partialResponse copy];
        }
        
        if (isDone) {
            // 完成响应
            [self hideThinkingStatus];
            
            // partialResponse为AI 响应的最新片段
            if (self.currentUpdatingAIMessage && partialResponse) {
                // 确保全部内容已添加到缓冲区
                if (![partialResponse isEqualToString:self.lastResponseContent]) {
                    incrementalContent = [partialResponse substringFromIndex:self.lastResponseContent.length];
                    if (incrementalContent.length > 0) {
                        [self addTextToTypingBuffer:incrementalContent];
                    }
                }
                
                // 设置任务已完成标志
                self.currentStreamingTask = nil;
                
                // 注意：不需要立即调用saveContext，typeNextCharacter方法会在缓冲区为空时保存
            } else if (partialResponse) {
                // 如果没有正在更新的消息（例如，出错了或首次就完成了），则直接添加
                [self addMessageWithText:partialResponse isFromUser:NO];
            }
            
            self.currentStreamingTask = nil; // 清理任务引用
            // 注意：我们保留currentUpdatingAIMessage，直到缓冲区清空
        } else { // isDone == NO，处理中间的数据块
            if (self.isThinking) {
                // 收到第一个数据块，创建新消息
                [self hideThinkingStatus];
                
                // 创建新的 AI 消息记录到 Core Data，但初始为空内容
                self.currentUpdatingAIMessage = [[CoreDataManager sharedManager] addMessageToChat:self.chat content:@"" isFromUser:NO];
                
                // 重新获取数据并用无动画方式插入新行
                [self fetchMessages]; 
                NSIndexPath *newIndexPath = [NSIndexPath indexPathForRow:self.messages.count - 1 inSection:0];
                
                // 使用无动画方式插入，减少抖动
                [UIView performWithoutAnimation:^{
                    [self.tableView beginUpdates];
                    [self.tableView insertRowsAtIndexPaths:@[newIndexPath] withRowAnimation:UITableViewRowAnimationNone];
                    [self.tableView endUpdates];
                }];
                
                // 平滑滚动到底部
                [self scrollToBottomImmediate];
                
                // 将这个数据块添加到打印缓冲区
                if (incrementalContent.length > 0) {
                    [self addTextToTypingBuffer:incrementalContent];
                }
            } else if (self.currentUpdatingAIMessage) {
                // 将这个增量数据块添加到打印缓冲区
                if (incrementalContent.length > 0) {
                    [self addTextToTypingBuffer:incrementalContent];
                }
            }
        }
    }];
}

- (void)addMessageWithText:(NSString *)text isFromUser:(BOOL)isFromUser {
    // 记录当前消息数量
    NSInteger currentCount = self.messages.count;
    
    // 保存消息到CoreData
    [[CoreDataManager sharedManager] addMessageToChat:self.chat content:text isFromUser:isFromUser];
    
    // 重新获取消息数据
    [self fetchMessages];
    
    // 如果实际上是新增了消息，则只插入新行而不是完全刷新
    if (self.messages.count > currentCount) {
        NSIndexPath *newIndexPath = [NSIndexPath indexPathForRow:self.messages.count - 1 inSection:0];
        
        // 禁用动画执行插入操作，减少视觉抖动
        [UIView performWithoutAnimation:^{
            [self.tableView beginUpdates];
            [self.tableView insertRowsAtIndexPaths:@[newIndexPath] withRowAnimation:UITableViewRowAnimationNone];
            [self.tableView endUpdates];
        }];
        
        // 滚动到底部
        [self scrollToBottom];
    }
}

#pragma mark - Input Handling

- (void)handleInputTextViewTap:(UITapGestureRecognizer *)gesture {
    // 确保输入框成为第一响应者
    [self.inputTextView becomeFirstResponder];
}

- (BOOL)textViewShouldBeginEditing:(UITextView *)textView {
    // 开始编辑时滚动到底部
    [self scrollToBottom];
    
    // 显式调用成为第一响应者（虽然返回YES通常会自动执行此操作）
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.inputTextView becomeFirstResponder];
    });
    
    return YES;
}

- (void)showAPIKeyAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"设置 API Key"
                                                                  message:@"请输入您的 OpenAI API Key"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.placeholder = @"sk-...";
        textField.secureTextEntry = YES;
        
        // 如果已有 API Key，则预填充（这里只显示前后几位，中间用星号代替）
        NSString *apiKey = [[NSUserDefaults standardUserDefaults] stringForKey:@"OpenAIAPIKey"];
        if (apiKey.length > 8) {
            NSString *prefix = [apiKey substringToIndex:4];
            NSString *suffix = [apiKey substringFromIndex:apiKey.length - 4];
            textField.text = [NSString stringWithFormat:@"%@•••••%@", prefix, suffix];
            textField.tag = 1; // 标记为已有 API Key
        }
    }];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消"
                                                          style:UIAlertActionStyleCancel
                                                        handler:nil];
    
    UIAlertAction *saveAction = [UIAlertAction actionWithTitle:@"保存"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction * _Nonnull action) {
        UITextField *textField = alert.textFields.firstObject;
        NSString *apiKey = textField.text;
        
        // 检查是否是有效的 API Key 格式（简单检查）
        if (apiKey.length < 10 || ![apiKey hasPrefix:@"sk-"]) {
            if (textField.tag != 1) { // 如果不是已有 API Key
                [self showErrorAlert:@"API Key 格式不正确，请输入有效的 API Key"];
                return;
            }
            // 如果是已有 API Key 且未修改，则不做任何操作
            return;
        }
        
        // 保存 API Key
        [[NSUserDefaults standardUserDefaults] setObject:apiKey forKey:@"OpenAIAPIKey"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        // 设置 API Manager 的 API Key
        [[APIManager sharedManager] setApiKey:apiKey];
        
        // 显示成功提示
        [self showSuccessAlert:@"API Key 已保存"];
    }];
    
    [alert addAction:cancelAction];
    [alert addAction:saveAction];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showErrorAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"错误"
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"确定"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil];
    
    [alert addAction:okAction];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showSuccessAlert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"成功"
                                                                  message:message
                                                           preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *okAction = [UIAlertAction actionWithTitle:@"确定"
                                                      style:UIAlertActionStyleDefault
                                                    handler:nil];
    
    [alert addAction:okAction];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showNeedAPIKeyAlert {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"需要设置 API Key"
                                                                  message:@"使用 ChatGPT 功能需要设置有效的 OpenAI API Key。立即设置吗？"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"稍后"
                                                          style:UIAlertActionStyleCancel
                                                        handler:nil];
    
    UIAlertAction *settingAction = [UIAlertAction actionWithTitle:@"立即设置"
                                                           style:UIAlertActionStyleDefault
                                                         handler:^(UIAlertAction * _Nonnull action) {
        [self showAPIKeyAlert];
    }];
    
    [alert addAction:cancelAction];
    [alert addAction:settingAction];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)resetAPIKey {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重置 API Key"
                                                                  message:@"确定要重置当前的 API Key 吗？"
                                                           preferredStyle:UIAlertControllerStyleAlert];
    
    UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:@"取消"
                                                         style:UIAlertActionStyleCancel
                                                       handler:nil];
    
    UIAlertAction *resetAction = [UIAlertAction actionWithTitle:@"重置"
                                                        style:UIAlertActionStyleDestructive
                                                      handler:^(UIAlertAction * _Nonnull action) {
        // 清除保存的API Key
        [[NSUserDefaults standardUserDefaults] removeObjectForKey:@"OpenAIAPIKey"];
        [[NSUserDefaults standardUserDefaults] synchronize];
        
        // 清空API Manager中的API Key
        [[APIManager sharedManager] setApiKey:@""];
        
        // 显示成功提示
        [self showSuccessAlert:@"API Key 已重置，请设置新的 API Key"];
        
        // 提示用户设置新的API Key
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self showAPIKeyAlert];
        });
    }];
    
    [alert addAction:cancelAction];
    [alert addAction:resetAction];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (BOOL)isTableViewScrolledToBottom {
    // 判断tableView是否滚动到底部的逻辑
    CGFloat contentHeight = self.tableView.contentSize.height;
    CGFloat offsetY = self.tableView.contentOffset.y + self.tableView.frame.size.height;
    
    // 如果偏移量加上tableView高度大于或等于内容高度(减去一个小的阈值)，则认为滚动到底部
    return offsetY >= contentHeight - 20;
}

- (void)showModelSelectionMenu:(UIButton *)sender {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"选择模型"
                                                                             message:nil
                                                                      preferredStyle:UIAlertControllerStyleActionSheet];
    
    // 添加模型选项
    [alertController addAction:[UIAlertAction actionWithTitle:@"GPT-3.5"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction * _Nonnull action) {
        [self updateModelSelection:@"gpt-3.5-turbo" button:sender];
    }]];
    
    [alertController addAction:[UIAlertAction actionWithTitle:@"GPT-4o"
                                                        style:UIAlertActionStyleDefault
                                                      handler:^(UIAlertAction * _Nonnull action) {
        [self updateModelSelection:@"gpt-4o" button:sender];
    }]];
    
    // 添加取消选项
    [alertController addAction:[UIAlertAction actionWithTitle:@"取消"
                                                        style:UIAlertActionStyleCancel
                                                      handler:nil]];
    
    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)updateModelSelection:(NSString *)modelName button:(UIButton *)button {
    // 更新 APIManager 中的模型名称
    [APIManager sharedManager].currentModelName = modelName;
    
    // 更新按钮标题
    [button setTitle:modelName forState:UIControlStateNormal];
    
    // 保存选择到 UserDefaults
    [[NSUserDefaults standardUserDefaults] setObject:modelName forKey:@"SelectedModelName"];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - 逐字打印实现

// 启动逐字打印定时器
- (void)startTypingAnimation {
    // 如果已有定时器正在运行，则不重新启动
    if (self.typingTimer && self.typingTimer.valid) {
        return;
    }
    
    // 创建并启动定时器
    self.typingTimer = [NSTimer scheduledTimerWithTimeInterval:self.typingSpeed
                                                      target:self
                                                    selector:@selector(typeNextCharacter)
                                                    userInfo:nil
                                                     repeats:YES];
    
    // 确保定时器在滚动时也能正常工作
    [[NSRunLoop currentRunLoop] addTimer:self.typingTimer forMode:NSRunLoopCommonModes];
}

// 停止逐字打印定时器
- (void)stopTypingAnimation {
    if (self.typingTimer) {
        [self.typingTimer invalidate];
        self.typingTimer = nil;
    }
}

// 将文本添加到打印缓冲区
- (void)addTextToTypingBuffer:(NSString *)text {
    // 将新文本添加到缓冲区
    [self.typingBuffer appendString:text];
    
    // 确保定时器正在运行
    [self startTypingAnimation];
}

// 显示缓冲区中的下一个字符
- (void)typeNextCharacter {
    // 检查是否还有未打印的字符
    if (self.typingBuffer.length == 0) {
        [self stopTypingAnimation];
        return;
    }
    
    NSIndexPath *lastRow = [NSIndexPath indexPathForRow:self.messages.count - 1 inSection:0];
    MessageCell *cell = [self.tableView cellForRowAtIndexPath:lastRow];
    
    if (!cell) {
        return; // 如果单元格不可见，暂停打印
    }
    
    // 获取当前显示的文本
    NSString *currentText = cell.messageLabel.attributedText.string ?: @"";
    
    // 从缓冲区取出一个字符
    NSString *nextChar = [self.typingBuffer substringToIndex:1];
    [self.typingBuffer deleteCharactersInRange:NSMakeRange(0, 1)];
    
    // 更新cell中显示的文本
    NSString *newText = [currentText stringByAppendingString:nextChar];
    
    // 创建与实际显示相同的段落样式
    NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    paragraphStyle.lineSpacing = 4; // 行间距
    paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
    
    // 使用带格式的文本
    NSAttributedString *attributedText = [[NSAttributedString alloc] initWithString:newText 
                                                                        attributes:@{
                                                                            NSParagraphStyleAttributeName: paragraphStyle,
                                                                            NSFontAttributeName: [UIFont systemFontOfSize:16]
                                                                        }];
    cell.messageLabel.attributedText = attributedText;
    
    // 更新数据库中的消息（但不立即保存，减少数据库操作）
    if (self.currentUpdatingAIMessage) {
        [self.currentUpdatingAIMessage setValue:newText forKey:@"content"];
    }
    
    // 检查是否需要重新计算高度（当内容增长触发新行时）
    static NSInteger lastUpdateLength = 0;
    static NSInteger updateFrequency = 30; // 每30个字符更新一次布局
    
    BOOL needsUpdate = NO;
    
    // 优化更新策略，减少不必要的布局计算
    if (newText.length > 0 && 
        (newText.length - lastUpdateLength >= updateFrequency || // 每N个字符检查一次
         [newText containsString:@"\n"] || // 包含换行符
         self.typingBuffer.length == 0)) { // 缓冲区为空（最后一个字符）
        
        // 更新最后检查的长度
        lastUpdateLength = newText.length;
        needsUpdate = YES;
    }
    
    // 只在需要时更新布局，减少抖动
    if (needsUpdate) {
        [UIView performWithoutAnimation:^{
            [self.tableView beginUpdates];
            [self.tableView endUpdates];
            
            // 触发布局更新
            [cell setNeedsLayout];
            [cell layoutIfNeeded];
        }];
    }
    
    // 判断是否需要滚动
    if ([self isTableViewScrolledToBottom]) {
        // 只有当文本长度变化足够大时才滚动，减少频繁滚动
        if (needsUpdate) {
            [self scrollToBottom];
        }
    }
    
    // 如果缓冲区为空，且当前响应已完成，则保存数据
    if (self.typingBuffer.length == 0 && !self.currentStreamingTask) {
        // 保存最终的消息内容
        [[CoreDataManager sharedManager] saveContext]; 
        
        // 确保最后一次高度刷新
        dispatch_async(dispatch_get_main_queue(), ^{
            [UIView performWithoutAnimation:^{
                [self.tableView beginUpdates];
                [self.tableView endUpdates];
            }];
        });
    }
}

// 清空打印缓冲区并立即显示所有内容（用于紧急情况）
- (void)flushTypingBuffer {
    if (self.typingBuffer.length == 0) {
        return;
    }
    
    NSIndexPath *lastRow = [NSIndexPath indexPathForRow:self.messages.count - 1 inSection:0];
    MessageCell *cell = [self.tableView cellForRowAtIndexPath:lastRow];
    
    if (cell) {
        // 获取当前显示的文本
        NSString *currentText = cell.messageLabel.attributedText.string ?: @"";
        
        // 将整个缓冲区的内容一次性添加
        NSString *newText = [currentText stringByAppendingString:self.typingBuffer];
        
        // 创建与实际显示相同的段落样式
        NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
        paragraphStyle.lineSpacing = 4; // 行间距
        paragraphStyle.lineBreakMode = NSLineBreakByWordWrapping;
        
        // 使用带格式的文本
        NSAttributedString *attributedText = [[NSAttributedString alloc] initWithString:newText 
                                                                            attributes:@{
                                                                                NSParagraphStyleAttributeName: paragraphStyle,
                                                                                NSFontAttributeName: [UIFont systemFontOfSize:16]
                                                                            }];
        cell.messageLabel.attributedText = attributedText;
        
        // 更新数据库中的消息
        if (self.currentUpdatingAIMessage) {
            [self.currentUpdatingAIMessage setValue:newText forKey:@"content"];
            [[CoreDataManager sharedManager] saveContext];
        }
        
        // 重新计算高度
        [self.tableView beginUpdates];
        [self.tableView endUpdates];
        
        // 触发布局更新
        [cell setNeedsLayout];
        [cell layoutIfNeeded];
        
        [self scrollToBottom];
    }
    
    // 清空缓冲区
    [self.typingBuffer setString:@""];
    
    // 停止定时器
    [self stopTypingAnimation];
}

#pragma mark - 应用程序状态通知处理

- (void)applicationWillResignActive:(NSNotification *)notification {
    // 应用即将进入非活动状态（如来电、短信等）
    [self flushTypingBuffer]; // 立即显示所有内容
}

- (void)applicationDidEnterBackground:(NSNotification *)notification {
    // 应用进入后台
    [self flushTypingBuffer]; // 立即显示所有内容并保存
    
    // 确保取消任何正在进行的任务
    if (self.currentStreamingTask) {
        [[APIManager sharedManager] cancelStreamingTask:self.currentStreamingTask];
        self.currentStreamingTask = nil;
    }
}

@end 
