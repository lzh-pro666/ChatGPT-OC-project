//
//  AICodeBlockNode.m
//  ChatGPT-OC-Clone
//
//  Created by AI Assistant
//

#import "AICodeBlockNode.h"
#import "AISyntaxHighlighter.h"
#import <AsyncDisplayKit/ASButtonNode.h>
#import <AsyncDisplayKit/ASScrollNode.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <AsyncDisplayKit/ASTextNode2.h>

@interface AICodeBlockNode () <UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSString *code;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, assign) BOOL isFromUser;
@property (nonatomic, strong) AISyntaxHighlighter *highlighter;
@property (nonatomic, strong) ASTextNode2 *langNode;
@property (nonatomic, strong) ASButtonNode *duplicateButton;
@property (nonatomic, strong) ASTextNode2 *codeNode;
@property (nonatomic, strong) ASScrollNode *scrollNode; // 横向滚动容器（按需创建）
// 流式渲染：逐行节点与状态
@property (nonatomic, assign) BOOL isStreaming;
@property (nonatomic, strong) NSMutableArray<ASTextNode2 *> *lineNodes;
@property (nonatomic, strong) NSMutableString *streamAccumulatedPlain;
@property (nonatomic, assign) NSTimeInterval codeLineRevealDuration;
// 帧级合并：布局与动画
@property (nonatomic, assign) BOOL layoutCoalesceScheduled;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *pendingRevealTasks; // { node: ASDisplayNode, completion: block }
@property (nonatomic, assign) BOOL revealBatchScheduled;
@property (nonatomic, assign) NSInteger runningRevealAnimations;
@property (nonatomic, assign) BOOL pendingFinalizeAfterReveal;
// Header 尺寸缓存，避免重复参与测量（保留标签与复制按钮尺寸）
@property (nonatomic, assign) BOOL headerSizePrepared;
@property (nonatomic, assign) CGSize langPreferredSize;
@property (nonatomic, assign) CGSize duplicatePreferredSize;
// 更新合并与增量应用
@property (nonatomic, assign) BOOL pendingTextApplyScheduled;
@property (nonatomic, strong) NSAttributedString *pendingAttr;   // 待应用文本
@property (nonatomic, assign) BOOL pendingIsAppend;               // 是否为仅追加
@property (nonatomic, strong) NSMutableAttributedString *appliedAttr; // 已应用缓存
@property (nonatomic) dispatch_queue_t lineHighlightQueue; // 逐行高亮串行队列
@end

@implementation AICodeBlockNode
{
    CGFloat _fixedContentWidth;
    CGFloat _cachedMaxLineWidth;
    BOOL _hasCachedMaxLineWidth;
    // 移除未使用的高度缓存字段
    BOOL _heightLocked;
    CGFloat _lockedHeight;
    // 记录最近一次应用到 scrollNode 的内容高度，避免重复样式写入
    CGFloat _appliedScrollHeight;
}

// 非流式初始化时：若已有完整代码，立即生成高亮并准备内容宽度
- (void)applyInitialCodeIfAny {
    NSString *full = [self.streamAccumulatedPlain copy] ?: @"";
    if (full.length == 0) { return; }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf; if (!strongSelf) return;
        NSAttributedString *highlighted = [strongSelf.highlighter highlightCode:full language:strongSelf.language fontSize:14];
        NSMutableAttributedString *mutable = highlighted ? [[NSMutableAttributedString alloc] initWithAttributedString:highlighted] : [[NSMutableAttributedString alloc] initWithString:full attributes:@{ NSFontAttributeName: [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular], NSForegroundColorAttributeName: strongSelf.highlighter.theme.text }];
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init]; ps.lineBreakMode = NSLineBreakByClipping; ps.lineSpacing = 2; [mutable addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, mutable.length)];
        // 计算最长行
        CGFloat maxLineWidth = 0.0; UIFont *mono = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
        for (NSString *ln in [full componentsSeparatedByString:@"\n"]) {
            if (ln.length == 0) continue;
            CGSize s = [ln boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                       options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                    attributes:@{ NSFontAttributeName: mono }
                                       context:nil].size;
            if (s.width > maxLineWidth) maxLineWidth = s.width;
        }
        CGFloat contentWidth = (strongSelf->_fixedContentWidth > 1.0) ? ceil(strongSelf->_fixedContentWidth) : ((maxLineWidth > 0.0) ? (ceil(maxLineWidth) + 4.0) : 1.0);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self2 = weakSelf; if (!self2) return;
            self2.code = full;
            self2.appliedAttr = [mutable mutableCopy];
            self2.codeNode.attributedText = [mutable copy];
            self2->_cachedMaxLineWidth = contentWidth; self2->_hasCachedMaxLineWidth = YES;
            self2->_codeNode.style.minWidth = ASDimensionMakeWithPoints(contentWidth);
            self2->_codeNode.style.maxWidth = ASDimensionMakeWithPoints(contentWidth);
            self2->_codeNode.style.width = ASDimensionMakeWithPoints(contentWidth);
            [self2 ensureScrollContainerExists];
            [self2 setNeedsLayout];
        });
    });
}

