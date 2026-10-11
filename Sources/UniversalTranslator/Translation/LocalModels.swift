import Foundation
import LocalLLM
import LocalMLX
import Observation
import os
import TranslatorCore

/// An on-device model the app downloads from Hugging Face: a translation LLM (a GGUF file run with llama.cpp,
/// or an MLX model folder) or a Core ML speech model (a compiled `.mlmodelc` directory).
struct LocalModel: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let summary: String
    let repository: String
    /// Pinned commit (or "main").
    var revision = "main"
    /// Folder in the repository holding the files ("" = the repository root).
    var remoteFolder = ""
    /// Files to fetch, relative to `remoteFolder`.
    let files: [String]
    /// The file (single-file models) or folder the model is stored as in the models folder.
    let localName: String
    let bytes: Int64
    var contextLength = 4096
    /// Chat markers for translation models.
    var promptFormat: HyMT2Prompt.Format = .hy
    /// The runtime that loads a translation model.
    var engine: LocalEngine = .llamaCpp

    var isSingleFile: Bool { files == [localName] }

    func url(for file: String) -> URL {
        let path = remoteFolder.isEmpty ? file : remoteFolder + "/" + file
        return URL(string: "https://huggingface.co/\(repository)/resolve/\(revision)/\(path)")!
    }

    /// Fast live translator: Tencent Hy-MT2 1.8B (Apache-2.0), 4-bit.
    static let hyMT2Small = LocalModel(
        id: "hy-mt2-1.8b-q4", name: "Hy-MT2 1.8B",
        summary: "Fast on-device translation model for live captions (~150 tokens/s on Apple silicon).",
        repository: "tencent/Hy-MT2-1.8B-GGUF", files: ["Hy-MT2-1.8B-Q4_K_M.gguf"],
        localName: "Hy-MT2-1.8B-Q4_K_M.gguf", bytes: 1_133_080_448
    )

    /// Second-pass reviser: Tencent Hy-MT2 7B (Apache-2.0), 4-bit.
    static let hyMT2Large = LocalModel(
        id: "hy-mt2-7b-q4", name: "Hy-MT2 7B",
        summary: "Higher-quality on-device model for the second pass (about 4× slower than 1.8B).",
        repository: "tencent/Hy-MT2-7B-GGUF", files: ["Hy-MT2-7B-Q4_K_M.gguf"],
        localName: "Hy-MT2-7B-Q4_K_M.gguf", bytes: 4_620_000_000, promptFormat: .hunyuan
    )

    private static let mlxFiles = ["config.json", "generation_config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json"]

    /// Hy-MT2 1.8B for MLX, 8-bit. Tencent publishes GGUF only; this is a community conversion of Tencent's
    /// weights (pinned). The 4-bit MLX conversions lose more than llama.cpp's mixed 4/6-bit Q4_K_M: their live
    /// translations change more from word to word, so drafts are rejected more often and updates end up slower.
    static let hyMT2SmallMLX = LocalModel(
        id: "hy-mt2-1.8b-mlx-8bit", name: "Hy-MT2 1.8B (MLX, 8-bit)",
        summary: "The live translation model for the MLX engine. Closer to Tencent's full-precision model than the 4-bit llama.cpp build.",
        repository: "sahilchachra/hy-mt2-1.8b-8bit-mlx", revision: "03229cf1c62ff13a11b343e0da545ecf799a0810",
        files: mlxFiles, localName: "hy-mt2-1.8b-8bit-mlx", bytes: 1_912_776_186, engine: .mlx
    )

    /// Hy-MT2 7B for MLX, 4-bit (community conversion of Tencent's weights, pinned).
    static let hyMT2LargeMLX = LocalModel(
        id: "hy-mt2-7b-mlx-4bit", name: "Hy-MT2 7B (MLX, 4-bit)",
        summary: "The second-pass model for the MLX engine.",
        repository: "sahilchachra/hy-mt2-7b-4bit-mlx", revision: "dec81cca5b22983bf74d3c898ff57ddd8b0f20db",
        files: mlxFiles, localName: "hy-mt2-7b-4bit-mlx", bytes: 4_238_196_675, promptFormat: .hunyuan, engine: .mlx
    )

    private static let coreMLFiles = ["analytics/coremldata.bin", "coremldata.bin", "model.mil", "weights/weight.bin"]

    /// Silero VAD v6 (MIT), Core ML conversion by FluidInference: speech probability per 32 ms.
    static let sileroVAD = LocalModel(
        id: "silero-vad-v6", name: "Silero VAD v6",
        summary: "Neural voice detection: ignores keyboard, fans and music far better than a level meter.",
        repository: "FluidInference/silero-vad-coreml", revision: "b419383c55c110e2c9271fa6ee0ea83d03c70d96",
        remoteFolder: "silero-vad-unified-v6.0.0.mlmodelc", files: coreMLFiles + ["metadata.json"],
        localName: "silero-vad-unified-v6.0.0.mlmodelc", bytes: 911_498
    )

    /// Smart Turn v3.2 (BSD-2, Pipecat), Core ML conversion by soniqo: has the speaker finished the thought?
    static let smartTurn = LocalModel(
        id: "smart-turn-v3.2", name: "Smart Turn v3.2",
        summary: "End-of-turn model: hears whether a pause ends the thought (23 languages), from intonation and pace.",
        repository: "aufklarer/Smart-Turn-v3.2-CoreML", revision: "75f069717f500947195fa1945c46ddb472559cff",
        remoteFolder: "smart_turn.mlmodelc", files: coreMLFiles,
        localName: "smart_turn.mlmodelc", bytes: 16_785_094
    )

    private static let nemotronFiles = ["decoder", "decoder_joint", "encoder", "joint", "preprocessor"]
        .flatMap { name in coreMLFiles.map { "\(name).mlmodelc/\($0)" } } + ["metadata.json", "tokenizer.json"]

    /// NVIDIA Nemotron 3.5 ASR Streaming 0.6B (NVIDIA Open Model License), Core ML conversion by FluidInference,
    /// 560 ms chunks. The Latin-script build (en, es, fr, de, it, pt) has a smaller, faster vocabulary.
    static let nemotronLatin = LocalModel(
        id: "nemotron-asr-latin-560", name: "NVIDIA Nemotron Speech (Latin-script languages)",
        summary: "Streaming speech recognition for English, Spanish, French, German, Italian and Portuguese: words arrive every 0.56 s and never change.",
        repository: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
        revision: "1a41b75758b0337ff67db7d5408280aaaf23074e", remoteFolder: "latin/560ms", files: nemotronFiles,
        localName: "nemotron-asr-latin-560ms", bytes: 610_993_681
    )

    static let nemotronMultilingual = LocalModel(
        id: "nemotron-asr-multilingual-560", name: "NVIDIA Nemotron Speech (all languages)",
        summary: "Streaming speech recognition for 40 locales, including Chinese, Japanese, Korean, Hindi and Arabic.",
        repository: "FluidInference/Nemotron-3.5-ASR-Streaming-Multilingual-0.6b-CoreML",
        revision: "1a41b75758b0337ff67db7d5408280aaaf23074e", remoteFolder: "multilingual/560ms", files: nemotronFiles,
        localName: "nemotron-asr-multilingual-560ms", bytes: 663_797_881
    )

    /// The Nemotron build for a speech locale.
    static func nemotron(for locale: String) -> LocalModel {
        let code = Locale(identifier: locale).language.languageCode?.identifier ?? locale
        return ["en", "es", "fr", "de", "it", "pt"].contains(code) ? nemotronLatin : nemotronMultilingual
    }

    /// The live and second-pass translation models for an engine.
    static func live(_ engine: LocalEngine) -> LocalModel { engine == .mlx ? hyMT2SmallMLX : hyMT2Small }
    static func reviser(_ engine: LocalEngine) -> LocalModel { engine == .mlx ? hyMT2LargeMLX : hyMT2Large }

    static func translationModels(_ engine: LocalEngine) -> [LocalModel] { [live(engine), reviser(engine)] }
    static let translationModels = [hyMT2Small, hyMT2Large, hyMT2SmallMLX, hyMT2LargeMLX]
    static let speechModels = [sileroVAD, smartTurn]
    static let recognitionModels = [nemotronLatin, nemotronMultilingual]
    static let catalog = translationModels + speechModels + recognitionModels
}

