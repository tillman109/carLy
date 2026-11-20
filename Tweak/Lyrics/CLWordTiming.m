#import "Lyrics/CLWordTiming.h"
#import <math.h>

/// A line shown for up to this long is assumed to be sung across nearly all of it.
static const NSTimeInterval kCLEstimateShortGap = 6.0;
/// Share of a short gap the words fill; the rest is the breath before the next line.
static const double kCLEstimateFillRatio = 0.92;
/// Singing speed used to size the sung part of a long gap (an instrumental break follows it).
static const double kCLEstimateSecondsPerCharacter = 0.08;
static const NSTimeInterval kCLEstimateMinimumSung = 1.0;
/// Used when the line is the last one and nothing says how long it lasts.
static const NSTimeInterval kCLEstimateFinalLineDuration = 5.0;

NSArray<CLLyricWord *> *CLEstimatedWords(NSString *text, NSTimeInterval start, NSTimeInterval available) {
    if (![text isKindOfClass:[NSString class]] || text.length == 0) return nil;
    if (!isfinite(start) || !isfinite(available) || available <= 0.0) return nil;

    // Runs of non-whitespace.
    NSCharacterSet *whitespace = [NSCharacterSet whitespaceAndNewlineCharacterSet];
    NSMutableArray<NSValue *> *ranges = [NSMutableArray array];
    NSUInteger length = text.length;
    NSUInteger index = 0;
    while (index < length) {
        while (index < length && [whitespace characterIsMember:[text characterAtIndex:index]]) index++;
        if (index >= length) break;
        NSUInteger begin = index;
        while (index < length && ![whitespace characterIsMember:[text characterAtIndex:index]]) index++;
        [ranges addObject:[NSValue valueWithRange:NSMakeRange(begin, index - begin)]];
    }
    if (ranges.count == 0) return nil;

    NSTimeInterval sung;
    if (available <= kCLEstimateShortGap) {
        sung = available * kCLEstimateFillRatio;
    } else {
        sung = (NSTimeInterval)text.length * kCLEstimateSecondsPerCharacter;
        sung = fmin(fmax(sung, kCLEstimateMinimumSung), kCLEstimateShortGap);
    }

    double totalWeight = 0.0;
    for (NSValue *value in ranges) totalWeight += (double)value.rangeValue.length + 1.0;

    NSMutableArray<CLLyricWord *> *words = [NSMutableArray arrayWithCapacity:ranges.count];
    double consumed = 0.0;
    for (NSValue *value in ranges) {
        NSRange range = value.rangeValue;
        double weight = (double)range.length + 1.0;
        NSTimeInterval wordStart = start + sung * (consumed / totalWeight);
        consumed += weight;
        NSTimeInterval wordEnd = start + sung * (consumed / totalWeight);
        [words addObject:[CLLyricWord wordWithTime:wordStart endTime:wordEnd range:range]];
    }
    return words;
}

/// `line.words` re-based onto `displayText`, or nil when they do not fit it.
static NSArray<CLLyricWord *> *CLRebasedWords(CLLyricLine *line, NSString *displayText) {
    NSArray<CLLyricWord *> *own = line.words;
    if (own.count == 0 || displayText.length == 0) return nil;
    if ([line.text isEqualToString:displayText]) return own;

    NSRange found = [line.text rangeOfString:displayText options:NSLiteralSearch];
    if (found.location == NSNotFound) return nil;
    NSMutableArray<CLLyricWord *> *shifted = [NSMutableArray arrayWithCapacity:own.count];
    for (CLLyricWord *word in own) {
        if (word.range.location < found.location) continue;
        NSRange moved = NSMakeRange(word.range.location - found.location, word.range.length);
        if (NSMaxRange(moved) > displayText.length) continue;
        [shifted addObject:[CLLyricWord wordWithTime:word.time endTime:word.endTime range:moved]];
    }
    return shifted.count ? shifted : nil;
}

NSArray<CLLyricWord *> *CLWordsForLine(NSString *displayText, CLLyricLine *line,
                                       NSTimeInterval nextLineTime, BOOL estimate) {
    if (![displayText isKindOfClass:[NSString class]] || displayText.length == 0) return nil;
    if (![line isKindOfClass:[CLLyricLine class]]) return nil;

    NSArray<CLLyricWord *> *real = CLRebasedWords(line, displayText);
    if (real) return real;
    if (!estimate) return nil;

    NSTimeInterval available = nextLineTime - line.time;
    if (!isfinite(available) || available <= 0.0) available = kCLEstimateFinalLineDuration;
    return CLEstimatedWords(displayText, line.time, available);
}
