// Owned by the ui slice. The full, scrolling lyrics panel (effective modes 4 "side by side" and
// 5 "full panel", shown as "No Artwork"): every line in one font sized to fit the panel (see
// CLLayoutPanelFit), the active one centred and at full colour. Display only: it takes no touches and never CarPlay knob/touchpad
// focus (see -cl_commonInit), so the drag-to-scroll and tap-to-seek paths below are dormant.
//
// Pure UIKit + CLLyricsTypes. Main thread only (public methods hop to the main queue themselves).
#import <UIKit/UIKit.h>
#import "Lyrics/CLLyricsTypes.h"
#import "UI/CLLayoutGeometry.h"

NS_ASSUME_NONNULL_BEGIN

@class CLLyricsPanelView;

@protocol CLLyricsPanelViewDelegate <NSObject>
@optional
/// A timed line was tapped. `index` indexes into the lyrics' `lines` array. Only sent for synced
/// lyrics (plain text has nothing to seek to).
- (void)lyricsPanel:(CLLyricsPanelView *)panel didSelectLineAtIndex:(NSInteger)index;
@end

/// Seconds of auto-scroll silence after the user lets go of the list.
extern const NSTimeInterval CLLyricsPanelAutoScrollPause;

/// The lyric clock: the playback position in the same time base as the lines' `time` (sync offset
/// already applied), or NAN when unknown.
typedef NSTimeInterval (^CLLyricsPanelTimeProvider)(void);

@interface CLLyricsPanelView : UIView

@property (nonatomic, weak, nullable) id<CLLyricsPanelViewDelegate> delegate;
/// Where word-by-word highlighting reads the playback position from. While the current line has
/// word timing the panel polls this about 30 times a second (and only while it is in a window);
/// with no provider, or NAN from it, the current line is highlighted whole, as before.
@property (nonatomic, copy, nullable) CLLyricsPanelTimeProvider lyricTimeProvider;

@property (nonatomic, readonly, nullable) CLLyrics *lyrics;
@property (nonatomic, readonly) NSInteger currentLineIndex;
/// NO when there is nothing to show (no lyrics, or unsynced text the user asked to hide).
@property (nonatomic, readonly) BOOL hasVisibleContent;
/// The font-fit rule (default Column; CLLayoutPanelFontSize in UI/CLLayoutGeometry.h, the same
/// rule the settings preview draws with). Setting a different value re-measures and reloads the rows.
@property (nonatomic) CLLayoutPanelFit fit;

- (void)setLyrics:(nullable CLLyrics *)lyrics;
/// Highlights `index` and (unless the user is scrolling) centres it. Idempotent.
- (void)setCurrentLineIndex:(NSInteger)index animated:(BOOL)animated;
/// Re-reads every visual preference from CLPrefs and re-renders. Call on CLPrefsDidChangeNotification.
- (void)applyPrefs;

@end

NS_ASSUME_NONNULL_END
