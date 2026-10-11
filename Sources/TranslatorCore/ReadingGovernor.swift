import Foundation

/// Keeps roll-up captions readable: a line may only scroll away once it has been on screen for its reading
/// time. When new text arrives faster than that (a burst at the end of a sentence), the caption grows by up to
/// `extraLines` for a moment instead of dropping a line the reader hasn't finished. New text is never delayed.
public struct ReadingGovernor: Sendable {
    /// Reading speed in characters per second for alphabetic scripts (0 = off). Guidelines suggest 15–20 for
    /// adults; Japanese and Chinese characters count as two (see `readingUnits`).
    public var charactersPerSecond: Double
    public var extraLines: Int
    /// No line leaves sooner than this.
    public var minimumDuration: Double = 1.0
    private var shownAt: [String: Double] = [:]

    public init(charactersPerSecond: Double = 17, extraLines: Int = 1) {
        self.charactersPerSecond = charactersPerSecond
        self.extraLines = extraLines
    }

    /// How many of the wrapped `lines` (oldest first) to show, normally `maxLines`, and when to look again
    /// because a held line's time is up.
    public mutating func visibleCount(lines: [String], maxLines: Int, now: Double) -> (count: Int, recheckAt: Double?) {
        let n = lines.count
        var count = min(n, maxLines)
        var recheck: Double?
        if charactersPerSecond > 0 {
            while count < min(n, maxLines + extraLines) {
                // The line that would scroll out next. Lines never shown can't be held back.
                let line = lines[n - count - 1]
                guard let shown = shownAt[line] else { break }
                let due = shown + readingTime(line)
                guard now < due else { break }
                count += 1
                recheck = min(recheck ?? due, due)
            }
        }
        var kept: [String: Double] = [:]
        for line in lines.suffix(count) { kept[line] = shownAt[line] ?? now }
        shownAt = kept
        return (count, recheck)
    }

    public func readingTime(_ text: String) -> Double {
        max(minimumDuration, Self.readingUnits(text) / max(charactersPerSecond, 1))
    }

    /// Characters weighted by how long they take to read: a Chinese character or kana counts as two Latin
    /// letters (17 → 8.5 per second, near the 9 that subtitle guidelines give Chinese and typical Japanese
    /// reading speed), Hangul as 1.4 (about 12 per second, the Korean guideline).
    public static func readingUnits(_ text: String) -> Double {
        var units = 0.0
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            switch scalar.value {
            case 0x3040...0x30FF, 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF: units += 2
            case 0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F: units += 1.4
            default: units += 1
            }
        }
        return units
    }

    public mutating func reset() {
        shownAt = [:]
    }
}
