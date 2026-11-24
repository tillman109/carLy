#import "UI/CLLyricsPanelView.h"
#import "UI/CLLayoutGeometry.h"
#import "UI/CLLyricsStyle.h"
#import "Lyrics/CLWordTiming.h"
#import "Util/CLLog.h"
#import "Util/CLPrefs.h"

const NSTimeInterval CLLyricsPanelAutoScrollPause = 3.0;

static NSString *const CLLyricsPanelCellIdentifier = @"CLLyricsPanelCell";
static const NSInteger CLLyricsPanelLabelTag = 9101;
/// Space above and below each lyric line (so 2x between two lines), and the height of a blank
/// stanza-break row.
static const CGFloat CLLyricsPanelRowPadding = 4.0;
static const CGFloat CLLyricsPanelBlankRowHeight = 12.0;

/// How often the word highlight is redrawn while a line with word timing is current.
static const NSTimeInterval CLLyricsPanelWordTick = 1.0 / 30.0;

/// A label that remembers whether it is currently showing word-highlighted attributed text, so a
/// reused cell can be put back to plain text (UILabel gives no way to ask).
@interface CLLyricsPanelLabel : UILabel
@property (nonatomic) BOOL wordStyled;
@end

@implementation CLLyricsPanelLabel
@end

/// 0...1: how much of `word` has been sung at lyric time `now`.
static double CLLyricsWordProgress(CLLyricWord *word, NSTimeInterval now) {
    NSTimeInterval duration = word.endTime - word.time;
    if (duration <= 0.001) return now >= word.time ? 1.0 : 0.0;
    double progress = (now - word.time) / duration;
    if (progress < 0.0) return 0.0;
    if (progress > 1.0) return 1.0;
    return progress;
}

/// Changes only when the picture changes: -1 before the first word, INT max after the last, else
/// the time in 1/60 s steps. Lets the redraw loop skip frames while playback is paused or between
/// words of a held note.
static NSInteger CLLyricsWordPaintKey(NSArray<CLLyricWord *> *words, NSTimeInterval now) {
    NSTimeInterval first = INFINITY, last = -INFINITY;
    for (CLLyricWord *word in words) {
        first = fmin(first, word.time);
        last = fmax(last, word.endTime);
    }
    if (now < first) return -1;
    if (now >= last) return NSIntegerMax;
    return (NSInteger)(now * 60.0);
}

static UIColor *CLLyricsBlend(UIColor *from, UIColor *to, CGFloat fraction) {
    CGFloat fr, fg, fb, fa, tr, tg, tb, ta;
    if (![from getRed:&fr green:&fg blue:&fb alpha:&fa] || ![to getRed:&tr green:&tg blue:&tb alpha:&ta]) {
        return fraction < 0.5 ? from : to;
    }
    return [UIColor colorWithRed:fr + (tr - fr) * fraction
                           green:fg + (tg - fg) * fraction
                            blue:fb + (tb - fb) * fraction
                           alpha:fa + (ta - fa) * fraction];
}

@interface CLLyricsPanelView () <UITableViewDataSource, UITableViewDelegate, UIGestureRecognizerDelegate>
@end

@implementation CLLyricsPanelView {
    CLLyricsStyle *_style;
    /// Every row uses this one font: lyricsFontSize, capped to what the panel's size can show (see
    /// -cl_fittedFontSize). One font for all rows means a line becoming current never changes its
    /// height, so nothing re-wraps, truncates or jumps; the current line stands out by colour.
    UIFont *_rowFont;
    UIView *_backgroundView;
    UITableView *_tableView;
    NSArray<NSString *> *_rows;
    /// Parallel to _rows: the CLLyricWords to sweep through for that row, or NSNull (whole line).
    NSArray *_rowWords;
    NSTimer *_wordTimer;             ///< runs only while the current row has words and we are on screen
    NSInteger _lastPaintRow;         ///< what the word highlight last drew, to skip identical frames
    NSInteger _lastPaintKey;
    BOOL _rowsAreTimed;              ///< synced lyrics: rows map 1:1 to lyrics.lines and can be tapped
    NSTimer *_resumeTimer;
    // After tap-to-seek the audio command is sent immediately, but this display
    // deliberately keeps its previous line until delayed wireless audio catches up.
    NSTimer *_tapSeekTimer;
    BOOL _tapSeekHoldActive;
    NSInteger _tapSeekPendingIndex;
    CFAbsoluteTime _autoScrollBlockedUntil;
    BOOL _userIsDragging;
    UIPanGestureRecognizer *_touchPan;
    UITapGestureRecognizer *_touchTap;
    NSTimeInterval _snapBackSeconds;
}

