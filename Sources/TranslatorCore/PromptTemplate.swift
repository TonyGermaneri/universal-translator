import Foundation

/// Chat templates for raw text completion (`/v1/completions`), so the assistant's reply can be *prefilled*
/// with the committed translation and the model continues it (prefix forcing), the way the on-device engine
/// works. The chat API can't do that, so its translations restart from scratch on every update.
public enum PromptTemplate: String, Codable, CaseIterable, Sendable {
    /// Picks a template from the model's name.
    case automatic
    case chatML
    /// ChatML with thinking switched off (Qwen 3).
    case qwen3
    case llama3
    case gemma
    case mistral
    case phi
    case hyMT2
    /// The chat API: no prefix forcing.
    case chatAPI

    public var title: String {
        switch self {
        case .automatic: return "Automatic (from the model name)"
        case .chatML: return "ChatML (Qwen 2.5, Hunyuan, many fine-tunes)"
        case .qwen3: return "Qwen 3 (thinking off)"
        case .llama3: return "Llama 3"
        case .gemma: return "Gemma"
        case .mistral: return "Mistral"
        case .phi: return "Phi 3 / 4"
        case .hyMT2: return "Hy-MT2 translation model"
        case .chatAPI: return "Chat API (no prefix forcing, slower captions)"
        }
    }

    /// The template for a model identifier such as "qwen/qwen3-8b" or "tencent/hy-mt2-1.8b".
    public static func detect(modelID: String) -> PromptTemplate {
        let id = modelID.lowercased()
        if id.contains("hy-mt") || id.contains("hymt") || id.contains("hunyuan-mt") { return .hyMT2 }
        if id.contains("qwen3") || id.contains("qwen-3") { return .qwen3 }
        if id.contains("qwen") || id.contains("hunyuan") || id.contains("yi-") || id.contains("openhermes") { return .chatML }
        if id.contains("llama-3") || id.contains("llama3") || id.contains("llama-4") { return .llama3 }
        if id.contains("gemma") { return .gemma }
        if id.contains("mistral") || id.contains("ministral") || id.contains("mixtral") { return .mistral }
        if id.contains("phi-3") || id.contains("phi-4") || id.contains("phi3") || id.contains("phi4") { return .phi }
        return .chatAPI
    }

    public func resolved(modelID: String) -> PromptTemplate {
        self == .automatic ? Self.detect(modelID: modelID) : self
    }

    public var supportsPrefix: Bool { self != .chatAPI && self != .automatic }

    /// The prompt up to and including the start of the assistant's reply, followed by `prefix`.
    public func render(system: String, user: String, prefix: String) -> String {
        switch self {
        case .chatML, .automatic, .chatAPI:
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n\(prefix)"
        case .qwen3:
            return "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n\(prefix)"
        case .llama3:
            return "<|start_header_id|>system<|end_header_id|>\n\n\(system)<|eot_id|><|start_header_id|>user<|end_header_id|>\n\n\(user)<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n\(prefix)"
        case .gemma:
            // No system role: the instructions open the user turn.
            return "<start_of_turn>user\n\(system)\n\n\(user)<end_of_turn>\n<start_of_turn>model\n\(prefix)"
        case .mistral:
            return "[INST] \(system)\n\n\(user) [/INST] \(prefix)"
        case .phi:
            return "<|system|>\n\(system)<|end|>\n<|user|>\n\(user)<|end|>\n<|assistant|>\n\(prefix)"
        case .hyMT2:
            // Hy-MT2 has its own prompt format (see `HyMT2Prompt`); `user` is that prompt.
            return user + prefix
        }
    }

    /// Text that ends the reply (the server stops there).
    public var stop: [String] {
        switch self {
        case .chatML, .qwen3, .automatic, .chatAPI: return ["<|im_end|>", "<|im_start|>"]
        case .llama3: return ["<|eot_id|>", "<|start_header_id|>"]
        case .gemma: return ["<end_of_turn>", "<start_of_turn>"]
        case .mistral: return ["</s>", "[INST]"]
        case .phi: return ["<|end|>", "<|user|>"]
        case .hyMT2: return ["<｜hy_end▁of▁sentence｜>", "<｜"]
        }
    }
}
