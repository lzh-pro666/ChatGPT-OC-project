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

@interface AICodeBlockNode () <UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSString *code;
@property (nonatomic, copy) NSString *language;
@property (nonatomic, assign) BOOL isFromUser;
@property (nonatomic, strong) AISyntaxHighlighter *highlighter;
@property (nonatomic, strong) ASDisplayNode *header;
@property (nonatomic, strong) ASTextNode *langNode;
@property (nonatomic, strong) ASButtonNode *duplicateButton;
@property (nonatomic, strong) ASTextNode *codeNode;
@property (nonatomic, strong) ASScrollNode *scrollNode; // 新增：横向滚动容器
// 更新合并与增量应用
@property (nonatomic, assign) BOOL pendingTextApplyScheduled;
@property (nonatomic, strong) NSAttributedString *pendingAttr;   // 待应用文本
@property (nonatomic, assign) BOOL pendingIsAppend;               // 是否为仅追加
@property (nonatomic, strong) NSMutableAttributedString *appliedAttr; // 已应用缓存
@end

@implementation AICodeBlockNode
{
    CGFloat _fixedContentWidth;
    CGFloat _cachedMaxLineWidth;
    BOOL _hasCachedMaxLineWidth;
    CGFloat _cachedHeightForWidth;
    CGFloat _cachedWidthForHeight;
    BOOL _hasCachedHeight;
    BOOL _heightLocked;
    CGFloat _lockedHeight;
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
        _langNode = [ASTextNode new];
        _langNode.attributedText = [[NSAttributedString alloc] initWithString:_language.uppercaseString
            attributes:@{
                NSFontAttributeName: [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold],
                NSForegroundColorAttributeName: [UIColor secondaryLabelColor]
            }];
        
        // 复制按钮
        _duplicateButton = [ASButtonNode new];
        [_duplicateButton setTitle:@"复制" withFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] withColor:[UIColor labelColor] forState:UIControlStateNormal];
        [_duplicateButton addTarget:self action:@selector(onCopy) forControlEvents:ASControlNodeEventTouchUpInside];
        
        // 头部容器
        _header = [ASDisplayNode new];
        _header.backgroundColor = [[UIColor secondarySystemBackgroundColor] colorWithAlphaComponent:0.7];
        
        // 代码文本节点
        _codeNode = [ASTextNode new];
        _codeNode.maximumNumberOfLines = 0;
        _codeNode.truncationMode = NSLineBreakByClipping; // 不换行，超过宽度时裁剪
        _codeNode.style.flexGrow = 0;
        _codeNode.style.flexShrink = 0;
        _codeNode.layerBacked = YES; // 降低 UIView 创建
        
        // 应用语法高亮并强制段落样式为不换行
        NSAttributedString *highlightedCode = [_highlighter highlightCode:_code language:_language fontSize:14];
        NSMutableAttributedString *mutable = nil;
        if (highlightedCode && highlightedCode.length > 0) {
            mutable = [[NSMutableAttributedString alloc] initWithAttributedString:highlightedCode];
        } else {
            NSString *raw = _code ?: @"";
            mutable = [[NSMutableAttributedString alloc] initWithString:raw attributes:@{
                NSFontAttributeName: [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular],
                NSForegroundColorAttributeName: _highlighter.theme.text
            }];
        }
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.lineBreakMode = NSLineBreakByClipping; // 禁止自动换行
        ps.lineSpacing = 2;
        [mutable addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, mutable.length)];
        _codeNode.attributedText = [mutable copy];
        self.appliedAttr = [mutable mutableCopy];
        self.pendingTextApplyScheduled = NO;
        self.pendingAttr = nil;
        self.pendingIsAppend = NO;
        
        // 依据最长行设置内容宽度，启用横向滚动
        [self updateCodeContentWidth];
        
        // 横向滚动容器
        _scrollNode = [[ASScrollNode alloc] init];
        _scrollNode.automaticallyManagesSubnodes = NO;
        _scrollNode.automaticallyManagesContentSize = NO;
        _scrollNode.scrollableDirections = ASScrollDirectionHorizontalDirections;
        _scrollNode.style.flexGrow = 1.0;
        _scrollNode.style.flexShrink = 1.0;
        _scrollNode.view.showsHorizontalScrollIndicator = YES;
        _scrollNode.view.alwaysBounceHorizontal = YES;
        _scrollNode.view.alwaysBounceVertical = NO;
        _scrollNode.view.directionalLockEnabled = YES;
        _scrollNode.view.delaysContentTouches = NO;
        _scrollNode.view.canCancelContentTouches = YES;
        _scrollNode.view.panGestureRecognizer.cancelsTouchesInView = NO;
        // 手动管理子节点，直接将 codeNode 加入 scrollNode 作为内容视图
        [_scrollNode addSubnode:_codeNode];
        
        NSLog(@"AICodeBlockNode: 创建代码块，语言: %@，内容长度: %lu", _language, (unsigned long)_code.length);
    }
    return self;
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
        strongSelf.pendingIsAppend = NO;
        strongSelf->_hasCachedMaxLineWidth = NO;
        strongSelf->_hasCachedHeight = NO;
        [strongSelf updateCodeContentWidthAsync];
        [strongSelf setNeedsLayout];
    });
}

