#import "ChatsViewController.h"
#import "ChatCell.h"
#import "CoreDataManager.h"
#import "ChatDetailViewController.h"
#import "AlertHelper.h"
@import CoreData;

@interface ChatsViewController () <UITableViewDelegate, UITableViewDataSource>

@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *chatList;
@property (nonatomic, strong) UIButton *addChatButton;

@end

@implementation ChatsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupViews];
    [self fetchChats];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self fetchChats];
    [self.tableView reloadData];
}

- (void)setupViews {
    self.view.backgroundColor = [UIColor whiteColor];
    
    // 头部视图
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 80)];
    
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    titleLabel.text = @"聊天";
    titleLabel.textColor = [UIColor blackColor];
    titleLabel.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [headerView addSubview:titleLabel];
    
    // 新建聊天按钮
    self.addChatButton = [UIButton buttonWithType:UIButtonTypeSystem];
    [self.addChatButton setTitle:@"  新建" forState:UIControlStateNormal];
    [self.addChatButton setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
    self.addChatButton.backgroundColor = [UIColor colorWithRed:240/255.0 green:240/255.0 blue:240/255.0 alpha:1.0]; // 浅灰色背景
    self.addChatButton.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    self.addChatButton.layer.cornerRadius = 16;
    [self.addChatButton addTarget:self action:@selector(createNewChat) forControlEvents:UIControlEventTouchUpInside];
    
    // 添加“+”图标
    UIImageView *plusIcon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"plus"]];
    plusIcon.tintColor = [UIColor blackColor];
    plusIcon.contentMode = UIViewContentModeScaleAspectFit;
    plusIcon.translatesAutoresizingMaskIntoConstraints = NO;
    [self.addChatButton addSubview:plusIcon];
    
    self.addChatButton.translatesAutoresizingMaskIntoConstraints = NO;
    [headerView addSubview:self.addChatButton];
    
    // 设置约束
    [NSLayoutConstraint activateConstraints:@[
        [titleLabel.leadingAnchor constraintEqualToAnchor:headerView.leadingAnchor constant:20],
        [titleLabel.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor],
        [self.addChatButton.trailingAnchor constraintEqualToAnchor:headerView.trailingAnchor constant:-20],
        [self.addChatButton.centerYAnchor constraintEqualToAnchor:headerView.centerYAnchor],
        [self.addChatButton.widthAnchor constraintEqualToConstant:90],
        [self.addChatButton.heightAnchor constraintEqualToConstant:40],
        
        [plusIcon.leadingAnchor constraintEqualToAnchor:self.addChatButton.leadingAnchor constant:12],
        [plusIcon.centerYAnchor constraintEqualToAnchor:self.addChatButton.centerYAnchor],
        [plusIcon.widthAnchor constraintEqualToConstant:16],
        [plusIcon.heightAnchor constraintEqualToConstant:16]
    ]];
    
    // 列表视图
    self.tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tableView.separatorInset = UIEdgeInsetsMake(0, 16, 0, 16);
    self.tableView.backgroundColor = [UIColor whiteColor];
    self.tableView.separatorColor = [UIColor colorWithRed:229/255.0 green:229/255.0 blue:229/255.0 alpha:1.0]; // #e5e5e5
    self.tableView.tableHeaderView = headerView;
    [self.tableView registerClass:[ChatCell class] forCellReuseIdentifier:@"ChatCell"];
    self.tableView.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.tableView];
    
    // 添加长按手势
    UILongPressGestureRecognizer *longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
    longPress.minimumPressDuration = 0.5; // 设置长按时间为0.5秒
    [self.tableView addGestureRecognizer:longPress];
    
    // 添加左滑返回手势
    UISwipeGestureRecognizer *swipeGesture = [[UISwipeGestureRecognizer alloc] initWithTarget:self action:@selector(handleSwipe:)];
    swipeGesture.direction = UISwipeGestureRecognizerDirectionLeft;
    [self.view addGestureRecognizer:swipeGesture];
    
    [NSLayoutConstraint activateConstraints:@[
        [self.tableView.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.tableView.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.tableView.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.tableView.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)fetchChats {
    self.chatList = [[CoreDataManager sharedManager] fetchAllChats];
}

- (void)createNewChat {
    id newChat = [[CoreDataManager sharedManager] createNewChatWithTitle:@"新的聊天"];
    [self fetchChats];
    [self.tableView reloadData];
    
    if (self.delegate) {
        [self.delegate didSelectChat:newChat];
    }
}

#pragma mark - UITableViewDataSource

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.chatList.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    ChatCell *cell = [tableView dequeueReusableCellWithIdentifier:@"ChatCell" forIndexPath:indexPath];
    
    NSManagedObject *chat = self.chatList[indexPath.row];
    NSString *title = [chat valueForKey:@"title"];
    NSDate *date = [chat valueForKey:@"date"];
    [cell setTitle:title date:date];
    
    return cell;
}

#pragma mark - UITableViewDelegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    NSManagedObject *selectedChat = self.chatList[indexPath.row];
    
    if (self.delegate) {
        [self.delegate didSelectChat:selectedChat];
    }
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    return 70;
}