- (instancetype)initWithCode:(NSString *)code 
                    language:(NSString *)lang 
                  isFromUser:(BOOL)isFromUser {
    if (self = [super init]) {
        _code = [code copy];
        _language = lang.length ? lang : @"plaintext";
        _isFromUser = isFromUser;
        _highlighter = [[AISyntaxHighlighter alloc] initWithTheme:[AICodeTheme defaultTheme]];
        
        self.automaticallyManagesSubnodes = YES;
        self.backgroundColor = _highlighter.theme.bg;
        self.cornerRadius = 12.0;
        self.clipsToBounds = YES;
        self.borderColor = _highlighter.theme.border.CGColor;
        self.borderWidth = 0.5;
        
        // 关键：让代码块在父容器中拉伸占满宽度
        self.style.flexGrow = 1;
        self.style.flexShrink = 1;
        
        // 语言标签
        _langNode = [ASTextNode2 new];
        _langNode.attributedText = [[NSAttributedString alloc] initWithString:_language.uppercaseString
            attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold],
                NSForegroundColorAttributeName: [UIColor secondaryLabelColor]
            }];
        
        // 复制按钮
        _duplicateButton = [ASButtonNode new];
        [_duplicateButton setTitle:@"复制" withFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] withColor:[UIColor labelColor] forState:UIControlStateNormal];
        [_duplicateButton addTarget:self action:@selector(onCopy) forControlEvents:ASControlNodeEventTouchUpInside];
        
        // 移除未使用的 header 容器
        
        // 代码文本节点
        _codeNode = [ASTextNode2 new];
        _codeNode.maximumNumberOfLines = 0;
        _codeNode.truncationMode = NSLineBreakByClipping; // 不换行，超过宽度时裁剪
        _codeNode.style.flexGrow = 0;
        _codeNode.style.flexShrink = 0;
        _codeNode.layerBacked = YES; // 降低 UIView 创建
        
        // 初始化流式相关状态（构造时不立即创建滚动容器，待 finalize）
        self.appliedAttr = nil;
        self.pendingTextApplyScheduled = NO;
        self.pendingAttr = nil;
        self.pendingIsAppend = NO;
        self.isStreaming = NO;
        self.lineNodes = [NSMutableArray array];
        self.streamAccumulatedPlain = [NSMutableString string];
        self.codeLineRevealDuration = 0.5;
        self.headerSizePrepared = NO;
        self.layoutCoalesceScheduled = NO;
        self.pendingRevealTasks = [NSMutableArray array];
        self.revealBatchScheduled = NO;
        if (_code.length > 0) { [self.streamAccumulatedPlain setString:_code]; }
        // 非流式创建且已有完整代码时，立即应用一次完整高亮与宽度计算
        if (_code.length > 0) {
            [self applyInitialCodeIfAny];
        }
        _lineHighlightQueue = dispatch_queue_create("com.chat.codeLine.highlight", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (void)requestCoalescedLayout {
    if (self.layoutCoalesceScheduled) { return; }
    self.layoutCoalesceScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf; if (!strongSelf) return;
        strongSelf.layoutCoalesceScheduled = NO;
        [strongSelf setNeedsLayout];
    });
}

- (void)_scheduleRevealBatchIfNeeded {
    if (self.revealBatchScheduled) { return; }
    self.revealBatchScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf; if (!strongSelf) return;
        strongSelf.revealBatchScheduled = NO;
        NSArray<NSDictionary *> *tasks = [strongSelf.pendingRevealTasks copy];
        [strongSelf.pendingRevealTasks removeAllObjects];
        for (NSDictionary *t in tasks) {
            ASDisplayNode *node = t[@"node"]; dispatch_block_t completion = t[@"completion"]; if ((NSNull *)completion == (NSNull *)[NSNull null]) completion = nil;
            [strongSelf _applyLeftToRightRevealMaskOnNode:node duration:strongSelf.codeLineRevealDuration tries:4 completion:completion];
        }
    });
}


