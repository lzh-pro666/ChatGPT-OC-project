#import "MainViewController.h"
#import "ChatsViewController.h"
#import "ChatDetailViewController.h"
#import "ChatDetailViewControllerV2.h"
#import "CoreDataManager.h"
#import "ChatDetailMenuDelegate.h"

@interface MainViewController () <ChatsViewControllerDelegate, ChatDetailMenuDelegate>

@property (nonatomic, strong) UINavigationController *navigationController;
@property (nonatomic, strong) ChatDetailViewController *chatDetailViewController;
@property (nonatomic, strong) ChatDetailViewControllerV2 *chatDetailViewControllerV2;
@property (nonatomic, strong) ChatsViewController *chatsViewController;
@property (nonatomic, strong) UIViewController *currentChatController; // 当前使用的聊天控制器

@end

@implementation MainViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // 切换版本：YES=V2版本(Texture)，NO=原版本(SwiftUI)
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
    
    // 构建根导航栏
    self.navigationController = [self buildRootNavigationWith:[self getOrCreateCurrentChatController]];
    
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
    
    // 绑定菜单点击回调
    [self wireMenuDelegateIfPossible];
}

- (void)showChatsList {
    // 让ChatsViewController从左侧滑出
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
    
    // 先记录切换前所使用的控制器版本，再读取对应的当前聊天
    BOOL previousUseV2 = self.useV2Controller;
    
    // 保存当前聊天数据（基于切换前的控制器）
    id currentChat = nil;
    if (previousUseV2 && self.chatDetailViewControllerV2) {
        currentChat = self.chatDetailViewControllerV2.chat;
    } else if (!previousUseV2 && self.chatDetailViewController) {
        currentChat = self.chatDetailViewController.chat;
    }
    
    // 更新为目标版本
    self.useV2Controller = useV2;
    
    // 重新设置视图
    [self.navigationController.view removeFromSuperview];
    [self.navigationController removeFromParentViewController];
    
    // 销毁未使用的控制器，降低内存占用
    if (useV2) {
        self.chatDetailViewController = nil;
    } else {
        self.chatDetailViewControllerV2 = nil;
    }
    
    [self setupViews];
    
    // 恢复聊天数据
    if (currentChat) {
        [self didSelectChat:currentChat];
    }
    
    NSLog(@"[AB测试] 已切换到%@版本", useV2 ? @"V2" : @"原");
}

#pragma mark - Helper (lazy creation & wiring)
// 懒加载对应控制器
- (UIViewController *)getOrCreateCurrentChatController {
    if (self.useV2Controller) {
        if (!self.chatDetailViewControllerV2) {
            self.chatDetailViewControllerV2 = [[ChatDetailViewControllerV2 alloc] init];
        }
        self.chatDetailViewControllerV2.menuDelegate = (id)self;
        self.currentChatController = self.chatDetailViewControllerV2;
    } else {
        if (!self.chatDetailViewController) {
            self.chatDetailViewController = [[ChatDetailViewController alloc] init];
        }
        self.chatDetailViewController.menuDelegate = (id)self;
        self.currentChatController = self.chatDetailViewController;
    }
    return self.currentChatController;
}

// 配置导航栏
- (UINavigationController *)buildRootNavigationWith:(UIViewController *)root {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.navigationBarHidden = YES;
    nav.interactivePopGestureRecognizer.enabled = NO;
    return nav;
}

- (void)wireMenuDelegateIfPossible {
    if ([self.currentChatController respondsToSelector:@selector(setMenuDelegate:)]) {
        [(id)self.currentChatController setMenuDelegate:(id)self];
    }
}

#pragma mark - ChatDetailMenuDelegate

- (void)chatDetailDidTapMenu {
    [self showChatsList];
}

@end