#pragma mark - 手势处理

- (void)handleLongPress:(UILongPressGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.state == UIGestureRecognizerStateBegan) {
        CGPoint point = [gestureRecognizer locationInView:self.tableView];
        NSIndexPath *indexPath = [self.tableView indexPathForRowAtPoint:point];
        
        if (indexPath) {
            // 选中行，便于后续删除操作确定目标
            [self.tableView selectRowAtIndexPath:indexPath animated:NO scrollPosition:UITableViewScrollPositionNone];
            
            // 使用 AlertHelper 显示聊天操作菜单
            NSArray *actions = @[
                @{@"重命名": ^{
                    [self renameChatAtIndexPath:indexPath];
                }},
                @{@"删除": ^{
                    [self deleteChat:nil];
                }}
            ];
            [AlertHelper showActionMenuOn:self title:nil actions:actions cancelTitle:@"取消"];
        }
    }
}

- (void)handleSwipe:(UISwipeGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer.direction == UISwipeGestureRecognizerDirectionLeft) {
        // 模拟返回
        [self.navigationController popViewControllerAnimated:YES];
    }
}

// 删除聊天
- (void)deleteChat:(id)sender {
    NSIndexPath *indexPath = [self.tableView indexPathForSelectedRow];
    if (indexPath) {
        NSManagedObject *chatToDelete = self.chatList[indexPath.row];
        
        // 使用 AlertHelper 显示确认删除对话框
        [AlertHelper showConfirmationAlertOn:self
                                   withTitle:@"确认删除"
                                     message:@"确定要删除这个聊天吗？此操作不可撤销。"
                                confirmTitle:@"删除"
                         confirmationHandler:^{
            // 删除聊天
            [[CoreDataManager sharedManager].managedObjectContext deleteObject:chatToDelete];
            [[CoreDataManager sharedManager] saveContext];
            
            // 刷新数据
            [self fetchChats];
            
            // 更新UI
            [self.tableView reloadData];
            
            // 如果删除后没有聊天，自动创建一个新聊天
            if (self.chatList.count == 0) {
                [self createNewChat];
            }
        }];
    }
}

// 重命名聊天
- (void)renameChatAtIndexPath:(NSIndexPath *)indexPath {
    if (!indexPath || indexPath.row >= self.chatList.count) { return; }
    NSManagedObject *chat = self.chatList[indexPath.row];
    NSString *currentTitle = [chat valueForKey:@"title"] ?: @"";
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"重命名聊天"
                                                                   message:@"请输入新的标题"
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addTextFieldWithConfigurationHandler:^(UITextField * _Nonnull textField) {
        textField.text = currentTitle;
        textField.placeholder = @"聊天标题";
        textField.clearButtonMode = UITextFieldViewModeWhileEditing;
        textField.returnKeyType = UIReturnKeyDone;
    }];
    
    [alert addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction * _Nonnull action) {
        __strong typeof(weakSelf) self = weakSelf;
        NSString *newTitle = [[alert.textFields.firstObject.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]] copy];
        if (newTitle.length == 0) {
            [AlertHelper showAlertOn:self withTitle:@"无效标题" message:@"标题不能为空。" buttonTitle:@"确定"];
            return;
        }
        [chat setValue:newTitle forKey:@"title"];
        [[CoreDataManager sharedManager] saveContext];
        
        // 仅刷新该行，避免整表刷新带来的打断
        [self.tableView reloadRowsAtIndexPaths:@[indexPath] withRowAnimation:UITableViewRowAnimationAutomatic];
    }]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    
    // 如果有动画，为返回添加动画
    if ([self.navigationController.viewControllers indexOfObject:self] == NSNotFound) {
        CATransition *transition = [CATransition animation];
        transition.duration = 0.3;
        transition.type = kCATransitionPush;
        transition.subtype = kCATransitionFromRight;
        [self.navigationController.view.layer addAnimation:transition forKey:kCATransition];
    }
}

@end
