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

/// Earlier captions a translator repeated at the end of its output. Hy-MT2 1.8B sometimes appends the translation of
/// a context sentence ("Is there a good lunch place nearby? How long does it take?", 2026-10-25/26, both engines), and
/// a partial clause can come back as nothing but context.
public enum ContextEcho {
    /// `hypothesis` without context translations repeated at its end. Never cuts into `prefix` (already on screen),
    /// keeps a repeat the speaker actually said again (its source is in `source`), and returns a final translation
    /// that would be left empty as it was.
    public static func strip(_ hypothesis: String, source: String, context: [TranslationContext], prefix: String = "",
                             isFinal: Bool) -> String {
        let echoes = context.filter { !source.contains($0.source.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .map { $0.translation.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 8 }
        var text = hypothesis.trimmingCharacters(in: .whitespacesAndNewlines)
        var stripped = true
        while stripped {
            stripped = false
            for echo in echoes where text.hasSuffix(echo) && text.count - echo.count >= prefix.count {
                text = String(text.dropLast(echo.count)).trimmingCharacters(in: .whitespacesAndNewlines)
                stripped = true
            }
        }
        if text == hypothesis.trimmingCharacters(in: .whitespacesAndNewlines) || (isFinal && text.isEmpty) { return hypothesis }
        return text
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
