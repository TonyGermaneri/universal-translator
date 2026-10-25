import Foundation

/// A per-language help for reading caption text: readings shown with the characters (furigana for Japanese, pinyin
/// for Chinese), or the text shown in another script (Chinese Traditional or Simplified characters). Each aid belongs
/// to one language; a language has at most one of each kind. Applied to a caption, aids turn it into segments: pieces
/// of the text, some with a reading to show beside them.
public enum ReadingAid: String, Codable, CaseIterable, Sendable {
    case furigana, pinyin, traditional, simplified

    public enum Kind: Sendable { case readings, script }

    public var kind: Kind {
        switch self {
        case .furigana, .pinyin: return .readings
        case .traditional, .simplified: return .script
        }
    }

    /// Base language code (as in "ja" of "ja-JP") whose captions this aid applies to.
    public var language: String {
        switch self {
        case .furigana: return "ja"
        case .pinyin, .traditional, .simplified: return "zh"
        }
    }

    public var title: String {
        switch self {
        case .furigana: return "Furigana (kana under kanji)"
        case .pinyin: return "Pinyin (under each character)"
        case .traditional: return "Traditional characters"
        case .simplified: return "Simplified characters"
        }
    }

    /// The aid's name in a sentence ("Japanese (furigana)").
    public var name: String {
        switch self {
        case .furigana: return "furigana"
        case .pinyin: return "pinyin"
        case .traditional: return "Traditional characters"
        case .simplified: return "Simplified characters"
        }
    }

    /// Every language with an aid and its aids, in English: "Japanese (furigana); Chinese (pinyin, …)".
    public static var summary: String {
        var languages: [String] = []
        for aid in allCases where !languages.contains(aid.language) { languages.append(aid.language) }
        return languages.map { code in
            let name = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
            return "\(name) (\(choices(for: code).map(\.name).joined(separator: ", ")))"
        }.joined(separator: "; ")
    }

