import Foundation

/// A word-sized piece of recognized speech placed on the audio timeline.
///
/// Times are seconds from the start of the audio stream fed to the recognizer, so tokens,
/// voice activity and the segmenter cursor all share one clock.
public struct Token: Equatable, Sendable {
    /// Text exactly as recognized, including any leading whitespace, so tokens can be re-joined losslessly.
    public var text: String
    public var start: Double
    public var end: Double
    /// Final tokens will not be revised by the recognizer; volatile ones may still change.
    public var isFinal: Bool

    public init(text: String, start: Double, end: Double, isFinal: Bool) {
        self.text = text
        self.start = start
        self.end = end
        self.isFinal = isFinal
    }

    public var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var midpoint: Double { (start + end) / 2 }
}

/// A run of recognizer output with an optional audio time range (one `AttributedString` run).
public struct TimedPiece: Equatable, Sendable {
    public var text: String
    public var start: Double?
    public var end: Double?

    public init(text: String, start: Double?, end: Double?) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public enum Tokenizer {
    /// Splits recognizer runs into word tokens.
    ///
    /// A run that holds several words has its time range divided across them in proportion to their length.
    /// Runs without timing inherit from their neighbours, bounded by `fallbackStart...fallbackEnd`
    /// (the time range of the whole recognizer result).
    public static func tokens(
        from pieces: [TimedPiece],
        isFinal: Bool,
        fallbackStart: Double,
        fallbackEnd: Double
    ) -> [Token] {
        var tokens: [Token] = []
        var pendingWhitespace = ""
        var cursor = fallbackStart

        for piece in pieces {
            let words = splitKeepingLeadingSpace(pendingWhitespace + piece.text)
            pendingWhitespace = ""
            guard !words.isEmpty else {
                // Whitespace-only run: carry it onto the next word.
                pendingWhitespace += piece.text
                if let end = piece.end { cursor = max(cursor, end) }
                continue
            }

            let start = piece.start ?? cursor
            let end = max(piece.end ?? max(start, min(fallbackEnd, start + 0.3 * Double(words.count))), start)
            let totalWeight = words.reduce(0) { $0 + max(1, $1.trimmingCharacters(in: .whitespaces).count) }
            var t = start
            for word in words {
                let weight = Double(max(1, word.trimmingCharacters(in: .whitespaces).count))
                let duration = totalWeight > 0 ? (end - start) * weight / Double(totalWeight) : 0
                tokens.append(Token(text: word, start: t, end: t + duration, isFinal: isFinal))
                t += duration
            }
            cursor = end
        }
        return tokens
    }

    /// "  hello world," -> ["  hello", " world,"]. Whitespace-only input yields no words.
    static func splitKeepingLeadingSpace(_ s: String) -> [String] {
        var result: [String] = []
        var current = ""
        var sawNonSpace = false
        for ch in s {
            if ch.isWhitespace {
                if sawNonSpace {
                    result.append(current)
                    current = ""
                    sawNonSpace = false
                }
                current.append(ch)
            } else {
                current.append(ch)
                sawNonSpace = true
            }
        }
        if sawNonSpace { result.append(current) }
        return result
    }
}

/// The running transcript: finalized tokens, the recognizer's current volatile hypothesis, and which
/// words have already been committed for translation.
///
/// The recognizer only attaches word timings to *final* results; a volatile result is one run covering the
/// whole unfinalized region, revised as more audio arrives. So commits are tracked by aligning words, not by
/// time: committed-but-not-yet-finalized words are matched against each new hypothesis with an edit-distance
/// alignment, which survives revisions like "3 things the" → "3 things, the".
///
/// Volatile text can change, so only its *agreed* prefix (unchanged across the last two hypotheses, the
/// "local agreement" policy used by streaming ASR systems) is treated as stable enough to commit.
public struct TranscriptBuffer: Sendable {
    public private(set) var finalTokens: [Token] = []
    /// Number of leading `finalTokens` that have been committed.
    public private(set) var finalCommitted = 0
    public private(set) var volatileTokens: [Token] = []
    private var previousVolatile: [Token] = []
    /// Number of leading `volatileTokens` that also appeared in the previous hypothesis.
    public private(set) var agreedVolatileCount = 0
    /// Utterances committed from text that hasn't been finalized yet: their normalized words still waiting
    /// for final results, and the final tokens they've been matched with so far.
    private var unsettled: [(id: UUID, words: [String], settled: [Token])] = []
    private var unsettledWords: [String] { unsettled.flatMap(\.words) }
    /// Committed utterances whose words have all been finalized, with the recognizer's final tokens for them
    /// (often more accurate than the in-progress text they were translated from). Drain with `takeSettled()`.
    public private(set) var settledUtterances: [(id: UUID, tokens: [Token])] = []
    /// Audio time up to which the recognizer has finalized its results.
    public private(set) var finalizedThrough: Double = 0
    /// Audio time covered by the latest in-progress (volatile) hypothesis.
    public private(set) var volatileThrough: Double = 0

