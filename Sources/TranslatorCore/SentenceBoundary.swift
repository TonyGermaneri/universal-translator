import Foundation

/// Punctuation rules for where sentences and clauses end in recognized speech.
public enum SentenceBoundary {
    static let abbreviations: Set<String> = [
        "mr.", "mrs.", "ms.", "dr.", "prof.", "st.", "sr.", "jr.", "vs.", "etc.", "e.g.", "i.e.", "approx.", "no.",
    ]

    /// The word ends a sentence ("leave.", "本当？"), excluding abbreviations and initials ("Dr.", "J.").
    public static func endsSentence(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        if "?!？！。…".contains(last) { return true }
        if last == "." {
            return !abbreviations.contains(text.lowercased()) && !(text.count == 2 && text.first!.isUppercase)
        }
        return false
    }

    /// The word ends a clause ("station,", "、").
    public static func endsClause(_ text: String) -> Bool {
        guard let last = text.last else { return false }
        return ",;:—–、，；：".contains(last)
    }
}
