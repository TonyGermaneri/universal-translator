import Foundation
import llama
import os

public enum LlamaError: LocalizedError {
    case loadFailed(String)
    case contextFailed
    case tokenizeFailed
    case decodeFailed(Int32)
    case promptTooLong(Int, Int)

    public var errorDescription: String? {
        switch self {
        case .loadFailed(let path): return "Couldn't load the model at \(path)."
        case .contextFailed: return "Couldn't create the model context."
        case .tokenizeFailed: return "Couldn't tokenize the prompt."
        case .decodeFailed(let code): return "The model failed to decode (code \(code))."
        case .promptTooLong(let n, let max): return "Prompt is too long (\(n) tokens, limit \(max))."
        }
    }
}

/// A loaded GGUF model with one KV cache that is reused across calls.
///
/// Consecutive prompts in simultaneous translation share most of their text (instructions, context and
/// the sentence so far), so each call only processes the tokens after the longest common prefix with the
/// previous call. Decoding is greedy, which keeps re-translations stable. All llama.cpp calls run on one
/// serial queue; `cancel()` can be called from anywhere and stops generation at the next token.
public final class LlamaRunner: CompletionRunner, @unchecked Sendable {
    private let queue: DispatchQueue
    private let model: OpaquePointer
    private let context: OpaquePointer
    private let vocab: OpaquePointer
    private let sampler: UnsafeMutablePointer<llama_sampler>
    private let batchSize: Int
    public let contextLength: Int
    /// Tokens currently held in the KV cache (sequence 0), in order.
    private var cached: [llama_token] = []
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    private var isClosed = false

    private static let backend: Void = { llama_backend_init() }()

    public init(modelPath: String, contextLength: Int = 4096, label: String = "llama") throws {
        _ = Self.backend
        var modelParams = llama_model_default_params()
        modelParams.n_gpu_layers = 999 // everything on the GPU (Metal)
        guard let model = llama_model_load_from_file(modelPath, modelParams) else {
            throw LlamaError.loadFailed(modelPath)
        }
        var contextParams = llama_context_default_params()
        contextParams.n_ctx = UInt32(contextLength)
        contextParams.n_batch = 512
        contextParams.n_ubatch = 512
        let threads = Int32(max(1, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))
        contextParams.n_threads = threads
        contextParams.n_threads_batch = threads
        guard let context = llama_init_from_model(model, contextParams) else {
            llama_model_free(model)
            throw LlamaError.contextFailed
        }
        self.model = model
        self.context = context
        vocab = llama_model_get_vocab(model)
        sampler = llama_sampler_init_greedy()
        batchSize = 512
        self.contextLength = contextLength
        queue = DispatchQueue(label: "LocalLLM.\(label)", qos: .userInteractive)
    }

    deinit {
        free()
    }

    /// Releases the model and its GPU memory now. Call before the process exits: llama.cpp's Metal backend
    /// asserts if a model is still loaded when its static teardown runs.
    public func close() {
        cancel()
        queue.sync { free() }
    }

    private func free() {
        guard !isClosed else { return }
        isClosed = true
        llama_sampler_free(sampler)
        llama_free(context)
        llama_model_free(model)
    }

    /// Stops the running completion at its next token (it returns what it has so far).
    public func cancel() {
        cancelled.withLock { $0 = true }
    }

    /// Token IDs of `text` (special tokens parsed), for comparing tokenizers.
    public func tokenIDs(_ text: String) throws -> [Int] {
        try queue.sync { try tokenize(text).map(Int.init) }
    }

    /// See `CompletionRunner.complete`.
    public func complete(prompt: String, maxTokens: Int, draft: String? = nil, healPrefix: Bool = false,
                         stop: [String] = []) async throws -> LocalCompletion {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try self.run(prompt: prompt, maxTokens: maxTokens, draft: draft,
                                                                heal: healPrefix, stop: stop))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Internals (queue only)

    /// Bias toward the draft (see `Decoding.keepsDraft`).
    public var draftBias: Float = Decoding.draftBias

