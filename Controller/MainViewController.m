#import "MainViewController.h"
#import "ChatsViewController.h"
#import "ChatDetailViewController.h"
#import "CoreDataManager.h"

@interface MainViewController () <ChatsViewControllerDelegate>

@property (nonatomic, strong) UINavigationController *navigationController;
@property (nonatomic, strong) ChatDetailViewController *chatDetailViewController;
@property (nonatomic, strong) ChatsViewController *chatsViewController;

@end

@implementation MainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupViews];
    
    // 初始化CoreData默认数据
    [[CoreDataManager sharedManager] setupDefaultChatsIfNeeded];
    
    // 获取第一个聊天
    NSArray *chatList = [[CoreDataManager sharedManager] fetchAllChats];
    if (chatList.count > 0) {
        [self didSelectChat:chatList[0]];
    }
}

- (void)setupViews {
    self.view.backgroundColor = [UIColor whiteColor];
    
    // 创建聊天详情视图控制器
    self.chatDetailViewController = [[ChatDetailViewController alloc] init];
    
    // 创建导航控制器，以聊天详情为根视图
    self.navigationController = [[UINavigationController alloc] initWithRootViewController:self.chatDetailViewController];
    
    // 隐藏导航栏，因为聊天详情有自己的导航UI
    self.navigationController.navigationBarHidden = YES;
    
    // 禁用导航控制器的交互式弹出手势，因为我们将自己管理滑动手势
    self.navigationController.interactivePopGestureRecognizer.enabled = NO;
    
    // 创建聊天历史视图控制器
    self.chatsViewController = [[ChatsViewController alloc] init];
    self.chatsViewController.delegate = self;
    
    // 添加导航控制器作为子视图控制器
    [self addChildViewController:self.navigationController];
    [self.view addSubview:self.navigationController.view];
    [self.navigationController didMoveToParentViewController:self];
    
    // 设置约束
    self.navigationController.view.translatesAutoresizingMaskIntoConstraints = NO;
    
    [NSLayoutConstraint activateConstraints:@[
        [self.navigationController.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.navigationController.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.navigationController.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.navigationController.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
    
    // 为ChatDetailViewController中的菜单按钮添加动作
    [self setupMenuButton];
}

- (void)setupMenuButton {
    // 查找三横线菜单按钮并设置动作
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIButton *menuButton = [self findMenuButtonInChatDetailView];
        if (menuButton) {
            [menuButton removeTarget:nil action:NULL forControlEvents:UIControlEventTouchUpInside];
            [menuButton addTarget:self action:@selector(showChatsList) forControlEvents:UIControlEventTouchUpInside];
        }
    });
}

- (UIButton *)findMenuButtonInChatDetailView {
    // 递归查找菜单按钮
    return [self findButtonWithSystemImageName:@"line.horizontal.3" inView:self.chatDetailViewController.view];
}

- (UIButton *)findButtonWithSystemImageName:(NSString *)imageName inView:(UIView *)view {
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        UIImage *image = [button imageForState:UIControlStateNormal];
        
        // 简单判断
        if (image && button.imageView && 
            [button.imageView.image.description containsString:imageName]) {
            return button;
        }
    }
    
    for (UIView *subview in view.subviews) {
        UIButton *foundButton = [self findButtonWithSystemImageName:imageName inView:subview];
        if (foundButton) {
            return foundButton;
        }
    }
    
    return nil;
}

- (void)showChatsList {
    // 修改为自定义转场，让ChatsViewController从左侧滑出
    self.chatsViewController.modalPresentationStyle = UIModalPresentationCustom;
    
    // 添加自定义动画
    CATransition *transition = [CATransition animation];
    transition.duration = 0.3;
    transition.type = kCATransitionPush;
    transition.subtype = kCATransitionFromLeft;
    [self.navigationController.view.layer addAnimation:transition forKey:kCATransition];
    
    [self.navigationController pushViewController:self.chatsViewController animated:NO];
}

#pragma mark - ChatsViewControllerDelegate

- (void)didSelectChat:(id)chat {
    self.chatDetailViewController.chat = chat;
    [self.navigationController popToRootViewControllerAnimated:YES];
}

@end 
