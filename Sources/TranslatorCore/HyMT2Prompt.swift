import Foundation

/// Prompt format for Tencent's Hy-MT2 translation models (raw text; the special tokens are parsed by the
/// tokenizer). Earlier sentences go in the model's "background information" template so the translation
/// stays consistent; that part only changes between utterances, which keeps the prompt cache effective.
public enum HyMT2Prompt {
    /// The two sizes use different tokenizers and chat markers (from each GGUF's chat template). Prompting the
    /// 7B model with the 1.8B markers turns them into plain text, and it then rambles, answers questions
    /// instead of translating them, and writes its end marker out as text.
    public enum Format: String, Sendable {
        /// Hy-MT2 1.8B: `<｜hy_begin▁of▁sentence｜><｜hy_User｜>…<｜hy_Assistant｜>`.
        case hy
        /// Hy-MT2 7B (Hunyuan 7B tokenizer): `<|startoftext|>…<|extra_0|>`, ends with `<|eos|>`.
        case hunyuan

        var opening: String { self == .hy ? "<｜hy_begin▁of▁sentence｜><｜hy_User｜>" : "<|startoftext|>" }
        var assistant: String { self == .hy ? "<｜hy_Assistant｜>" : "<|extra_0|>" }
        var bos: String { self == .hy ? "<｜hy_begin▁of▁sentence｜>" : "<|startoftext|>" }
        /// Text a confused model may write instead of ending (never part of a translation).
        public var stop: [String] { self == .hy ? ["<｜", "｜>", "<|"] : ["<|", "<｜"] }
    }

    /// - Parameters:
    ///   - targetName: English name of the target language ("Japanese").
    ///   - targetCode: BCP-47 code; Chinese targets use the model's Chinese instructions.
    ///   - glossary: required term translations (only the ones present in `source` are included), in the
    ///     model's terminology format.
    ///   - style: optional style requirement ("polite and formal"), in the model's style format.
    public static func make(source: String, targetName: String, targetCode: String, context: [TranslationContext],
                            glossary: [GlossaryEntry] = [], style: String = "", format: Format = .hy) -> String {
        let chinese = targetCode.lowercased().hasPrefix("zh")
        var body: String
        if context.isEmpty {
            body = chinese
                ? "将以下文本翻译为中文，注意只需要输出翻译后的结果，不要额外解释：\n\n\(source)"
                : "Translate the following text into \(targetName). Note that you should only output the translated result without any additional explanation:\n\n\(source)"
        } else {
            let background = context.map(\.source).joined(separator: " ")
            body = chinese
                ? "【背景信息】\n\(background)\n\n请结合背景信息将以下文本翻译为中文，注意只需要输出翻译后的结果，不要额外解释。\n\n【待翻译文本】\n\(source)"
                : "[Background Information]\n\(background)\n\nPlease translate the following text into \(targetName), taking the provided background information into consideration. Note that you should only output the translated result without any additional explanation.\n\n[Source Text]\n\(source)"
        }
        let style = style.trimmingCharacters(in: .whitespacesAndNewlines)
        if !style.isEmpty {
            body += chinese ? "\n\n注意翻译的风格要严格符合【\(style)】" : "\n\nNote that the translation style must strictly conform to [\(style)]."
        }
        let terms = Glossary.matches(glossary, in: source)
        if !terms.isEmpty {
            let lines = terms.map { chinese ? "\($0.source) 翻译成 \($0.rendering)" : "\($0.source) translates to \($0.rendering)" }
            body = (chinese ? "参考下面的翻译：\n" : "Reference the following translations:\n") + lines.joined(separator: "\n") + "\n\n" + body
        }
        return format.opening + body + format.assistant
    }

    /// The prompt without its leading begin-of-sentence token, for servers that add it themselves.
    public static func withoutBOS(_ prompt: String) -> String {
        for format in [Format.hy, .hunyuan] where prompt.hasPrefix(format.bos) {
            return String(prompt.dropFirst(format.bos.count))
        }
        return prompt
    }

    /// Generation budget: translations rarely exceed ~2.5 tokens per source character for CJK targets.
    public static func maxTokens(forSource source: String) -> Int {
        min(512, 24 + source.count * 2)
    }
}