    private func run(prompt: String, maxTokens: Int, draft: String?, heal: Bool, stop: [String] = []) throws -> LocalCompletion {
        let stops = stop.map { Array($0.utf8) }.filter { !$0.isEmpty }
        guard !isClosed else { throw LlamaError.contextFailed }
        cancelled.withLock { $0 = false }
        var tokens = try tokenize(prompt)
        // Token healing: back off the last token of the forced prefix and constrain the first new token.
        var healText: [UInt8] = []
        if heal, tokens.count > 1, let last = tokens.last, !llama_vocab_is_control(vocab, last) {
            healText = piece(last)
            tokens.removeLast()
        }
        guard tokens.count + maxTokens < contextLength else { throw LlamaError.promptTooLong(tokens.count, contextLength) }

        // Reuse the cache for the shared prefix; at least one token must be decoded to get fresh logits.
        var common = 0
        while common < cached.count, common < tokens.count, cached[common] == tokens[common] { common += 1 }
        if common == tokens.count { common -= 1 }
        let memory = llama_get_memory(context)
        if !llama_memory_seq_rm(memory, 0, Int32(common), -1) {
            llama_memory_clear(memory, true)
            common = 0
        }
        cached.removeSubrange(common...)

        let promptStart = DispatchTime.now()
        var index = common
        while index < tokens.count {
            let count = min(batchSize, tokens.count - index)
            let rc = tokens.withUnsafeMutableBufferPointer { buffer in
                llama_decode(context, llama_batch_get_one(buffer.baseAddress! + index, Int32(count)))
            }
            guard rc == 0 else {
                llama_memory_clear(memory, true)
                cached = []
                throw LlamaError.decodeFailed(rc)
            }
            index += count
        }
        cached.append(contentsOf: tokens[common...])
        let promptMs = Double(DispatchTime.now().uptimeNanoseconds - promptStart.uptimeNanoseconds) / 1e6

        let generationStart = DispatchTime.now()
        var bytes: [UInt8] = []
        // Generated text must stay valid UTF-8 (a model can start a multi-byte character with a byte token and
        // never finish it). The text before the healed token sets the starting state.
        var utf8 = UTF8Tracker()
        utf8.feed(Array(Array(prompt.utf8).dropLast(healText.count).suffix(4)))
        var generated = 0
        var accepted = 0
        let constraint: [UInt8]? = healText.isEmpty ? nil : healText
        // Speculative verification of the draft; `next` is the token chosen after it, if any. When healing,
        // the draft starts with the backed-off text (only if that text is whole UTF-8).
        var next: llama_token?
        var draftText = draft
        if !healText.isEmpty {
            draftText = String(bytes: healText, encoding: .utf8).map { $0 + (draft ?? "") }
        }
        var constrainedFirst = constraint != nil
        if let draftText, !draftText.isEmpty, let draftTokens = try? tokenize(draftText), !draftTokens.isEmpty {
            let result = try verify(Array(draftTokens.prefix(maxTokens)), constraint: constraint, utf8: utf8)
            accepted = result.accepted.count
            for token in result.accepted {
                bytes += piece(token)
                utf8.feed(piece(token))
            }
            generated = accepted
            next = result.next
            constrainedFirst = false // verify() applied the constraint to the first position
        }
        while generated < maxTokens, !cancelled.withLock({ $0 }) {
            var token: llama_token
            if let chosen = next {
                token = chosen
            } else if let logits = llama_get_logits_ith(context, -1) {
                token = choose(logits, vocabSize: Int(llama_vocab_n_tokens(vocab)), draft: nil,
                               prefix: constrainedFirst ? constraint : nil, utf8: utf8)
            } else {
                token = llama_sampler_sample(sampler, context, -1)
            }
            next = nil
            constrainedFirst = false
            if llama_vocab_is_eog(vocab, token) { break }
            bytes += piece(token)
            utf8.feed(piece(token))
            if let cut = Decoding.firstMatch(of: stops, in: bytes) {
                bytes.removeSubrange(cut...)
                break
            }
            let rc = llama_decode(context, llama_batch_get_one(&token, 1))
            guard rc == 0 else { throw LlamaError.decodeFailed(rc) }
            cached.append(token)
            generated += 1
        }
        let generationMs = Double(DispatchTime.now().uptimeNanoseconds - generationStart.uptimeNanoseconds) / 1e6
        // The healed text was already part of the prompt's forced prefix.
        if !healText.isEmpty, bytes.starts(with: healText) { bytes.removeFirst(healText.count) }
        return LocalCompletion(text: String(decoding: bytes, as: UTF8.self),
                               promptTokensProcessed: tokens.count - common, generatedTokens: generated,
                               promptMilliseconds: promptMs, generationMilliseconds: generationMs,
                               draftTokensAccepted: accepted)
    }

