#import "UI/CLLyricsFullScreenView.h"
#import "UI/CLLayoutGeometry.h"
#import "UI/CLLyricsStyle.h"
#import "UI/CLSongMarquee.h"

#import <objc/message.h>

// Every measure of this view is in UI/CLLayoutGeometry.h (CLLayoutFullScreen*), shared with the
// settings preview. Only the button metrics below are this view's own.
static const CGFloat kCLFullScreenRowHeight = CLLayoutFullScreenRowHeight;
static const CGFloat kCLFullScreenRowLeading = CLLayoutFullScreenRowLeading;
static const CGFloat kCLFullScreenRowTrailing = CLLayoutFullScreenRowTrailing;
static const CGFloat kCLFullScreenProgressHeight = CLLayoutFullScreenProgressHeight;
static const CGFloat kCLFullScreenProgressBarThickness = CLLayoutFullScreenProgressThickness;
/// Keep the same touch-target width as the host while centring all three controls.
static const CGFloat kCLFullScreenTransportExtraWidth = 20.0;
static const CGFloat kCLFullScreenPlayModeButtonWidth = 44.0;
static const CGFloat kCLFullScreenPlayModeButtonHeight = CLLayoutFullScreenPlayModeHeight;
/// The progress line's time labels and their gap to the bar.
static const CGFloat kCLFullScreenTimeWidth = 40.0;
static const CGFloat kCLFullScreenTimeGap = 8.0;
static const NSTimeInterval kCLFullScreenProgressTick = 0.5;

@implementation CLLyricsFullScreenView {
    CLLyricsPanelView *_panelView;
    UILabel *_statusLabel;
    UILabel *_titleLabel;
    UILabel *_artistLabel;
    CLSongMarquee *_titleMarquee;
    CLSongMarquee *_artistMarquee;
    UIButton *_previousButton;
    UIButton *_playButton;
    UIButton *_nextButton;
    UIButton *_closeButton;
    BOOL _playing;
    /// YES once the host's own play/pause image was handed over; -setPlaying: then stays out of it.
    BOOL _hasHostPlayImage;
    CGFloat _buttonHeight;
    NSArray<NSLayoutConstraint *> *_transportSizeConstraints;
    UIStackView *_textStack;
    UIStackView *_playModeStack;
    NSArray<UIButton *> *_sourcePlayModeButtons;  // host owns its real controls
    NSMutableArray<UIButton *> *_mirrorPlayModeButtons;
    CGFloat _hostPlayModeWidth;
    NSLayoutConstraint *_playModeWidthConstraint;
    NSLayoutConstraint *_playModeBottomConstraint;
    NSLayoutConstraint *_progressBelowTransportConstraint;
    NSLayoutConstraint *_progressAbovePlayModeConstraint;
    NSLayoutConstraint *_songBelowTransportConstraint;
    NSLayoutConstraint *_lyricsBelowSongConstraint;
    // Progress (display only).
    UIView *_progressRow;
    UIView *_progressTrack;
    UIView *_progressFill;
    UILabel *_elapsedLabel;
    UILabel *_remainingLabel;
    CLPlaybackState *_playbackState;
    CGFloat _progressFraction;
    NSTimer *_progressTimer;
    BOOL _progressHiddenByPreference;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self cl_build];
    return self;
}

- (instancetype)initWithCoder:(NSCoder *)coder {
    self = [super initWithCoder:coder];
    if (self) [self cl_build];
    return self;
}

- (CLLyricsPanelView *)panelView {
    return _panelView;
}

- (NSArray<UIButton *> *)controlButtons {
    return @[ _previousButton, _playButton, _nextButton, _closeButton ];
}

- (NSArray<UIButton *> *)playModeButtons {
    return [(_mirrorPlayModeButtons ?: @[]) arrayByAddingObject:_closeButton];
}

#pragma mark - Building

