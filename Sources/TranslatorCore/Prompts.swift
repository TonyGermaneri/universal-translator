import Foundation

/// A previously translated chunk, given to LLM translators so terminology and tone stay consistent.
public struct TranslationContext: Equatable, Sendable {
    public var source: String
    public var translation: String

    public init(source: String, translation: String) {
        self.source = source
        self.translation = translation
    }
}

public enum Prompts {
    // MARK: Translation

    public static func translationInstructions(source: String, target: String, custom: String, hint: String = "",
                                               glossary: [GlossaryEntry] = []) -> String {
        var s = """
        You are a professional simultaneous interpreter translating live spoken \(source) into natural, fluent \
        \(target). Each request is the current sentence of continuous speech, often still unfinished. \
        The input may be incomplete; preserve incompleteness. Do not infer missing content. \
        Do not complete or extend the text. Keep names, numbers and technical terms accurate, and stay \
        consistent with the earlier sentences. Output only the \(target) translation, with no quotes, notes, \
        or explanations.
        """
        if !hint.isEmpty { s += " " + hint }
        if !glossary.isEmpty {
            s += "\n\nAlways translate these terms exactly as given:\n" + glossary.map { "- \($0.source) → \($0.rendering)" }.joined(separator: "\n")
        }
        let custom = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { s += "\n\nAdditional instructions: \(custom)" }
        return s
    }

    public static func translationPrompt(fragment: String, context: [TranslationContext], isFinal: Bool = true) -> String {
        let label = isFinal ? "Sentence" : "Unfinished sentence (translate only what has been said)"
        guard !context.isEmpty else { return "\(label):\n\(fragment)" }
        let history = context.map { "- \($0.source)\n  → \($0.translation)" }.joined(separator: "\n")
        return "Earlier sentences and their translations:\n\(history)\n\n\(label):\n\(fragment)"
    }

    /// Removes `<think>…</think>` blocks and wrapping quotes that reasoning or chatty models emit.
    public static func stripReasoning(_ text: String) -> String {
        var s = text
        while let open = s.range(of: "<think>") {
            if let close = s.range(of: "</think>", range: open.upperBound..<s.endIndex) {
                s.removeSubrange(open.lowerBound..<close.upperBound)
            } else {
                s.removeSubrange(open.lowerBound..<s.endIndex)
            }
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        for (open, close) in [("\"", "\""), ("“", "”"), ("「", "」")] where s.count >= 2 && s.hasPrefix(open) && s.hasSuffix(close) {
            let inner = s.dropFirst(open.count).dropLast(close.count)
            if !inner.contains(open) { s = String(inner) }
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