/// Downloads, stores and loads on-device models. Loaded translation models are shared, so switching
/// settings doesn't reload them.
@MainActor
@Observable
final class LocalModelStore {
    static let shared = LocalModelStore()

    enum State: Equatable {
        case notDownloaded
        case downloading(Double)
        case ready
        case failed(String)
    }

    private(set) var states: [String: State] = [:]
    @ObservationIgnored private var downloads: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var transfers: [String: URLSessionDownloadTask] = [:]
    @ObservationIgnored private var runners: [String: any CompletionRunner] = [:]
    @ObservationIgnored private let log = Logger(subsystem: "UniversalTranslator", category: "models")

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Universal Translator/Models", isDirectory: true)
    }

    init() {
        for model in LocalModel.catalog { states[model.id] = isDownloaded(model) ? .ready : .notDownloaded }
    }

    func path(_ model: LocalModel) -> URL { Self.directory.appendingPathComponent(model.localName) }

    /// Bytes on disk (0 if not downloaded).
    func sizeOnDisk(_ model: LocalModel) -> Int64 {
        let url = path(model)
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else {
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    func isDownloaded(_ model: LocalModel) -> Bool {
        FileManager.default.fileExists(atPath: path(model).path)
    }

    func state(_ model: LocalModel) -> State { states[model.id] ?? .notDownloaded }

    /// Starts downloading in the background (progress is published in `states`).
    func download(_ model: LocalModel) {
        guard downloads[model.id] == nil, !isDownloaded(model) else { return }
        downloads[model.id] = Task { await self.perform(model) }
    }

    /// Downloads the model if needed and waits for it.
    func ensureDownloaded(_ model: LocalModel) async throws {
        if isDownloaded(model) { return }
        download(model)
        await downloads[model.id]?.value
        guard isDownloaded(model) else {
            if case .failed(let message) = state(model) { throw LocalModelError.downloadFailed(model.name, message) }
            throw CancellationError()
        }
    }

    private func perform(_ model: LocalModel) async {
        states[model.id] = .downloading(0)
        let staging = Self.directory.appendingPathComponent(".download-\(model.id)", isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: staging)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            var done: Int64 = 0
            for file in model.files {
                let destination = model.isSingleFile
                    ? staging.appendingPathComponent(file)
                    : staging.appendingPathComponent(model.localName).appendingPathComponent(file)
                try await fetch(model.url(for: file), to: destination, id: model.id) { [weak self] received in
                    self?.states[model.id] = .downloading(min(1, Double(done + received) / Double(max(model.bytes, 1))))
                }
                done += (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            }
            try? FileManager.default.removeItem(at: path(model))
            try FileManager.default.moveItem(at: staging.appendingPathComponent(model.localName), to: path(model))
            try? FileManager.default.removeItem(at: staging)
            states[model.id] = .ready
            log.info("Downloaded \(model.name, privacy: .public)")
        } catch {
            try? FileManager.default.removeItem(at: staging)
            let cancelled = (error as? URLError)?.code == .cancelled || error is CancellationError
            states[model.id] = cancelled ? .notDownloaded : .failed(error.localizedDescription)
            log.error("Download of \(model.name, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        downloads[model.id] = nil
        transfers[model.id] = nil
    }

    /// One file, with progress in bytes received (reported on the main actor).
    private func fetch(_ url: URL, to destination: URL, id: String,
                       progress: @escaping @MainActor (Int64) -> Void) async throws {
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        var observation: NSKeyValueObservation?
        defer { observation?.invalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let task = URLSession.shared.downloadTask(with: url) { location, response, error in
                if let error { return continuation.resume(throwing: error) }
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    return continuation.resume(throwing: LocalModelError.http(http.statusCode))
                }
                guard let location else { return continuation.resume(throwing: URLError(.badServerResponse)) }
                do {
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: location, to: destination)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            observation = task.observe(\.countOfBytesReceived) { task, _ in
                let received = task.countOfBytesReceived
                Task { @MainActor in progress(received) }
            }
            transfers[id] = task
            task.resume()
        }
    }

    func cancelDownload(_ model: LocalModel) {
        transfers[model.id]?.cancel()
        downloads[model.id]?.cancel()
    }

    /// Releases every loaded model (call when the app quits).
    func unloadAll() {
        runners.values.forEach { $0.close() }
        runners = [:]
    }

    func delete(_ model: LocalModel) {
        runners[model.id]?.close()
        runners[model.id] = nil
        try? FileManager.default.removeItem(at: path(model))
        states[model.id] = .notDownloaded
    }

    /// The loaded translation model, loading it on first use (a second or two).
    func runner(_ model: LocalModel) async throws -> any CompletionRunner {
        if let runner = runners[model.id] { return runner }
        guard isDownloaded(model) else { throw LocalModelError.notDownloaded(model.name) }
        let url = path(model)
        let started = Date()
        let runner: any CompletionRunner = try await Task.detached(priority: .userInitiated) {
            switch model.engine {
            case .llamaCpp: try LlamaRunner(modelPath: url.path, contextLength: model.contextLength, label: model.id)
            case .mlx: try await MLXRunner.load(directory: url, contextLength: model.contextLength, label: model.id)
            }
        }.value
        log.info("Loaded \(model.name, privacy: .public) in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")
        runners[model.id] = runner
        return runner
    }
}

enum LocalModelError: LocalizedError {
    case notDownloaded(String)
    case downloadFailed(String, String)
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notDownloaded(let name):
            return "\(name) isn't downloaded yet. Download it in Settings → Translation."
        case .downloadFailed(let name, let reason):
            return "\(name) couldn't be downloaded: \(reason)"
        case .http(let code):
            return "The server returned HTTP \(code)."
        }
    }
}

/// Translation with an on-device Hy-MT2 model (llama.cpp or MLX). Supports prefix forcing: the committed
/// translation is appended after the prompt, and the model continues it.
@MainActor
final class LocalLLMTranslator: SentenceTranslator {
    let supportsPrefix = true
    private let model: LocalModel
    private let targetName: String
    private let targetCode: String
    private let glossary: [GlossaryEntry]
    private let style: String
    private var runner: (any CompletionRunner)?
    /// The previous hypothesis, used as the speculative draft for the next update of the same utterance.
    private var lastHypothesis = ""

    init(model: LocalModel, targetName: String, targetCode: String, glossary: [GlossaryEntry] = [], style: String = "") {
        self.model = model
        self.targetName = targetName
        self.targetCode = targetCode
        self.glossary = glossary
        self.style = style
    }

    var qualityKey: String { "\(model.id)-\(targetCode)" }

    /// New tokens generated per live update. Enough look-ahead for the agreement check (research uses
    /// 16–24); shorter keeps updates fast under GPU load and the provisional tail steadier.
    static let liveTokenBudget = 12

    func prepare() async throws {
        let runner = try await LocalModelStore.shared.runner(model)
        self.runner = runner
        // Process the instructions once so the first caption doesn't pay for it.
        await runner.prewarm(prompt: HyMT2Prompt.make(source: "Hello.", targetName: targetName, targetCode: targetCode,
                                                      context: [], format: model.promptFormat))
    }

    func translate(source: String, prefix: String, context: [TranslationContext], isFinal: Bool) async throws -> String {
        if runner == nil { try await prepare() }
        guard let runner else { return source }
        let prompt = HyMT2Prompt.make(source: source, targetName: targetName, targetCode: targetCode, context: context,
                                      glossary: glossary, style: style, format: model.promptFormat) + prefix
        // Live steps only need the next few words: they're shown provisionally and agreed on next time.
        // Generating a whole speculative ending is slower and makes the provisional tail churn.
        let budget = isFinal ? HyMT2Prompt.maxTokens(forSource: source) : Self.liveTokenBudget
        // Draft: what the previous update said after the committed prefix (same utterance only).
        let draft = lastHypothesis.hasPrefix(prefix) && lastHypothesis.count > prefix.count
            ? String(lastHypothesis.dropFirst(prefix.count)) : nil
        let result = try await runner.complete(prompt: prompt, maxTokens: budget, draft: draft, healPrefix: !prefix.isEmpty,
                                               stop: model.promptFormat.stop)
        DebugLog.write(String(format: "LLM %@ prompt %d tok %.0fms, gen %d tok (%d from draft) %.0fms", model.id,
                              result.promptTokensProcessed, result.promptMilliseconds,
                              result.generatedTokens, result.draftTokensAccepted, result.generationMilliseconds))
        let hypothesis = prefix + result.text.trimmingCharacters(in: .newlines)
        lastHypothesis = isFinal ? "" : hypothesis
        return hypothesis
    }

    func cancelInFlight() {
        runner?.cancel()
    }
}