    public init() {}

    public var allTokens: [Token] { finalTokens + volatileTokens }

    public mutating func applyFinal(_ tokens: [Token], rangeEnd: Double) {
        // The final result replaces the part of the volatile hypothesis it covers (its leading words).
        let covered = WordAlignment.prefixEnd(of: tokens.map(\.normalized), in: volatileTokens.map(\.normalized))
        volatileTokens.removeFirst(min(covered, volatileTokens.count))
        previousVolatile = []
        agreedVolatileCount = 0
        finalTokens.append(contentsOf: tokens)
        finalizedThrough = max(finalizedThrough, rangeEnd, tokens.last?.end ?? 0)
        settle()
    }

    public mutating func applyVolatile(_ tokens: [Token], rangeEnd: Double? = nil) {
        if let rangeEnd { volatileThrough = max(volatileThrough, rangeEnd) }
        previousVolatile = volatileTokens
        volatileTokens = tokens
        agreedVolatileCount = Self.agreementPrefix(volatileTokens, previousVolatile)
    }

    /// Words not yet committed, and how many of them (from the front) are stable enough to commit.
    public func pending() -> (tokens: [Token], stableCount: Int) {
        let unaccounted = Array(finalTokens[finalCommitted...]) + volatileTokens
        let skip = unsettled.isEmpty ? 0 : WordAlignment.prefixEnd(of: unsettledWords, in: unaccounted.map(\.normalized))
        let finals = max(0, finalTokens.count - finalCommitted - skip)
        let volatileSkipped = max(0, skip - (finalTokens.count - finalCommitted))
        let agreed = max(0, agreedVolatileCount - volatileSkipped)
        return (Array(unaccounted.dropFirst(skip)), finals + agreed)
    }

    /// Records that these leading pending tokens were committed (as one utterance, `id`).
    public mutating func markCommitted(_ tokens: [Token], utterance id: UUID = UUID()) {
        unsettled.append((id, tokens.map(\.normalized), []))
        settle()
    }

    /// Returns and clears the utterances that have been finalized since the last call.
    public mutating func takeSettled() -> [(id: UUID, tokens: [Token])] {
        defer { settledUtterances = [] }
        return settledUtterances
    }

    /// Matches committed words with final results as they arrive (by word alignment, which survives
    /// revisions), advancing `finalCommitted` and reporting each utterance once all its words are final.
    private mutating func settle() {
        while var head = unsettled.first {
            let finals = finalTokens.count - finalCommitted
            guard finals > 0 else { return }
            let unaccounted = (finalTokens[finalCommitted...] + volatileTokens).map(\.normalized)
            let end = WordAlignment.prefixEnd(of: head.words, in: unaccounted)
            if end <= finals {
                head.settled += finalTokens[finalCommitted..<(finalCommitted + end)]
                finalCommitted += end
                unsettled.removeFirst()
                settledUtterances.append((head.id, head.settled))
            } else {
                let split = WordAlignment.split(head.words, alignedTo: unaccounted, at: finals)
                head.settled += finalTokens[finalCommitted...]
                finalCommitted += finals
                head.words.removeFirst(min(split, head.words.count))
                unsettled[0] = head
                return
            }
        }
    }

    /// Drops committed final tokens to bound memory in long sessions.
    public mutating func trim(keepingCommitted keep: Int = 200) {
        let drop = finalCommitted - keep
        guard drop > 0 else { return }
        finalTokens.removeFirst(drop)
        finalCommitted -= drop
    }

    public mutating func reset() {
        finalTokens = []
        finalCommitted = 0
        volatileTokens = []
        previousVolatile = []
        agreedVolatileCount = 0
        unsettled = []
        settledUtterances = []
        finalizedThrough = 0
        volatileThrough = 0
    }

