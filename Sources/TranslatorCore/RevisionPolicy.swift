import Foundation

/// Decides whether a second-pass translation of a finished sentence should replace what's on screen.
///
/// Readers prefer stable captions over marginally better ones, so a revision is shown only when the
/// content actually changed (ignoring punctuation, spacing and character width), at most once per sentence.
public struct RevisionPolicy: Equatable, Sendable {
    /// Content changes smaller than this (fraction of units) aren't worth disturbing the reader. Wording
    /// tweaks between two good translations typically stay below it; meaning fixes usually exceed it.
    public var minChange: Double = 0.22
    /// Rewording alone changes many characters in Chinese and Japanese, so they need a bigger change.
    public var minCharacterChange: Double = 0.30
    /// When the source text didn't change (no recognition fix), the live translation already saw the whole
    /// sentence: only a substantial difference is worth showing, not a second model's paraphrase.
    public var minChangeSameSource: Double = 0.40
    /// A second pass that adds a sentence or grows/shrinks the text this much is inventing or dropping content
    /// (a model "completing" a fragment), not fixing it.
    public var maxLengthRatio: Double = 1.6
    /// A near-total rewrite of a long sentence is more likely a misfire than a fix.
    public var maxChange: Double = 0.85
    public var maxRevisionsPerSentence = 1

    public init() {}

    public enum Decision: Equatable, Sendable {
        /// Apply it; `changed` holds character ranges in the new text that differ from the old one.
        case accept(changed: [Range<Int>])
        case reject(String)
    }

    /// - Parameter sourceChanged: the candidate translates a corrected transcript (the recognizer's final text
    ///   differs from what the live pass translated).
    public func evaluate(current: String, candidate: String, unit: LanguageProfile.Unit, revisionsSoFar: Int,
                         sourceChanged: Bool = true) -> Decision {
        guard revisionsSoFar < maxRevisionsPerSentence else { return .reject("revision budget used") }
        let old = Self.contentUnits(current, unit: unit)
        let new = Self.contentUnits(candidate, unit: unit)
        guard !new.isEmpty else { return .reject("empty candidate") }
        if Self.sentenceCount(candidate) > max(Self.sentenceCount(current), 1) {
            return .reject("adds a sentence")
        }
        let longer = Double(max(old.count, new.count)), shorter = Double(max(1, min(old.count, new.count)))
        if longer > 8, longer / shorter > maxLengthRatio {
            return .reject(String(format: "length changes %.1f×", longer / shorter))
        }
        let ratio = Self.changeRatio(old, new)
        let threshold = sourceChanged ? (unit == .character ? minCharacterChange : minChange) : minChangeSameSource
        if ratio < threshold { return .reject(String(format: "change %.2f below threshold %.2f", ratio, threshold)) }
        if ratio > maxChange, max(old.count, new.count) > 12 { return .reject(String(format: "change %.2f looks like a misfire", ratio)) }
        return .accept(changed: Self.changedRanges(old: current, new: candidate))
    }

    /// Sentences, counted by their final punctuation (a trailing fragment counts as one).
    public static func sentenceCount(_ text: String) -> Int {
        let enders = Set("。！？!?.")
        var count = 0
        var inSentence = false
        for ch in text {
            if enders.contains(ch) {
                if inSentence { count += 1 }
                inSentence = false
            } else if ch.isLetter || ch.isNumber {
                inSentence = true
            }
        }
        return count + (inSentence ? 1 : 0)
    }

    /// Whether two transcripts of the same speech differ in their words (not just punctuation or case).
    public static func sourceDiffers(_ a: String, _ b: String) -> Bool {
        let unit: LanguageProfile.Unit = (a + b).unicodeScalars.contains(where: TextJoiner.isSpacelessScript) ? .character : .word
        return changeRatio(contentUnits(a, unit: unit), contentUnits(b, unit: unit)) > 0.02
    }

    /// Comparable content: lowercased, compatibility-normalized (full/half width), without punctuation or spaces.
    public static func contentUnits(_ text: String, unit: LanguageProfile.Unit) -> [String] {
        let normalized = text.precomposedStringWithCompatibilityMapping.lowercased()
        let drop = CharacterSet.punctuationCharacters.union(.symbols).union(.whitespacesAndNewlines)
        switch unit {
        case .character:
            return normalized.unicodeScalars.filter { !drop.contains($0) }.map { String($0) }
        case .word:
            return normalized.components(separatedBy: .whitespacesAndNewlines)
                .map { $0.trimmingCharacters(in: drop) }
                .filter { !$0.isEmpty }
        }
    }

    /// Normalized edit distance between unit sequences (0 = identical, 1 = completely different).
    public static func changeRatio(_ a: [String], _ b: [String]) -> Double {
        let n = max(a.count, b.count)
        guard n > 0 else { return 0 }
        return Double(editDistance(a, b)) / Double(n)
    }

    static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = Array(repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// Character ranges (offsets into `new`) not shared with `old`, merged into runs, for highlighting.
    public static func changedRanges(old: String, new: String) -> [Range<Int>] {
        let a = Array(old), b = Array(new)
        guard !b.isEmpty else { return [] }
        guard !a.isEmpty else { return [0..<b.count] }
        // LCS table (sentences are short, so O(n·m) is fine).
        var lcs = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        for i in stride(from: a.count - 1, through: 0, by: -1) {
            for j in stride(from: b.count - 1, through: 0, by: -1) {
                lcs[i][j] = a[i] == b[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var kept = Array(repeating: false, count: b.count)
        var i = 0, j = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] {
                kept[j] = true
                i += 1
                j += 1
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        var ranges: [Range<Int>] = []
        var start: Int?
        for (index, isKept) in kept.enumerated() {
            if !isKept, start == nil { start = index }
            if isKept, let s = start {
                ranges.append(s..<index)
                start = nil
            }
        }
        if let s = start { ranges.append(s..<b.count) }
        return ranges
    }
}