#pragma mark - Lifecycle

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self cl_commonInit];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self cl_commonInit];
    return self;
}

- (void)dealloc {
    [_tapSeekTimer invalidate];
    [_resumeTimer invalidate];
    _resumeTimer = nil;
    [_wordTimer invalidate];
    _wordTimer = nil;
    _tableView.dataSource = nil;
    _tableView.delegate = nil;
}

- (void)cl_commonInit {
    _currentLineIndex = -1;          // CLLyricsNoLine
    _tapSeekPendingIndex = -1;
    _rows = @[];
    _rowWords = @[];
    _lastPaintRow = -1;
    _lastPaintKey = 0;
    _rowsAreTimed = NO;
    _fit = CLLayoutPanelFitColumn;

    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;
    self.clipsToBounds = YES;
    // Display only. CarPlay's focus behavior puts a view controller's content scroll view among the
    // preferred focus environments (_UIFocusBehavior_CarPlay includesContentScrollViewInPreferred-
    // FocusEnvironments), and UIKit adopts this table as the Now Playing controller's content scroll
    // view: the rotary knob's focus went to the lyrics (0.2.0: a lyric row, 0.2.1: the list itself,
    // drawn as up/down arrows) and stopped reaching the player's buttons. A view that does not take
    // user interaction is never eligible for focus, so the knob and touch both stay with the host.
    self.userInteractionEnabled = NO;

    _backgroundView = [[UIView alloc] initWithFrame:CGRectZero];
    _backgroundView.translatesAutoresizingMaskIntoConstraints = NO;
    _backgroundView.userInteractionEnabled = NO;
    _backgroundView.hidden = YES;
    [self addSubview:_backgroundView];

    _tableView = [[UITableView alloc] initWithFrame:CGRectZero style:UITableViewStylePlain];
    _tableView.translatesAutoresizingMaskIntoConstraints = NO;
    _tableView.backgroundColor = UIColor.clearColor;
    _tableView.backgroundView = nil;
    _tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    _tableView.showsVerticalScrollIndicator = NO;
    _tableView.userInteractionEnabled = NO;       // see -cl_commonInit: never a focus target
    // Nor something the knob may scroll: CarPlay's focus system treats a scroll-enabled content
    // scroll view as rotary-scrollable and drew its up/down arrows on this table (a cyan "X" at its
    // trailing edge, 0.2.1 – 0.6.0). The panel only ever scrolls itself, through -setContentOffset:
    // and -scrollToRowAtIndexPath:, which work with scrolling disabled.
    _tableView.scrollEnabled = NO;
    _tableView.showsHorizontalScrollIndicator = NO;
    _tableView.allowsSelection = YES;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    _tableView.estimatedRowHeight = 32.0;
    // Lyrics are for reading, not for the knob or touchpad: focus stays on the player controls.
    _tableView.remembersLastFocusedIndexPath = NO;
    _tableView.dataSource = self;
    _tableView.delegate = self;
    // Touch is handled by the non-focusable panel, not by the internal UITableView. In
    // particular the table must NEVER become rotary-scrollable on CarPlay.
    _touchPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(cl_handleTouchPan:)];
    _touchPan.maximumNumberOfTouches = 1;
    _touchPan.delegate = self;
    [self addGestureRecognizer:_touchPan];
    _touchTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cl_handleTouchTap:)];
    [self addGestureRecognizer:_touchTap];
    if (@available(iOS 15.0, *)) {
        _tableView.sectionHeaderTopPadding = 0.0;
    }
    _tableView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    [self addSubview:_tableView];

    [NSLayoutConstraint activateConstraints:@[
        [_backgroundView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_backgroundView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_backgroundView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_backgroundView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
        [_tableView.topAnchor constraintEqualToAnchor:self.topAnchor],
        [_tableView.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
        [_tableView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
        [_tableView.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    ]];

    [self applyPrefs];
}

#pragma mark - Public API

- (void)setLyrics:(CLLyrics *)lyrics {
    CLUIRunOnMain(^{
        if (lyrics == self->_lyrics) return;
        [self cl_cancelTapSeekHold];
        self->_lyrics = lyrics;
        self->_currentLineIndex = -1;
        self->_userIsDragging = NO;
        self->_autoScrollBlockedUntil = 0.0;
        [self->_resumeTimer invalidate];
        self->_resumeTimer = nil;
        [self cl_rebuildRows];
        [self->_tableView reloadData];
        [self cl_updateBackgroundVisibility];
        [self->_tableView setContentOffset:CGPointMake(0.0, -self->_tableView.contentInset.top) animated:NO];
        [self cl_updateWordTimer];
    });
}

- (void)setLyricTimeProvider:(CLLyricsPanelTimeProvider)lyricTimeProvider {
    _lyricTimeProvider = [lyricTimeProvider copy];
    CLUIRunOnMain(^{
        [self cl_restyleVisibleCells];
        [self cl_updateWordTimer];
    });
}

- (void)setCurrentLineIndex:(NSInteger)index animated:(BOOL)animated {
    CLUIRunOnMain(^{
        if (self->_tapSeekHoldActive) {
            self->_tapSeekPendingIndex = index;
            return;
        }
        if (index == self->_currentLineIndex) return;
        self->_currentLineIndex = index;
        if (!self->_rowsAreTimed) return;
        [self cl_restyleVisibleCells];
        [self cl_updateWordTimer];
        [self cl_scrollToCurrentLineAnimated:animated force:NO];
    });
}

- (void)setFit:(CLLayoutPanelFit)fit {
    if (_fit == fit) return;
    _fit = fit;
    _rowFont = nil;                            // a different rule: re-measure from scratch
    if ([self cl_updateRowFont]) [_tableView reloadData];
    [self setNeedsLayout];
}

- (void)applyPrefs {
    CLUIRunOnMain(^{
        CLPrefs *prefs = CLPrefs.shared;
        self->_snapBackSeconds = MAX(2.0, MIN(5.0, prefs.lyricsSnapBackSeconds));
        self.userInteractionEnabled = prefs.lyricsTouchControls;
        if (!self.userInteractionEnabled || !prefs.lyricsTapSeekWirelessDelay) {
            [self cl_cancelTapSeekHold];
        }
        CLLogDebug(@"[ui] lyric touch controls %@ (timed=%d, rows=%lu, return=%.1fs)",
                   self.userInteractionEnabled ? @"enabled" : @"disabled",
                   self->_rowsAreTimed, (unsigned long)self->_rows.count, self->_snapBackSeconds);
        if (!self.userInteractionEnabled) {
            self->_userIsDragging = NO;
            self->_autoScrollBlockedUntil = 0.0;
            [self->_resumeTimer invalidate];
            self->_resumeTimer = nil;
        }
        CLLyricsStyle *style = [CLLyricsStyle currentStyle];
        BOOL sameStyle = [style isEqualToStyle:self->_style];
        self->_style = style;
        if (sameStyle) return;
        self->_rowFont = nil;
        [self cl_updateRowFont];
        [self cl_applyBackgroundStyle];
        [self cl_rebuildRows];                 // showNoteOnGap / showPlainWhenUnsynced can change
        [self->_tableView reloadData];         // fonts changed: row heights must be re-measured
        [self cl_updateBackgroundVisibility];
        [self cl_updateWordTimer];
        [self cl_scrollToCurrentLineAnimated:NO force:NO];
    });
}

#pragma mark - Layout

- (void)layoutSubviews {
    [super layoutSubviews];

    CGFloat radius = 0.0;
    if (_style.backgroundStyle == 1) {
        radius = MIN(18.0, CGRectGetHeight(self.bounds) / 2.0);
    } else if (_style.backgroundStyle == 2) {
        radius = 4.0;
    }
    if (fabs(_backgroundView.layer.cornerRadius - radius) > 0.01) {
        _backgroundView.layer.cornerRadius = radius;
    }

    if ([self cl_updateRowFont]) {
        [_tableView reloadData];               // a new size: every row must be re-measured
    }

    // Half-height insets so the first and last line can still be centred.
    CGFloat rowHeight = ceil(_rowFont.lineHeight) + 2.0 * CLLyricsPanelRowPadding;
    CGFloat vertical = MAX(0.0, CGRectGetHeight(self.bounds) / 2.0 - rowHeight / 2.0);
    UIEdgeInsets insets = UIEdgeInsetsMake(vertical, 0.0, vertical, 0.0);
    if (!UIEdgeInsetsEqualToEdgeInsets(_tableView.contentInset, insets)) {
        _tableView.contentInset = insets;
        __weak typeof(self) weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf cl_scrollToCurrentLineAnimated:NO force:NO];
        });
    }
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    if (!self.window) {
        [self cl_cancelTapSeekHold];
        [_resumeTimer invalidate];
        _resumeTimer = nil;
    }
    [self cl_updateWordTimer];     // starts with the window, stops without it
}

