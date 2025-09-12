#import "MainViewController.h"
#import "ChatsViewController.h"
#import "ChatDetailViewController.h"
#import "ChatDetailViewControllerV2.h"
#import "CoreDataManager.h"
#import "ChatDetailMenuDelegate.h"

@interface MainViewController () <ChatsViewControllerDelegate, ChatDetailMenuDelegate>

@property (nonatomic, strong) UINavigationController *rootNavigationController;
@property (nonatomic, strong) ChatDetailViewController *chatDetailViewController;

// texture 实现
@property (nonatomic, strong) ChatDetailViewControllerV2 *chatDetailViewControllerV2;

// swiftui 实现
@property (nonatomic, strong) ChatsViewController *chatsViewController; 

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
    self.rootNavigationController = [self buildRootNavigationWith:[self getOrCreateCurrentChatController]];
    
    // 创建聊天历史视图控制器
    self.chatsViewController = [[ChatsViewController alloc] init];
    self.chatsViewController.delegate = self;
    
    // 添加导航控制器作为子视图控制器
    [self addChildViewController:self.rootNavigationController];
    [self.view addSubview:self.rootNavigationController.view];
    [self.rootNavigationController didMoveToParentViewController:self];
    
    // 设置约束
    self.rootNavigationController.view.translatesAutoresizingMaskIntoConstraints = NO;
    
    [NSLayoutConstraint activateConstraints:@[
        [self.rootNavigationController.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.rootNavigationController.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.rootNavigationController.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [self.rootNavigationController.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor]
    ]];
}

- (void)showChatsList {
    // 自定义 push 动画（左侧滑入）
    CATransition *transition = [CATransition animation];
    transition.duration = 0.3;
    transition.type = kCATransitionPush;
    transition.subtype = kCATransitionFromLeft;
    [self.rootNavigationController.view.layer addAnimation:transition forKey:kCATransition];
    
    [self.rootNavigationController pushViewController:self.chatsViewController animated:NO];
}

#pragma mark - ChatsViewControllerDelegate

- (void)didSelectChat:(id)chat {
    // 根据当前使用的控制器版本设置聊天数据
    [self applyChat:chat];
    [self.rootNavigationController popToRootViewControllerAnimated:YES];
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
    id currentChat = previousUseV2 ? self.chatDetailViewControllerV2.chat : self.chatDetailViewController.chat;
    
    // 更新为目标版本
    self.useV2Controller = useV2;
    
    // 重新设置视图容器
    [self.rootNavigationController.view removeFromSuperview];
    [self.rootNavigationController removeFromParentViewController];
    self.rootNavigationController = nil;
    
    // 销毁未使用的控制器，降低内存占用
    if (useV2) {
        self.chatDetailViewController = nil;
    } else {
        self.chatDetailViewControllerV2 = nil;
    }
    
    [self setupViews];
    
    // 恢复聊天数据
    if (currentChat) {
        [self applyChat:currentChat];
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
        return self.chatDetailViewControllerV2;
    } else {
        if (!self.chatDetailViewController) {
            self.chatDetailViewController = [[ChatDetailViewController alloc] init];
        }
        self.chatDetailViewController.menuDelegate = (id)self;
        return self.chatDetailViewController;
    }
}

// 返回当前正在展示的聊天
- (id)currentChat {
    return self.useV2Controller ? self.chatDetailViewControllerV2.chat : self.chatDetailViewController.chat;
}

// 将聊天应用到当前控制器
- (void)applyChat:(id)chat {
    if (self.useV2Controller) {
        if (self.chatDetailViewControllerV2) {
            self.chatDetailViewControllerV2.chat = chat;
        }
    } else {
        if (self.chatDetailViewController) {
            self.chatDetailViewController.chat = chat;
        }
    }
}

// 配置导航栏
- (UINavigationController *)buildRootNavigationWith:(UIViewController *)root {
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:root];
    nav.navigationBarHidden = YES;
    nav.interactivePopGestureRecognizer.enabled = NO;
    return nav;
}

#pragma mark - ChatDetailMenuDelegate

- (void)chatDetailDidTapMenu {
    [self showChatsList];
}

@end
