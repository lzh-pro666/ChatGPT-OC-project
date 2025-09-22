//
//  MessageContentUtils.m
//  ChatGPT-OC-Clone
//

#import "MessageContentUtils.h"

@implementation MessageContentUtils

+ (NSArray<NSURL *> *)parseAttachmentURLsFromContent:(NSString *)content {
    if (![content isKindOfClass:[NSString class]] || content.length == 0) {
        return @[];
    }
    NSRange start = [content rangeOfString:@"[附件链接："];
    if (start.location == NSNotFound) { return @[]; }
    NSRange end = [content rangeOfString:@"]" options:0 range:NSMakeRange(start.location, content.length - start.location)];
    if (end.location == NSNotFound || end.location <= start.location) { return @[]; }
    NSString *block = [content substringWithRange:NSMakeRange(start.location, end.location - start.location)];
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    [block enumerateLinesUsingBlock:^(NSString * _Nonnull line, BOOL * _Nonnull stop) {
        NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if ([trim hasPrefix:@"-"]) {
            NSString *candidate = [[trim substringFromIndex:1] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            NSURL *u = [NSURL URLWithString:candidate];
            if (u && ([u.scheme.lowercaseString isEqualToString:@"http"] || [u.scheme.lowercaseString isEqualToString:@"https"])) {
                [urls addObject:u];
            }
        }
    }];
    return [urls copy];
}

+ (NSString *)displayTextByStrippingAttachmentBlock:(NSString *)content {
    if (![content isKindOfClass:[NSString class]]) { return @""; }
    NSString *text = content ?: @"";
    NSRange marker = [text rangeOfString:@"[附件链接："];
    if (marker.location != NSNotFound) {
        text = [text substringToIndex:marker.location];
    }
    return [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

@end