- (void)traitCollectionDidChange:(UITraitCollection *)previousTraitCollection {
    [super traitCollectionDidChange:previousTraitCollection];
    if ([self.traitCollection hasDifferentColorAppearanceComparedToTraitCollection:previousTraitCollection]) {
        [self cl_restyleVisibleCells];
        [self setNeedsLayout];
    }
}

#pragma mark - Font

/// lyricsFontSize, capped by the fit rule: CLLayoutPanelFontSize in UI/CLLayoutGeometry.h, the
/// one copy of the arithmetic (the settings preview draws with it too).
///   Column — about seven lines at once and roughly a dozen characters per line before wrapping:
///     a 210x180 pt panel (a 1920x720 @3x display) gets 19 pt, a 400x420 pt one keeps the preference.
///   Rows — three rows (each ceil(1.2 * size) + 8 tall) must fit the height; no width term, long
///     lines wrap: a 216–320 pt artwork square keeps 24 pt, a 300x80 pt panel gets 16.
- (CGFloat)cl_fittedFontSize {
    return CLLayoutPanelFontSize(self.bounds.size, _fit, _style.fontSize);
}

/// YES when the row font changed (the caller reloads the table).
- (BOOL)cl_updateRowFont {
    if (!_style) return NO;
    CGFloat size = [self cl_fittedFontSize];
    if (_rowFont && fabs(_rowFont.pointSize - size) < 0.01) return NO;
    _rowFont = [_style fontWithSize:size weight:_style.fontWeight];
    _tableView.estimatedRowHeight = ceil(_rowFont.lineHeight) + 2.0 * CLLyricsPanelRowPadding;
    return YES;
}

