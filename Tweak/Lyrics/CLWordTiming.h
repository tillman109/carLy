// Word timing for the line-highlight -> word-highlight feature. Foundation only, no side effects.
//
// Apple Music's TTML (and word-tagged LRC) carry real per-word times; those arrive on
// CLLyricLine.words. Spotify and LRCLIB only time whole lines, so for those the UI may *estimate*:
// the line's words share the time until the next line, weighted by length. It is a guess (a singer
// can rush or hold a word) but it reads as a steady sweep, which is what the eye wants.
#import <Foundation/Foundation.h>
#import "Lyrics/CLLyricsTypes.h"

NS_ASSUME_NONNULL_BEGIN

/// Splits `text` on whitespace and spreads its words over `available` seconds from `start`,
/// each word's share proportional to its length (plus one, so short words and bare punctuation
/// still take a beat). A gap longer than a few seconds is assumed to hold a pause, so the words
/// are packed into the part of it a singer would plausibly fill. nil for empty text or a
/// non-positive/non-finite time.
NSArray<CLLyricWord *> *_Nullable CLEstimatedWords(NSString *_Nullable text,
                                                   NSTimeInterval start,
                                                   NSTimeInterval available);

/// The words to highlight for one displayed row. `displayText` is the row's text as drawn (the
/// line's text, trimmed); `nextLineTime` is the next line's start, or NAN for the last line.
///   * the line's own timed words when it has them (ranges are re-based if `displayText` is the
///     line text with its outer whitespace trimmed);
///   * otherwise an estimate when `estimate` is YES;
///   * otherwise nil: the row is highlighted as a whole line.
NSArray<CLLyricWord *> *_Nullable CLWordsForLine(NSString *displayText,
                                                 CLLyricLine *line,
                                                 NSTimeInterval nextLineTime,
                                                 BOOL estimate);

NS_ASSUME_NONNULL_END
