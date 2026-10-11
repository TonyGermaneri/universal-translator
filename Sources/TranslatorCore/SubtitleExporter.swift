import Foundation

/// One translated chunk of a session, for transcript export.
public struct SessionEntry: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var source: String
    public var translation: String

    public init(start: Double, end: Double, source: String, translation: String) {
        self.start = start
        self.end = end
        self.source = source
        self.translation = translation
    }
}

public enum SubtitleExporter {
    /// SubRip subtitles with the translation, optionally followed by the original on a second line.
    public static func srt(_ entries: [SessionEntry], includeSource: Bool) -> String {
        entries.enumerated().map { i, e in
            let end = max(e.end, e.start + 1.0)
            var body = e.translation
            if includeSource, !e.source.isEmpty { body += "\n" + e.source }
            return "\(i + 1)\n\(timestamp(e.start, separator: ",")) --> \(timestamp(end, separator: ","))\n\(body)\n"
        }.joined(separator: "\n")
    }

    /// WebVTT captions with the translation, optionally followed by the original on a second line.
    public static func vtt(_ entries: [SessionEntry], includeSource: Bool) -> String {
        "WEBVTT\n\n" + entries.enumerated().map { i, e in
            let end = max(e.end, e.start + 1.0)
            var body = e.translation
            if includeSource, !e.source.isEmpty { body += "\n" + e.source }
            return "\(i + 1)\n\(timestamp(e.start, separator: ".")) --> \(timestamp(end, separator: "."))\n\(body)\n"
        }.joined(separator: "\n")
    }

    /// Plain text: original and translation side by side, one chunk per paragraph.
    public static func text(_ entries: [SessionEntry]) -> String {
        entries.map { "[\(timestamp($0.start, separator: "."))] \($0.source)\n→ \($0.translation)" }
            .joined(separator: "\n\n") + "\n"
    }

    static func timestamp(_ seconds: Double, separator: String) -> String {
        let ms = Int((max(0, seconds) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60_000) % 60, (ms / 1000) % 60, separator, ms % 1000)
    }
}
