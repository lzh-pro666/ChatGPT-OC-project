#import "MainViewController.h"
#import "ChatsViewController.h"
#import "ChatDetailViewController.h"
#import "ChatDetailViewControllerV2.h"
#import "CoreDataManager.h"

@interface MainViewController () <ChatsViewControllerDelegate>

@property (nonatomic, strong) UINavigationController *navigationController;
@property (nonatomic, strong) ChatDetailViewController *chatDetailViewController;
@property (nonatomic, strong) ChatDetailViewControllerV2 *chatDetailViewControllerV2;
@property (nonatomic, strong) ChatsViewController *chatsViewController;
@property (nonatomic, strong) UIViewController *currentChatController; // 当前使用的聊天控制器

@end

@implementation MainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 初始化AB测试变量，默认使用已迁移到 SwiftUI 的原版本
    // 可以通过修改这个值来切换版本：YES=V2版本(Texture)，NO=原版本(SwiftUI)
    self.useV2Controller = YES;
    
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
    
    // 根据AB测试变量创建对应版本的聊天详情视图控制器
    if (self.useV2Controller) {
        // 使用V2版本
        self.chatDetailViewControllerV2 = [[ChatDetailViewControllerV2 alloc] init];
        self.currentChatController = self.chatDetailViewControllerV2;
        NSLog(@"[AB测试] 使用ChatDetailViewControllerV2");
    } else {
        // 使用原版本
        self.chatDetailViewController = [[ChatDetailViewController alloc] init];
        self.currentChatController = self.chatDetailViewController;
        NSLog(@"[AB测试] 使用ChatDetailViewController");
    }
    
    // 创建导航控制器，以当前聊天详情控制器为根视图
    self.navigationController = [[UINavigationController alloc] initWithRootViewController:self.currentChatController];
    
    // 隐藏导航栏，因为聊天详情有自己的导航UI
    self.navigationController.navigationBarHidden = YES;
    
    // 禁用导航控制器的交互式弹出手势，因为我们将自己管理滑动手势
    self.navigationController.interactivePopGestureRecognizer.enabled = NO;
    
    // 创建聊天历史视图控制器
    self.chatsViewController = [[ChatsViewController alloc] init];
    self.chatsViewController.delegate = self;
    
    // 添� 导航控制器作为子视图控制器
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
    
    // 为ChatDetailViewController中的菜单按钮添� 动作
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
    // 递归查找菜单按钮，在当前使用的控制器中查找
    return [self findButtonWithSystemImageName:@"line.horizontal.3" inView:self.currentChatController.view];
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
    // 修改为自定义�场，让ChatsViewController从左侧滑出
    self.chatsViewController.modalPresentationStyle = UIModalPresentationCustom;
    
    // 添� 自定义动画
    CATransition *transition = [CATransition animation];
    transition.duration = 0.3;
    transition.type = kCATransitionPush;
    transition.subtype = kCATransitionFromLeft;
    [self.navigationController.view.layer addAnimation:transition forKey:kCATransition];
    
    [self.navigationController pushViewController:self.chatsViewController animated:NO];
}

#pragma mark - ChatsViewControllerDelegate

- (void)didSelectChat:(id)chat {
    // 根据当前使用的控制器版本设置聊天数据
    if (self.useV2Controller && self.chatDetailViewControllerV2) {
        self.chatDetailViewControllerV2.chat = chat;
    } else if (!self.useV2Controller && self.chatDetailViewController) {
        self.chatDetailViewController.chat = chat;
    }
    [self.navigationController popToRootViewControllerAnimated:YES];
}

#pragma mark - AB测试方法

- (void)switchToVersion:(BOOL)useV2 {
    if (self.useV2Controller == useV2) {
        NSLog(@"[AB测试] 已经是当前版本，无需切换");
        return;
    }
    
    self.useV2Controller = useV2;
    
    // 保存当前聊天数据
    id currentChat = nil;
    if (self.useV2Controller && self.chatDetailViewController) {
        currentChat = self.chatDetailViewController.chat;
    } else if (!self.useV2Controller && self.chatDetailViewControllerV2) {
        currentChat = self.chatDetailViewControllerV2.chat;
    }
    
    // 重新设置视图
    [self.navigationController.view removeFromSuperview];
    [self.navigationController removeFromParentViewController];
    
    [self setupViews];
    
    // 恢复聊天数据
    if (currentChat) {
        [self didSelectChat:currentChat];
    }
    
    NSLog(@"[AB测试] 已切换到%@版本", useV2 ? @"V2" : @"原");
}

@end