#pragma mark - Content

- (void)cl_rebuildRows {
    CLLyrics *lyrics = _lyrics;
    NSMutableArray<NSString *> *rows = [NSMutableArray array];
    NSMutableArray *rowWords = [NSMutableArray array];
    BOOL timed = NO;

    if (lyrics.kind == CLLyricsKindSynced && lyrics.lines.count > 0) {
        timed = YES;
        NSArray<CLLyricLine *> *lines = lyrics.lines;
        for (NSUInteger i = 0; i < lines.count; i++) {
            CLLyricLine *line = lines[i];
            NSString *text = [(line.text ?: @"") stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            BOOL gap = CLLyricsTextIsGap(text);
            if (gap) text = _style.showNoteOnGap ? CLLyricsNoteGlyph : @"";
            [rows addObject:text];

            NSArray<CLLyricWord *> *words = nil;
            if (_style.wordHighlight && !gap) {
                NSTimeInterval next = (i + 1 < lines.count) ? lines[i + 1].time : NAN;
                words = CLWordsForLine(text, line, next, _style.wordEstimate);
            }
            [rowWords addObject:words ?: (id)NSNull.null];
        }
    } else if (lyrics.kind == CLLyricsKindInstrumental) {
        if (_style.showNoteOnGap) [rows addObject:CLLyricsNoteGlyph];
    } else if (lyrics && _style.showPlainWhenUnsynced) {
        NSString *plain = lyrics.plainText;
        for (NSString *raw in [(plain ?: @"") componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
            NSString *text = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            // A line of notes follows the gap switch here too; an empty line stays a stanza break.
            if (text.length > 0 && CLLyricsTextIsGap(text)) text = _style.showNoteOnGap ? CLLyricsNoteGlyph : @"";
            [rows addObject:text];
        }
        while (rows.count > 0 && ((NSString *)rows.lastObject).length == 0) [rows removeLastObject];
    }

    _rows = [rows copy];
    _rowWords = timed ? [rowWords copy] : @[];
    _lastPaintRow = -1;
    _rowsAreTimed = timed;
    _hasVisibleContent = (_rows.count > 0);
}

/// The words to sweep through for `row`, or nil when it is highlighted as a whole line.
- (NSArray<CLLyricWord *> *)cl_wordsForRow:(NSInteger)row {
    if (!_rowsAreTimed || row < 0 || row >= (NSInteger)_rowWords.count) return nil;
    id words = _rowWords[(NSUInteger)row];
    return [words isKindOfClass:[NSArray class]] ? words : nil;
}

- (void)cl_applyBackgroundStyle {
    _backgroundView.backgroundColor = _style.backgroundFill ?: UIColor.clearColor;
    [self cl_updateBackgroundVisibility];
    [self setNeedsLayout];
}

- (void)cl_updateBackgroundVisibility {
    BOOL visible = (_style.backgroundStyle != 0) && _hasVisibleContent;
    if (_backgroundView.hidden == visible) _backgroundView.hidden = !visible;
}

#pragma mark - Cells

- (CLLyricsPanelLabel *)cl_labelInCell:(UITableViewCell *)cell {
    CLLyricsPanelLabel *label = (CLLyricsPanelLabel *)[cell.contentView viewWithTag:CLLyricsPanelLabelTag];
    if ([label isKindOfClass:CLLyricsPanelLabel.class]) return label;

    label = [[CLLyricsPanelLabel alloc] initWithFrame:CGRectZero];
    label.tag = CLLyricsPanelLabelTag;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    label.numberOfLines = 0;
    label.backgroundColor = UIColor.clearColor;
    label.adjustsFontForContentSizeCategory = NO;
    [cell.contentView addSubview:label];

    CGFloat padY = CLLyricsPanelRowPadding;
    CGFloat padX = CLLayoutPanelTextInset;
    NSLayoutConstraint *height = [cell.contentView.heightAnchor constraintGreaterThanOrEqualToConstant:0.0];
    height.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        [label.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:padY],
        [cell.contentView.bottomAnchor constraintEqualToAnchor:label.bottomAnchor constant:padY],
        [label.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:padX],
        [cell.contentView.trailingAnchor constraintEqualToAnchor:label.trailingAnchor constant:padX],
        height,
    ]];
    return label;
}