UIButton *CLMakeHostStyleButton(BOOL prefersWhite) {
    Class modern = NSClassFromString(@"CPUIModernButton");
    UIButton *button = nil;
    if (modern && [modern isSubclassOfClass:UIButton.class]) {
        // -[CPUIPlayModeControlView initWithFrame:] / -[CPUITransportControlView initWithFrame:]
        // (iOS 17.3): +buttonWithType:0, an image, and for the transport row prefersWhite.
        button = [modern buttonWithType:UIButtonTypeCustom];
        SEL white = NSSelectorFromString(@"setPrefersWhiteInDefaultState:");
        if (prefersWhite && [button respondsToSelector:white]) {
            ((void (*)(id, SEL, BOOL))objc_msgSend)(button, white, YES);
        }
    }
    if (!button) {
        button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.tintColor = UIColor.labelColor;
    }
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.contentMode = UIViewContentModeCenter;
    button.imageView.contentMode = UIViewContentModeCenter;
    return button;
}

/// Equal strings, or both empty/nil.
static BOOL CLSameText(NSString *a, NSString *b) {
    if (a.length == 0 && b.length == 0) return YES;
    return [a isEqualToString:b];
}

static UIImage *CLSymbol(NSString *name, CGFloat pointSize, UIImageSymbolWeight weight) {
    UIImageSymbolConfiguration *configuration = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:weight];
    return [[UIImage systemImageNamed:name withConfiguration:configuration] imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
}

