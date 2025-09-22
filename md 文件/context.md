# iOS ChatGPT客户端项目开发流程与类结构

## 项目概述
本项目是一个iOS平台的ChatGPT客户端，使用Objective-C开发，实现了与OpenAI API的集成，支持多种GPT模型，提供流式响应输出，并能保存聊天历史记录。

## 开发流程

### 1. 项目架构设计
- 采用MVC架构模式
- 使用CoreData进行数据持久化
- 设计网络层与OpenAI API交互
- 设计UI组件和布局

### 2. 数据模型设计
- 使用CoreData设计Chat和Message实体
- 实现数据管理类

### 3. 网络层实现
- 实现APIManager类处理API请求和响应
- 集成流式响应处理机制

### 4. 用户界面实现
- 实现主视图控制器
- 实现聊天历史列表界面
- 实现聊天详情界面
- 实现自定义UI组件

### 5. 功能整合
- 连接数据层、网络层和UI层
- 实现消息的发送与接收
- 实现模型选择功能
- 实现聊天历史管理

## 主要类结构

### 1. APIManager
负责处理与OpenAI API的通信

#### 属性
```objc
// 单例实例
+ (instancetype)sharedManager;

// API相关
@property (nonatomic, copy) NSString *apiKey;
@property (nonatomic, copy) NSString *defaultSystemPrompt;
@property (nonatomic, copy) NSString *currentModelName;

// 内部属性
@property (nonatomic, strong) NSURLSession *session;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, StreamingResponseBlock> *taskCallbacks;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableString *> *taskAccumulatedData;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, NSMutableData *> *taskBuffers;
@property (nonatomic, strong) NSMutableSet<NSNumber *> *completedTaskIdentifiers;
```

#### 方法
```objc
// API设置
- (void)setApiKey:(NSString *)apiKey;

// 消息发送
- (NSURLSessionDataTask *)streamingChatCompletionWithMessages:(NSArray *)messages 
                                               streamCallback:(StreamingResponseBlock)callback;
- (void)cancelStreamingTask:(NSURLSessionDataTask *)task;

// NSURLSessionDataDelegate方法
- (void)URLSession:(NSURLSession *)session 
          dataTask:(NSURLSessionDataTask *)dataTask 
didReceiveResponse:(NSURLResponse *)response 
 completionHandler:(void (^)(NSURLSessionResponseDisposition disposition))completionHandler;

- (void)URLSession:(NSURLSession *)session 
          dataTask:(NSURLSessionDataTask *)dataTask 
    didReceiveData:(NSData *)data;

- (void)URLSession:(NSURLSession *)session 
              task:(NSURLSessionTask *)task 
didCompleteWithError:(nullable NSError *)error;

// 内部方法
- (void)cleanupTask:(NSURLSessionTask *)task;
```

### 2. CoreDataManager
管理CoreData数据库操作

#### 属性
```objc
// 单例实例
+ (instancetype)sharedManager;

// CoreData相关
@property (readonly, strong) NSPersistentContainer *persistentContainer;
@property (readonly, strong) NSManagedObjectContext *managedObjectContext;
```

#### 方法
```objc
// 数据库操作
- (void)saveContext;
- (id)createNewChatWithTitle:(NSString *)title;
- (id)addMessageToChat:(id)chat content:(NSString *)content isFromUser:(BOOL)isFromUser;
- (NSArray *)fetchAllChats;
- (NSArray *)fetchMessagesForChat:(id)chat;
- (void)setupDefaultChatsIfNeeded;
```

### 3. ChatDetailViewController
聊天详情界面的控制器

#### 属性
```objc
// 外部设置
@property (nonatomic, strong) id chat;
@property (nonatomic, strong) UILabel *placeholderLabel;
@property (nonatomic, strong) NSLayoutConstraint *inputTextViewHeightConstraint;

// UI组件
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

// API相关
@property (nonatomic, strong) NSURLSessionDataTask *currentStreamingTask;
@property (nonatomic, weak) NSManagedObject *currentUpdatingAIMessage;
```

#### 方法
```objc
// 视图生命周期
- (void)viewDidLoad;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewWillDisappear:(BOOL)animated;

// UI设置
- (void)setupViews;
- (void)setupHeader;
- (void)setupTableView;
- (void)setupInputArea;

// 数据操作
- (void)fetchMessages;

// 消息处理
- (void)sendButtonTapped;
- (void)showThinkingStatus;
- (void)hideThinkingStatus;
- (void)scrollToBottom;
- (void)simulateAIResponse;
- (void)addMessageWithText:(NSString *)text isFromUser:(BOOL)isFromUser;

// 输入处理
- (void)handleInputTextViewTap:(UITapGestureRecognizer *)gesture;
- (BOOL)textViewShouldBeginEditing:(UITextView *)textView;
- (void)updatePlaceholderVisibility;

// 键盘处理
- (void)keyboardWillShow:(NSNotification *)notification;
- (void)keyboardWillHide:(NSNotification *)notification;

// API设置对话框
- (void)showAPIKeyAlert;
- (void)showErrorAlert:(NSString *)message;
- (void)showSuccessAlert:(NSString *)message;
- (void)showNeedAPIKeyAlert;
- (void)resetAPIKey;

// 模型选择
- (void)showModelSelectionMenu:(UIButton *)sender;
- (void)updateModelSelection:(NSString *)modelName button:(UIButton *)button;

// 工具方法
- (BOOL)isTableViewScrolledToBottom;
```

