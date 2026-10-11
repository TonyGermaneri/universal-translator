import Foundation

/// How simultaneous translation behaves for a particular *target* language.
///
/// Agreement between consecutive translations is measured in `unit`s: words for languages written with
/// spaces, characters for Chinese and Japanese (then trimmed back to a safe boundary so a commit never ends
/// halfway through a word or before its particle). Verb-final targets (Japanese, Korean) reorder more, so
/// they get a longer `maxDelay` before a commit is forced.
public struct LanguageProfile: Equatable, Sendable {
    public enum Unit: Equatable, Sendable { case word, character }

    public var code: String
    public var unit: Unit
    /// Seconds new source words may go without any committed translation before a commit is forced.
    public var maxDelay: Double
    /// Units at the end of the provisional (ghost) tail that are hidden because they're the least stable.
    public var maskK: Int
    /// For character units: a commit may only end right after one of these.
    public var safeBoundaries: Set<Character>
    /// Extra guidance for LLM translators (interpreter style suited to the language's word order).
    public var promptHint: String

    public init(code: String, unit: Unit, maxDelay: Double, maskK: Int, safeBoundaries: Set<Character> = [], promptHint: String = "") {
        self.code = code
        self.unit = unit
        self.maxDelay = maxDelay
        self.maskK = maskK
        self.safeBoundaries = safeBoundaries
        self.promptHint = promptHint
    }

    public static func forTarget(_ code: String) -> LanguageProfile {
        let base = code.split(separator: "-").first.map(String.init)?.lowercased() ?? code
        switch base {
        case "ja":
            return LanguageProfile(
                code: "ja", unit: .character, maxDelay: 4.5, maskK: 3,
                safeBoundaries: Set("、。！？」』）・はがをにでともへやのてね"),
                promptHint: "Translate clause by clause in the order spoken, the way a simultaneous interpreter would; prefer short sentences over long reordered ones."
            )
        case "zh":
            return LanguageProfile(
                code: "zh", unit: .character, maxDelay: 3.5, maskK: 2,
                safeBoundaries: Set("，。！？、；：」』）的了"),
                promptHint: "Translate clause by clause in the order spoken; prefer short sentences."
            )
        case "ko":
            return LanguageProfile(
                code: "ko", unit: .word, maxDelay: 4.5, maskK: 1,
                promptHint: "Translate clause by clause in the order spoken, the way a simultaneous interpreter would; prefer short sentences over long reordered ones."
            )
        case "de", "nl":
            return LanguageProfile(code: base, unit: .word, maxDelay: 3.0, maskK: 2)
        case "tr", "hi", "fa", "ur", "bn":
            return LanguageProfile(code: base, unit: .word, maxDelay: 4.0, maskK: 1)
        case "th":
            return LanguageProfile(code: base, unit: .character, maxDelay: 3.5, maskK: 3, safeBoundaries: Set(" ๆฯ"))
        default:
            return LanguageProfile(code: base, unit: .word, maxDelay: 2.8, maskK: 2)
        }
    }

    /// Applies the user's Responsive (0) ↔ Stable (1) preference: more stability means waiting longer
    /// before forcing a commit and hiding more of the unstable tail.
    public func tuned(stability: Double) -> LanguageProfile {
        let s = min(max(stability, 0), 1)
        var p = self
        p.maxDelay = maxDelay * (0.65 + 0.7 * s)
        p.maskK = max(0, maskK + Int(((s - 0.5) * 2).rounded()))
        return p
    }

    // MARK: - Units

    /// Splits text into agreement units. Word units keep their leading whitespace so they re-join losslessly.
    public func units(_ text: String) -> [String] {
        switch unit {
        case .character:
            return text.map(String.init)
        case .word:
            var result: [String] = []
            var current = ""
            var sawNonSpace = false
            for ch in text {
                if ch.isWhitespace, sawNonSpace {
                    result.append(current)
                    current = ""
                    sawNonSpace = false
                }
                current.append(ch)
                if !ch.isWhitespace { sawNonSpace = true }
            }
            if !current.isEmpty { result.append(current) }
            return result
        }
    }

    /// Longest prefix (in units) the two texts share.
    public func agreedPrefix(_ a: String, _ b: String) -> String {
        let ua = units(a), ub = units(b)
        var n = 0
        while n < ua.count, n < ub.count, ua[n] == ub[n] { n += 1 }
        return ua.prefix(n).joined()
    }

    /// Trims a candidate commit back so it ends on a safe boundary (character units only).
    public func trimToSafeBoundary(_ text: String) -> String {
        guard unit == .character, !safeBoundaries.isEmpty else { return text }
        guard let index = text.lastIndex(where: { safeBoundaries.contains($0) }) else { return "" }
        return String(text[...index])
    }

    /// Drops the last `k` units (used for the forced commit and the display mask).
    public func dropLast(_ text: String, units k: Int) -> String {
        guard k > 0 else { return text }
        let u = units(text)
        return u.dropLast(min(k, u.count)).joined()
    }

    /// Characters that end a sentence in the target language.
    public static let sentenceFinal: Set<Character> = [".", "!", "?", "。", "！", "？", "…"]

    /// Removes sentence-final punctuation the model adds to an unfinished source.
    public func stripFinalPunctuation(_ text: String) -> String {
        var s = text
        while let last = s.last, Self.sentenceFinal.contains(last) || last.isWhitespace { s.removeLast() }
        return s
    }
}
