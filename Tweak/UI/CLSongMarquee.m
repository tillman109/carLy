#import "UI/CLSongMarquee.h"
#import "Util/CLLog.h"
#import <QuartzCore/QuartzCore.h>

#pragma mark - Non-interactive looping song-detail marquee

// The host labels may contain an ellipsis already. Use the full MediaRemote metadata only
// when the shortened label matches the same song or artist; otherwise trust the host UI.
static NSString *CLMarqueeText(NSString *hostText, NSString *sourceText) {
    if (hostText.length == 0 || sourceText.length == 0) return hostText ?: @"";
    if ([hostText isEqualToString:sourceText]) return sourceText;
    NSString *prefix = hostText;
    if ([prefix hasSuffix:@"..."]) prefix = [prefix substringToIndex:prefix.length - 3];
    else if ([prefix hasSuffix:@"…"]) prefix = [prefix substringToIndex:prefix.length - 1];
    prefix = [prefix stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (prefix.length > 0 && sourceText.length > hostText.length &&
        [sourceText rangeOfString:prefix options:(NSCaseInsensitiveSearch | NSAnchoredSearch)].location == 0) {
        return sourceText;
    }
    return hostText;
}

// The original implementation measured the label itself and often got a 4-5pt overflow,
// even when a clipping ancestor showed much less. Intersect with each ancestor's clip.
static CGFloat CLMarqueeViewportWidth(UILabel *label) {
    if (!label || CGRectIsEmpty(label.bounds)) return 0.0;
    CGRect visible = label.bounds;
    for (UIView *ancestor = label.superview; ancestor; ancestor = ancestor.superview) {
        if (!ancestor.clipsToBounds && !ancestor.layer.masksToBounds) continue;
        CGRect clip = [ancestor convertRect:ancestor.bounds toView:label];
        visible = CGRectIntersection(visible, clip);
        if (CGRectIsNull(visible) || CGRectIsEmpty(visible)) return 0.0;
    }
    return floor(CGRectGetWidth(visible));
}

// Render with UIKit's UIFont instead of passing font.fontName to CATextLayer.font.
// Private system font names (e.g. Apple's San Francisco UI fonts) can silently
// resolve to a generic serif font in CATextLayer. A cached transparent bitmap
// preserves the exact weight, glyphs, antialiasing and color of the stock UILabel.
// It remains a CALayer (not a focusable UIView) and scrolls via Core Animation.
static UIImage *CLMarqueeImage(NSString *text, UIFont *font, UIColor *color,
                               CGSize size, CGFloat scale) {
    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = NO;
    format.scale = MAX(1.0, scale);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size
                                                                              format:format];
    return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
        CGFloat top = MAX(0.0, (size.height - font.lineHeight) / 2.0);
        [text drawAtPoint:CGPointMake(0.0, top)
          withAttributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: color }];
    }];
}

@implementation CLSongMarquee {
    __weak UILabel *_host;
    CALayer *_textLayer;
    UIColor *_originalColor;
    BOOL _originalClips;
    NSString *_lastText;
    NSString *_lastFontName;
    CGFloat _lastSize;
    CGFloat _lastViewport;
}

- (void)stop {
    [_textLayer removeAllAnimations];
    [_textLayer removeFromSuperlayer];
    _textLayer = nil;
    UILabel *host = _host;
    if (host) {
        if (_originalColor) host.textColor = _originalColor;
        host.clipsToBounds = _originalClips;
    }
    _host = nil;
    _originalColor = nil;
    _lastText = nil;
    _lastFontName = nil;
    _lastSize = 0.0;
    _lastViewport = 0.0;
}

- (void)cl_updateImageWithText:(NSString *)text font:(UIFont *)font color:(UIColor *)color {
    if (!_textLayer || text.length == 0 || !font || !color) return;
    CGSize size = _textLayer.bounds.size;
    CGFloat scale = _host.window.screen.scale > 0.0 ? _host.window.screen.scale : UIScreen.mainScreen.scale;
    UIImage *image = CLMarqueeImage(text, font, color, size, scale);
    _textLayer.contents = (__bridge id)image.CGImage;
    _textLayer.contentsScale = MAX(1.0, scale);
}

- (UIColor *)visibleColorForLabel:(UILabel *)label {
    if (!label) return nil;
    return (_host == label && _textLayer) ? _originalColor : label.textColor;
}