    /// The aids offered for captions in `language` (any BCP-47 identifier; only its base language counts).
    public static func choices(for language: String, kind: Kind? = nil) -> [ReadingAid] {
        let code = baseLanguage(language)
        return allCases.filter { $0.language == code && (kind == nil || $0.kind == kind) }
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

    /// The aids in a stored setting ("pinyin,traditional") that apply to `language`: names this build doesn't know
    /// are skipped, and only the first of each kind counts.
    public static func parse(_ stored: String, language: String) -> [ReadingAid] {
        var out: [ReadingAid] = []
        for name in stored.split(separator: ",") {
            guard let aid = ReadingAid(rawValue: name.trimmingCharacters(in: .whitespaces)),
                  aid.language == baseLanguage(language), !out.contains(where: { $0.kind == aid.kind }) else { continue }
            out.append(aid)
        }
        return out
    }

    /// The setting's stored form of `aids`.
    public static func stored(_ aids: [ReadingAid]) -> String { aids.map(\.rawValue).joined(separator: ",") }

    /// `text` as segments with `aids` applied: the script first, character for character (so the text keeps its
    /// UTF-16 length and styled ranges still line up), then the readings.
    public static func segments(_ text: String, aids: [ReadingAid]) -> [ReadingSegment] {
        var converted = text
        for aid in aids where aid.kind == .script {
            converted = ChineseScript.convert(converted, toTraditional: aid == .traditional)
        }
        switch aids.first(where: { $0.kind == .readings }) {
        case .furigana: return Furigana.segments(converted)
        case .pinyin: return Pinyin.segments(converted)
        default: return converted.isEmpty ? [] : [ReadingSegment(converted)]
        }
    }

    /// `text` as segments with this aid alone applied.
    public func segments(_ text: String) -> [ReadingSegment] { Self.segments(text, aids: [self]) }
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

/// Pinyin for each Chinese character. The system tokenizer gives each word's pinyin with tone marks and readings that
/// depend on the word (银行 yínháng, 不 bú before a fourth tone); it's split into one syllable per character, with
/// each character's own most common reading breaking ties (西安 xīān → xī ān, not xīa n). Traditional text is
/// tokenized through a Simplified copy, which the tokenizer reads much better.
public enum Pinyin {
    public static func segments(_ text: String) -> [ReadingSegment] {
        let ns = text as NSString
        guard ns.length > 0 else { return [] }
        let simplified = ChineseScript.convert(text, toTraditional: false) as NSString
        let tokenizer = CFStringTokenizerCreate(nil, simplified, CFRange(location: 0, length: ns.length),
                                                kCFStringTokenizerUnitWord, Locale(identifier: "zh-Hans") as CFLocale)
        var result: [ReadingSegment] = []
        var cursor = 0
        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
            let range = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard range.location >= cursor else { continue }
            if range.location > cursor {
                result.append(ReadingSegment(ns.substring(with: NSRange(location: cursor, length: range.location - cursor))))
            }
            let word = ns.substring(with: NSRange(location: range.location, length: range.length))
            let latin = CFStringTokenizerCopyCurrentTokenAttribute(tokenizer, kCFStringTokenizerAttributeLatinTranscription) as? String
            result += annotate(word, latin: latin)
            cursor = range.location + range.length
        }
        if cursor < ns.length { result.append(ReadingSegment(ns.substring(from: cursor))) }
        return Furigana.merged(result)
    }

    /// A word's characters with their syllables: the word's pinyin split up when it's all Chinese characters and the
    /// split works out, otherwise each character's own reading.
    static func annotate(_ word: String, latin: String?) -> [ReadingSegment] {
        let chars = Array(word)
        if chars.allSatisfy(isHan), let latin, let syllables = split(latin, into: chars) {
            return zip(chars, syllables).map { ReadingSegment(String($0), $1) }
        }
        return chars.map { ch in ReadingSegment(String(ch), isHan(ch) ? own(ch) : nil) }
    }

    /// A character's most common reading, out of context.
    static func own(_ ch: Character) -> String? {
        String(ch).applyingTransform(.mandarinToLatin, reverse: false).map(normalize).flatMap { isSyllable(bare($0)) ? $0 : nil }
    }

    /// Splits a word's pinyin into one valid syllable per character, preferring the split whose syllables match the
    /// characters' own readings most often. Nil when no split works.
    static func split(_ latin: String, into chars: [Character]) -> [String]? {
        let letters = Array(normalize(latin).filter { $0 != "'" && $0 != " " && $0 != "-" })
        let n = chars.count
        guard n > 0, !letters.isEmpty else { return nil }
        let hints = chars.map { own($0).map(bare) }
        // best[i][k]: best score splitting letters[i...] into the last n - k syllables, with where the next one ends.
        var best = [[(score: Int, end: Int)?]](repeating: [(score: Int, end: Int)?](repeating: nil, count: n + 1), count: letters.count + 1)
        best[letters.count][n] = (0, letters.count)
        for i in stride(from: letters.count - 1, through: 0, by: -1) {
            for k in stride(from: n - 1, through: 0, by: -1) {
                for j in (i + 1)...min(letters.count, i + 7) {
                    guard let rest = best[j][k + 1] else { continue }
                    let piece = bare(String(letters[i..<j]))
                    guard isSyllable(piece) else { continue }
                    let score = rest.score + (piece == hints[k] ? 1 : 0)
                    if best[i][k].map({ score > $0.score }) ?? true { best[i][k] = (score, j) }
                }
            }
        }
        guard best[0][0] != nil else { return nil }
        var out: [String] = []
        var i = 0
        for k in 0..<n {
            let j = best[i][k]!.end
            out.append(String(letters[i..<j]))
            i = j
        }
        return out
    }

    /// Lowercase, precomposed, with the tokenizer's "v" written as "ü" (nv̌ → nǚ).
    static func normalize(_ latin: String) -> String {
        // By scalar: "v̌" is one Character, which a string replacement of "v" wouldn't touch.
        let scalars = latin.lowercased().unicodeScalars.flatMap { $0 == "v" ? ["u", "\u{308}"] : [$0] }
        return String(String.UnicodeScalarView(scalars)).precomposedStringWithCanonicalMapping
    }

    /// A syllable without its tone mark (ǚ → ü).
    static func bare(_ syllable: String) -> String {
        let marks: Set<UInt32> = [0x300, 0x301, 0x304, 0x30C]
        let kept = syllable.decomposedStringWithCanonicalMapping.unicodeScalars.filter { !marks.contains($0.value) }
        return String(String.UnicodeScalarView(kept)).precomposedStringWithCanonicalMapping
    }

    private static let syllable = try! NSRegularExpression(pattern:
        "^(zh|ch|sh|[bpmfdtnlgkhjqxrzcsyw])?(iang|iong|uang|ueng|ang|eng|ing|ong|ian|iao|uai|uan|üan|ai|ei|ao|ou|an|en|in|un|ün|ia|ie|iu|ua|uo|ui|üe|ue|er|a|o|e|ê|i|u|ü|ng|n|m)$")

    static func isSyllable(_ bare: String) -> Bool {
        syllable.firstMatch(in: bare, range: NSRange(location: 0, length: (bare as NSString).length)) != nil
    }

    /// CJK ideographs (the main block and its extensions).
    static func isHan(_ ch: Character) -> Bool {
        ch.unicodeScalars.contains { s in
            switch s.value {
            case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2FA1F, 0xF900...0xFAFF: return true
            default: return false
            }
        }
    }
}

/// Chinese text shown in Traditional or Simplified characters, character for character: a character whose other
/// form is a different length (a handful of rare ones) stays as it is, so the text keeps its UTF-16 length.
public enum ChineseScript {
    public static func convert(_ text: String, toTraditional: Bool) -> String {
        let transform = StringTransform(toTraditional ? "Hans-Hant" : "Hant-Hans")
        // Almost always every character maps to one of the same length: check the whole text at once.
        if let whole = text.applyingTransform(transform, reverse: false), whole.utf16.count == text.utf16.count,
           whole.count == text.count {
            return whole
        }
        return String(text.map { ch -> String in
            let s = String(ch)
            guard let c = s.applyingTransform(transform, reverse: false), c.utf16.count == s.utf16.count else { return s }
            return c
        }.joined())
    }
}