// 新增：增量更新代码文本（追加优先）
- (void)updateCodeText:(NSString *)code {
    if (!code) { code = @""; }
    if ([_code isEqualToString:code]) { return; }
    BOOL isAppend = (_code.length > 0 && code.length > _code.length && [code hasPrefix:_code]);
    NSString *suffix = @"";
    if (isAppend) { suffix = [code substringFromIndex:_code.length]; }
    _code = [code copy];

    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (isAppend && suffix.length > 0 && strongSelf.appliedAttr.length > 0) {
            // 只高亮追加部分
            NSAttributedString *highlightedSuffix = [strongSelf.highlighter highlightCode:suffix language:strongSelf->_language fontSize:14];
            NSMutableAttributedString *mutable = nil;
            if (highlightedSuffix && highlightedSuffix.length > 0) {
                mutable = [[NSMutableAttributedString alloc] initWithAttributedString:highlightedSuffix];
            } else {
                mutable = [[NSMutableAttributedString alloc] initWithString:suffix attributes:@{
                    NSFontAttributeName: [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular],
                    NSForegroundColorAttributeName: strongSelf.highlighter.theme.text
                }];
            }
            NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
            ps.lineBreakMode = NSLineBreakByClipping;
            ps.lineSpacing = 2;
            [mutable addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, mutable.length)];
            strongSelf.pendingAttr = [mutable copy];
            strongSelf.pendingIsAppend = YES;

            // 增量更新最长行宽，避免全量重新扫描
            // 仅计算新增行的最大宽度，与已有缓存取 max
            CGFloat incrementMax = 0.0;
            UIFont *mono = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
            NSArray<NSString *> *suffixLines = [suffix componentsSeparatedByString:@"\n"];
            for (NSString *line in suffixLines) {
                if (line.length == 0) { continue; }
                CGSize s = [line boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                              options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                           attributes:@{ NSFontAttributeName: mono }
                                              context:nil].size;
                if (s.width > incrementMax) { incrementMax = s.width; }
            }
            if (incrementMax > 0.0) {
                CGFloat candidate = ceil(incrementMax) + 4.0;
                if (strongSelf->_hasCachedMaxLineWidth) {
                    if (candidate > strongSelf->_cachedMaxLineWidth) {
                        strongSelf->_cachedMaxLineWidth = candidate;
                    }
                } else {
                    strongSelf->_cachedMaxLineWidth = candidate;
                    strongSelf->_hasCachedMaxLineWidth = YES;
                }
            }
        } else {
            // 全量重建
            NSAttributedString *highlighted = [strongSelf.highlighter highlightCode:strongSelf->_code language:strongSelf->_language fontSize:14];
            NSMutableAttributedString *mutable = nil;
            if (highlighted && highlighted.length > 0) {
                mutable = [[NSMutableAttributedString alloc] initWithAttributedString:highlighted];
            } else {
                NSString *raw = strongSelf->_code ?: @"";
                mutable = [[NSMutableAttributedString alloc] initWithString:raw attributes:@{
                    NSFontAttributeName: [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular],
                    NSForegroundColorAttributeName: strongSelf.highlighter.theme.text
                }];
            }
            NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
            ps.lineBreakMode = NSLineBreakByClipping;
            ps.lineSpacing = 2;
            [mutable addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, mutable.length)];
            strongSelf.pendingAttr = [mutable copy];
            strongSelf.pendingIsAppend = NO;
        }
        [strongSelf coalescedApplyPendingText];
    });
}

// MARK: - 流式逐行 API