// 在流式渲染完成后执行一次性高亮，减少流中主线程压力
- (void)finalizeHighlighting {
    NSString *codeSnapshot = [self.code copy] ?: @"";
    NSString *langSnapshot = [self.language copy] ?: @"plaintext";
    if (codeSnapshot.length == 0) { return; }
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) { return; }
        NSAttributedString *highlighted = [strongSelf.highlighter highlightCode:codeSnapshot language:langSnapshot fontSize:14];
        if (!highlighted) { return; }
        NSMutableAttributedString *mutable = [[NSMutableAttributedString alloc] initWithAttributedString:highlighted];
        NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
        ps.lineBreakMode = NSLineBreakByClipping;
        ps.lineSpacing = 2;
        [mutable addAttribute:NSParagraphStyleAttributeName value:ps range:NSMakeRange(0, mutable.length)];
        dispatch_async(dispatch_get_main_queue(), ^{
            strongSelf.appliedAttr = mutable;
            strongSelf.codeNode.attributedText = [mutable copy];
            strongSelf->_hasCachedMaxLineWidth = NO;
            strongSelf->_hasCachedHeight = NO;
            [strongSelf updateCodeContentWidthAsync];
            [strongSelf setNeedsLayout];
        });
    });
}

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
        if (strongSelf->_fixedContentWidth > 1.0) {
            computedWidth = ceil(strongSelf->_fixedContentWidth);
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
        }
        if (computedWidth < 1.0) { computedWidth = 1.0; }
        dispatch_async(dispatch_get_main_queue(), ^{
            __strong typeof(weakSelf) strongSelf2 = weakSelf;
            if (!strongSelf2) return;
            strongSelf2->_cachedMaxLineWidth = computedWidth;
            strongSelf2->_hasCachedMaxLineWidth = YES;
            strongSelf2->_hasCachedHeight = NO;
            strongSelf2->_codeNode.style.minWidth = ASDimensionMakeWithPoints(computedWidth);
            strongSelf2->_codeNode.style.maxWidth = ASDimensionMakeWithPoints(computedWidth);
            strongSelf2->_codeNode.style.width = ASDimensionMakeWithPoints(computedWidth);
            [strongSelf2 setNeedsLayout];
        });
    });
}