- (void)cl_configureCell:(UITableViewCell *)cell forRow:(NSInteger)row {
    CLLyricsPanelLabel *label = [self cl_labelInCell:cell];
    NSString *text = (row >= 0 && row < (NSInteger)_rows.count) ? _rows[(NSUInteger)row] : @"";

    BOOL isCurrent = _rowsAreTimed && (row == _currentLineIndex);
    BOOL dimmed = _rowsAreTimed && !isCurrent &&
                  (!_style.keepSungBright || row > _currentLineIndex);

    // The current line sweeps word by word when it has word timing and the clock is available.
    NSArray<CLLyricWord *> *words = isCurrent ? [self cl_wordsForRow:row] : nil;
    CLLyricsPanelTimeProvider provider = _lyricTimeProvider;
    NSTimeInterval now = (words && provider) ? provider() : NAN;
    if (words && isfinite(now)) {
        label.textAlignment = _style.alignment;
        [self cl_paintWords:words row:row time:now inLabel:label];
    } else {
        if (label.wordStyled) {        // a reused cell that was sweeping: back to plain text
            label.wordStyled = NO;
            label.attributedText = nil;
            label.text = nil;
        }
        if (isCurrent) _lastPaintRow = -1;
        if (![label.text isEqualToString:text]) label.text = text;
        label.textAlignment = _style.alignment;

        UIFont *font = _rowFont ?: _style.currentLineFont;
        if (label.font != font) label.font = font;
        // Unsynced text has no "current" line, so it is rendered at full strength rather than dimmed.
        label.textColor = dimmed ? _style.nextColor : _style.currentColor;
    }

    // A blank row is a stanza break (or a gap marker with the note glyph turned off): it keeps its
    // place in the list with a little air, not a full line's height.
    CGFloat minimumHeight = (text.length == 0) ? CLLyricsPanelBlankRowHeight : 0.0;
    NSLayoutConstraint *heightConstraint = [self cl_minimumHeightConstraintInCell:cell];
    if (heightConstraint && fabs(heightConstraint.constant - minimumHeight) > 0.5) {
        heightConstraint.constant = minimumHeight;
    }
}

/// The `contentView.height >= n` constraint installed by -cl_labelInCell:, or nil.
- (NSLayoutConstraint *)cl_minimumHeightConstraintInCell:(UITableViewCell *)cell {
    for (NSLayoutConstraint *constraint in cell.contentView.constraints) {
        if (constraint.firstAttribute == NSLayoutAttributeHeight &&
            constraint.relation == NSLayoutRelationGreaterThanOrEqual &&
            constraint.secondItem == nil &&
            constraint.firstItem == cell.contentView) {
            return constraint;
        }
    }
    return nil;
}

- (void)cl_restyleVisibleCells {
    NSArray<NSIndexPath *> *visible = _tableView.indexPathsForVisibleRows;
    if (visible.count == 0) return;
    // Instant: a label's font cannot be interpolated, and cross-dissolving the whole table while
    // it is scrolling looks worse than a hard switch. The motion comes from the auto-scroll.
    for (NSIndexPath *indexPath in visible) {
        UITableViewCell *cell = [self->_tableView cellForRowAtIndexPath:indexPath];
        if (cell) [self cl_configureCell:cell forRow:indexPath.row];
    }
}

#pragma mark - Word highlight

