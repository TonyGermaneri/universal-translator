import Foundation

/// Result of one completion with timing, for latency metrics.
public struct LocalCompletion: Sendable {
    public var text: String
    /// Prompt tokens that had to be processed (the rest came from the reused cache).
    public var promptTokensProcessed: Int
    public var generatedTokens: Int
    public var promptMilliseconds: Double
    public var generationMilliseconds: Double
    /// Draft tokens accepted by speculative verification.
    public var draftTokensAccepted: Int = 0

    public init(text: String, promptTokensProcessed: Int, generatedTokens: Int, promptMilliseconds: Double,
                generationMilliseconds: Double, draftTokensAccepted: Int = 0) {
        self.text = text
        self.promptTokensProcessed = promptTokensProcessed
        self.generatedTokens = generatedTokens
        self.promptMilliseconds = promptMilliseconds
        self.generationMilliseconds = generationMilliseconds
        self.draftTokensAccepted = draftTokensAccepted
    }
}

/// A loaded on-device model that completes raw prompts: llama.cpp (`LlamaRunner`) or MLX (`MLXRunner`).
/// Both keep one KV cache that is reused across calls, decode greedily, and support the same speculative
/// draft verification, token healing, UTF-8 validity and stop strings, so they're interchangeable.
public protocol CompletionRunner: AnyObject, Sendable {
    /// Greedy completion of a raw prompt (chat template already applied; special tokens are parsed).
    ///
    /// - Parameter draft: text the completion is expected to resemble (e.g. the previous re-translation).
    ///   Its tokens are verified in one batch and kept wherever the model nearly agrees with them
    ///   (speculative, stability-biased decoding, SSBD).
    /// - Parameter healPrefix: the prompt ends with forced output text (e.g. a committed translation). Its last
    ///   token is backed off and the first generated token must start with that text ("token healing").
    /// - Parameter stop: generation ends at the first of these strings (not included).
    func complete(prompt: String, maxTokens: Int, draft: String?, healPrefix: Bool, stop: [String]) async throws -> LocalCompletion
    /// Stops the running completion at its next token (it returns what it has so far).
    func cancel()
    /// Releases the model and its memory now.
    func close()
}

extension CompletionRunner {
    public func complete(prompt: String, maxTokens: Int) async throws -> LocalCompletion {
        try await complete(prompt: prompt, maxTokens: maxTokens, draft: nil, healPrefix: false, stop: [])
    }

    /// Processes a prompt ahead of time so the next call that extends it starts fast.
    public func prewarm(prompt: String) async {
        _ = try? await complete(prompt: prompt, maxTokens: 1)
    }
}

/// Decoding rules shared by the runners.
public enum Decoding {
    /// Bias toward the draft (SSBD uses β = 0.2): a draft token is kept if (1−β)·p(draft) + β ≥ (1−β)·p(best).
    public static let draftBias: Float = 0.2

    public static func keepsDraft(pDraft: Float, pBest: Float, bias: Float = draftBias) -> Bool {
        (1 - bias) * pDraft + bias >= (1 - bias) * pBest
    }

    /// Where the earliest stop sequence starts in `bytes`, if any.
    public static func firstMatch(of stops: [[UInt8]], in bytes: [UInt8]) -> Int? {
        var best: Int?
        for stop in stops where bytes.count >= stop.count {
            for start in 0...(bytes.count - stop.count) where best.map({ start < $0 }) ?? true {
                if bytes[start..<(start + stop.count)].elementsEqual(stop) { best = start; break }
            }
        }
        return best
    }
}

/// Tracks whether bytes so far end inside a multi-byte UTF-8 character, to keep generated text valid (a model
/// can start a multi-byte character with a byte token and never finish it).
public struct UTF8Tracker: Sendable {
    /// Continuation bytes still needed to finish the current character.
    public private(set) var needs = 0

    public init() {}

    public mutating func feed(_ bytes: [UInt8]) {
        for byte in bytes { advance(byte) }
    }

    /// Whether appending `bytes` keeps the text well formed.
    public func fits(_ bytes: [UInt8]) -> Bool {
        var copy = self
        for byte in bytes {
            let continuation = byte & 0xC0 == 0x80
            if (copy.needs > 0) != continuation { return false }
            copy.advance(byte)
        }
        return true
    }

    private mutating func advance(_ byte: UInt8) {
        if byte & 0xC0 == 0x80 {
            needs = max(0, needs - 1)
        } else {
            needs = byte >= 0xF0 ? 3 : byte >= 0xE0 ? 2 : byte >= 0xC0 ? 1 : 0
        }
    }
}
