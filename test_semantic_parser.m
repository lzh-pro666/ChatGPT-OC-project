#import <Foundation/Foundation.h>
#import "Parser/SemanticBlockParser.h"

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        SemanticBlockParser *parser = [[SemanticBlockParser alloc] init];
        
        // 测试案例1：正常的代码块
        NSLog(@"=== 测试案例1：正常代码块 ===");
        NSArray *result1 = [parser consumeFullText:@"```swift\nlet x = 1\n```\n### 5.函数" isDone:NO];
        NSLog(@"结果1: %@", result1);
        
        // 测试案例2：有前导空格的围栏
        NSLog(@"\n=== 测试案例2：前导空格围栏 ===");
        [parser reset];
        NSArray *result2 = [parser consumeFullText:@"   ```swift\nlet y = 2\n   ```\n### 标题" isDone:NO];
        NSLog(@"结果2: %@", result2);
        
        // 测试案例3：围栏后紧跟标题
        NSLog(@"\n=== 测试案例3：围栏后紧跟标题 ===");
        [parser reset];
        NSArray *result3 = [parser consumeFullText:@"```swift\nlet z = 3\n```### 5.函数" isDone:NO];
        NSLog(@"结果3: %@", result3);
        
        // 测试案例4：流式输入
        NSLog(@"\n=== 测试案例4：流式输入 ===");
        [parser reset];
        NSArray *result4a = [parser consumeFullText:@"```swift\nlet a = 1" isDone:NO];
        NSLog(@"流式结果4a: %@", result4a);
        NSArray *result4b = [parser consumeFullText:@"```swift\nlet a = 1\nlet b = 2" isDone:NO];
        NSLog(@"流式结果4b: %@", result4b);
        NSArray *result4c = [parser consumeFullText:@"```swift\nlet a = 1\nlet b = 2\n```\n### 5.函数" isDone:NO];
        NSLog(@"流式结果4c: %@", result4c);
    }
    return 0;
}
