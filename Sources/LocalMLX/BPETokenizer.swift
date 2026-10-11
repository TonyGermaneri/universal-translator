import Foundation

/// A byte-level BPE tokenizer read from a Hugging Face `tokenizer.json` (the GPT-2 family, which includes both
/// Hy-MT2 models), matching the reference `tokenizers` library for those files.
///
/// Written for the translation loop rather than taken from swift-transformers: its regex search splits some
/// text differently from the reference (Hy-MT2 1.8B's ":\n\n" became three tokens instead of one, so prompts
/// differed from the ones the model was trained on), and it took ~3 ms per prompt. Here pre-tokenization uses
/// `NSRegularExpression` (which matches the reference) and each pre-token's BPE result is cached, so the
/// growing prompt of a live sentence costs a fraction of a millisecond.
public final class BPETokenizer: @unchecked Sendable {
    enum TokenizerError: LocalizedError {
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let what): return "Unsupported tokenizer: \(what)."
            }
        }
    }

    private enum PreTokenizer {
        /// Matches and the text between them become separate pieces (the `Isolated` behavior).
        case split(NSRegularExpression)
        /// Bytes → printable characters, optionally after GPT-2's own split.
        case byteLevel(addPrefixSpace: Bool, regex: NSRegularExpression?)
    }

    private let vocabulary: [String: Int]
    private let ranks: [Pair: Int]
    private let ignoreMerges: Bool
    private let preTokenizers: [PreTokenizer]
    /// All added tokens (special or not), longest first.
    private let addedPattern: NSRegularExpression?
    private let added: [String: Int]
    /// Every token's text as bytes (added tokens: their content).
    let pieces: [[UInt8]]
    /// Added tokens marked special (chat markers, end of text).
    let specialIDs: Set<Int>
    private var cache: [String: [Int]] = [:]
    private let lock = NSLock()

    private struct Pair: Hashable {
        let left: String
        let right: String
    }

    private static let gpt2Pattern = #"'s|'t|'re|'ve|'m|'ll|'d| ?\p{L}+| ?\p{N}+| ?[^\s\p{L}\p{N}]+|\s+(?!\S)|\s+"#

    public init(url: URL) throws {
        guard let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let model = json["model"] as? [String: Any], model["type"] as? String == "BPE",
              let vocabulary = model["vocab"] as? [String: Int]
        else { throw TokenizerError.unsupported("not a BPE tokenizer.json") }
        if let normalizer = json["normalizer"] as? [String: Any],
           !(normalizer["type"] as? String == "Sequence" && (normalizer["normalizers"] as? [Any])?.isEmpty == true) {
            throw TokenizerError.unsupported("normalizer \(normalizer["type"] ?? "?")")
        }
        for key in ["continuing_subword_prefix", "end_of_word_suffix", "dropout"] where !(model[key] is NSNull) && model[key] != nil {
            throw TokenizerError.unsupported(key)
        }
        self.vocabulary = vocabulary
        ignoreMerges = model["ignore_merges"] as? Bool ?? false

        var ranks: [Pair: Int] = [:]
        for (rank, merge) in (model["merges"] as? [Any] ?? []).enumerated() {
            let parts: [String]
            if let pair = merge as? [String] {
                parts = pair
            } else if let line = merge as? String {
                parts = line.split(separator: " ", maxSplits: 1).map(String.init)
            } else {
                continue
            }
            guard parts.count == 2 else { continue }
            ranks[Pair(left: parts[0], right: parts[1])] = rank
        }
        self.ranks = ranks

        preTokenizers = try Self.preTokenizers(json["pre_tokenizer"] as? [String: Any])

        var added: [String: Int] = [:]
        var special = Set<Int>()
        for token in json["added_tokens"] as? [[String: Any]] ?? [] {
            guard let id = token["id"] as? Int, let content = token["content"] as? String else { continue }
            added[content] = id
            if token["special"] as? Bool == true { special.insert(id) }
        }
        self.added = added
        specialIDs = special
        let alternatives = added.keys.sorted { $0.count > $1.count }.map(NSRegularExpression.escapedPattern(for:))
        addedPattern = alternatives.isEmpty ? nil : try NSRegularExpression(pattern: alternatives.joined(separator: "|"))

        let size = max((vocabulary.values.max() ?? 0), (added.values.max() ?? 0)) + 1
        var pieces = [[UInt8]](repeating: [], count: size)
        let bytes = Self.byteDecoder
        for (token, id) in vocabulary {
            pieces[id] = token.unicodeScalars.flatMap { scalar in bytes[scalar].map { [$0] } ?? Array(String(scalar).utf8) }
        }
        for (content, id) in added { pieces[id] = Array(content.utf8) }
        self.pieces = pieces
    }

    private static func preTokenizers(_ config: [String: Any]?) throws -> [PreTokenizer] {
        guard let config else { return [] }
        switch config["type"] as? String {
        case "Sequence":
            return try (config["pretokenizers"] as? [[String: Any]] ?? []).flatMap { try preTokenizers($0) }
        case "Split":
            guard config["behavior"] as? String == "Isolated", config["invert"] as? Bool != true,
                  let pattern = config["pattern"] as? [String: Any]
            else { throw TokenizerError.unsupported("Split behavior \(config["behavior"] ?? "?")") }
            if let regex = pattern["Regex"] as? String {
                return [.split(try NSRegularExpression(pattern: regex))]
            }
            if let string = pattern["String"] as? String {
                return [.split(try NSRegularExpression(pattern: NSRegularExpression.escapedPattern(for: string)))]
            }
            throw TokenizerError.unsupported("Split pattern")
        case "ByteLevel":
            let regex = config["use_regex"] as? Bool ?? true ? try NSRegularExpression(pattern: gpt2Pattern) : nil
            return [.byteLevel(addPrefixSpace: config["add_prefix_space"] as? Bool ?? false, regex: regex)]
        default:
            throw TokenizerError.unsupported("pre-tokenizer \(config["type"] ?? "?")")
        }
    }

    /// Token IDs for `text`. Added tokens written in the text (chat markers) become their IDs; nothing else is added.
    public func encode(_ text: String) -> [Int] {
        var ids: [Int] = []
        let ns = text as NSString
        var start = 0
        for match in addedPattern?.matches(in: text, range: NSRange(location: 0, length: ns.length)) ?? [] {
            if match.range.location > start {
                ids += encodeOrdinary(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            }
            if let id = added[ns.substring(with: match.range)] { ids.append(id) }
            start = match.range.location + match.range.length
        }
        if start < ns.length { ids += encodeOrdinary(ns.substring(from: start)) }
        return ids
    }

    private func encodeOrdinary(_ text: String) -> [Int] {
        var pieces = [text]
        var byteLevel = false
        for step in preTokenizers {
            switch step {
            case .split(let regex):
                pieces = pieces.flatMap { Self.split($0, by: regex) }
            case .byteLevel(let addPrefixSpace, let regex):
                if addPrefixSpace { pieces = pieces.map { $0.hasPrefix(" ") ? $0 : " " + $0 } }
                if let regex { pieces = pieces.flatMap { Self.split($0, by: regex) } }
                byteLevel = true
            }
        }
        let table = Self.byteEncoder
        return pieces.flatMap { piece -> [Int] in
            let word = byteLevel ? String(String.UnicodeScalarView(piece.utf8.map { table[Int($0)] })) : piece
            return bpe(word)
        }
    }

    /// Splits around every match, keeping matches and the text between them as separate pieces.
    private static func split(_ text: String, by regex: NSRegularExpression) -> [String] {
        let ns = text as NSString
        var result: [String] = []
        var start = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) where match.range.length > 0 {
            if match.range.location > start {
                result.append(ns.substring(with: NSRange(location: start, length: match.range.location - start)))
            }
            result.append(ns.substring(with: match.range))
            start = match.range.location + match.range.length
        }
        if start < ns.length { result.append(ns.substring(from: start)) }
        return result
    }

    /// Merges a pre-token's characters by rank (lowest first) and maps the parts to IDs. Results are cached.
    private func bpe(_ word: String) -> [Int] {
        if let ids = lock.withLock({ cache[word] }) { return ids }
        var ids: [Int]
        if ignoreMerges, let id = vocabulary[word] {
            ids = [id]
        } else {
            // Characters missing from the vocabulary are dropped before merging (no unknown token), as the
            // reference does: Hy-MT2 1.8B has no "\r", so "\r\n\r\n" merges as "\n\n".
            var parts = word.unicodeScalars.map { String($0) }.filter { vocabulary[$0] != nil }
            while parts.count > 1 {
                var best: (rank: Int, index: Int)?
                for i in 0..<(parts.count - 1) {
                    if let rank = ranks[Pair(left: parts[i], right: parts[i + 1])], rank < (best?.rank ?? .max) {
                        best = (rank, i)
                    }
                }
                guard let best else { break }
                // Merge every occurrence of the pair, left to right (as the reference does).
                let left = parts[best.index], right = parts[best.index + 1]
                var merged: [String] = []
                var i = 0
                while i < parts.count {
                    if i < parts.count - 1, parts[i] == left, parts[i + 1] == right {
                        merged.append(left + right)
                        i += 2
                    } else {
                        merged.append(parts[i])
                        i += 1
                    }
                }
                parts = merged
            }
            ids = parts.compactMap { vocabulary[$0] }
        }
        lock.withLock { if cache.count < 50_000 { cache[word] = ids } }
        return ids
    }

    /// GPT-2's table: each byte as a printable character (byte-level BPE vocabularies are written this way).
    static let byteEncoder: [Unicode.Scalar] = {
        var printable = Array(33...126) + Array(161...172) + Array(174...255)
        var characters = printable
        var extra = 0
        for byte in 0..<256 where !printable.contains(byte) {
            printable.append(byte)
            characters.append(256 + extra)
            extra += 1
        }
        var table = [Unicode.Scalar](repeating: " ", count: 256)
        for (byte, character) in zip(printable, characters) { table[byte] = Unicode.Scalar(UInt32(character))! }
        return table
    }()

    static let byteDecoder: [Unicode.Scalar: UInt8] = {
        var table: [Unicode.Scalar: UInt8] = [:]
        for (byte, scalar) in byteEncoder.enumerated() { table[scalar] = UInt8(byte) }
        return table
    }()
}
