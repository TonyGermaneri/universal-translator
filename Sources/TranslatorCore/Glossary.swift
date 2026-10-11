import Foundation

/// A term with a required translation. An empty `target` means "keep it as is" (names, products).
public struct GlossaryEntry: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var source: String
    public var target: String

    public init(id: UUID = UUID(), source: String, target: String) {
        self.id = id
        self.source = source
        self.target = target
    }

    /// The translation to use: the given one, or the source term itself when blank.
    public var rendering: String {
        let t = target.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? source.trimmingCharacters(in: .whitespaces) : t
    }
}

public enum Glossary {
    /// Entries whose source term occurs in `text`: whole words (case-insensitive) for spaced scripts,
    /// plain substrings for Chinese and Japanese terms.
    public static func matches(_ entries: [GlossaryEntry], in text: String) -> [GlossaryEntry] {
        let haystack = text.lowercased()
        return entries.filter { entry in
            let term = entry.source.trimmingCharacters(in: .whitespaces).lowercased()
            guard !term.isEmpty else { return false }
            if term.unicodeScalars.contains(where: TextJoiner.isSpacelessScript) { return haystack.contains(term) }
            let pattern = "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: term) + "(?![\\p{L}\\p{N}])"
            return haystack.range(of: pattern, options: .regularExpression) != nil
        }
    }
}