    static func agreementPrefix(_ a: [Token], _ b: [Token]) -> Int {
        var n = 0
        while n < a.count, n < b.count, a[n].normalized == b[n].normalized {
            n += 1
        }
        return n
    }
}

extension Token {
    /// Lowercased word without surrounding punctuation, for alignment.
    var normalized: String {
        trimmed.lowercased().trimmingCharacters(in: .punctuationCharacters.union(.symbols))
    }
}

/// Edit-distance alignment between word sequences.
enum WordAlignment {
    private static func cost(_ a: String, _ b: String) -> Double {
        if a == b { return 0 }
        if a.count >= 2, b.count >= 2, a.hasPrefix(b) || b.hasPrefix(a) { return 0.3 } // partial word ("hi" → "hiring")
        return 1
    }

    /// D[i][j] = cost of aligning a[0..<i] with b[0..<j].
    private static func table(_ a: [String], _ b: [String]) -> [[Double]] {
        var d = Array(repeating: Array(repeating: 0.0, count: b.count + 1), count: a.count + 1)
        for i in 0...a.count { d[i][0] = Double(i) }
        for j in 0...b.count { d[0][j] = Double(j) }
        if a.isEmpty || b.isEmpty { return d }
        for i in 1...a.count {
            for j in 1...b.count {
                d[i][j] = min(d[i - 1][j - 1] + cost(a[i - 1], b[j - 1]), d[i - 1][j] + 1, d[i][j - 1] + 1)
            }
        }
        return d
    }

    /// How many leading words of `hypothesis` correspond to all of `words`.
    static func prefixEnd(of words: [String], in hypothesis: [String]) -> Int {
        guard !words.isEmpty, !hypothesis.isEmpty else { return 0 }
        let d = table(words, hypothesis)
        let last = d[words.count]
        var best = 0
        // On ties prefer consuming more of the hypothesis: a revised word is likelier than a dropped one.
        for j in 0...hypothesis.count where last[j] <= last[best] {
            best = j
        }
        return best
    }

    /// How many leading words of `words` correspond to the first `position` words of `hypothesis`.
    static func split(_ words: [String], alignedTo hypothesis: [String], at position: Int) -> Int {
        guard !words.isEmpty, position > 0 else { return 0 }
        let d = table(words, hypothesis)
        var best = 0
        for i in 0...words.count where d[i][position] <= d[best][position] {
            best = i
        }
        return best
    }
}

public enum TextJoiner {
    /// Joins two caption fragments, adding a space only where the script uses spaces between words.
    public static func join(_ a: String, _ b: String) -> String {
        let left = a.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = b.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        if let l = left.unicodeScalars.last, let r = right.unicodeScalars.first,
           isSpacelessScript(l) || isSpacelessScript(r) {
            return left + right
        }
        return left + " " + right
    }

    public static func isSpacelessScript(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x3000...0x303F, // CJK punctuation
             0x3040...0x30FF, // Hiragana, Katakana
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, // CJK ideographs
             0xFF00...0xFFEF, // full-width forms
             0x0E00...0x0E7F: // Thai
            return true
        default:
            return false
        }
    }

    /// Removes spaces that some translators insert between Chinese/Japanese characters and punctuation
    /// ("です。 まず" → "です。まず"), keeping spaces next to Latin text ("Mac 用").
    public static func normalizeSpacelessSpacing(_ text: String) -> String {
        var out = ""
        let scalars = Array(text.unicodeScalars)
        for (i, scalar) in scalars.enumerated() {
            if scalar.properties.isWhitespace,
               let prev = scalars[..<i].last(where: { !$0.properties.isWhitespace }),
               let next = scalars[(i + 1)...].first(where: { !$0.properties.isWhitespace }),
               isSpacelessScript(prev) || isSpacelessScript(next),
               !(prev.properties.isAlphabetic && !isSpacelessScript(prev)),
               !(next.properties.isAlphabetic && !isSpacelessScript(next)) {
                continue
            }
            out.unicodeScalars.append(scalar)
        }
        return out
    }

    /// Approximate word count that treats each pair of CJK characters as one word.
    public static func wordCount(_ text: String) -> Int {
        var count = 0
        var spaceless = 0
        for word in text.split(whereSeparator: { $0.isWhitespace }) {
            let scalars = word.unicodeScalars
            let cjk = scalars.filter(isSpacelessScript).count
            if cjk > 0 {
                spaceless += cjk
                if scalars.count - cjk > 0 { count += 1 }
            } else if word.contains(where: { $0.isLetter || $0.isNumber }) {
                count += 1
            }
        }
        return count + (spaceless + 1) / 2
    }
}