- (UIButton *)cl_transportButtonWithSymbol:(NSString *)symbol label:(NSString *)label {
    UIButton *button = CLMakeHostStyleButton(YES);
    [button setImage:CLSymbol(symbol, 22.0, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
    button.accessibilityLabel = label;
    [button addTarget:self action:@selector(cl_transportTouchDown:) forControlEvents:UIControlEventTouchDown];
    [button addTarget:self action:@selector(cl_transportTouchUp:)
     forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    return button;
}

- (void)cl_build {
    self.backgroundColor = UIColor.clearColor;
    self.opaque = NO;

    _panelView = [[CLLyricsPanelView alloc] initWithFrame:CGRectZero];
    _panelView.translatesAutoresizingMaskIntoConstraints = NO;
    _panelView.fit = CLLayoutPanelFitRows;
    _panelView.hidden = YES;
    [self addSubview:_panelView];

    _statusLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _statusLabel.userInteractionEnabled = NO;
    _statusLabel.textAlignment = NSTextAlignmentCenter;
    _statusLabel.numberOfLines = 2;
    _statusLabel.font = [UIFont systemFontOfSize:20.0 weight:UIFontWeightSemibold];
    _statusLabel.textColor = UIColor.secondaryLabelColor;
    _statusLabel.hidden = YES;
    [self addSubview:_statusLabel];

    _titleLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _titleLabel.font = [UIFont systemFontOfSize:16.0 weight:UIFontWeightSemibold];
    _titleLabel.textColor = UIColor.labelColor;
    _titleLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _titleLabel.textAlignment = NSTextAlignmentCenter;
    _artistLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _artistLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _artistLabel.font = [UIFont systemFontOfSize:13.0 weight:UIFontWeightRegular];
    _artistLabel.textColor = UIColor.secondaryLabelColor;
    _artistLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _artistLabel.textAlignment = NSTextAlignmentCenter;
    UIStackView *text = [[UIStackView alloc] initWithArrangedSubviews:@[ _titleLabel, _artistLabel ]];
    text.translatesAutoresizingMaskIntoConstraints = NO;
    text.axis = UILayoutConstraintAxisVertical;
    text.alignment = UIStackViewAlignmentCenter;
    text.spacing = 1.0;
    text.userInteractionEnabled = NO;
    [text setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    [self addSubview:text];
    _textStack = text;
    _titleMarquee = [CLSongMarquee new];
    _titleMarquee.role = @"full-screen title";
    _artistMarquee = [CLSongMarquee new];
    _artistMarquee.role = @"full-screen artist";
    [self cl_buildProgressRow];

    // The transport row: CarPlay's own button class, glyphs and height (the host's images replace
    // these fallbacks as soon as the customizer hands them over).
    _previousButton = [self cl_transportButtonWithSymbol:@"backward.fill" label:@"Previous"];
    _playButton = [self cl_transportButtonWithSymbol:@"play.fill" label:@"Play"];
    _nextButton = [self cl_transportButtonWithSymbol:@"forward.fill" label:@"Next"];
    _buttonHeight = CLLayoutHostTransportSmall;
    NSMutableArray<NSLayoutConstraint *> *sizes = [NSMutableArray array];
    for (UIButton *button in @[ _previousButton, _playButton, _nextButton ]) {
        NSLayoutConstraint *width = [button.widthAnchor constraintEqualToConstant:_buttonHeight + kCLFullScreenTransportExtraWidth];
        NSLayoutConstraint *height = [button.heightAnchor constraintEqualToConstant:_buttonHeight];
        [sizes addObjectsFromArray:@[ width, height ]];
    }
    _transportSizeConstraints = sizes;

    // On Now Playing the microphone is the fifth PLAY-MODE control, not an
    // oversized transport button. Keep that same size/row in the lyrics view.
    _closeButton = CLMakeHostStyleButton(NO);
    [_closeButton setImage:CLSymbol(@"mic", 15.0, UIImageSymbolWeightRegular) forState:UIControlStateNormal];
    _closeButton.accessibilityLabel = @"Hide Lyrics";
    SEL staySelected = NSSelectorFromString(@"setShouldStaySelected:");
    if ([_closeButton respondsToSelector:staySelected]) {
        ((void (*)(id, SEL, BOOL))objc_msgSend)(_closeButton, staySelected, YES);
    }
    _closeButton.selected = YES;
    if (!NSClassFromString(@"CPUIModernButton")) {
        _closeButton.backgroundColor = UIColor.tertiarySystemFillColor;
        _closeButton.layer.cornerRadius = 8.0;
    }
    [_closeButton addTarget:self action:@selector(cl_closeTapped:) forControlEvents:UIControlEventTouchUpInside];
    [sizes addObjectsFromArray:@[
        [_closeButton.widthAnchor constraintEqualToConstant:kCLFullScreenPlayModeButtonWidth],
        [_closeButton.heightAnchor constraintEqualToConstant:kCLFullScreenPlayModeButtonHeight],
    ]];
    [NSLayoutConstraint activateConstraints:sizes];

    // Three equally-spaced host-sized transport buttons across 70% of the
    // screen, matching their Now Playing x positions (left / centre / right).
    UIStackView *buttons = [[UIStackView alloc] initWithArrangedSubviews:@[ _previousButton, _playButton, _nextButton ]];
    buttons.translatesAutoresizingMaskIntoConstraints = NO;
    buttons.axis = UILayoutConstraintAxisHorizontal;
    buttons.alignment = UIStackViewAlignmentCenter;
    buttons.distribution = UIStackViewDistributionEqualSpacing;
    [self addSubview:buttons];

    // The native host owns shuffle / repeat / queue / extra controls. Mirrors
    // below show its real icons and forward taps to the hidden host controls.
    // The microphone closes full-screen, just as it did in the previous build.
    _mirrorPlayModeButtons = [NSMutableArray array];
    _sourcePlayModeButtons = @[];
    _playModeStack = [[UIStackView alloc] initWithArrangedSubviews:@[ _closeButton ]];
    _playModeStack.translatesAutoresizingMaskIntoConstraints = NO;
    _playModeStack.axis = UILayoutConstraintAxisHorizontal;
    _playModeStack.alignment = UIStackViewAlignmentCenter;
    _playModeStack.distribution = UIStackViewDistributionEqualSpacing;
    [self addSubview:_playModeStack];

    _playModeWidthConstraint = [_playModeStack.widthAnchor constraintEqualToConstant:kCLFullScreenPlayModeButtonWidth];
    _playModeBottomConstraint = [_playModeStack.bottomAnchor constraintEqualToAnchor:self.bottomAnchor];
    _progressAbovePlayModeConstraint = [_progressRow.bottomAnchor constraintEqualToAnchor:_playModeStack.topAnchor];
    _progressBelowTransportConstraint = [buttons.bottomAnchor constraintEqualToAnchor:_progressRow.topAnchor];
    _songBelowTransportConstraint = [text.bottomAnchor constraintEqualToAnchor:buttons.topAnchor];
    _lyricsBelowSongConstraint = [_panelView.bottomAnchor constraintEqualToAnchor:text.topAnchor];

    [NSLayoutConstraint activateConstraints:@[
        [_panelView.topAnchor constraintEqualToAnchor:self.topAnchor constant:CLLayoutFullScreenLyricsTop],
        [_panelView.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:CLLayoutFullPanelLyricsInset],
        [self.trailingAnchor constraintEqualToAnchor:_panelView.trailingAnchor constant:CLLayoutFullPanelLyricsInset],

        [_statusLabel.centerYAnchor constraintEqualToAnchor:_panelView.centerYAnchor],
        [_statusLabel.leadingAnchor constraintEqualToAnchor:_panelView.leadingAnchor constant:CLLayoutPanelTextInset],
        [_panelView.trailingAnchor constraintEqualToAnchor:_statusLabel.trailingAnchor constant:CLLayoutPanelTextInset],

        [_playModeStack.heightAnchor constraintEqualToConstant:kCLFullScreenPlayModeButtonHeight],
        [_playModeStack.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        _playModeWidthConstraint,
        _playModeBottomConstraint,

        [_progressRow.heightAnchor constraintEqualToConstant:kCLFullScreenProgressHeight],
        _progressAbovePlayModeConstraint,
        [_progressRow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:kCLFullScreenRowLeading],
        [self.trailingAnchor constraintEqualToAnchor:_progressRow.trailingAnchor constant:kCLFullScreenRowTrailing],

        [buttons.heightAnchor constraintEqualToConstant:kCLFullScreenRowHeight],
        [buttons.widthAnchor constraintEqualToAnchor:self.widthAnchor multiplier:0.70],
        [buttons.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        _progressBelowTransportConstraint,

        // Song metadata sits between the lyrics and transport controls, never
        // beside/under a transport button. Its marquees continue working.
        [text.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
        [text.widthAnchor constraintLessThanOrEqualToAnchor:self.widthAnchor multiplier:0.62],
        [text.heightAnchor constraintLessThanOrEqualToConstant:CLLayoutFullScreenSongInfoHeight],
        _songBelowTransportConstraint,
        _lyricsBelowSongConstraint,
    ]];
    [self cl_updateFooterMetrics];
    [self setPlaying:NO];
}

- (void)cl_buildProgressRow {
    _progressRow = [[UIView alloc] initWithFrame:CGRectZero];
    _progressRow.translatesAutoresizingMaskIntoConstraints = NO;
    _progressRow.userInteractionEnabled = NO;
    _progressRow.hidden = YES;
    [self addSubview:_progressRow];

    UILabel *(^timeLabel)(NSTextAlignment) = ^UILabel *(NSTextAlignment alignment) {
        UILabel *label = [[UILabel alloc] initWithFrame:CGRectZero];
        label.translatesAutoresizingMaskIntoConstraints = NO;
        label.font = [UIFont monospacedDigitSystemFontOfSize:11.0 weight:UIFontWeightMedium];
        label.textColor = UIColor.secondaryLabelColor;
        label.textAlignment = alignment;
        return label;
    };
    _elapsedLabel = timeLabel(NSTextAlignmentLeft);
    _remainingLabel = timeLabel(NSTextAlignmentRight);
    _progressTrack = [[UIView alloc] initWithFrame:CGRectZero];
    _progressTrack.translatesAutoresizingMaskIntoConstraints = NO;
    _progressTrack.backgroundColor = [UIColor.labelColor colorWithAlphaComponent:0.25];
    _progressTrack.layer.cornerRadius = kCLFullScreenProgressBarThickness / 2.0;
    _progressTrack.clipsToBounds = YES;
    // The fill is laid out by hand (a width that changes twice a second is not a constraint).
    _progressFill = [[UIView alloc] initWithFrame:CGRectZero];
    _progressFill.backgroundColor = UIColor.labelColor;
    _progressFill.layer.cornerRadius = kCLFullScreenProgressBarThickness / 2.0;
    [_progressTrack addSubview:_progressFill];
    for (UIView *view in @[ _elapsedLabel, _progressTrack, _remainingLabel ]) [_progressRow addSubview:view];

    [NSLayoutConstraint activateConstraints:@[
        [_elapsedLabel.leadingAnchor constraintEqualToAnchor:_progressRow.leadingAnchor],
        [_elapsedLabel.widthAnchor constraintEqualToConstant:kCLFullScreenTimeWidth],
        [_elapsedLabel.centerYAnchor constraintEqualToAnchor:_progressRow.centerYAnchor],
        [_progressRow.trailingAnchor constraintEqualToAnchor:_remainingLabel.trailingAnchor],
        [_remainingLabel.widthAnchor constraintEqualToConstant:kCLFullScreenTimeWidth],
        [_remainingLabel.centerYAnchor constraintEqualToAnchor:_progressRow.centerYAnchor],
        [_progressTrack.leadingAnchor constraintEqualToAnchor:_elapsedLabel.trailingAnchor constant:kCLFullScreenTimeGap],
        [_remainingLabel.leadingAnchor constraintEqualToAnchor:_progressTrack.trailingAnchor constant:kCLFullScreenTimeGap],
        [_progressTrack.heightAnchor constraintEqualToConstant:kCLFullScreenProgressBarThickness],
        [_progressTrack.centerYAnchor constraintEqualToAnchor:_progressRow.centerYAnchor],
    ]];
}

- (void)cl_updateFooterMetrics {
    // Readable on short displays, exact stock Now Playing row spacing at >=700pt.
    CGFloat scale = CLLayoutFullScreenSpacingScale(CGRectGetHeight(self.bounds));
    _playModeBottomConstraint.constant = -CLLayoutFullScreenPlayModeBottom * scale;
    _progressAbovePlayModeConstraint.constant = -CLLayoutFullScreenProgressAbovePlayMode * scale;
    _progressBelowTransportConstraint.constant = -CLLayoutFullScreenProgressBelowTransport * scale;
    _songBelowTransportConstraint.constant = -CLLayoutFullScreenSongInfoGap * scale;
    _lyricsBelowSongConstraint.constant = -CLLayoutFullScreenLyricsGap * scale;

    NSUInteger count = _mirrorPlayModeButtons.count + 1;
    CGFloat minimum = kCLFullScreenPlayModeButtonWidth * count;
    CGFloat natural = minimum + 16.0 * (count ? count - 1 : 0);
    CGFloat requested = _hostPlayModeWidth >= minimum ? _hostPlayModeWidth : natural;
    CGFloat limit = MAX(minimum, CGRectGetWidth(self.bounds) - 24.0);
    CGFloat width = MIN(requested, limit);
    if (fabs(_playModeWidthConstraint.constant - width) > 0.5) _playModeWidthConstraint.constant = width;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [self cl_updateFooterMetrics];
    [self cl_layoutProgressFill];
    [self cl_updateSongMarquees];
}

// The full-screen labels are not Spotify's labels and must be animated independently.
// This runs after layout (when compressed UILabel widths are known); the helper keeps
// the same layer/animation while nothing changes, so playback ticks don't restart it.
- (void)cl_updateSongMarquees {
    if (_textStack.isHidden) {
        [_titleMarquee stop];
        [_artistMarquee stop];
        return;
    }
    [_titleMarquee updateForLabel:_titleLabel sourceText:_titleLabel.text];
    [_artistMarquee updateForLabel:_artistLabel sourceText:_artistLabel.text];
}

- (void)cl_layoutProgressFill {
    CGRect track = _progressTrack.bounds;
    CGRect fill = CGRectMake(0.0, 0.0, round(CGRectGetWidth(track) * _progressFraction), CGRectGetHeight(track));
    if (!CGRectEqualToRect(_progressFill.frame, fill)) _progressFill.frame = fill;
}

/// "3:07" / "1:02:07".
static NSString *CLTimeText(NSTimeInterval seconds) {
    NSInteger total = (NSInteger)floor(MAX(0.0, seconds));
    NSInteger hours = total / 3600, minutes = (total / 60) % 60, rest = total % 60;
    if (hours > 0) return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)hours, (long)minutes, (long)rest];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)minutes, (long)rest];
}

/// Where the song is now (interpolated from the last MediaRemote sample), on the bar and in the
/// two times; hidden while the length is unknown (radio, some ads).
- (void)cl_updateProgress {
    CLPlaybackState *state = _playbackState;
    NSTimeInterval duration = state.duration;
    BOOL known = duration > 0.0 && isfinite(duration);
    BOOL shown = known && !_progressHiddenByPreference;
    if (_progressRow.isHidden == shown) _progressRow.hidden = !shown;
    if (!shown) return;
    NSTimeInterval elapsed = MIN(duration, MAX(0.0, [state elapsedNow]));
    _progressFraction = (CGFloat)(elapsed / duration);
    NSString *elapsedText = CLTimeText(elapsed);
    NSString *remainingText = [@"-" stringByAppendingString:CLTimeText(duration - elapsed)];
    if (![_elapsedLabel.text isEqualToString:elapsedText]) _elapsedLabel.text = elapsedText;
    if (![_remainingLabel.text isEqualToString:remainingText]) _remainingLabel.text = remainingText;
    [self cl_layoutProgressFill];
}

- (void)didMoveToWindow {
    [super didMoveToWindow];
    [_progressTimer invalidate];
    _progressTimer = nil;
    if (!self.window) {
        [_titleMarquee stop];
        [_artistMarquee stop];
        return;
    }
    [self setNeedsLayout];
    // A block timer holding self weakly: the view can go away without anyone stopping it first.
    __weak typeof(self) weakSelf = self;
    _progressTimer = [NSTimer timerWithTimeInterval:kCLFullScreenProgressTick repeats:YES block:^(NSTimer *timer) {
        CLUISafePerform(@"full screen progress", ^{ [weakSelf cl_updateProgress]; });
    }];
    [NSRunLoop.mainRunLoop addTimer:_progressTimer forMode:NSRunLoopCommonModes];
    [self cl_updateProgress];
}

- (void)dealloc {
    [_progressTimer invalidate];
    [_titleMarquee stop];
    [_artistMarquee stop];
}

/// Knob focus lands on play/pause first (like CarPlay's own player), the microphone next.
- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    return @[ _playButton, _closeButton ];
}

#pragma mark - Public API

- (void)setTitle:(NSString *)title artist:(NSString *)artist {
    NSString *titleText = title.length ? title : nil;
    NSString *artistText = artist.length ? artist : nil;
    if (!CLSameText(_titleLabel.text, titleText)) _titleLabel.text = titleText;
    if (!CLSameText(_artistLabel.text, artistText)) _artistLabel.text = artistText;
    if (_titleLabel.isHidden != (titleText == nil)) _titleLabel.hidden = (titleText == nil);
    if (_artistLabel.isHidden != (artistText == nil)) _artistLabel.hidden = (artistText == nil);
    [self cl_updateSongMarquees];
}

- (void)setPlaying:(BOOL)playing {
    _playing = playing;
    _playButton.accessibilityLabel = playing ? @"Pause" : @"Play";
    if (_hasHostPlayImage) return;
    [_playButton setImage:CLSymbol(playing ? @"pause.fill" : @"play.fill", 22.0, UIImageSymbolWeightSemibold)
                 forState:UIControlStateNormal];
}

- (void)setPreviousImage:(UIImage *)previous playPauseImage:(UIImage *)playPause
               nextImage:(UIImage *)next buttonHeight:(CGFloat)buttonHeight {
    if (previous && [_previousButton imageForState:UIControlStateNormal] != previous) {
        [_previousButton setImage:previous forState:UIControlStateNormal];
    }
    if (next && [_nextButton imageForState:UIControlStateNormal] != next) {
        [_nextButton setImage:next forState:UIControlStateNormal];
    }
    if (playPause) {
        _hasHostPlayImage = YES;
        if ([_playButton imageForState:UIControlStateNormal] != playPause) {
            [_playButton setImage:playPause forState:UIControlStateNormal];
        }
    }
    // The row is 44 pt tall: the host's two sizes (36, 44) fit, anything else keeps the last one.
    if (buttonHeight >= 20.0 && buttonHeight <= kCLFullScreenRowHeight && fabs(buttonHeight - _buttonHeight) > 0.5) {
        _buttonHeight = buttonHeight;
        for (NSLayoutConstraint *constraint in _transportSizeConstraints) {
            if (constraint.firstAttribute == NSLayoutAttributeWidth) constraint.constant = buttonHeight + kCLFullScreenTransportExtraWidth;
            if (constraint.firstAttribute == NSLayoutAttributeHeight) constraint.constant = buttonHeight;
        }
    }
}

- (void)cl_syncHostPlayModeImages {
    NSUInteger count = MIN(_mirrorPlayModeButtons.count, _sourcePlayModeButtons.count);
    for (NSUInteger i = 0; i < count; i++) {
        UIButton *source = _sourcePlayModeButtons[i];
        UIButton *mirror = _mirrorPlayModeButtons[i];
        for (NSNumber *stateNumber in @[ @(UIControlStateNormal), @(UIControlStateSelected), @(UIControlStateDisabled) ]) {
            UIControlState state = (UIControlState)stateNumber.unsignedIntegerValue;
            UIImage *image = [source imageForState:state];
            if (state == UIControlStateNormal && !image) image = source.currentImage;
            if (image && [mirror imageForState:state] != image) [mirror setImage:image forState:state];
        }
        mirror.enabled = source.isEnabled;
        mirror.selected = source.isSelected;
        mirror.tintColor = source.tintColor ?: UIColor.labelColor;
        mirror.accessibilityLabel = source.accessibilityLabel ?: source.titleLabel.text;
    }
}

/// The four normal play-mode actions stay Spotify's controls, mirrored on top
/// of the hidden Now Playing view. The last action is carLy's microphone.
- (void)setHostPlayModeButtons:(NSArray<UIButton *> *)sources hostWidth:(CGFloat)hostWidth {
    NSArray<UIButton *> *valid = sources ?: @[];
    if (![_sourcePlayModeButtons isEqualToArray:valid]) {
        for (UIButton *mirror in _mirrorPlayModeButtons) {
            [_playModeStack removeArrangedSubview:mirror];
            [mirror removeFromSuperview];
        }
        [_mirrorPlayModeButtons removeAllObjects];
        _sourcePlayModeButtons = [valid copy];
        NSUInteger index = 0;
        for (UIButton *source in valid) {
            UIButton *mirror = CLMakeHostStyleButton(NO);
            mirror.accessibilityLabel = source.accessibilityLabel;
            [mirror addTarget:self action:@selector(cl_hostPlayModeTapped:) forControlEvents:UIControlEventTouchUpInside];
            [NSLayoutConstraint activateConstraints:@[
                [mirror.widthAnchor constraintEqualToConstant:kCLFullScreenPlayModeButtonWidth],
                [mirror.heightAnchor constraintEqualToConstant:kCLFullScreenPlayModeButtonHeight]
            ]];
            [_playModeStack insertArrangedSubview:mirror atIndex:index++];
            [_mirrorPlayModeButtons addObject:mirror];
        }
    }
    _hostPlayModeWidth = hostWidth;
    [self cl_syncHostPlayModeImages];
    [self cl_updateFooterMetrics];
}

- (void)setMicrophoneImage:(UIImage *)image {
    if (image && [_closeButton imageForState:UIControlStateNormal] != image) {
        [_closeButton setImage:image forState:UIControlStateNormal];
    }
}

- (void)setPlaybackState:(CLPlaybackState *)state {
    _playbackState = state;
    [self cl_updateProgress];
}

- (UIView *)progressView {
    return _progressRow;
}

- (void)setProgressHidden:(BOOL)hidden {
    if (_progressHiddenByPreference == hidden) return;
    _progressHiddenByPreference = hidden;
    [self cl_updateProgress];
}

- (void)setAccentColor:(UIColor *)color {
    UIColor *fill = color ?: [UIColor colorWithWhite:1.0 alpha:0.9];
    // The full-screen artist should follow the SONG TITLE in dark appearance,
    // not an artwork accent that may be nearly black against the backdrop.
    UIColor *titleColor = [_titleMarquee visibleColorForLabel:_titleLabel] ?: UIColor.labelColor;
    UIColor *resolved = [titleColor resolvedColorWithTraitCollection:self.traitCollection];
    CGFloat r = 0, g = 0, b = 0, a = 0;
    BOOL lightTitle = [resolved getRed:&r green:&g blue:&b alpha:&a] &&
                      (0.2126*r + 0.7152*g + 0.0722*b) > 0.65 && a > 0.1;
    BOOL dark = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark || lightTitle;
    UIColor *artist = dark ? titleColor : (color ?: UIColor.secondaryLabelColor);
    if (![_progressFill.backgroundColor isEqual:fill]) _progressFill.backgroundColor = fill;
    [_artistMarquee setVisibleTextColor:artist forLabel:_artistLabel];
    [self cl_updateSongMarquees];
}

- (void)setStatusText:(NSString *)text {
    NSString *value = text.length ? text : nil;
    if (!((value == nil && _statusLabel.text == nil) || [_statusLabel.text isEqualToString:value])) _statusLabel.text = value;
    BOOL hidden = (value == nil);
    if (_statusLabel.isHidden != hidden) _statusLabel.hidden = hidden;
}

- (void)applyPrefs {
    [_panelView applyPrefs];
    [self cl_updateSongMarquees];
}

#pragma mark - Actions

// UIKit calls these straight from the touch handler, outside every hook: nothing below may raise.

- (CLPlaybackCommand)cl_commandForButton:(id)sender {
    if (sender == _previousButton) return CLPlaybackCommandPreviousTrack;
    if (sender == _nextButton) return CLPlaybackCommandNextTrack;
    return CLPlaybackCommandTogglePlayPause;
}

- (void)cl_transportTouchDown:(id)sender {
    CLUISafePerform(@"full screen transport down", ^{
        [self.delegate lyricsFullScreenView:self didSendEvents:UIControlEventTouchDown forCommand:[self cl_commandForButton:sender]];
    });
}

- (void)cl_transportTouchUp:(id)sender {
    CLUISafePerform(@"full screen transport up", ^{
        [self.delegate lyricsFullScreenView:self didSendEvents:UIControlEventTouchUpInside
                                 forCommand:[self cl_commandForButton:sender]];
    });
}

- (void)cl_hostPlayModeTapped:(UIButton *)sender {
    CLUISafePerform(@"full screen host play-mode tap", ^{
        NSUInteger index = [_mirrorPlayModeButtons indexOfObjectIdenticalTo:sender];
        if (index == NSNotFound || index >= _sourcePlayModeButtons.count) return;
        UIButton *source = _sourcePlayModeButtons[index];
        // Forward to the host's actual toggle/action. This preserves Spotify's
        // add-to-library, shuffle, repeat and radio behaviour and source state.
        [source sendActionsForControlEvents:UIControlEventTouchUpInside];
        [self cl_syncHostPlayModeImages];
    });
}

- (void)cl_closeTapped:(id)sender {
    CLUISafePerform(@"full screen close", ^{
        [self.delegate lyricsFullScreenViewDidRequestClose:self];
    });
}

@end
