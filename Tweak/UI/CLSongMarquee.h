// Shared non-interactive scrolling text for both stock Now Playing and carLy full-screen labels.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLSongMarquee : NSObject
@property (nonatomic, copy) NSString *role;
- (void)updateForLabel:(nullable UILabel *)label sourceText:(nullable NSString *)sourceText;
/// Retrieve the readable colour even while the host UILabel is transparent for scrolling.
- (nullable UIColor *)visibleColorForLabel:(nullable UILabel *)label;
/// Recolour an active scrolling label without restarting the animation.
- (void)setVisibleTextColor:(nullable UIColor *)color forLabel:(nullable UILabel *)label;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
