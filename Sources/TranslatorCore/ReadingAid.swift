import Foundation

/// A per-language help for reading caption text, e.g. furigana (kana readings with the kanji) for Japanese.
/// Each aid belongs to one language and turns a caption into segments: pieces of the text, some with a reading to
/// show beside them. New aids (Chinese pinyin, Traditional↔Simplified display) plug in as new cases.
public enum ReadingAid: String, Codable, CaseIterable, Sendable {
    case furigana

    /// Base language code (as in "ja" of "ja-JP") whose captions this aid applies to.
    public var language: String {
        switch self {
        case .furigana: return "ja"
        }
    }

    public var title: String {
        switch self {
        case .furigana: return "Furigana (kana readings under kanji)"
        }
    }

    /// The aids offered for captions in `language` (any BCP-47 identifier; only its base language counts).
    public static func choices(for language: String) -> [ReadingAid] {
        let code = baseLanguage(language)
        return allCases.filter { $0.language == code }
    }

    /// The base languages among `identifiers` (the caption lines' languages) that have an aid to offer, each once,
    /// in order.
    public static func languages(offeredFor identifiers: [String]) -> [String] {
        var out: [String] = []
        for code in identifiers.map(baseLanguage) where !out.contains(code) && !choices(for: code).isEmpty {
            out.append(code)
        }
        return out
    }

    /// "ja" for "ja-JP", "zh" for "zh-Hant-TW".
    public static func baseLanguage(_ identifier: String) -> String {
        String(identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? "").lowercased()
    }

    /// `text` as segments in order; their texts joined give back `text` exactly.
    public func segments(_ text: String) -> [ReadingSegment] {
        switch self {
        case .furigana: return Furigana.segments(text)
        }
    }
}

/// A piece of caption text and, if it has one, the reading to show with it.
public struct ReadingSegment: Equatable, Sendable {
    public var text: String
    public var reading: String?

    public init(_ text: String, _ reading: String? = nil) {
        self.text = text
        self.reading = reading
    }
}

/// Kana readings for the kanji in Japanese text: the system's word tokenizer gives each word's reading in Latin
/// letters, which is turned into hiragana and lined up with the word so only its kanji get a reading (取り扱い →
/// 取(と)り扱(あつか)い). Readings can be wrong for names and words read differently by context.
public enum Furigana {
    /// Readings the tokenizer gets wrong for everyday speech (it reads 私 as the formal わたくし).
    static let overrides: [String: String] = ["私": "わたし"]

    public static func segments(_ text: String) -> [ReadingSegment] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let tokenizer = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: ns.length),
                                                kCFStringTokenizerUnitWord, Locale(identifier: "ja") as CFLocale)
        var result: [ReadingSegment] = []
        var cursor = 0
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard range.location >= cursor else { continue }
            if range.location > cursor {
                result.append(ReadingSegment(ns.substring(with: NSRange(location: cursor, length: range.location - cursor))))
            }
            let word = ns.substring(with: NSRange(location: range.location, length: range.length))
            if containsKanji(word) {
                let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
                let reading = overrides[word] ?? latin.flatMap(hiragana)
                result += reading.map { align(word, reading: $0) } ?? [ReadingSegment(word)]
            } else {
                result.append(ReadingSegment(word))
            }
            cursor = range.location + range.length
        }
        if cursor < ns.length { result.append(ReadingSegment(ns.substring(from: cursor))) }
        return merged(result)
    }

    /// Latin transcription → hiragana ("~" marks a small っ); nil if anything but kana and digits is left over.
    static func hiragana(_ latin: String) -> String? {
        let text = NSMutableString(string: latin)
        CFStringTransform(text, nil, kCFStringTransformLatinHiragana, false)
        let result = text as String
        return result.unicodeScalars.allSatisfy({ isKana($0) || ("0"..."9").contains($0) }) ? result : nil
    }

    /// Splits `word` so each run of kanji carries its part of `reading` and the kana around them carry none.
    /// When the kana in the word can't be found in the reading, the whole word carries the whole reading.
    public static func align(_ word: String, reading: String) -> [ReadingSegment] {
        // Alternating runs: kanji (need a reading) and everything else (must appear in the reading as written).
        var runs: [(text: String, kanji: Bool)] = []
        for ch in word {
            let k = isKanji(ch)
            if let last = runs.last, last.kanji == k {
                runs[runs.count - 1].text.append(ch)
            } else {
                runs.append((String(ch), k))
            }
        }
        let target = Array(toHiragana(reading))
        var readings = [String](repeating: "", count: runs.count)
        func match(_ run: Int, _ at: Int) -> Bool {
            if run == runs.count { return at == target.count }
            if runs[run].kanji {
                // Each kanji run takes at least one kana; try the shortest first, backtracking on a later miss.
                guard at < target.count else { return false }
                for end in (at + 1)...target.count {
                    readings[run] = String(target[at..<end])
                    if match(run + 1, end) { return true }
                }
                return false
            }
            let literal = Array(toHiragana(runs[run].text))
            guard at + literal.count <= target.count, Array(target[at..<at + literal.count]) == literal else { return false }
            return match(run + 1, at + literal.count)
        }
        guard match(0, 0) else { return [ReadingSegment(word, reading)] }
        return runs.enumerated().map { i, run in
            ReadingSegment(run.text, run.kanji ? readings[i] : nil)
        }
    }

    /// Joins neighbouring segments that have no reading, so a sentence is a handful of segments.
    static func merged(_ segments: [ReadingSegment]) -> [ReadingSegment] {
        var out: [ReadingSegment] = []
        for s in segments where !s.text.isEmpty {
            if s.reading == nil, let last = out.last, last.reading == nil {
                out[out.count - 1].text += s.text
            } else {
                out.append(s)
            }
        }
        return out
    }

    static func containsKanji(_ text: String) -> Bool { text.contains(where: isKanji) }

    /// CJK ideographs, plus 々 (repeat mark), 〆 and ヶ (as in 三ヶ月), which are read like kanji.
    static func isKanji(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { s in
            switch s.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2FA1F, 0xF900...0xFAFF, 0x3005, 0x3006, 0x30F6: return true
            default: return false
            }
        }
    }

    static func isKana(_ s: Unicode.Scalar) -> Bool {
        (0x3041...0x309F).contains(s.value) || (0x30A0...0x30FF).contains(s.value)
    }

    /// Katakana → hiragana, so a word's katakana matches its reading.
    static func toHiragana(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.map { s in
            (0x30A1...0x30F5).contains(s.value) ? Unicode.Scalar(s.value - 0x60)! : s
        }))
    }
}
