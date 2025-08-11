#import <Foundation/Foundation.h>
#import <CoreData/CoreData.h>

@class Chat;
@class Message;

NS_ASSUME_NONNULL_BEGIN

@interface CoreDataManager : NSObject

/**
 * 应用程序的 Core Data 持久化容器。
 */
@property (readonly, strong) NSPersistentContainer *persistentContainer;

/**
 * 用于 Core Data 操作的主托管对象上下文。
 */
@property (readonly, strong) NSManagedObjectContext *managedObjectContext;

/**
 * 将托管对象上下文中的更改保存到持久化存储。
 */
- (void)saveContext;

/**
 * 创建一个具有指定� �题的新 Chat 实体。
 * @param title 新聊天的� �题。
 * @return 新创建的 Chat 对象。
 */
- (Chat *)createNewChatWithTitle:(NSString *)title;

/**
 * 为指定聊天添� 一个新 Message 实体。
 * @param chat 消息所属的 Chat 对象。
 * @param content 消息的文�内容。
 * @param isFromUser 布尔值，指示消息是否来自用户（YES）或 AI（NO）。
 * @return 新创建的 Message 对象。
 */
- (Message *)addMessageToChat:(Chat *)chat content:(NSString *)content isFromUser:(BOOL)isFromUser;

/**
 * 获取所有 Chat 实体，按日期降序排序。
 * @return Chat 对象的数组，如果发生错误则返回空数组。
 */
- (NSArray *)fetchAllChats;

/**
 * 获取指定聊天的所有 Message 实体，按日期升序排序。
 * @param chat 需要获取消息的 Chat 对象。
 * @return Message 对象的数组，如果发生错误则返回空数组。
 */
- (NSArray *)fetchMessagesForChat:(Chat *)chat;

/**
 * 如果数据库中没有聊天数据，则创建默认聊天数据。
 * @note 添� 一个示例聊天和消息以展示功能。
 */
- (void)setupDefaultChatsIfNeeded;

/**
 * 返回 CoreDataManager 的单例实例。
 */
+ (instancetype)sharedManager;

@end

NS_ASSUME_NONNULL_END 
