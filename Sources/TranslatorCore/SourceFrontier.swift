import Foundation

/// The part of the live transcript that's safe to translate, as one translation unit at a time.
///
/// The unit is the **utterance**: everything said up to a real pause, the way the IWSLT 2025/2026 winning
/// systems reset at end-of-utterance. Sentence punctuation can't be used to split units while speech
/// continues, because the recognizer only punctuates when it finalizes (about a second later) and by then
/// translation of the following words may already be committed.
///
/// Final recognizer words are always stable. Volatile words count only once they've been agreed on by
/// consecutive hypotheses (see `TranscriptBuffer`) *and* have existed for `holdBack` seconds: the newest
/// volatile words are the ones the recognizer most often revises.
public struct SourceFrontier: Sendable {
    public var holdBack: Double
    /// Utterances longer than this are finished early (at the edge of the stable words) so translation
    /// and context keep flowing during long monologues.
    public var maxSentenceWords: Int
    /// Hand over stable words only up to the last clause boundary (、。，, and the like), the way an interpreter
    /// waits for the clause: in a language that puts the verb last, English made from half a clause is often wrong
    /// and then can't be taken back ("会議にご参加いただき…" → "Please attend the meeting"). See `waitsForClauses(in:)`.
    public var clauseGated: Bool
    /// With `clauseGated`, words after the last boundary are handed over anyway once there are this many, so a
    /// speaker who doesn't pause for commas still gets captions.
    public var clauseFallbackWords: Int
    private var firstSeen: [String: Double] = [:]

    public init(holdBack: Double = 0.25, maxSentenceWords: Int = 40, clauseGated: Bool = false,
                clauseFallbackWords: Int = 16) {
        self.holdBack = holdBack
        self.maxSentenceWords = maxSentenceWords
        self.clauseGated = clauseGated
        self.clauseFallbackWords = clauseFallbackWords
    }

    /// Speech languages whose live captions wait for each clause. Measured 2026-10-26 with scripts/evaluate.py
    /// (llama.cpp, chrF): Japanese 56.1 word by word, 60.0 by clause; Chinese 58.2 and 62.8; Korean 59.1 and 64.4, for
    /// about 2 s more lag (its run-on monologue, without commas, waits for the 16-word fallback: 10 s).
    public static func waitsForClauses(in locale: String) -> Bool {
        ["ja", "zh", "ko"].contains(locale.split(separator: "-").first.map { $0.lowercased() } ?? "")
    }

    static let clauseEnders: Set<Character> = Set("、。，,！？!?；;：:")

    /// How the end of the speaker's turn delimits the utterance.
    public enum UtteranceEnd: Equatable, Sendable {
        /// Everything pending belongs to the finished utterance (the recognizer has caught up with the end
        /// of speech, so its in-progress text is complete).
        case all
        /// Speech resumed after the pause: final tokens centered before this audio time form the utterance,
        /// the rest stays for the next one.
        case finalsBefore(Double)
    }

    public struct Sentence: Equatable, Sendable {
        /// Tokens of the unit that are stable enough to translate (all of them when `isComplete`).
        public var tokens: [Token]
        /// The unit has ended (end-of-thought pause or length cap) and can be translated in full and finished.
        public var isComplete: Bool
        /// Finished mid-speech at the length cap: a fragment of a longer thought.
        public var isCut = false

        public var text: String { tokens.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The translation unit in progress.
    ///
    /// - Parameters:
    ///   - pending: uncommitted tokens from `TranscriptBuffer.pending()`.
    ///   - stableCount: how many of them the recognizer has settled on.
    ///   - utteranceEnd: the speaker's turn ended (see `UtteranceEnd`).
    ///   - flushAll: end the utterance with whatever is pending, final or not (long silence fallback).
    public mutating func currentSentence(pending: [Token], stableCount: Int, utteranceEnd: UtteranceEnd? = nil,
                                         flushAll: Bool = false, now: Double) -> Sentence {
        let ready = readyCount(pending: pending, stableCount: stableCount, now: now)
        if !pending.isEmpty, flushAll {
            return Sentence(tokens: pending, isComplete: true)
        }
        switch utteranceEnd {
        case .all?:
            if !pending.isEmpty { return Sentence(tokens: pending, isComplete: true) }
        case .finalsBefore(let end)?:
            let unit = pending.prefix { $0.isFinal && $0.midpoint < end }
            if !unit.isEmpty { return Sentence(tokens: Array(unit), isComplete: true) }
        case nil:
            break
        }
        var stable = Array(pending.prefix(ready))
        if clauseGated { stable = clausePrefix(stable) }
        // A long monologue without pauses: finish what's stable. Everything committed so far translates
        // words inside this stable prefix, so finishing exactly here never contradicts the screen.
        if TextJoiner.wordCount(stable.map(\.text).joined()) >= maxSentenceWords {
            return Sentence(tokens: stable, isComplete: true, isCut: true)
        }
        return Sentence(tokens: stable, isComplete: false)
    }

    /// The stable words up to the last clause boundary, or all of them once the rest is `clauseFallbackWords` long.
    func clausePrefix(_ stable: [Token]) -> [Token] {
        let boundary = stable.lastIndex { $0.trimmed.last.map(Self.clauseEnders.contains) ?? false }
        let rest = stable[(boundary.map { $0 + 1 } ?? 0)...]
        if TextJoiner.wordCount(rest.map(\.text).joined()) >= clauseFallbackWords { return stable }
        return boundary.map { Array(stable[...$0]) } ?? []
    }

    /// Leading tokens that are final, or agreed and old enough.
    mutating func readyCount(pending: [Token], stableCount: Int, now: Double) -> Int {
        var live: [String: Double] = [:]
        var count = 0
        var blocked = false
        for (index, token) in pending.enumerated() {
            let key = "\(index)|\(token.normalized)"
            let seen = firstSeen[key] ?? now
            live[key] = seen
            guard !blocked else { continue }
            if token.isFinal || (index < stableCount && now - seen >= holdBack) {
                count += 1
            } else {
                blocked = true
            }
        }
        firstSeen = live
        return count
    }

    /// The first `count` pending tokens were committed; keep the ages of the rest.
    public mutating func consume(_ count: Int) {
        var shifted: [String: Double] = [:]
        for (key, seen) in firstSeen {
            let parts = key.split(separator: "|", maxSplits: 1)
            guard parts.count == 2, let index = Int(parts[0]), index >= count else { continue }
            shifted["\(index - count)|\(parts[1])"] = seen
        }
        firstSeen = shifted
    }

    public mutating func reset() {
        firstSeen = [:]
    }
}