/// The row's text with sung words in the current colour, unsung ones dimmed, and the word being
/// sung swept left to right (by character, the boundary character blended).
- (NSAttributedString *)cl_attributedTextForRow:(NSInteger)row words:(NSArray<CLLyricWord *> *)words time:(NSTimeInterval)now {
    NSString *text = (row >= 0 && row < (NSInteger)_rows.count) ? _rows[(NSUInteger)row] : @"";
    UIFont *font = _rowFont ?: _style.currentLineFont;
    UIColor *bright = _style.currentColor;
    UIColor *dim = _style.nextColor;
    NSMutableAttributedString *result = [[NSMutableAttributedString alloc]
        initWithString:text
            attributes:@{ NSFontAttributeName: font, NSForegroundColorAttributeName: dim }];
    NSUInteger length = text.length;
    NSUInteger cursor = 0;
    BOOL previousComplete = NO;

    for (CLLyricWord *word in words) {
        NSRange range = word.range;
        if (range.location < cursor || range.length == 0 || NSMaxRange(range) > length) continue;
        double progress = CLLyricsWordProgress(word, now);

        // Characters between words (spaces, a quote the timing did not cover) follow the word
        // they lead into: lit once that word has started.
        if (range.location > cursor && progress > 0.0) {
            [result addAttribute:NSForegroundColorAttributeName value:bright
                           range:NSMakeRange(cursor, range.location - cursor)];
        }

        if (progress >= 1.0) {
            [result addAttribute:NSForegroundColorAttributeName value:bright range:range];
        } else if (progress > 0.0) {
            NSMutableArray<NSValue *> *units = [NSMutableArray array];
            [text enumerateSubstringsInRange:range
                                     options:NSStringEnumerationByComposedCharacterSequences
                                  usingBlock:^(NSString *substring, NSRange unit, NSRange enclosing, BOOL *stop) {
                [units addObject:[NSValue valueWithRange:unit]];
            }];
            double scaled = progress * (double)units.count;
            NSUInteger whole = (NSUInteger)floor(scaled);
            if (whole > units.count) whole = units.count;
            if (whole > 0) {
                NSRange lastLit = units[whole - 1].rangeValue;
                [result addAttribute:NSForegroundColorAttributeName value:bright
                               range:NSMakeRange(range.location, NSMaxRange(lastLit) - range.location)];
            }
            double fraction = scaled - (double)whole;
            if (whole < units.count && fraction > 0.0) {
                [result addAttribute:NSForegroundColorAttributeName
                               value:CLLyricsBlend(dim, bright, (CGFloat)fraction)
                               range:units[whole].rangeValue];
            }
        }
        previousComplete = (progress >= 1.0);
        cursor = NSMaxRange(range);
    }

    // Trailing punctuation outside the last word lights up with it.
    if (cursor < length && previousComplete) {
        [result addAttribute:NSForegroundColorAttributeName value:bright range:NSMakeRange(cursor, length - cursor)];
    }
    return result;
}

- (void)cl_paintWords:(NSArray<CLLyricWord *> *)words row:(NSInteger)row time:(NSTimeInterval)now
              inLabel:(CLLyricsPanelLabel *)label {
    label.wordStyled = YES;
    label.attributedText = [self cl_attributedTextForRow:row words:words time:now];
    _lastPaintRow = row;
    _lastPaintKey = CLLyricsWordPaintKey(words, now);
}

/// Runs only while it can matter: on screen, a clock to read, and a current row with words.
- (void)cl_updateWordTimer {
    BOOL needed = (self.window != nil) && (_lyricTimeProvider != nil) &&
                  ([self cl_wordsForRow:_currentLineIndex] != nil);
    if (needed && !_wordTimer) {
        __weak typeof(self) weakSelf = self;
        NSTimer *timer = [NSTimer timerWithTimeInterval:CLLyricsPanelWordTick repeats:YES
                                                  block:^(NSTimer *fired) {
            [weakSelf cl_wordTick];
        }];
        timer.tolerance = CLLyricsPanelWordTick / 4.0;
        [NSRunLoop.mainRunLoop addTimer:timer forMode:NSRunLoopCommonModes];
        _wordTimer = timer;
    } else if (!needed && _wordTimer) {
        [_wordTimer invalidate];
        _wordTimer = nil;
    }
}

- (void)cl_wordTick {
    // A timer block has no handler above it: an exception here would abort CarPlayTemplateUIHost.
    CLUISafePerform(@"lyrics word tick", ^{
        if (self->_tapSeekHoldActive) return; // keep previous lyrics static during wireless delay
        NSInteger row = self->_currentLineIndex;
        NSArray<CLLyricWord *> *words = [self cl_wordsForRow:row];
        CLLyricsPanelTimeProvider provider = self->_lyricTimeProvider;
        if (!words || !provider || self.hidden || !self.window) return;

        NSTimeInterval now = provider();
        if (!isfinite(now)) return;
        NSInteger key = CLLyricsWordPaintKey(words, now);
        if (row == self->_lastPaintRow && key == self->_lastPaintKey) return;   // nothing moved

        UITableViewCell *cell = [self->_tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]];
        if (!cell) return;                                                      // scrolled out of view
        [self cl_paintWords:words row:row time:now inLabel:[self cl_labelInCell:cell]];
    });
}