- (void)appendCodeLine:(NSString *)line isFirst:(BOOL)isFirst completion:(void (^ _Nullable)(void))completion {
    if (!line) { if (completion) completion(); return; }
    __weak typeof(self) weakSelf = self;
    dispatch_async(self.lineHighlightQueue, ^{
        __strong typeof(weakSelf) strongSelfBG = weakSelf; if (!strongSelfBG) { if (completion) completion(); return; }
        NSAttributedString *hl = [strongSelfBG.highlighter highlightCode:line language:strongSelfBG.language fontSize:14] ?: [[NSAttributedString alloc] initWithString:line];
        NSMutableAttributedString *mutable = [[NSMutableAttributedString alloc] initWithAttributedString:hl];
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.lineBreakMode = NSLineBreakByClipping; ps.lineSpacing = 2;
        [mutable addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, mutable.length)];
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf; if (!strongSelf) { if (completion) completion(); return; }
            if (isFirst && !strongSelf.isStreaming) {
                strongSelf.isStreaming = YES;
                [strongSelf.lineNodes removeAllObjects];
                [strongSelf.streamAccumulatedPlain setString:@""];
            }
            ASTextNode2 *lineNode = [[ASTextNode2 alloc] init];
            lineNode.layerBacked = YES;
            lineNode.maximumNumberOfLines = 1;
            lineNode.truncationMode = NSLineBreakByClipping;
            lineNode.attributedText = [mutable copy];
            lineNode.style.flexGrow = 1.0;
            lineNode.style.flexShrink = 1.0;
            {
                CGSize s = lineNode.bounds.size;
                if (s.width < 1.0 || s.height < 1.0) { s = CGSizeMake(4096, 1024); }
                CALayer *preMask = [CALayer layer];
                preMask.backgroundColor = [UIColor blackColor].CGColor;
                preMask.anchorPoint = CGPointMake(0.0, 0.5);
                preMask.bounds = CGRectMake(0, 0, s.width, s.height);
                preMask.position = CGPointMake(0, s.height * 0.5);
                preMask.transform = CATransform3DMakeScale(0.0, 1.0, 1.0);
                lineNode.layer.mask = preMask;
            }
            [strongSelf.lineNodes addObject:lineNode];
            if (strongSelf.streamAccumulatedPlain.length > 0) { [strongSelf.streamAccumulatedPlain appendString:@"\n"]; }
            [strongSelf.streamAccumulatedPlain appendString:(line ?: @"")];
            [strongSelf requestCoalescedLayout];
            strongSelf.runningRevealAnimations += 1;
            dispatch_block_t userCompletion = completion ? [completion copy] : nil;
            dispatch_block_t internal = ^{
                __strong typeof(weakSelf) self3 = weakSelf; if (!self3) return;
                self3.runningRevealAnimations = MAX(0, self3.runningRevealAnimations - 1);
                if (self3.pendingFinalizeAfterReveal && self3.runningRevealAnimations == 0) {
                    self3.pendingFinalizeAfterReveal = NO;
                    [self3 finalizeStreaming];
                }
            };
            dispatch_block_t chained = ^{
                if (userCompletion) userCompletion();
                internal();
            };
            [strongSelf.pendingRevealTasks addObject:@{ @"node": lineNode, @"completion": chained }];
            [strongSelf _scheduleRevealBatchIfNeeded];
        });
    });
}

- (void)finalizeStreaming {
    if (!self.isStreaming) { return; }
    // 若仍有进行中的 reveal，挂起 finalize，待全部完成后再切换 scrollNode，避免丢最后一行
    if (self.runningRevealAnimations > 0) {
        self.pendingFinalizeAfterReveal = YES;
        return;
    }
    NSString *full = [self.streamAccumulatedPlain copy] ?: @"";
    if (full.length == 0) { self.isStreaming = NO; [self requestCoalescedLayout]; return; }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf; if (!strongSelf) return;
        NSAttributedString *highlighted = [strongSelf.highlighter highlightCode:full language:strongSelf.language fontSize:14];
        NSMutableAttributedString *mutable = highlighted ? [[NSMutableAttributedString alloc] initWithAttributedString:highlighted] : [[NSMutableAttributedString alloc] initWithString:full attributes:@{ NSFontAttributeName: [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular], NSForegroundColorAttributeName: strongSelf.highlighter.theme.text }];
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.lineBreakMode = NSLineBreakByClipping; ps.lineSpacing = 2;
        [mutable addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, mutable.length)];
        // 计算最长行
        CGFloat maxLineWidth = 0.0; UIFont *mono = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
        for (NSString *ln in [full componentsSeparatedByString:@"\n"]) {
            if (ln.length == 0) continue;
            CGSize s = [ln boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                       options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                    attributes:@{ NSFontAttributeName: mono }
                                       context:nil].size;
            if (s.width > maxLineWidth) maxLineWidth = s.width;
        }
        CGFloat contentWidth = (strongSelf->_fixedContentWidth > 1.0) ? ceil(strongSelf->_fixedContentWidth) : ((maxLineWidth > 0.0) ? (ceil(maxLineWidth) + 4.0) : 1.0);
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) self2 = weakSelf; if (!self2) return;
            self2.code = full;
            self2.appliedAttr = [mutable mutableCopy];
            self2.codeNode.attributedText = [mutable copy];
            self2->_cachedMaxLineWidth = contentWidth; self2->_hasCachedMaxLineWidth = YES;
            self2->_codeNode.style.minWidth = ASDimensionMakeWithPoints(contentWidth);
            self2->_codeNode.style.maxWidth = ASDimensionMakeWithPoints(contentWidth);
            self2->_codeNode.style.width = ASDimensionMakeWithPoints(contentWidth);
            [self2 ensureScrollContainerExists];
            // 计算高度并设置容器高度，避免折叠
            CGSize bound = [[self2.appliedAttr copy] boundingRectWithSize:CGSizeMake(contentWidth, CGFLOAT_MAX)
                                                                  options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                                  context:nil].size;
            CGFloat contentHeight = ceil(bound.height);
            if (contentHeight < 1.0) { contentHeight = 1.0; }
            self2.scrollNode.style.minHeight = ASDimensionMakeWithPoints(contentHeight);
            self2.scrollNode.style.height = ASDimensionMakeWithPoints(contentHeight);
            [self2.lineNodes removeAllObjects];
            self2.isStreaming = NO;
            [self2 setNeedsLayout];
        });
    });
}

