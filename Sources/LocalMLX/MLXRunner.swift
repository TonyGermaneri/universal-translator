import Foundation
import LocalLLM
import MLX
import MLXLLM
import MLXLMCommon
import MLXNN
import os

public enum MLXRunnerError: LocalizedError {
    case closed
    case promptTooLong(Int, Int)

    public var errorDescription: String? {
        switch self {
        case .closed: return "The model was unloaded."
        case .promptTooLong(let n, let max): return "Prompt is too long (\(n) tokens, limit \(max))."
        }
    }
}

/// A Hugging Face MLX model folder (`config.json`, `*.safetensors`, `tokenizer.json`) run with MLX on the GPU.
///
/// Same contract as `LlamaRunner`: one KV cache reused across calls (each call only processes the tokens after
/// the longest common prefix with the previous one), greedy decoding, speculative draft verification, token
/// healing, valid UTF-8 and stop strings. All MLX work runs on one serial queue, in a GPU stream of its own so
/// two runners (live and second pass) can work at the same time.
///
/// Decoding is pipelined: the forward pass for the next token is queued on the GPU before the current token is
/// read back, so the CPU work per token (building the graph, checks) overlaps with the GPU. A queued token that
/// turns out not to be wanted (end of text, stop string, broken character) is trimmed from the cache.
public final class MLXRunner: CompletionRunner, @unchecked Sendable {
    private let queue: DispatchQueue
    private var model: (any LanguageModel)?
    private let tokenizer: BPETokenizer
    /// Projects hidden states onto the vocabulary, for models whose final hidden states we can reach.
    private let head: ((MLXArray) -> MLXArray)?
    private var cache: [KVCache]
    /// Tokens currently held in the KV cache, in order.
    private var cached: [Int] = []
    /// Every token's text as bytes (special tokens: their marker text).
    private let pieces: [[UInt8]]
    /// Special tokens (chat markers, end of text) and IDs without a token: never part of a translation, so
    /// generating one ends the completion.
    private let special: [Bool]
    public let contextLength: Int
    private let cancelled = OSAllocatedUnfairLock(initialState: false)
    /// Bias toward the draft (see `Decoding.keepsDraft`).
    public var draftBias: Float = Decoding.draftBias
    /// Prompt tokens evaluated per forward pass.
    private let prefillStep = 512

    private init(model: any LanguageModel, tokenizer: BPETokenizer, vocabularySize: Int, endTokens: Set<Int>,
                 contextLength: Int, label: String) throws {
        self.model = model
        self.tokenizer = tokenizer
        // IDs without a token are never wanted (special); end-of-text IDs from the model's configuration too.
        let size = max(vocabularySize, tokenizer.pieces.count)
        pieces = tokenizer.pieces + Array(repeating: [], count: size - tokenizer.pieces.count)
        special = (0..<size).map { id in
            id >= tokenizer.pieces.count || tokenizer.specialIDs.contains(id) || endTokens.contains(id)
                || (tokenizer.pieces[id].isEmpty)
        }
        head = Self.vocabularyHead(of: model)
        self.contextLength = contextLength
        cache = try model.newCache(parameters: nil)
        queue = DispatchQueue(label: "LocalMLX.\(label)", qos: .userInteractive)
    }

    /// Loads the model folder (weights, then tokenizer). A second or two for a 1–4 GB model.
    public static func load(directory: URL, contextLength: Int = 4096, label: String = "mlx") async throws -> MLXRunner {
        // Freed GPU buffers are kept for reuse up to this size; MLX's default is most of the GPU's memory.
        Memory.cacheLimit = min(Memory.cacheLimit, 256 * 1024 * 1024)
        let configData = try Data(contentsOf: directory.appending(component: "config.json"))
        let base = try JSONDecoder.json5().decode(BaseConfiguration.self, from: configData)
        let model = try await LLMTypeRegistry.shared.createModel(configuration: configData, modelType: base.modelType)
        try await loadWeights(modelDirectory: directory, model: model, perLayerQuantization: base.perLayerQuantization)
        let tokenizer = try BPETokenizer(url: directory.appending(component: "tokenizer.json"))
        var endTokens = base.effectiveEOSTokenIds
        if let data = try? Data(contentsOf: directory.appending(component: "generation_config.json")),
           let generation = try? JSONDecoder.json5().decode(GenerationEOS.self, from: data) {
            endTokens.formUnion(generation.eosTokenIds?.values ?? [])
        }
        let vocabularySize = (try? JSONSerialization.jsonObject(with: configData) as? [String: Any])?["vocab_size"] as? Int ?? 0
        return try MLXRunner(model: model, tokenizer: tokenizer, vocabularySize: vocabularySize, endTokens: endTokens,
                             contextLength: contextLength, label: label)
    }