#pragma mark - Auto-scroll

- (void)cl_scrollToCurrentLineAnimated:(BOOL)animated force:(BOOL)force {
    if (!_rowsAreTimed) return;
    NSInteger row = _currentLineIndex;
    if (row < 0 || row >= (NSInteger)_rows.count) return;
    if (_tableView.numberOfSections < 1) return;
    if (row >= [_tableView numberOfRowsInSection:0]) return;      // reloadData has not landed yet
    if (!force) {
        if (_userIsDragging || _tableView.isDragging || _tableView.isTracking) return;
        if (CFAbsoluteTimeGetCurrent() < _autoScrollBlockedUntil) return;
    }
    [_tableView scrollToRowAtIndexPath:[NSIndexPath indexPathForRow:row inSection:0]
                      atScrollPosition:UITableViewScrollPositionMiddle
                              animated:(animated && _style.animations)];
}

- (void)cl_suspendAutoScroll {
    NSTimeInterval delay = _snapBackSeconds > 0 ? _snapBackSeconds : CLLyricsPanelAutoScrollPause;
    _autoScrollBlockedUntil = CFAbsoluteTimeGetCurrent() + delay;
    [_resumeTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _resumeTimer = [NSTimer timerWithTimeInterval:delay repeats:NO
                                           block:^(NSTimer *timer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        strongSelf->_autoScrollBlockedUntil = 0.0;
        if (strongSelf->_userIsDragging) return;
        [strongSelf cl_scrollToCurrentLineAnimated:YES force:YES];
    }];
    [NSRunLoop.mainRunLoop addTimer:_resumeTimer forMode:NSRunLoopCommonModes];
}

#pragma mark - UITableViewDataSource

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return 1;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return (NSInteger)_rows.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:CLLyricsPanelCellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault
                                      reuseIdentifier:CLLyricsPanelCellIdentifier];
        cell.backgroundColor = UIColor.clearColor;
        cell.contentView.backgroundColor = UIColor.clearColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    [self cl_configureCell:cell forRow:indexPath.row];
    return cell;
}

#pragma mark - Wireless CarPlay tap-to-seek alignment

- (void)cl_cancelTapSeekHold {
    [_tapSeekTimer invalidate];
    _tapSeekTimer = nil;
    _tapSeekHoldActive = NO;
    _tapSeekPendingIndex = -1;
}

/// Uses the timing preference for the *actual lyrics provider* (Spotify/Apple Music or other).
/// Its magnitude is the delay in milliseconds: the sign still has its normal meaning for
/// continuous playback synchronisation. Playback itself is never held.
- (NSTimeInterval)cl_wirelessSeekDelay {
    CLPrefs *prefs = CLPrefs.shared;
    if (!prefs.lyricsTapSeekWirelessDelay || !prefs.lyricsTouchControls) return 0.0;
    NSString *source = _lyrics.source ?: @"";
    BOOL service = [source isEqualToString:@"spotify"] ||
                   [source isEqualToString:@"spotify-cache"] ||
                   [source isEqualToString:@"apple-music"];
    NSInteger ms = service ? prefs.serviceLyricsOffsetMs : prefs.lyricsOffsetMs;
    return MIN(2.0, fabs((double)ms) / 1000.0);
}

- (void)cl_holdLyricsAfterTappedSeek:(NSInteger)selectedRow {
    [self cl_cancelTapSeekHold];
    NSTimeInterval delay = [self cl_wirelessSeekDelay];
    if (delay < 0.005) return;
    _tapSeekHoldActive = YES;
    _tapSeekPendingIndex = selectedRow;
    CLLogDebug(@"[ui] tap-to-seek wireless sync: delaying lyric highlight %.0fms (line=%ld)",
               delay * 1000.0, (long)selectedRow);

    __weak typeof(self) weakSelf = self;
    _tapSeekTimer = [NSTimer timerWithTimeInterval:delay repeats:NO block:^(NSTimer *timer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || !strongSelf->_tapSeekHoldActive) return;
        NSInteger target = strongSelf->_tapSeekPendingIndex;
        [strongSelf cl_cancelTapSeekHold];
        // Apply the latest playback line when available, or the tapped line if the
        // MediaRemote response is still pending. Preserve exact line-start word timing.
        if (target < 0) return;
        [strongSelf setCurrentLineIndex:target animated:NO];
        [strongSelf cl_scrollToCurrentLineAnimated:NO force:YES];
        [strongSelf cl_restyleVisibleCells];
        CLLogDebug(@"[ui] tap-to-seek lyric highlight released (line=%ld)", (long)target);
    }];
    [NSRunLoop.mainRunLoop addTimer:_tapSeekTimer forMode:NSRunLoopCommonModes];
}