- (void)setCodeLineRevealDuration:(NSTimeInterval)duration { _codeLineRevealDuration = MAX(0.01, duration); }

// 合并应用待更新文本（节流到主线程下一帧）
- (void)coalescedApplyPendingText {
    if (self.pendingTextApplyScheduled) { return; }
    self.pendingTextApplyScheduled = YES;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }
        strongSelf.pendingTextApplyScheduled = NO;
        if (!strongSelf.pendingAttr) { return; }
        if (strongSelf.pendingIsAppend && strongSelf.appliedAttr.length > 0) {
            [strongSelf.appliedAttr appendAttributedString:strongSelf.pendingAttr];
            strongSelf.codeNode.attributedText = [strongSelf.appliedAttr copy];
        } else {
            strongSelf.appliedAttr = [strongSelf.pendingAttr mutableCopy];
            strongSelf.codeNode.attributedText = strongSelf.pendingAttr;
        }
        strongSelf.pendingAttr = nil;
        // 若为追加且宽度未增长，则不清空宽度缓存，避免重复全量扫描
        if (!strongSelf.pendingIsAppend) {
            strongSelf->_hasCachedMaxLineWidth = NO;
        }
        strongSelf.pendingIsAppend = NO;
        // 移除未使用的高度缓存
        // 按需创建滚动容器，仅在非流式阶段
        [strongSelf ensureScrollContainerExists];
        [strongSelf updateCodeContentWidthAsync];
        [strongSelf setNeedsLayout];
    });
}

// 移除未使用的 finalizeHighlighting（由流式或初始化路径负责完整高亮）