- (void)setVisibleTextColor:(UIColor *)color forLabel:(UILabel *)label {
    if (!label || !color) return;
    if (_host == label && _textLayer) {
        if (![_originalColor isEqual:color]) {
            _originalColor = color;
            if (_lastText.length) {
                NSString *looped = [NSString stringWithFormat:@"%@        %@", _lastText, _lastText];
                [self cl_updateImageWithText:looped font:label.font color:color];
            }
        }
        // Keep the stock UILabel hidden while our pre-rendered layer scrolls.
        if (![label.textColor isEqual:UIColor.clearColor]) label.textColor = UIColor.clearColor;
    } else if (![label.textColor isEqual:color]) {
        label.textColor = color;
    }
}

- (void)updateForLabel:(UILabel *)label sourceText:(NSString *)sourceText {
    if (![label isKindOfClass:UILabel.class] || label.isHidden || label.text.length == 0 ||
        !label.font || CGRectGetHeight(label.bounds) < 10.0) {
        [self stop];
        return;
    }
    NSString *text = CLMarqueeText(label.text, sourceText);
    UIFont *font = label.font;
    CGFloat viewport = CLMarqueeViewportWidth(label);
    CGFloat textWidth = ceil([text sizeWithAttributes:@{NSFontAttributeName: font}].width);
    if (viewport < 24.0 || textWidth <= viewport + 1.0) {
        [self stop];
        return;
    }

    BOOL unchanged = _host == label && _textLayer != nil &&
        [text isEqualToString:_lastText] && [font.fontName isEqualToString:_lastFontName] &&
        fabs(font.pointSize - _lastSize) < 0.1 &&
        fabs(viewport - _lastViewport) < 0.5;
    if (unchanged) {
        // CarPlay can reset the label colour on its layout pass. Refresh the overlay colour,
        // but never restart its animation just because the view was laid out again.
        if (![label.textColor isEqual:UIColor.clearColor]) {
            _originalColor = label.textColor ?: UIColor.labelColor;
            NSString *loop = [NSString stringWithFormat:@"%@        %@", text, text];
            [self cl_updateImageWithText:loop font:font color:_originalColor];
            label.textColor = UIColor.clearColor;
        }
        return;
    }

    [self stop];
    _host = label;
    _originalColor = label.textColor ?: UIColor.labelColor;
    _originalClips = label.clipsToBounds;
    _lastText = [text copy];
    _lastFontName = [font.fontName copy];
    _lastSize = font.pointSize;
    _lastViewport = viewport;

    // A duplicated string and an interstitial gap form a *continuous loop*. It moves the
    // full length of the song/artist text even when the original overflow was only 4pt.
    NSString *gap = @"        ";
    NSString *oneCopy = [text stringByAppendingString:gap];
    NSString *looped = [oneCopy stringByAppendingString:text];
    CGFloat distance = ceil([oneCopy sizeWithAttributes:@{NSFontAttributeName: font}].width);
    CGFloat width = ceil([looped sizeWithAttributes:@{NSFontAttributeName: font}].width) + 6.0;

    CALayer *layer = [CALayer layer];
    layer.name = @"carLy-system-font-marquee";
    layer.frame = CGRectMake(0.0, 0.0, width, CGRectGetHeight(label.bounds));
    layer.contentsGravity = kCAGravityTopLeft;
    _textLayer = layer;
    [self cl_updateImageWithText:looped font:font color:_originalColor];
    label.clipsToBounds = YES;
    [label.layer addSublayer:layer];
    label.textColor = UIColor.clearColor;

    CABasicAnimation *animation = [CABasicAnimation animationWithKeyPath:@"position.x"];
    animation.fromValue = @(layer.position.x);
    animation.toValue = @(layer.position.x - distance);
    animation.duration = MAX(8.0, distance / 18.0);  // calm, constant ~18pt/sec
    animation.repeatCount = HUGE_VALF;
    animation.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionLinear];
    animation.beginTime = [layer convertTime:CACurrentMediaTime() fromLayer:nil] + 0.4;
    [layer addAnimation:animation forKey:@"cl-song-scroll"];
    CLLogDebug(@"[ui] %@ marquee scrolling (viewport=%.0f text=%.0f loop=%.0f speed=18pt/s)",
               self.role ?: @"label", viewport, textWidth, distance);
}
@end