#pragma mark - UITableViewDelegate

- (BOOL)tableView:(UITableView *)tableView canFocusRowAtIndexPath:(NSIndexPath *)indexPath {
    return NO;
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
    return _rowsAreTimed;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:NO];
    if (!_rowsAreTimed) return;
    NSInteger row = indexPath.row;
    if (row < 0 || row >= (NSInteger)_rows.count) return;
    if (row >= (NSInteger)_lyrics.lines.count ||
        CLLyricsTextIsGap(_lyrics.lines[(NSUInteger)row].text)) return;
    id<CLLyricsPanelViewDelegate> delegate = self.delegate;
    if ([delegate respondsToSelector:@selector(lyricsPanel:didSelectLineAtIndex:)]) {
        [self cl_holdLyricsAfterTappedSeek:row];
        [delegate lyricsPanel:self didSelectLineAtIndex:row];
    }
    // Clear any prior pan-induced auto-scroll block. Wireless sync holds the
    // highlight separately until the audio output has caught up.
    _autoScrollBlockedUntil = 0.0;
    [_resumeTimer invalidate];
    _resumeTimer = nil;
}

#pragma mark - Optional touch gestures (the table itself remains non-interactive)

// The gestures belong to the outer UIView, never the UITableView: a scrollable table would
// steal rotary focus from the host transport controls on CarPlay.
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)recognizer {
    if (recognizer == _touchPan) {
        CGPoint velocity = [_touchPan velocityInView:self];
        return fabs(velocity.y) >= fabs(velocity.x);
    }
    return YES;
}

- (void)cl_handleTouchPan:(UIPanGestureRecognizer *)gesture {
    if (!self.userInteractionEnabled || !_rowsAreTimed) return;
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            CLLogDebug(@"[ui] lyric touch pan began (rows=%lu)", (unsigned long)_rows.count);
            _userIsDragging = YES;
            [_resumeTimer invalidate];
            _resumeTimer = nil;
            break;
        case UIGestureRecognizerStateChanged: {
            CGPoint translation = [gesture translationInView:self];
            [gesture setTranslation:CGPointZero inView:self];
            CGFloat bottom = MAX(-_tableView.contentInset.top,
                                 _tableView.contentSize.height - _tableView.bounds.size.height +
                                 _tableView.contentInset.bottom);
            CGFloat y = _tableView.contentOffset.y - translation.y;
            y = MAX(-_tableView.contentInset.top, MIN(bottom, y));
            [_tableView setContentOffset:CGPointMake(0, y) animated:NO];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled:
        case UIGestureRecognizerStateFailed:
            _userIsDragging = NO;
            [self cl_suspendAutoScroll];
            CLLogDebug(@"[ui] lyric touch pan ended (offset=%.1f, return=%.1fs)",
                       _tableView.contentOffset.y, _snapBackSeconds);
            break;
        default:
            break;
    }
}

- (void)cl_handleTouchTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state != UIGestureRecognizerStateRecognized ||
        !self.userInteractionEnabled || !_rowsAreTimed) return;
    NSIndexPath *index = [_tableView indexPathForRowAtPoint:[gesture locationInView:_tableView]];
    CLLogDebug(@"[ui] lyric touch tap recognized (row=%ld)", (long)(index ? index.row : -1));
    if (!index) return;
    [self tableView:_tableView didSelectRowAtIndexPath:index];
}

#pragma mark - UIScrollViewDelegate

- (void)scrollViewWillBeginDragging:(UIScrollView *)scrollView {
    _userIsDragging = YES;
    _autoScrollBlockedUntil = CFAbsoluteTimeGetCurrent() +
                             (_snapBackSeconds > 0 ? _snapBackSeconds : CLLyricsPanelAutoScrollPause);
    [_resumeTimer invalidate];
    _resumeTimer = nil;
}

- (void)scrollViewDidEndDragging:(UIScrollView *)scrollView willDecelerate:(BOOL)decelerate {
    _userIsDragging = NO;
    if (!decelerate) [self cl_suspendAutoScroll];
}

- (void)scrollViewDidEndDecelerating:(UIScrollView *)scrollView {
    _userIsDragging = NO;
    [self cl_suspendAutoScroll];
}

- (void)scrollViewDidEndScrollingAnimation:(UIScrollView *)scrollView {
    // Our own animated scrolls end here too; nothing to do, but keep the flag honest.
    _userIsDragging = NO;
}

@end