// 新增：异步计算代码内容宽度并在主线程应用
- (void)updateCodeContentWidthAsync {
    __weak typeof(self) weakSelf = self;
    NSAttributedString *attr = self->_codeNode.attributedText ?: [[NSAttributedString alloc] initWithString:@""];
    if (attr.length == 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            strongSelf->_codeNode.style.preferredSize = CGSizeZero;
            [strongSelf setNeedsLayout];
        });
        return;
    }
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        CGFloat computedWidth = 0.0;
        CGFloat computedHeight = 0.0;
        if (strongSelf->_fixedContentWidth > 1.0) {
            computedWidth = ceil(strongSelf->_fixedContentWidth);
        } else if (strongSelf->_hasCachedMaxLineWidth && strongSelf->_cachedMaxLineWidth > 0.0) {
            computedWidth = ceil(strongSelf->_cachedMaxLineWidth);
        } else {
            CGFloat maxLineWidth = 0.0;
            UIFont *font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
            for (NSString *line in [attr.string componentsSeparatedByString:@"\n"]) {
                if (line.length == 0) { continue; }
                CGSize s = [line boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                              options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                           attributes:@{ NSFontAttributeName: font }
                                              context:nil].size;
                if (s.width > maxLineWidth) { maxLineWidth = s.width; }
            }
            computedWidth = (maxLineWidth > 0.0) ? (ceil(maxLineWidth) + 4.0) : 1.0;
            strongSelf->_cachedMaxLineWidth = computedWidth;
            strongSelf->_hasCachedMaxLineWidth = YES;
        }
        if (computedWidth < 1.0) { computedWidth = 1.0; }
        // 后台测高度
        if (attr.length > 0) {
            CGSize bound = [attr boundingRectWithSize:CGSizeMake(computedWidth, CGFLOAT_MAX)
                                              options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                              context:nil].size;
            computedHeight = ceil(bound.height);
            if (computedHeight < 1.0) { computedHeight = 1.0; }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;
            strongSelf2->_cachedMaxLineWidth = computedWidth;
            strongSelf2->_hasCachedMaxLineWidth = YES;
            strongSelf2->_codeNode.style.minWidth = ASDimensionMakeWithPoints(computedWidth);
            strongSelf2->_codeNode.style.maxWidth = ASDimensionMakeWithPoints(computedWidth);
            strongSelf2->_codeNode.style.width = ASDimensionMakeWithPoints(computedWidth);
            // 同步更新滚动容器高度，避免出现只有边框无内容的情况
            if (!strongSelf2.isStreaming) {
                [strongSelf2 ensureScrollContainerExists];
                if (computedHeight > 1.0) {
                    // 仅在增大时更新，避免频繁样式写入
                    CGFloat newH = computedHeight;
                    if (newH > strongSelf2->_appliedScrollHeight + 0.5) {
                        strongSelf2->_appliedScrollHeight = newH;
                        strongSelf2.scrollNode.style.minHeight = ASDimensionMakeWithPoints(newH);
                        strongSelf2.scrollNode.style.height = ASDimensionMakeWithPoints(newH);
                    }
                }
            }
            [strongSelf2 requestCoalescedLayout];
        });
    });
}

- (void)onCopy {
    if (_code.length) {
        [UIPasteboard generalPasteboard].string = _code;
        // removed debug log
        
        // 显示复制成功反馈
        [_duplicateButton setTitle:@"已复制" withFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] withColor:[UIColor systemBlueColor] forState:UIControlStateNormal];
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self->_duplicateButton setTitle:@"复制" withFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] withColor:[UIColor labelColor] forState:UIControlStateNormal];
        });
    }
}

// 新增：根据最长行宽度更新代码内容宽度，确保可横向滚动
- (void)updateCodeContentWidth {
    NSAttributedString *attr = self->_codeNode.attributedText ?: [[NSAttributedString alloc] initWithString:@""];
    if (attr.length == 0) {
        self->_codeNode.style.preferredSize = CGSizeZero;
        return;
    }
    CGFloat w = 0.0;
    if (_fixedContentWidth > 1.0) {
        w = ceil(_fixedContentWidth);
    } else {
        if (!_hasCachedMaxLineWidth) {
            CGFloat maxLineWidth = 0.0;
            UIFont *font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
            for (NSString *line in [attr.string componentsSeparatedByString:@"\n"]) {
                if (line.length == 0) { continue; }
                CGSize s = [line boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                              options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                           attributes:@{ NSFontAttributeName: font }
                                              context:nil].size;
                if (s.width > maxLineWidth) { maxLineWidth = s.width; }
            }
            _cachedMaxLineWidth = (maxLineWidth > 0.0) ? (ceil(maxLineWidth) + 4.0) : 0.0;
            _hasCachedMaxLineWidth = YES;
        }
        w = _cachedMaxLineWidth;
    }
    if (w < 1.0) { w = 1.0; }
    self->_codeNode.style.minWidth = ASDimensionMakeWithPoints(w);
    self->_codeNode.style.maxWidth = ASDimensionMakeWithPoints(w);
    self->_codeNode.style.width = ASDimensionMakeWithPoints(w);
    [self setNeedsLayout];
}

// 不再覆写 layout，交给 Texture 自动内容尺寸与布局

- (void)setFixedContentWidth:(CGFloat)width {
    _fixedContentWidth = MAX(0, width);
    _hasCachedMaxLineWidth = NO;
    // 移除未使用的高度缓存
    if (!self.isStreaming) {
        [self ensureScrollContainerExists];
        [self updateCodeContentWidthAsync];
    }
}