- (void)onCopy {
    if (_code.length) {
        [UIPasteboard generalPasteboard].string = _code;
        NSLog(@"AICodeBlockNode: 代码已复制到剪贴板");
        
        // 显示复制成功反馈
        [_duplicateButton setTitle:@"已复制" withFont:[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold] withColor:[UIColor systemGreenColor] forState:UIControlStateNormal];
        
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

// 手动设置 scrollNode 的 contentSize，避免横向滚动被重置
- (void)layout {
    [super layout];
    // 若用户正在与代码滚动视图交互，避免在过程中重设 contentSize 造成回弹
    if (self->_scrollNode.view.isDragging || self->_scrollNode.view.isTracking || self->_scrollNode.view.isDecelerating) {
        return;
    }
    // 计算内容宽高
    CGFloat contentWidth = 0.0;
    if (_fixedContentWidth > 1.0) {
        contentWidth = ceil(_fixedContentWidth);
    } else {
        if (!_hasCachedMaxLineWidth) {
            NSAttributedString *attr = self->_codeNode.attributedText ?: [[NSAttributedString alloc] initWithString:@""];
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
        contentWidth = _cachedMaxLineWidth;
    }
    if (contentWidth < 1.0) { contentWidth = self->_scrollNode.view.bounds.size.width; }
    // 高度：使用文本测量高度或当前可见高度，确保不为0
    CGFloat contentHeight = 0.0;
    NSAttributedString *attrText = self->_codeNode.attributedText ?: [[NSAttributedString alloc] initWithString:@""];
    if (attrText.length > 0 && contentWidth > 0.0) {
        if (_hasCachedHeight && fabs(_cachedWidthForHeight - contentWidth) < 0.5) {
            contentHeight = _cachedHeightForWidth;
        } else {
            CGSize bound = [attrText boundingRectWithSize:CGSizeMake(contentWidth, CGFLOAT_MAX)
                                                 options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                 context:nil].size;
            contentHeight = ceil(bound.height);
            _cachedHeightForWidth = contentHeight;
            _cachedWidthForHeight = contentWidth;
            _hasCachedHeight = YES;
        }
    }
    if (contentHeight < 1.0) { contentHeight = MAX(1.0, self->_scrollNode.view.bounds.size.height); }
    // 设置 codeNode 的 frame 以匹配内容尺寸（高度仅允许单调递增，避免果冻回弹）
    CGRect codeFrame = self->_codeNode.frame;
    codeFrame.origin = CGPointZero;
    CGSize desired = CGSizeMake(contentWidth, contentHeight);
    CGSize current = self->_codeNode.frame.size;
    CGSize applied = CGSizeMake(desired.width, MAX(current.height, desired.height));
    if (!CGSizeEqualToSize(current, applied)) {
        self->_codeNode.frame = (CGRect){CGPointZero, applied};
    }
    // 设置内容尺寸（高度同样单调递增）
    CGSize target = CGSizeMake(desired.width, MAX(self->_scrollNode.view.contentSize.height, desired.height));
    if (!CGSizeEqualToSize(self->_scrollNode.view.contentSize, target)) {
        self->_scrollNode.view.contentSize = target;
    }
}

- (void)setFixedContentWidth:(CGFloat)width {
    _fixedContentWidth = MAX(0, width);
    _hasCachedMaxLineWidth = NO;
    _hasCachedHeight = NO;
    [self updateCodeContentWidth];
}

- (ASLayoutSpec *)layoutSpecThatFits:(ASSizeRange)constrainedSize {
    // 头部行：语言标签 + 复制按钮
    ASStackLayoutSpec *headerRow = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionHorizontal
                                                                           spacing:8
                                                                    justifyContent:ASStackLayoutJustifyContentSpaceBetween
                                                                        alignItems:ASStackLayoutAlignItemsCenter
                                                                          children:@[_langNode, _duplicateButton]];
    headerRow.style.height = ASDimensionMake(32);
    
    // 头部容器
    ASInsetLayoutSpec *headerInset = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(4, 12, 4, 12) child:headerRow];
    
    // 计算代码内容高度，为滚动容器提供最小高度，避免在垂直栈中被压缩为0
    CGFloat measuredContentWidth = 0.0;
    if (_fixedContentWidth > 1.0) {
        measuredContentWidth = ceil(_fixedContentWidth);
    } else {
        if (!_hasCachedMaxLineWidth) {
            NSAttributedString *attr = self->_codeNode.attributedText ?: [[NSAttributedString alloc] initWithString:@""];
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
        measuredContentWidth = _cachedMaxLineWidth;
    }
    CGFloat measuredContentHeight = 0.0;
    NSAttributedString *attrText = self->_codeNode.attributedText ?: [[NSAttributedString alloc] initWithString:@""];
    if (attrText.length > 0 && measuredContentWidth > 0.0) {
        if (_hasCachedHeight && fabs(_cachedWidthForHeight - measuredContentWidth) < 0.5) {
            measuredContentHeight = _cachedHeightForWidth;
        } else {
            CGSize bound = [attrText boundingRectWithSize:CGSizeMake(measuredContentWidth, CGFLOAT_MAX)
                                                 options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading
                                                 context:nil].size;
            measuredContentHeight = ceil(bound.height);
            _cachedHeightForWidth = measuredContentHeight;
            _cachedWidthForHeight = measuredContentWidth;
            _hasCachedHeight = YES;
        }
    }
    // 至少给一个很小的高度，避免完全折叠
    CGFloat containerHeight = measuredContentHeight;
    if (_heightLocked && _lockedHeight > 1.0) {
        containerHeight = _lockedHeight;
    }
    self->_scrollNode.style.minHeight = ASDimensionMakeWithPoints(MAX(1.0, containerHeight));
    self->_scrollNode.style.height = ASDimensionMakeWithPoints(MAX(1.0, containerHeight));
    
    // 代码内容容器（横向滚动）
    ASInsetLayoutSpec *scrollInset = [ASInsetLayoutSpec insetLayoutSpecWithInsets:UIEdgeInsetsMake(8, 12, 8, 12) child:_scrollNode];
    
    // 垂直堆叠：头部 + 代码
    ASStackLayoutSpec *verticalStack = [ASStackLayoutSpec stackLayoutSpecWithDirection:ASStackLayoutDirectionVertical
                                                                               spacing:0
                                                                        justifyContent:ASStackLayoutJustifyContentStart
                                                                            alignItems:ASStackLayoutAlignItemsStretch
                                                                              children:@[headerInset, scrollInset]];
    
    return verticalStack;
}

- (void)didLoad {
    [super didLoad];
    // 配置滚动视图手势，优先横向，允许与外层表同时识别
    self->_scrollNode.view.showsHorizontalScrollIndicator = YES;
    self->_scrollNode.view.showsVerticalScrollIndicator = NO;
    self->_scrollNode.view.bounces = YES;
    self->_scrollNode.view.alwaysBounceHorizontal = YES;
    self->_scrollNode.view.alwaysBounceVertical = NO;
    self->_scrollNode.view.directionalLockEnabled = YES;
    self->_scrollNode.view.scrollsToTop = NO;
    self->_scrollNode.view.scrollEnabled = YES;
    self->_scrollNode.view.indicatorStyle = UIScrollViewIndicatorStyleDefault;
    if (@available(iOS 11.0, *)) {
        self->_scrollNode.view.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    if (self->_scrollNode.view.panGestureRecognizer) {
        // 监听代码块横向滚动手势，传播到控制器以暂停自动粘底/布局
        [self->_scrollNode.view.panGestureRecognizer addTarget:self action:@selector(_onCodeScrollPan:)];
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
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self->_scrollNode.view flashScrollIndicators];
    });
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
    // 清理高度缓存，立即应用锁定高度
    _hasCachedHeight = NO;
    [self setNeedsLayout];
}

- (void)unlockContentHeight {
    // 解锁后不强制回退高度，保留当前可见高度作为下限，避免果冻
    _heightLocked = NO;
    _lockedHeight = 0.0;
    // 不清空已测高度，等待内容自然增长
    [self setNeedsLayout];
}

@end




