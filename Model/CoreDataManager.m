#import "CoreDataManager.h"
@import CoreData;

@implementation CoreDataManager

+ (instancetype)sharedManager {
    static CoreDataManager *sharedManager = nil;
    // 用于确保某个代� �块在程序的整个生命周期中只执行一�，保证代� �块在多线程环境下只执行一�，即使多个线程同时调用，保证线程安全。
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedManager = [[self alloc] init];
    });
    return sharedManager;
}


#pragma mark - Core Data � �� �

@synthesize persistentContainer = _persistentContainer;

- (NSPersistentContainer *)persistentContainer {
    // 懒� 载模式，只有在�一�访问时才初始化
    if (_persistentContainer != nil) {
        return _persistentContainer;
    }
    
    _persistentContainer = [[NSPersistentContainer alloc] initWithName:@"chatgpttest2"];
    // 调用 loadPersistentStoresWithCompletionHandler � 载持久化存储
    [_persistentContainer loadPersistentStoresWithCompletionHandler:^(NSPersistentStoreDescription *storeDescription, NSError *error) {
        if (error != nil) {
            NSLog(@"Unresolved error %@, %@", error, error.userInfo);
            abort();
        }
    }];
    return _persistentContainer;
}

// 主线程的托管对象上下文，用于大多数数据操作。
- (NSManagedObjectContext *)managedObjectContext {
    return self.persistentContainer.viewContext;
}

#pragma mark - Core Data 保存支持

- (void)saveContext {
    NSManagedObjectContext *context = self.managedObjectContext;
    NSError *error = nil;
    if ([context hasChanges] && ![context save:&error]) {
        NSLog(@"Unresolved error %@, %@", error, error.userInfo);
        abort();
    }
}

#pragma mark - Chat Operations

- (id)createNewChatWithTitle:(NSString *)title {
    NSManagedObject *chat = [NSEntityDescription insertNewObjectForEntityForName:@"Chat"
                                              inManagedObjectContext:self.managedObjectContext];
    [chat setValue:title forKey:@"title"];
    [chat setValue:[NSDate date] forKey:@"date"];
    [self saveContext];
    return chat;
}

- (id)addMessageToChat:(id)chat content:(NSString *)content isFromUser:(BOOL)isFromUser {
    NSManagedObject *message = [NSEntityDescription insertNewObjectForEntityForName:@"Message"
                                                   inManagedObjectContext:self.managedObjectContext];
    [message setValue:content forKey:@"content"];
    [message setValue:[NSDate date] forKey:@"date"];
    [message setValue:@(isFromUser) forKey:@"isFromUser"];
    [message setValue:chat forKey:@"chat"];
    [self saveContext];
    return message;
}

- (NSArray *)fetchAllChats {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Chat"];
    NSSortDescriptor *sortByDate = [NSSortDescriptor sortDescriptorWithKey:@"date" ascending:NO];
    // 将包含 sortByDate 的数组赋值给 request.sortDescriptors，告诉 NSFetchRequest 在执行查询时按照 sortByDate 定义的规则对结果排序。
    request.sortDescriptors = @[sortByDate];
    
    NSError *error = nil;
    NSArray *results = [self.managedObjectContext executeFetchRequest:request error:&error];
    if (error) {
        NSLog(@"Error fetching chats: %@", error);
        return @[];
    }
    
    return results;
}

- (NSArray *)fetchMessagesForChat:(id)chat {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Message"];
    // 这行代� �的作用是创建一个谓词（Predicate），用于过滤 Core Data 查询结果，限制只返回与指定 Chat 对象关联的 Message 实体。
    NSPredicate *predicate = [NSPredicate predicateWithFormat:@"chat == %@", chat];
    NSSortDescriptor *sortByDate = [NSSortDescriptor sortDescriptorWithKey:@"date" ascending:YES];
    
    request.predicate = predicate;
    request.sortDescriptors = @[sortByDate];
    
    NSError *error = nil;
    NSArray *results = [self.managedObjectContext executeFetchRequest:request error:&error];
    if (error) {
        NSLog(@"Error fetching messages: %@", error);
        return @[];
    }
    
    return results;
}

- (void)setupDefaultChatsIfNeeded {
    NSFetchRequest *request = [NSFetchRequest fetchRequestWithEntityName:@"Chat"];
    NSError *error = nil;
    NSInteger count = [self.managedObjectContext countForFetchRequest:request error:&error];
    
    if (count == 0) {
        // 创建示例聊天
        id chat1 = [self createNewChatWithTitle:@"iOS应用界面设计讨论"];

        // 为�一个聊天添� 消息示例
        [self addMessageToChat:chat1 content:@"您好！我是ChatGPT，一个AI助手。我可以帮助您解答问题，请问有什么我可以帮您的吗？" isFromUser:NO];
        [self addMessageToChat:chat1 content:@"� 能帮我解释一下iOS的导航模式吗？" isFromUser:YES];
        [self addMessageToChat:chat1 content:@"iOS有� 种主要的导航模式：\n\n1. 层级导航（Hierarchical）\n- 使用UINavigationController\n- 适合展示层级内容\n- 支持返回手势\n\n2. 平铺导航（Flat）\n- 使用UITabBarController\n- 适合同级内容切换\n- 底部� �签� �导航\n\n3. 模态导航（Modal）\n- 临时打断当前任务\n- 完整的上下文切换\n- 支持多种展示方式" isFromUser:NO];
        
        NSLog(@"已创建初始聊天数据");
    }
}

@end 