- (ASLayoutSpec *)layoutSpecThatFits:(ASSizeRange)constrainedSize {
    [self prepareHeaderPreferredSizesIfNeeded];
    ASStackLayoutSpec *headerRow = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionHorizontal
                                                                           spacing:8
                                                                    justifyContent:ASStackLayoutJustifyContentSpaceBetween
                                                                        alignItems:ASStackLayoutAlignItemsCenter
                                                                          children:@[_langNode, _duplicateButton]];
    headerRow.style.height = ASDimensionMake(32);
    ASInsetLayoutSpec *headerInset = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(4, 12, 4, 12) child:headerRow];

    ASLayoutSpec *contentSpec = nil;
    if (self.isStreaming) {
        NSArray<ASDisplayNode *> *children = self.lineNodes.count > 0 ? self.lineNodes : @[];
        ASStackLayoutSpec *linesStack = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionVertical
                                                                                spacing:2
                                                                         justifyContent:ASStackLayoutJustifyContentStart
                                                                             alignItems:ASStackLayoutAlignItemsStretch
                                                                               children:children];
        contentSpec = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(8, 12, 8, 12) child:linesStack];
    } else {
        if (!self.scrollNode) {
            // 尚未创建，临时使用 codeNode 直接显示
            ASInsetLayoutSpec *inner = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(8, 12, 8, 12) child:self.codeNode];
            contentSpec = inner;
        } else {
            if (_heightLocked && _lockedHeight > 1.0) {
                self.scrollNode.style.minHeight = ASDimensionMakeWithPoints(_lockedHeight);
                self.scrollNode.style.height = ASDimensionMakeWithPoints(_lockedHeight);
            }
            contentSpec = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(8, 12, 8, 12) child:self.scrollNode];
        }
    }

    ASStackLayoutSpec *verticalStack = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionVertical
                                                                               spacing:0
                                                                        justifyContent:ASStackLayoutJustifyContentStart
                                                                            alignItems:ASStackLayoutAlignItemsStretch
                                                                              children:@[headerInset, contentSpec]];
    return verticalStack;
}

- (void)didLoad {
    [super didLoad];
    if (self.scrollNode) {
        self.scrollNode.view.showsHorizontalScrollIndicator = YES;
        self.scrollNode.view.showsVerticalScrollIndicator = NO;
        self.scrollNode.view.bounces = YES;
        self.scrollNode.view.alwaysBounceHorizontal = YES;
        self.scrollNode.view.alwaysBounceVertical = NO;
        self.scrollNode.view.directionalLockEnabled = YES;
        self.scrollNode.view.scrollsToTop = NO;
        self.scrollNode.view.scrollEnabled = YES;
        self.scrollNode.view.indicatorStyle = UIScrollViewIndicatorStyleDefault;
        if (@available(iOS 11.0, *)) {
            self.scrollNode.view.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        }
        if (self.scrollNode.view.panGestureRecognizer) {
            [self.scrollNode.view.panGestureRecognizer addTarget:self action:@selector(_onCodeScrollPan:)];
        }
    }
}

#pragma mark - Header 预计算尺寸与滚动容器

- (void)prepareHeaderPreferredSizesIfNeeded {
    if (self.headerSizePrepared) return;
    NSString *lang = self.language.length ? self.language.uppercaseString : @"PLAINTEXT";
    UIFont *lf = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
    CGSize lsz = [lang boundingRectWithSize:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)
                                    options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                 attributes:@{ NSFontAttributeName: lf }
                                    context:nil].size;
    self.langPreferredSize = CGSizeMake(ceil(lsz.width), ceil(MAX(16.0, lsz.height)));
    self.duplicatePreferredSize = CGSizeMake(44.0, 24.0);
    self.langNode.style.preferredSize = self.langPreferredSize;
    self.duplicateButton.style.preferredSize = self.duplicatePreferredSize;
    self.headerSizePrepared = YES;
}

- (void)ensureScrollContainerExists {
    if (!self.scrollNode) {
        self.scrollNode = [[ASScrollNode alloc] init];
    }
    self.scrollNode.automaticallyManagesSubnodes = YES;
    self.scrollNode.automaticallyManagesContentSize = YES;
    self.scrollNode.scrollableDirections = ASScrollDirectionHorizontalDirections;
    self.scrollNode.style.flexGrow = 1.0;
    self.scrollNode.style.flexShrink = 1.0;
    self.scrollNode.view.showsHorizontalScrollIndicator = YES;
    self.scrollNode.view.alwaysBounceHorizontal = YES;
    self.scrollNode.view.alwaysBounceVertical = NO;
    self.scrollNode.view.directionalLockEnabled = YES;
    self.scrollNode.view.delaysContentTouches = NO;
    self.scrollNode.view.canCancelContentTouches = YES;
    self.scrollNode.view.panGestureRecognizer.cancelsTouchesInView = NO;
    __weak typeof(self) weakSelf = self;
    self.scrollNode.layoutSpecBlock = ^ASLayoutSpec * _Nonnull(__kindof ASDisplayNode * _Nonnull node, ASSizeRange constrainedSize) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return [ASLayoutSpec new]; }
        return [ASWrapperLayoutSpec wrapperWithLayoutElement:strongSelf.codeNode];
    };
    if (self.isNodeLoaded && self.scrollNode.view.panGestureRecognizer) {
        [self.scrollNode.view.panGestureRecognizer addTarget:self action:@selector(_onCodeScrollPan:)];
    }
}

