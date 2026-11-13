import Foundation

/// A listening session's transcript as text: a header, then each finished sentence with the clock time it
/// began, what was said, and its translation (the second pass's, once it has revised the sentence).
public enum TranscriptText {
    public struct Entry: Equatable, Sendable {
        public var started: Date
        public var source: String
        public var translation: String

        public init(started: Date, source: String, translation: String) {
            self.started = started
            self.source = source
            self.translation = translation
        }
    }

    public static func text(started: Date, languages: String, entries: [Entry], timeZone: TimeZone = .current) -> String {
        var out = "Universal Translator transcript, \(format(started, "yyyy-MM-dd HH:mm:ss", timeZone))\n\(languages)\n"
        for e in entries {
            out += "\n[\(format(e.started, "HH:mm:ss", timeZone))] \(e.source)\n→ \(e.translation)\n"
        }
        return out
    }

    /// "Transcript 2026-10-25 14.03.12.txt": sorts by time, and has no characters Finder shows oddly.
    public static func fileName(started: Date, timeZone: TimeZone = .current) -> String {
        "Transcript \(format(started, "yyyy-MM-dd HH.mm.ss", timeZone)).txt"
    }

    private static func format(_ date: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: date)
    }
}