    public func close() {
        cancel()
        queue.sync {
            model = nil
            cache = []
            cached = []
        }
        Memory.clearCache()
    }

    public func cancel() {
        cancelled.withLock { $0 = true }
    }

    /// Token IDs of `text` (special tokens parsed), for comparing tokenizers.
    public func tokenIDs(_ text: String) -> [Int] {
        tokenizer.encode(text)
    }

    public func complete(prompt: String, maxTokens: Int, draft: String? = nil, healPrefix: Bool = false,
                         stop: [String] = []) async throws -> LocalCompletion {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result {
                    try Stream.withNewDefaultStream(device: .gpu) {
                        try self.run(prompt: prompt, maxTokens: maxTokens, draft: draft, heal: healPrefix, stop: stop)
                    }
                })
            }
        }
    }

    // MARK: - Internals (queue only)

    private func run(prompt: String, maxTokens: Int, draft: String?, heal: Bool, stop: [String]) throws -> LocalCompletion {
        guard let model else { throw MLXRunnerError.closed }
        cancelled.withLock { $0 = false }
        let stops = stop.map { Array($0.utf8) }.filter { !$0.isEmpty }
        var tokens = tokenizer.encode(prompt)
        // Token healing: back off the last token of the forced prefix and constrain the first new token.
        var healText: [UInt8] = []
        if heal, tokens.count > 1, let last = tokens.last, !special[last] {
            healText = pieces[last]
            tokens.removeLast()
        }
        guard tokens.count + maxTokens < contextLength else { throw MLXRunnerError.promptTooLong(tokens.count, contextLength) }
        let constraint: [UInt8]? = healText.isEmpty ? nil : healText
        // The draft to verify. When healing, it starts with the backed-off text.
        var draftText = draft ?? ""
        if !healText.isEmpty { draftText = (String(bytes: healText, encoding: .utf8) ?? "") + draftText }
        let draftTokens = draftText.isEmpty ? [] : Array(tokenizer.encode(draftText).prefix(maxTokens))

        // Reuse the cache for the shared prefix; at least one token must be processed to get fresh logits.
        var common = 0
        while common < cached.count, common < tokens.count, cached[common] == tokens[common] { common += 1 }
        if common == tokens.count { common -= 1 }
        trimCache(to: common)

        // The new prompt tokens and the draft go through the model together: one forward pass instead of two
        // (on Apple GPUs, MLX runs batches this small row by row, so each pass has a large fixed cost).
        let promptStart = DispatchTime.now()
        let rows = process(Array(tokens[common...]), then: draftTokens, model: model)
        cached.append(contentsOf: tokens[common...])
        let promptMs = Self.milliseconds(since: promptStart)

        let generationStart = DispatchTime.now()
        var bytes: [UInt8] = []
        // The text before the healed token sets the starting UTF-8 state.
        var utf8 = UTF8Tracker()
        utf8.feed(Array(Array(prompt.utf8).dropLast(healText.count).suffix(4)))
        var generated = 0
        var accepted = 0
        // The logits for the next position, and a token already chosen on the CPU for it (not yet in the cache).
        var row = rows[0]
        var next: Int?
        if !draftTokens.isEmpty {
            let result = verify(draftTokens, rows: rows, constraint: constraint, utf8: utf8)
            accepted = result.accepted.count
            for token in result.accepted {
                bytes += pieces[token]
                utf8.feed(pieces[token])
            }
            generated = accepted
            next = result.next
            if let last = result.row { row = last }
        } else if let constraint {
            next = choose(row, draft: nil, prefix: constraint, utf8: utf8)
        }

        // The next token as a GPU value, read back one step later.
        var pending = next.map { MLXArray(Int32($0)) } ?? argMax(row)
        while generated < maxTokens, !cancelled.withLock({ $0 }) {
            let nextRow = step(pending, model: model)
            let nextPending = argMax(nextRow)
            asyncEval(nextPending, nextRow)
            var token = pending.item(Int.self)
            if !special[token], !utf8.fits(pieces[token]) {
                // Rare: the best token breaks a character. Take the best one that doesn't and redo the step.
                trimCache(to: cached.count)
                token = choose(row, draft: nil, utf8: utf8)
                pending = MLXArray(Int32(token))
                continue
            }
            if special[token] {
                trimCache(to: cached.count)
                break
            }
            bytes += pieces[token]
            utf8.feed(pieces[token])
            if let cut = Decoding.firstMatch(of: stops, in: bytes) {
                bytes.removeSubrange(cut...)
                trimCache(to: cached.count)
                break
            }
            cached.append(token)
            generated += 1
            pending = nextPending
            row = nextRow
        }
        let generationMs = Self.milliseconds(since: generationStart)
        // The healed text was already part of the prompt's forced prefix.
        if !healText.isEmpty, bytes.starts(with: healText) { bytes.removeFirst(healText.count) }
        return LocalCompletion(text: String(decoding: bytes, as: UTF8.self),
                               promptTokensProcessed: tokens.count - common, generatedTokens: generated,
                               promptMilliseconds: promptMs, generationMilliseconds: generationMs,
                               draftTokensAccepted: accepted)
    }

    /// Drops cache entries after the first `count` tokens.
    private func trimCache(to count: Int) {
        let excess = (cache.first?.offset ?? 0) - count
        if excess > 0 { for layer in cache { layer.trim(excess) } }
        if cached.count > count { cached.removeSubrange(count...) }
    }

    /// One token (a GPU value) through the model: the logits that follow it.
    private func step(_ token: MLXArray, model: any LanguageModel) -> MLXArray {
        model(token.reshaped(1, 1), cache: cache)[0, 0]
    }

    /// Runs prompt tokens, then draft tokens, through the model (all into the cache) and returns the logits
    /// after the last prompt token and after each draft token, [draft + 1, vocabulary], evaluated. Only those
    /// positions are projected onto the vocabulary: projecting every prompt position onto Hy-MT2's 120k
    /// tokens would cost more than the rest of the model for a short update.
    private func process(_ prompt: [Int], then draft: [Int], model: any LanguageModel) -> MLXArray {
        var rest = prompt[...]
        while rest.count > prefillStep {
            // Lazily: only the cache is evaluated, so these positions' logits are never computed.
            _ = model(MLXArray(rest.prefix(prefillStep).map(Int32.init))[.newAxis], cache: cache)
            eval(cache)
            rest = rest.dropFirst(prefillStep)
        }
        let input = MLXArray((Array(rest) + draft).map(Int32.init))[.newAxis]
        let first = rest.count - 1
        let rows: MLXArray
        if let head, let hunyuan = model as? HunyuanModel {
            rows = head(hunyuan.model(input, cache: cache)[0, first...])
        } else {
            rows = model(input, cache: cache)[0, first...]
        }
        eval(rows)
        return rows
    }

    /// The output projection of the models whose hidden states `process` can reach.
    private static func vocabularyHead(of model: any LanguageModel) -> ((MLXArray) -> MLXArray)? {
        guard model is HunyuanModel else { return nil }
        let modules = Dictionary(model.namedModules(), uniquingKeysWith: { first, _ in first })
        if let head = modules["lm_head"] as? any UnaryLayer { return { head($0) } }
        if let embedding = modules["model.embed_tokens"] as? Embedding { return { embedding.asLinear($0) } }
        return nil
    }

    /// Judges the draft tokens (already in the cache) with the logits `process` returned: `rows[i]` predicts
    /// `draft[i]`. Drops the rejected tokens from the cache and returns the accepted prefix, the model's own
    /// choice where a draft token was rejected (not in the cache), or, when every draft token was accepted, the
    /// logits that follow the last one.
    private func verify(_ draft: [Int], rows: MLXArray, constraint: [UInt8]?, utf8: UTF8Tracker) -> (accepted: [Int], next: Int?, row: MLXArray?) {
        let start = cached.count
        cached.append(contentsOf: draft)
        // The first draft token is judged on the CPU (it may carry the healing constraint).
        let first = choose(rows[0], draft: draft[0], prefix: constraint, utf8: utf8)
        guard first == draft[0], !special[first] else {
            trimCache(to: start)
            return ([], first, nil)
        }
        var accepted = 1
        var correction: Int?
        if draft.count > 1 {
            // The rest on the GPU: per position, the best token, its logit, the draft token's logit, the normalizer.
            let judged = rows[1..<draft.count]
            let best = argMax(judged, axis: -1)
            let bestLogit = judged.max(axis: -1)
            let normalizer = logSumExp(judged, axis: -1)
            let candidates = MLXArray(draft.dropFirst().map(Int32.init)).expandedDimensions(axis: -1)
            let draftLogit = takeAlong(judged, candidates, axis: -1).squeezed(axis: -1)
            eval(best, bestLogit, normalizer, draftLogit)
            let bests = best.asArray(Int32.self).map(Int.init)
            let bestLogits = bestLogit.asType(.float32).asArray(Float.self)
            let draftLogits = draftLogit.asType(.float32).asArray(Float.self)
            let normalizers = normalizer.asType(.float32).asArray(Float.self)
            var utf8 = utf8
            utf8.feed(pieces[draft[0]])
            for i in 1..<draft.count {
                let candidate = draft[i]
                var choice = bests[i - 1]
                if !special[choice], !utf8.fits(pieces[choice]) {
                    choice = choose(rows[i], draft: candidate, utf8: utf8) // rare: full rules on the CPU
                } else if choice != candidate, !special[candidate], utf8.fits(pieces[candidate]) {
                    let pBest = exp(bestLogits[i - 1] - normalizers[i - 1])
                    let pDraft = exp(draftLogits[i - 1] - normalizers[i - 1])
                    if Decoding.keepsDraft(pDraft: pDraft, pBest: pBest, bias: draftBias) { choice = candidate }
                }
                guard choice == candidate, !special[choice] else {
                    correction = choice
                    break
                }
                accepted += 1
                utf8.feed(pieces[candidate])
            }
        }
        trimCache(to: start + accepted)
        if accepted < draft.count { return (Array(draft[..<accepted]), correction, nil) }
        return (draft, nil, rows[draft.count])
    }

    /// Greedy choice on the CPU with the same rules as `LlamaRunner`: with `prefix`, only tokens whose text
    /// starts with those bytes (token healing); tokens that would break a character are skipped; a near tie
    /// with `draft` keeps the draft (SSBD).
    private func choose(_ row: MLXArray, draft: Int?, prefix: [UInt8]? = nil, utf8: UTF8Tracker) -> Int {
        let logits = row.asType(.float32).asArray(Float.self)
        func best(_ allowed: (Int) -> Bool) -> Int? {
            var index: Int?
            var value = -Float.infinity
            for i in 0..<min(logits.count, pieces.count) where logits[i] > value && allowed(i) {
                value = logits[i]
                index = i
            }
            return index
        }
        let matchesPrefix = { (i: Int) in prefix.map { self.pieces[i].starts(with: $0) } ?? true }
        guard let top = best(matchesPrefix) ?? best({ _ in true }) else { return 0 }
        if !special[top], !utf8.fits(pieces[top]) {
            return best { matchesPrefix($0) && (self.special[$0] || utf8.fits(self.pieces[$0])) } ?? top
        }
        guard let draft, draft != top, draft < logits.count, !special[draft], utf8.fits(pieces[draft]), matchesPrefix(draft)
        else { return top }
        var sum: Float = 0
        for value in logits { sum += exp(value - logits[top]) }
        let pBest = 1 / sum
        let pDraft = exp(logits[draft] - logits[top]) / sum
        return Decoding.keepsDraft(pDraft: pDraft, pBest: pBest, bias: draftBias) ? draft : top
    }

    private static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e6
    }
}

/// `eos_token_id` in generation_config.json (one ID or a list).
private struct GenerationEOS: Decodable {
    var eosTokenIds: IntOrIntArray?
    enum CodingKeys: String, CodingKey { case eosTokenIds = "eos_token_id" }
}