// 新增：手势回调，广播开始/结束交互
- (void)_onCodeScrollPan:(UIPanGestureRecognizer *)pan {
    UIGestureRecognizerState st = pan.state;
    if (st == UIGestureRecognizerStateBegan) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"CodeBlockPanBegan" object:self];
    } else if (st == UIGestureRecognizerStateEnded || st == UIGestureRecognizerStateCancelled || st == UIGestureRecognizerStateFailed) {
        [[NSNotificationCenter defaultCenter] postNotificationName:@"CodeBlockPanEnded" object:self];
    }
}

- (void)didEnterVisibleState {
    [super didEnterVisibleState];
    if (self.scrollNode) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self.scrollNode.view flashScrollIndicators];
        });
    }
}

#pragma mark - UIGestureRecognizerDelegate

- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gestureRecognizer {
    if (gestureRecognizer == self->_scrollNode.view.panGestureRecognizer && [gestureRecognizer isKindOfClass:[UIPanGestureRecognizer class]]) {
        UIPanGestureRecognizer *pan = (UIPanGestureRecognizer *)gestureRecognizer;
        CGPoint velocity = [pan velocityInView:self->_scrollNode.view];
        return fabs(velocity.x) >= fabs(velocity.y);
    }
    return YES;
}

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)gestureRecognizer shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)otherGestureRecognizer {
    return YES;
}

- (void)lockContentHeight:(CGFloat)height {
    _heightLocked = YES;
    _lockedHeight = MAX(1.0, height);
    [self setNeedsLayout];
}

- (void)unlockContentHeight {
    // 解锁后不强制回退高度，保留当前可见高度作为下限，避免果冻
    _heightLocked = NO;
    _lockedHeight = 0.0;
    // 不清空已测高度，等待内容自然增长
    [self setNeedsLayout];
}

// MARK: - 文本行蒙版渐显（左到右）

- (void)_applyLeftToRightRevealMaskOnNode:(ASDisplayNode *)node
                                  duration:(NSTimeInterval)duration
                                      tries:(NSInteger)tries
                                 completion:(dispatch_block_t)completion {
    if (!node) { if (completion) completion(); return; }
    CALayer *targetLayer = node.layer;
    if (!targetLayer) { if (completion) completion(); return; }
    CGSize size = node.bounds.size;
    if ((size.width < 1.0 || size.height < 1.0) && tries > 0) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.016 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) { if (completion) completion(); return; }
            [strongSelf _applyLeftToRightRevealMaskOnNode:node duration:duration tries:(tries - 1) completion:completion];
        });
        return;
    }
    if (size.width < 1.0 || size.height < 1.0) {
        if (completion) completion();
        return;
    }
    CALayer *maskLayer = [CALayer layer];
    maskLayer.backgroundColor = [UIColor blackColor].CGColor;
    maskLayer.anchorPoint = CGPointMake(0.0, 0.5);
    maskLayer.bounds = CGRectMake(0, 0, size.width, size.height);
    maskLayer.position = CGPointMake(0, size.height * 0.5);
    maskLayer.transform = CATransform3DMakeScale(0.0, 1.0, 1.0);
    targetLayer.mask = maskLayer;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    [CATransaction setCompletionBlock:^{
        maskLayer.transform = CATransform3DIdentity;
        targetLayer.mask = nil;
        if (completion) completion();
    }];
    CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"transform.scale.x"];
    anim.fromValue = @(0.0);
    anim.toValue = @(1.0);
    anim.duration = MAX(0.01, duration);
    anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
    [maskLayer addAnimation:anim forKey:@"revealX"];
    maskLayer.transform = CATransform3DIdentity;
    [CATransaction commit];
}

@end





