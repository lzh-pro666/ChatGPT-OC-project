#import "SemanticBlockParser.h"

@interface SemanticBlockParser ()
@property (nonatomic, strong) NSMutableString *pendingBuffer; // uncommitted tail
@property (nonatomic, strong) NSMutableString *seenPrefix;    // already processed prefix of full stream
@property (nonatomic, assign) BOOL insideFencedCode;          // ``` fence state
@property (nonatomic, copy) NSString *activeFenceMarker;      // tracks which fence opened (``` or ~~~)
@end

@implementation SemanticBlockParser

- (instancetype)init {
    self = [super init];
    if (self) {
        _pendingBuffer = [NSMutableString string];
        _seenPrefix = [NSMutableString string];
        _insideFencedCode = NO;
        _activeFenceMarker = nil;
    }
    return self;
}

- (void)reset {
    [self.pendingBuffer setString:@""];
    [self.seenPrefix setString:@""];
    self.insideFencedCode = NO;
    self.activeFenceMarker = nil;
}

#pragma mark - Public

- (NSArray<NSString *> *)consumeFullText:(NSString *)fullText isDone:(BOOL)isDone {
    if (![fullText isKindOfClass:[NSString class]]) { return @[]; }

    // normalize newlines first
    fullText = [[fullText stringByReplacingOccurrencesOfString:@"\r\n" withString:@"\n"]
                stringByReplacingOccurrencesOfString:@"\r" withString:@"\n"];

    // compute longest common prefix
    NSUInteger aLen = fullText.length;
    NSUInteger bLen = self.seenPrefix.length;
    NSUInteger maxPrefix = MIN(aLen, bLen);
    NSUInteger prefixLen = 0;
    while (prefixLen < maxPrefix &&
           [fullText characterAtIndex:prefixLen] == [self.seenPrefix characterAtIndex:prefixLen]) {
        prefixLen++;
    }

    NSString *delta = @"";
    if (prefixLen == bLen) {
        // fullText extends seenPrefix
        delta = (prefixLen < aLen) ? [fullText substringFromIndex:prefixLen] : @"";
    } else if (aLen < bLen) {
        // fullText shorter -> likely truncation/replacement -> reset
        [self reset];
        delta = fullText;
    } else {
        // diverged but have a non-zero common prefix: keep prefix and append remainder
        if (prefixLen == 0) {
            [self reset];
            delta = fullText;
        } else {
            // keep prefix part as seenPrefix then append remainder
            [self.seenPrefix setString:[fullText substringToIndex:prefixLen]];
            delta = [fullText substringFromIndex:prefixLen];
        }
    }

    if (delta.length > 0) {
        [self.pendingBuffer appendString:delta];
        [self.seenPrefix setString:fullText];
    }

    NSMutableArray<NSString *> *completed = [NSMutableArray array];

    while (YES) {
        NSRange consumed = NSMakeRange(NSNotFound, 0);
        NSString *block = [self tryParseOneBlockFromBuffer:self.pendingBuffer consumedRange:&consumed];
        if (block.length > 0 && consumed.location != NSNotFound) {
            // 修复：过滤掉只包含空白字符的块
            NSString *trimmed = [block stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
            if (trimmed.length > 0) {
                [completed addObject:block];
            }
            [self.pendingBuffer deleteCharactersInRange:consumed];
        } else {
            break;
        }
    }

    if (isDone && self.pendingBuffer.length > 0) {
        // Final flush on stream end:
        // - If still inside fenced code, flush the entire pending buffer so downstream Markdown parser can finalize an unclosed fence
        // - Otherwise, flush everything except a lone fence line
        NSString *trimmed = [self.pendingBuffer stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (self.insideFencedCode) {
            if (trimmed.length > 0) {
                [completed addObject:[self.pendingBuffer copy]];
            }
        } else {
            // Not inside code: flush everything that's not a pure fence line
            if (![trimmed isEqualToString:@"```"] && ![trimmed isEqualToString:@"~~~"]) {
                if (trimmed.length > 0) {
                    [completed addObject:[self.pendingBuffer copy]];
                }
            }
        }
        [self.pendingBuffer setString:@""];
        self.insideFencedCode = NO;
        self.activeFenceMarker = nil;
    }

    return completed;
}

#pragma mark - Core parsing

- (NSString *)tryParseOneBlockFromBuffer:(NSMutableString *)buffer consumedRange:(NSRange *)consumedRangeOut {
    if (buffer.length == 0) { return @""; }

    // If currently inside fenced code, look for closing fence matching the active marker on its own line
    if (self.insideFencedCode) {
        // Skip the opening fence at the very beginning if it exists in the buffer
        NSUInteger scanStart = 0;
        NSRange maybeOpen = [self rangeOfOpeningFenceInString:buffer];
        if (maybeOpen.location != NSNotFound) {
            NSUInteger startLine = [self lineStartIndexOfLocation:maybeOpen.location inString:buffer];
            if (startLine == 0) {
                scanStart = NSMaxRange(maybeOpen);
            }
        }
        NSString *marker = self.activeFenceMarker ?: @"```";
        NSRange endRange = [self rangeOfClosingFenceInString:buffer startFrom:scanStart marker:marker];
        if (endRange.location == NSNotFound) {
            return @""; // pending
        }
        // 根据闭合围栏后是否还有非空白字符，决定消费到行尾还是仅消费围栏本身
        NSUInteger afterFence = NSMaxRange(endRange);
        NSUInteger lineEnd = afterFence;
        while (lineEnd < buffer.length && [buffer characterAtIndex:lineEnd] != '\n') { lineEnd++; }
        NSRange tailRange = (afterFence < lineEnd) ? NSMakeRange(afterFence, lineEnd - afterFence) : NSMakeRange(NSNotFound, 0);
        BOOL tailHasContent = NO;
        if (tailRange.location != NSNotFound && tailRange.length > 0) {
            NSString *tail = [buffer substringWithRange:tailRange];
            NSString *tailTrim = [tail stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            tailHasContent = (tailTrim.length > 0);
        }
        NSUInteger consumeEnd = tailHasContent ? afterFence : (lineEnd + ((lineEnd < buffer.length && [buffer characterAtIndex:lineEnd] == '\n') ? 1 : 0));
        if (consumedRangeOut) { *consumedRangeOut = NSMakeRange(0, consumeEnd); }
        // Leaving fenced code state after consuming a full fenced block
        self.insideFencedCode = NO;
        self.activeFenceMarker = nil;
        return [buffer substringWithRange:*consumedRangeOut];
    }

    // Detect a fence start at beginning of buffer or line
    NSRange startFence = [self rangeOfOpeningFenceInString:buffer];
    if (startFence.location != NSNotFound) {
        NSUInteger startLine = [self lineStartIndexOfLocation:startFence.location inString:buffer];
        if (startLine == 0) { // 行首或仅有前导空白
            // Determine fence marker (``` or ~~~) by prefix
            if ([buffer hasPrefix:@"```"]) {
                self.activeFenceMarker = @"```";
            } else if ([buffer hasPrefix:@"~~~"]) {
                self.activeFenceMarker = @"~~~";
            } else {
                self.activeFenceMarker = @"```";
            }
            // Beginning with a fenced block
            NSRange endRange = [self rangeOfClosingFenceInString:buffer startFrom:NSMaxRange(startFence) marker:self.activeFenceMarker];
            if (endRange.location == NSNotFound) {
                self.insideFencedCode = YES;
                return @""; // pending until close
            }
            // 若闭合围栏行在标记后仍有非空白内容，仅消费围栏本身；否则消费至行尾（含换行）
            NSUInteger afterFence = NSMaxRange(endRange);
            NSUInteger lineEnd2 = afterFence;
            while (lineEnd2 < buffer.length && [buffer characterAtIndex:lineEnd2] != '\n') { lineEnd2++; }
            NSRange tailRange2 = (afterFence < lineEnd2) ? NSMakeRange(afterFence, lineEnd2 - afterFence) : NSMakeRange(NSNotFound, 0);
            BOOL tailHasContent2 = NO;
            if (tailRange2.location != NSNotFound && tailRange2.length > 0) {
                NSString *tail = [buffer substringWithRange:tailRange2];
                NSString *tailTrim = [tail stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                tailHasContent2 = (tailTrim.length > 0);
            }
            NSUInteger consumeEnd2 = tailHasContent2 ? afterFence : (lineEnd2 + ((lineEnd2 < buffer.length && [buffer characterAtIndex:lineEnd2] == '\n') ? 1 : 0));
            if (consumedRangeOut) { *consumedRangeOut = NSMakeRange(0, consumeEnd2); }
            return [buffer substringWithRange:*consumedRangeOut];
        }
    }

    // Otherwise, parse by priority: heading, list/quote, paragraph, line
    // 1) Heading ^#{1,6} . Single line - 修复：确保标题完整
    NSRange headingLineRange = [self firstLineRangeIn:buffer];
    if (headingLineRange.length > 0) {
        NSString *firstLine = [buffer substringWithRange:headingLineRange];
        if ([self string:firstLine matchesRegex:@"^#{1,6} "]) {
            // 检查标题是否完整（以换行符结尾）
            if (NSMaxRange(headingLineRange) <= buffer.length) {
                unichar lastChar = [buffer characterAtIndex:NSMaxRange(headingLineRange) - 1];
                if (lastChar == '\n') {
                    // 标题完整，可以输出
                    if (consumedRangeOut) { *consumedRangeOut = headingLineRange; }
                    return firstLine;
                } else {
                    // 标题不完整，等待更多内容
                    return @"";
                }
            }
        }
    }

    // 2) Quote/List: consume consecutive lines matching patterns; stop at first non-matching, blank line, or fence line
    NSRange listOrQuoteRange = [self contiguousListOrQuoteRangeIn:buffer];
    if (listOrQuoteRange.length > 0) {
        // Avoid emitting mid-sentence list/quote fragments during streaming
        BOOL shouldEmit = YES;
        NSUInteger endIndex = NSMaxRange(listOrQuoteRange);
        if (endIndex == buffer.length) {
            // Ends at buffer tail: require newline + sentence-ending punctuation
            BOOL endsWithNewline = NO;
            if (endIndex > 0) {
                unichar lastChar = [buffer characterAtIndex:endIndex - 1];
                endsWithNewline = (lastChar == '\n');
            }
            // find last non-whitespace character within the range
            NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
            NSInteger i = (NSInteger)endIndex - 1;
            while (i >= (NSInteger)listOrQuoteRange.location && [ws characterIsMember:[buffer characterAtIndex:(NSUInteger)i]]) { i--; }
            BOOL sentenceEnd = NO;
            if (i >= (NSInteger)listOrQuoteRange.location) {
                unichar c = [buffer characterAtIndex:(NSUInteger)i];
                sentenceEnd = (c == '.' || c == '!' || c == '?' || c == ':' || c == 0x3002 /*。*/ || c == 0xFF01 /*！*/ || c == 0xFF1F /*？*/ || c == 0xFF1A /*：*/ || c == 0x2026 /*…*/);
            }
            shouldEmit = (endsWithNewline && sentenceEnd);
        }
        if (!shouldEmit) { return @""; }
        if (consumedRangeOut) { *consumedRangeOut = listOrQuoteRange; }
        return [buffer substringWithRange:listOrQuoteRange];
    }

    // 3) Paragraph: up to next blank line or the next fence line, whichever comes first
    NSRange nextFence = [self rangeOfFirstFenceLineAnywhereIn:buffer startFrom:0];
    if (nextFence.location != NSNotFound && nextFence.location > 0) {
        if (consumedRangeOut) { *consumedRangeOut = NSMakeRange(0, nextFence.location); }
        return [buffer substringWithRange:*consumedRangeOut];
    }
    // Improved: paragraph consumes until a blank line, but do not emit partial sentences mid-stream.
    // If no blank line yet, require the last line to be logically complete (ends with punctuation) before emitting.
    NSRange paragraphRange = [buffer rangeOfString:@"\n\n"]; // blank line terminator
    if (paragraphRange.location != NSNotFound) {
        NSRange consume = NSMakeRange(0, paragraphRange.location + paragraphRange.length);
        if (consumedRangeOut) { *consumedRangeOut = consume; }
        return [buffer substringWithRange:consume];
    } else {
        // No blank line yet: check for sentence-ending punctuation at the end of buffer
        unichar lastChar = 0;
        if (buffer.length > 0) { lastChar = [buffer characterAtIndex:buffer.length - 1]; }
        BOOL endsWithNewline = (lastChar == '\n');
        // Determine if the last non-whitespace character is a sentence terminator
        NSCharacterSet *ws = [NSCharacterSet whitespaceAndNewlineCharacterSet];
        NSInteger i = (NSInteger)buffer.length - 1;
        while (i >= 0 && [ws characterIsMember:[buffer characterAtIndex:(NSUInteger)i]]) { i--; }
        BOOL sentenceEnd = NO;
        if (i >= 0) {
            unichar c = [buffer characterAtIndex:(NSUInteger)i];
            // Compare against ASCII and common CJK punctuation by Unicode code points
            sentenceEnd = (c == '.' || c == '!' || c == '?' || c == ':' || c == 0x3002 /*。*/ || c == 0xFF01 /*！*/ || c == 0xFF1F /*？*/ || c == 0xFF1A /*：*/ || c == 0x2026 /*…*/);
        }
        if (endsWithNewline && sentenceEnd) {
            if (consumedRangeOut) { *consumedRangeOut = NSMakeRange(0, (NSUInteger)i + 2); } // include trailing newline if any
            return [buffer substringWithRange:*consumedRangeOut];
        }
    }

    // 4) Fallback: single line if it ends with \n
    NSRange firstLine = [self firstLineRangeIn:buffer];
    if (firstLine.length > 0 && NSMaxRange(firstLine) <= buffer.length) {
        unichar last = [buffer characterAtIndex:NSMaxRange(firstLine) - 1];
        if (last == '\n') {
            // Guard: do NOT emit a lone opening fence line as a block
            NSString *line = [buffer substringWithRange:firstLine];
            NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
            if ([trim hasPrefix:@"```"] || [trim hasPrefix:@"~~~"]) {
                self.insideFencedCode = YES;
                self.activeFenceMarker = [trim hasPrefix:@"~~~"] ? @"~~~" : @"```";
                return @""; // wait for closing fence
            }
            // 修复：避免输出只包含空白字符的行
            if (trim.length > 0) {
                if (consumedRangeOut) { *consumedRangeOut = firstLine; }
                return [buffer substringWithRange:firstLine];
            }
        }
    }

    return @""; // pending
}

#pragma mark - Helpers

- (NSUInteger)lineStartIndexOfLocation:(NSUInteger)loc inString:(NSString *)s {
    if (loc > s.length) loc = s.length;
    NSUInteger lineStart = loc;
    while (lineStart > 0 && [s characterAtIndex:lineStart - 1] != '\n') { lineStart--; }
    return lineStart;
}

- (NSRange)firstLineRangeIn:(NSString *)s {
    NSRange r = [s rangeOfString:@"\n"];
    if (r.location == NSNotFound) {
        return NSMakeRange(0, s.length);
    }
    return NSMakeRange(0, r.location + 1); // include newline
}

- (BOOL)string:(NSString *)s matchesRegex:(NSString *)pattern {
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern options:NSRegularExpressionAnchorsMatchLines error:nil];
    NSRange full = NSMakeRange(0, s.length);
    NSTextCheckingResult *m = [re firstMatchInString:s options:0 range:full];
    return (m != nil && m.range.location != NSNotFound);
}

- (NSRange)contiguousListOrQuoteRangeIn:(NSString *)s {
    __block NSUInteger idx = 0;
    __block BOOL matchedAny = NO;
    __block NSUInteger endOfMatch = 0;
    [s enumerateSubstringsInRange:NSMakeRange(0, s.length)
                           options:NSStringEnumerationByLines
                        usingBlock:^(NSString * _Nullable substring, NSRange substringRange, NSRange enclosingRange, BOOL * _Nonnull stop) {
        if (substring.length == 0) {
            *stop = YES;
            return;
        }
        NSString *trim = [substring stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        // Stop if a fence line begins here
        if ([trim hasPrefix:@"```"] || [trim hasPrefix:@"~~~"]) {
            *stop = YES;
            return;
        }
        // Detect ordered lists like "1. " or "1) " with at least one space/tab after
        BOOL isNumbered = NO;
        if (trim.length > 2) {
            NSCharacterSet *digits = [NSCharacterSet decimalDigitCharacterSet];
            NSUInteger pos = 0;
            while (pos < trim.length && [digits characterIsMember:[trim characterAtIndex:pos]]) { pos++; }
            if (pos > 0 && pos < trim.length) {
                unichar sep = [trim characterAtIndex:pos];
                if (sep == '.' || sep == ')') {
                    if (pos + 1 < trim.length) {
                        unichar sp = [trim characterAtIndex:pos + 1];
                        if (sp == ' ' || sp == '\t') { isNumbered = YES; }
                    }
                }
            }
        }
        BOOL isList = (isNumbered || [trim hasPrefix:@"- "] || [trim hasPrefix:@"* "] || [trim hasPrefix:@"+ "]);
        BOOL isQuote = [trim hasPrefix:@">"];
        if (isList || isQuote) {
            if (!matchedAny) {
                idx = substringRange.location;
                matchedAny = YES;
            }
            endOfMatch = NSMaxRange(substringRange);
        } else if (matchedAny) {
            *stop = YES;
        }
    }];
    if (!matchedAny) { return NSMakeRange(NSNotFound, 0); }
    // Consume until the first blank line after the last matched line, but not beyond a fence
    NSRange fenceAfter = [self rangeOfFirstFenceLineAnywhereIn:s startFrom:endOfMatch];
    NSRange blankAfter = [s rangeOfString:@"\n\n" options:0 range:NSMakeRange(endOfMatch, s.length - endOfMatch)];
    NSUInteger end = s.length;
    if (blankAfter.location != NSNotFound) { end = blankAfter.location + blankAfter.length; }
    if (fenceAfter.location != NSNotFound && fenceAfter.location < end) { end = fenceAfter.location; }
    return NSMakeRange(idx, end - idx);
}

- (NSRange)rangeOfOpeningFenceInString:(NSString *)s {
    // 允许前导空白后的围栏开头（``` 或 ~~~）
    NSRange search = NSMakeRange(0, s.length);
    NSRange best = NSMakeRange(NSNotFound, 0);
    while (search.length > 0) {
        NSRange r1 = [s rangeOfString:@"```" options:0 range:search];
        NSRange r2 = [s rangeOfString:@"~~~" options:0 range:search];
        NSRange r = NSMakeRange(NSNotFound, 0);
        if (r1.location == NSNotFound) {
            r = r2;
        } else if (r2.location == NSNotFound) {
            r = r1;
        } else {
            r = (r1.location < r2.location) ? r1 : r2;
        }
        if (r.location == NSNotFound) { break; }
        // 取该行行首索引
        NSUInteger lineStart = r.location;
        while (lineStart > 0 && [s characterAtIndex:lineStart - 1] != '\n') {
            lineStart--;
        }
        // 行首到标记前是否全是空白
        BOOL onlyWhitespaceBefore = YES;
        for (NSUInteger i = lineStart; i < r.location; i++) {
            unichar c = [s characterAtIndex:i];
            if (c != ' ' && c != '\t') { onlyWhitespaceBefore = NO; break; }
        }
        if (onlyWhitespaceBefore) {
            best = r;
            break;
        }
        NSUInteger nextStart = NSMaxRange(r);
        if (nextStart >= s.length) { break; }
        search = NSMakeRange(nextStart, s.length - nextStart);
    }
    return best;
}

- (NSRange)rangeOfClosingFenceInString:(NSString *)s startFrom:(NSUInteger)start {
    // Backward compatibility: default to ```
    return [self rangeOfClosingFenceInString:s startFrom:start marker:@"```"];
}

- (NSRange)rangeOfClosingFenceInString:(NSString *)s startFrom:(NSUInteger)start marker:(NSString *)marker {
    if (marker.length == 0) { marker = @"```"; }
    if (start >= s.length) { return NSMakeRange(NSNotFound, 0); }
    NSRange search = NSMakeRange(start, s.length - start);
    while (search.length > 0) {
        NSRange r = [s rangeOfString:marker options:0 range:search];
        if (r.location == NSNotFound) { return NSMakeRange(NSNotFound, 0); }
        
        // 计算行首位置
        NSUInteger lineStart = r.location;
        while (lineStart > 0 && [s characterAtIndex:lineStart - 1] != '\n') { lineStart--; }
        
        // 确保从行首到围栏标记前只有空白字符
        BOOL onlyWhitespaceBefore = YES;
        for (NSUInteger i = lineStart; i < r.location; i++) {
            unichar c = [s characterAtIndex:i];
            if (c != ' ' && c != '\t') { onlyWhitespaceBefore = NO; break; }
        }
        if (!onlyWhitespaceBefore) {
            // not a valid fence-at-line-start, continue scanning
            NSUInteger nextStart = NSMaxRange(r);
            if (nextStart >= s.length) return NSMakeRange(NSNotFound, 0);
            search = NSMakeRange(nextStart, s.length - nextStart);
            continue;
        }
        
        // 进一步校验：该行必须只包含围栏标记与可选空白
        NSUInteger lineEnd = r.location;
        while (lineEnd < s.length && [s characterAtIndex:lineEnd] != '\n') {
            lineEnd++;
        }
        NSRange lineRange = NSMakeRange(r.location, lineEnd - r.location);
        NSString *line = [s substringWithRange:lineRange];
        NSString *trim = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if ([trim isEqualToString:marker]) {
            return r;
        }
        // 否则这是例如"```swift"之类的开围栏，继续向后查找真正的闭围栏
        NSUInteger nextStart = NSMaxRange(r);
        if (nextStart >= s.length) { return NSMakeRange(NSNotFound, 0); }
        search = NSMakeRange(nextStart, s.length - nextStart);
    }
    return NSMakeRange(NSNotFound, 0);
}

- (NSRange)rangeOfFirstFenceLineAnywhereIn:(NSString *)s startFrom:(NSUInteger)start {
    if (start >= s.length) { return NSMakeRange(NSNotFound, 0); }
    NSRange search = NSMakeRange(start, s.length - start);
    while (search.length > 0) {
        NSRange r1 = [s rangeOfString:@"```" options:0 range:search];
        NSRange r2 = [s rangeOfString:@"~~~" options:0 range:search];
        NSRange r = NSMakeRange(NSNotFound, 0);
        if (r1.location == NSNotFound) {
            r = r2;
        } else if (r2.location == NSNotFound) {
            r = r1;
        } else {
            r = (r1.location < r2.location) ? r1 : r2;
        }
        if (r.location == NSNotFound) { break; }
        // 行首起点
        NSUInteger lineStart = r.location;
        while (lineStart > 0 && [s characterAtIndex:lineStart - 1] != '\n') {
            lineStart--;
        }
        // lineStart..r.location 仅空格/制表符
        BOOL onlyWhitespaceBefore = YES;
        for (NSUInteger i = lineStart; i < r.location; i++) {
            unichar c = [s characterAtIndex:i];
            if (c != ' ' && c != '\t') { onlyWhitespaceBefore = NO; break; }
        }
        if (onlyWhitespaceBefore) {
            return NSMakeRange(r.location, 3);
        }
        NSUInteger nextStart = NSMaxRange(r);
        if (nextStart >= s.length) { break; }
        search = NSMakeRange(nextStart, s.length - nextStart);
    }
    return NSMakeRange(NSNotFound, 0);
}

@end