    /// Checks draft tokens against the model in a single batch. Returns the accepted prefix (already in the
    /// KV cache) and, when a draft token was rejected, the model's own choice at that position (not yet
    /// decoded). When every draft token is accepted, the last logits are left in place for normal sampling.
    private func verify(_ draft: [llama_token], constraint: [UInt8]?, utf8: UTF8Tracker) throws -> (accepted: [llama_token], next: llama_token?) {
        let vocabSize = Int(llama_vocab_n_tokens(vocab))
        var utf8 = utf8
        // The first draft token is judged by the logits the prompt left behind (and the healing constraint).
        guard let promptLogits = llama_get_logits_ith(context, -1) else { return ([], nil) }
        let first = choose(promptLogits, vocabSize: vocabSize, draft: draft[0], prefix: constraint, utf8: utf8)
        guard first == draft[0], !llama_vocab_is_eog(vocab, first) else { return ([], first) }

        // Decode every draft token at once, asking for logits at each position.
        let start = Int32(cached.count)
        var batch = llama_batch_init(Int32(draft.count), 0, 1)
        defer { llama_batch_free(batch) }
        for (i, token) in draft.enumerated() {
            batch.token[i] = token
            batch.pos[i] = start + Int32(i)
            batch.n_seq_id[i] = 1
            batch.seq_id[i]![0] = 0
            batch.logits[i] = 1
        }
        batch.n_tokens = Int32(draft.count)
        let rc = llama_decode(context, batch)
        guard rc == 0 else { throw LlamaError.decodeFailed(rc) }

        var accepted = 1
        var correction: llama_token?
        utf8.feed(piece(draft[0]))
        for i in 1..<draft.count {
            guard let logits = llama_get_logits_ith(context, Int32(i - 1)) else { break }
            let choice = choose(logits, vocabSize: vocabSize, draft: draft[i], utf8: utf8)
            if choice == draft[i], !llama_vocab_is_eog(vocab, choice) {
                accepted += 1
                utf8.feed(piece(choice))
            } else {
                correction = choice
                break
            }
        }
        if accepted < draft.count, correction == nil, let logits = llama_get_logits_ith(context, Int32(accepted - 1)) {
            correction = choose(logits, vocabSize: vocabSize, draft: nil, utf8: utf8)
        }
        // Drop the rejected draft tokens from the cache.
        if accepted < draft.count {
            _ = llama_memory_seq_rm(llama_get_memory(context), 0, start + Int32(accepted), -1)
        }
        cached.append(contentsOf: draft[..<accepted])
        return (Array(draft[..<accepted]), accepted < draft.count ? correction : nil)
    }

    /// Greedy choice, biased toward the draft token (SSBD). With `prefix`, only tokens whose text starts
    /// with those bytes are allowed (token healing). Tokens that would make the text invalid UTF-8 are skipped.
    private func choose(_ logits: UnsafeMutablePointer<Float>, vocabSize: Int, draft: llama_token?,
                        prefix: [UInt8]? = nil, utf8: UTF8Tracker = UTF8Tracker()) -> llama_token {
        var best = -1
        var bestLogit = -Float.infinity
        let table = pieceTable(vocabSize)
        for i in 0..<vocabSize where logits[i] > bestLogit {
            if let prefix, !table[i].starts(with: prefix) { continue }
            bestLogit = logits[i]
            best = i
        }
        if best < 0 { return choose(logits, vocabSize: vocabSize, draft: draft, utf8: utf8) } // nothing matched: unconstrained
        if !llama_vocab_is_control(vocab, llama_token(best)), !utf8.fits(table[best]) {
            // Rare: the best token breaks a character. Take the best one that doesn't.
            best = -1
            bestLogit = -Float.infinity
            for i in 0..<vocabSize where logits[i] > bestLogit && utf8.fits(table[i]) {
                if let prefix, !table[i].starts(with: prefix) { continue }
                bestLogit = logits[i]
                best = i
            }
            if best < 0 { return choose(logits, vocabSize: vocabSize, draft: nil) }
            return llama_token(best)
        }
        if let draft, Int(draft) < vocabSize, !utf8.fits(table[Int(draft)]) { return llama_token(best) }
        if let prefix, let draft, !table[Int(draft)].starts(with: prefix) { return llama_token(best) }
        guard let draft, Int(draft) != best, Int(draft) < vocabSize else { return llama_token(best) }
        var sum: Float = 0
        for i in 0..<vocabSize { sum += expf(logits[i] - bestLogit) }
        let pBest = 1 / sum
        let pDraft = expf(logits[Int(draft)] - bestLogit) / sum
        return Decoding.keepsDraft(pDraft: pDraft, pBest: pBest, bias: draftBias) ? draft : llama_token(best)
    }

    private func tokenize(_ text: String) throws -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 16)
        var count = text.withCString { llama_tokenize(vocab, $0, length, &tokens, Int32(tokens.count), false, true) }
        if count < 0 {
            tokens = [llama_token](repeating: 0, count: Int(-count))
            count = text.withCString { llama_tokenize(vocab, $0, length, &tokens, Int32(tokens.count), false, true) }
        }
        guard count >= 0 else { throw LlamaError.tokenizeFailed }
        return Array(tokens.prefix(Int(count)))
    }

    private var pieces: [[UInt8]] = []

    /// Every token's text, built once (used to find tokens that extend a healed prefix).
    private func pieceTable(_ vocabSize: Int) -> [[UInt8]] {
        if pieces.count != vocabSize { pieces = (0..<vocabSize).map { piece(llama_token($0)) } }
        return pieces
    }

    private func piece(_ token: llama_token) -> [UInt8] {
        var buffer = [CChar](repeating: 0, count: 64)
        var n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        if n < 0 {
            buffer = [CChar](repeating: 0, count: Int(-n))
            n = llama_token_to_piece(vocab, token, &buffer, Int32(buffer.count), 0, false)
        }
        return buffer.prefix(Int(max(n, 0))).map { UInt8(bitPattern: $0) }
    }
}