### 4. ChatsViewController
聊天历史列表界面的控制器

#### 属性
```objc
// 委托
@property (nonatomic, weak) id<ChatsViewControllerDelegate> delegate;

// UI组件
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *chatList;
@property (nonatomic, strong) UIButton *addChatButton;
```

#### 方法
```objc
// 视图生命周期
- (void)viewDidLoad;
- (void)viewWillAppear:(BOOL)animated;
- (void)viewWillDisappear:(BOOL)animated;

// UI设置
- (void)setupViews;

// 数据操作
- (void)fetchChats;
- (void)createNewChat;

// 手势处理
- (void)handleLongPress:(UILongPressGestureRecognizer *)gestureRecognizer;
- (void)handleSwipe:(UISwipeGestureRecognizer *)gestureRecognizer;
- (void)deleteChat:(id)sender;
```

### 5. MainViewController
主视图控制器，管理整个应用的导航

#### 属性
```objc
@property (nonatomic, strong) UINavigationController *navigationController;
@property (nonatomic, strong) ChatDetailViewController *chatDetailViewController;
@property (nonatomic, strong) ChatsViewController *chatsViewController;
```

#### 方法
```objc
// 视图生命周期
- (void)viewDidLoad;

// 设置方法
- (void)setupViews;
- (void)setupMenuButton;
- (UIButton *)findMenuButtonInChatDetailView;
- (UIButton *)findButtonWithSystemImageName:(NSString *)imageName inView:(UIView *)view;

// 导航方法
- (void)showChatsList;

// ChatsViewControllerDelegate方法
- (void)didSelectChat:(id)chat;
```

### 6. MessageCell
聊天消息的表格单元格

#### 属性
```objc
@property (nonatomic, strong) UILabel *messageLabel;
@property (nonatomic, strong) UIView *bubbleView;
```

#### 方法
```objc
- (void)configureWithMessage:(NSString *)message isFromUser:(BOOL)isFromUser;
+ (CGFloat)heightForMessage:(NSString *)message width:(CGFloat)width;
```

### 7. ChatCell
聊天历史列表的单元格

#### 属性
```objc
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *dateLabel;
```

#### 方法
```objc
- (void)setTitle:(NSString *)title date:(NSDate *)date;
```

### 8. ThinkingView
显示思考状态的动画视图

#### 属性
```objc
@property (nonatomic, strong) NSArray<UIView *> *dots;
```

#### 方法
```objc
- (void)startAnimating;
- (void)stopAnimating;
- (void)layoutDots;
```

## 数据模型

### Chat实体
- `title`: 聊天标题
- `date`: 创建日期
- `messages`: 关联的消息(一对多)

### Message实体
- `content`: 消息内容
- `date`: 发送日期
- `isFromUser`: 是否用户发送
- `chat`: 所属聊天(多对一)

## 项目文件管理框架

根据MVC架构模式，项目文件应按以下结构进行组织：

```
chatgpttest2/
├── Application/              # 应用程序主要文件
│   ├── AppDelegate.h/m       # 应用程序委托
│   ├── SceneDelegate.h/m     # 场景委托
│   └── main.m                # 主入口文件
│
├── Models/                   # 模型层
│   ├── Managers/             # 管理类
│   │   ├── CoreDataManager.h/m   # 数据库管理
│   │   └── APIManager.h/m    # API通信管理
│   │
│   └── Entities/             # 数据实体
│       └── chatgpttest2.xcdatamodeld  # CoreData模型
│
├── Views/                    # 视图层
│   ├── Cells/                # 表格单元格
│   │   ├── MessageCell.h/m   # 消息单元格
│   │   └── ChatCell.h/m      # 聊天历史单元格
│   │
│   └── Components/           # 自定义UI组件
│       └── ThinkingView.h/m  # 思考状态动画视图
│
├── Controllers/              # 控制器层
│   ├── MainViewController.h/m       # 主视图控制器
│   ├── ChatDetailViewController.h/m # 聊天详情控制器
│   └── ChatsViewController.h/m      # 聊天历史列表控制器
│
├── Resources/                # 资源文件
│   └── Assets.xcassets       # 图像资源
│
└── Supporting Files/         # 支持文件
    ├── Info.plist            # 项目配置
    └── chatgpttest2-Info.plist  # 额外配置
```

### 文件分类说明

1. **Model 文件**:
   - `CoreDataManager.h/m`: 负责CoreData数据库操作的管理类
   - `APIManager.h/m`: 负责与OpenAI API通信的管理类
   - `chatgpttest2.xcdatamodeld`: CoreData数据模型，包含Chat和Message实体

2. **View 文件**:
   - `MessageCell.h/m`: 聊天消息的表格单元格视图
   - `ChatCell.h/m`: 聊天历史列表的单元格视图
   - `ThinkingView.h/m`: 显示AI思考状态的动画视图

3. **Controller 文件**:
   - `MainViewController.h/m`: 应用程序的主视图控制器
   - `ChatDetailViewController.h/m`: 聊天详情界面的控制器
   - `ChatsViewController.h/m`: 聊天历史列表界面的控制器

### 创建文件夹的方法

1. 在Xcode中，右键点击项目导航器中的项目名称，选择"New Group"
2. 按照上述结构创建所有文件夹
3. 将现有文件拖动到相应的文件夹中
4. 确保创建的是"Group with folder"而不仅是"Group"，以便文件结构也反映在文件系统中