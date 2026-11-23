// Shared non-interactive scrolling text for both stock Now Playing and carLy full-screen labels.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface CLSongMarquee : NSObject
@property (nonatomic, copy) NSString *role;
- (void)updateForLabel:(nullable UILabel *)label sourceText:(nullable NSString *)sourceText;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
