// Owned by the UI slice. The full-screen lyrics view opened from the native microphone
// uses a compact two-row footer: title/artist beside previous/play/next, with
// elapsed/progress/remaining below. The host's original top-left back button
// returns to native Now Playing while lyrics are open.
// The host's player stays underneath and resumes without a navigation transition.
//
// UIKit/QuartzCore. Main thread only. Lyrics touch controls are opt-in; the inner table stays
// non-focusable to preserve CarPlay rotary controls. Only three transport buttons
// belong to this overlay; no duplicate back control is drawn.
#import <UIKit/UIKit.h>
#import "Core/CLNowPlayingSource.h"
#import "UI/CLLyricsPanelView.h"

NS_ASSUME_NONNULL_BEGIN

@class CLLyricsFullScreenView;

@protocol CLLyricsFullScreenViewDelegate <NSObject>
/// Previous, play/pause or next saw `events`: UIControlEventTouchDown when a touch starts, then
/// UIControlEventTouchUpInside once it ends (inside, outside or cancelled). The customizer forwards
/// both to the host's own transport button, which is exactly how CarPlay's player tells a tap from
/// a held skip (seek).
- (void)lyricsFullScreenView:(CLLyricsFullScreenView *)view didSendEvents:(UIControlEvents)events
                  forCommand:(CLPlaybackCommand)command;
@end

/// The host's CPUIModernButton (the class CarPlay's own transport and play-mode buttons are) when
/// it exists, set up the way CarPlayUI sets up its buttons; a custom-type UIButton otherwise.
/// Never UIButtonTypeSystem: on CarPlay that draws a dark platter behind the glyph.
FOUNDATION_EXPORT UIButton *CLMakeHostStyleButton(BOOL prefersWhite);

@interface CLLyricsFullScreenView : UIView

@property (nonatomic, weak, nullable) id<CLLyricsFullScreenViewDelegate> delegate;
/// The lyrics occupy the viewport above the compact two-row footer.
@property (nonatomic, readonly) CLLyricsPanelView *panelView;
/// Previous, play/pause, next — in that order (native Back is outside this view).
@property (nonatomic, readonly) NSArray<UIButton *> *controlButtons;
/// Empty for the compact footer; no shuffle/repeat/play-mode row.
@property (nonatomic, readonly) NSArray<UIButton *> *playModeButtons;

/// The row's song line. Empty strings and nil hide the respective label.
- (void)setTitle:(nullable NSString *)title artist:(nullable NSString *)artist;
/// Shows pause while playing, play otherwise (only used while no host images were handed over).
- (void)setPlaying:(BOOL)playing;
/// The host's own transport images (what its hidden player shows right now) and its button height;
/// nil images keep the SF Symbol fallbacks.
- (void)setPreviousImage:(nullable UIImage *)previous playPauseImage:(nullable UIImage *)playPause
               nextImage:(nullable UIImage *)next buttonHeight:(CGFloat)buttonHeight;
/// Compatibility no-op; the native CarPlay navigation bar owns Back.
- (void)setMicrophoneImage:(nullable UIImage *)image;
/// Compatibility no-op; the compact footer deliberately omits the host's play-mode row.
- (void)setHostPlayModeButtons:(NSArray<UIButton *> *)buttons hostWidth:(CGFloat)hostWidth;
/// What plays now: drives the thin progress line below the controls (elapsed, bar, remaining),
/// which interpolates between samples twice a second and hides while the length is unknown.
- (void)setPlaybackState:(nullable CLPlaybackState *)state;
/// The progress line (tests).
@property (nonatomic, readonly) UIView *progressView;
/// Layout > Progress Bar: Hide hides this line as well as the player's.
- (void)setProgressHidden:(BOOL)hidden;
/// Uses adaptive native foreground colours for progress and artist in both themes.
- (void)setAccentColor:(nullable UIColor *)color;
/// "Looking for lyrics…" / "No lyrics for this song" where the lyrics would be; nil hides it.
- (void)setStatusText:(nullable NSString *)text;
/// Re-reads the panel's visual preferences.
- (void)applyPrefs;

@end

NS_ASSUME_NONNULL_END
