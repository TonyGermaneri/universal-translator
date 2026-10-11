import Foundation
import FoundationModels
import Translation
import TranslatorCore

/// Translates a sentence, possibly unfinished, for the simultaneous policy (`SimulPolicy`).
@MainActor
protocol SentenceTranslator: AnyObject {
    /// Can continue a forced target prefix; the returned text then starts with `prefix`. Translators that
    /// can't return a full translation of `source` each time.
    var supportsPrefix: Bool { get }
    /// Translators with the same key produce the same output for the same input, so results can be reused.
    var qualityKey: String { get }
    func prepare() async throws
    func translate(source: String, prefix: String, context: [TranslationContext], isFinal: Bool) async throws -> String
    /// Abandons in-flight work so a more important request can run sooner.
    func cancelInFlight()
}

extension SentenceTranslator {
    func cancelInFlight() {}
}

enum TranslatorError: LocalizedError {
    case languagesNotInstalled(String, String)
    case unsupportedPair(String, String)
    case modelUnavailable(String)
    case noModelSelected

    var errorDescription: String? {
        switch self {
        case .languagesNotInstalled(let s, let t):
            return "The \(s) → \(t) translation languages aren't downloaded. Open Settings → Translation → Download languages."
        case .unsupportedPair(let s, let t):
            return "Apple Translation doesn't support \(s) → \(t)."
        case .modelUnavailable(let reason):
            return "The Apple Intelligence model is unavailable: \(reason)"
        case .noModelSelected:
            return "Choose an LM Studio model in Settings → Translation."
        }
    }
}

enum LanguageNames {
    static func name(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: code)
            ?? Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
    }

    /// "en-US" → "en"; "zh-Hans" stays "zh-Hans".
    static func translationLanguage(fromLocale identifier: String) -> Locale.Language {
        let locale = Locale(identifier: identifier)
        if let code = locale.language.languageCode?.identifier, code == "zh" {
            if locale.region?.identifier == "TW" || locale.region?.identifier == "HK" {
                return Locale.Language(identifier: "zh-Hant")
            }
            return Locale.Language(identifier: "zh-Hans")
        }
        return Locale.Language(identifier: locale.language.languageCode?.identifier ?? identifier)
    }
}

// MARK: - Apple Translation

/// Apple's on-device Translation framework. `.lowLatency` (~30–150 ms) drives live captions;
/// `.highFidelity` (~0.4–0.8 s) is better suited to the second pass.
@MainActor
final class AppleTranslator: SentenceTranslator {
    let supportsPrefix = false
    private let source: Locale.Language
    private let target: Locale.Language
    private var strategy: TranslationSession.Strategy
    private var session: TranslationSession?

    init(source: Locale.Language, target: Locale.Language, lowLatency: Bool) {
        self.source = source
        self.target = target
        strategy = lowLatency ? .lowLatency : .highFidelity
    }

    static func status(source: Locale.Language, target: Locale.Language) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }

    static func status(source: Locale.Language, target: Locale.Language, strategy: TranslationSession.Strategy) async -> LanguageAvailability.Status {
        await LanguageAvailability(preferredStrategy: strategy).status(from: source, to: target)
    }

    var qualityKey: String { "apple-\(strategy == .lowLatency ? "fast" : "hq")-\(source.minimalIdentifier)-\(target.minimalIdentifier)" }

    func prepare() async throws {
        // The low-latency model is a separate download; fall back to the standard model if it's missing.
        if strategy == .lowLatency {
            let fast = await Self.status(source: source, target: target, strategy: .lowLatency)
            DebugLog.write("APPLE low-latency \(source.maximalIdentifier)→\(target.maximalIdentifier): \(fast)")
            if fast != .installed { strategy = .highFidelity }
        }
        switch await Self.status(source: source, target: target, strategy: strategy) {
        case .installed:
            let session = TranslationSession(installedSource: source, target: target, preferredStrategy: strategy)
            self.session = session
            DebugLog.write("APPLE translator ready: \(qualityKey)")
            // Load the model now so the first caption isn't slow.
            _ = try? await session.translate("Hello.")
        case .supported:
            throw TranslatorError.languagesNotInstalled(LanguageNames.name(source.minimalIdentifier),
                                                        LanguageNames.name(target.minimalIdentifier))
        default:
            throw TranslatorError.unsupportedPair(LanguageNames.name(source.minimalIdentifier),
                                                  LanguageNames.name(target.minimalIdentifier))
        }
    }

    func translate(source text: String, prefix: String, context: [TranslationContext], isFinal: Bool) async throws -> String {
        if session == nil { try await prepare() }
        guard let session else { return text }
        let started = ProcessInfo.processInfo.systemUptime
        let result = try await session.translate(text).targetText
        DebugLog.write(String(format: "APPLE %@ %.0fms (%d chars)", strategy == .lowLatency ? "fast" : "hq",
                              (ProcessInfo.processInfo.systemUptime - started) * 1000, text.count))
        return result
    }

    func cancelInFlight() {
        guard let session else { return }
        session.cancel()
        self.session = TranslationSession(installedSource: source, target: target, preferredStrategy: strategy)
    }
}

// MARK: - Apple Intelligence (Foundation Models)

@MainActor
final class FoundationModelTranslator: SentenceTranslator {
    let supportsPrefix = false
    let qualityKey = "apple-intelligence"
    private let instructions: String
    private let model = SystemLanguageModel(useCase: .general, guardrails: .permissiveContentTransformations)

    init(sourceName: String, targetName: String, customInstructions: String, hint: String, glossary: [GlossaryEntry] = []) {
        instructions = Prompts.translationInstructions(source: sourceName, target: targetName, custom: customInstructions,
                                                       hint: hint, glossary: glossary)
    }

    func prepare() async throws {
        if case .unavailable(let reason) = model.availability {
            throw TranslatorError.modelUnavailable(String(describing: reason))
        }
        LanguageModelSession(model: model, instructions: instructions).prewarm()
    }

    func translate(source text: String, prefix: String, context: [TranslationContext], isFinal: Bool) async throws -> String {
        // A fresh session per request keeps the context window small; recent sentences go in the prompt instead.
        let session = LanguageModelSession(model: model, instructions: instructions)
        let response = try await session.respond(
            to: Prompts.translationPrompt(fragment: text, context: context, isFinal: isFinal),
            options: GenerationOptions(temperature: 0.2, maximumResponseTokens: 400)
        )
        return Prompts.stripReasoning(response.content)
    }
}

// MARK: - LM Studio

/// A model served by LM Studio (or any OpenAI-compatible server). With a known chat template it uses raw
/// completions and continues the committed translation (prefix forcing), like the on-device engine: live
/// updates generate a few tokens and the server reuses its prompt cache. Otherwise it falls back to the chat API.
@MainActor
final class LMStudioTranslator: SentenceTranslator {
    var supportsPrefix: Bool { template.supportsPrefix }
    var qualityKey: String { "lmstudio-\(model)" }
    private let client: OpenAICompatibleClient
    private let model: String
    private let instructions: String
    private let temperature: Double
    let template: PromptTemplate
    private let targetName: String
    private let targetCode: String
    private let glossary: [GlossaryEntry]
    private let style: String

    /// New tokens per live update (as for the on-device engine, a little more look-ahead over the network).
    static let liveTokenBudget = 16

    init(settings: TranslationSettings, sourceName: String, targetName: String, targetCode: String = "", hint: String) {
        client = OpenAICompatibleClient(baseURL: settings.lmStudioURL, apiKey: settings.lmStudioAPIKey)
        model = settings.lmStudioModel
        temperature = settings.temperature
        template = settings.lmStudioTemplate.resolved(modelID: settings.lmStudioModel)
        self.targetName = targetName
        self.targetCode = targetCode
        glossary = settings.glossary
        style = settings.customInstructions
        instructions = Prompts.translationInstructions(source: sourceName, target: targetName,
                                                       custom: settings.customInstructions, hint: hint,
                                                       glossary: settings.glossary)
    }

    func prepare() async throws {
        guard !model.isEmpty else { throw TranslatorError.noModelSelected }
        DebugLog.write("LMSTUDIO \(model) template=\(template.rawValue)")
    }

    func translate(source text: String, prefix: String, context: [TranslationContext], isFinal: Bool) async throws -> String {
        guard template.supportsPrefix else {
            return try await client.complete(
                model: model,
                messages: [
                    .init(role: "system", content: instructions),
                    .init(role: "user", content: Prompts.translationPrompt(fragment: text, context: context, isFinal: isFinal)),
                ],
                temperature: temperature,
                maxTokens: 400
            )
        }
        let user = template == .hyMT2
            ? HyMT2Prompt.withoutBOS(HyMT2Prompt.make(source: text, targetName: targetName, targetCode: targetCode,
                                                      context: context, glossary: glossary, style: style))
            : Prompts.translationPrompt(fragment: text, context: context, isFinal: isFinal)
        let prompt = template.render(system: instructions, user: user, prefix: prefix)
        let started = ProcessInfo.processInfo.systemUptime
        var continuation = try await client.completeText(
            model: model, prompt: prompt,
            maxTokens: isFinal ? HyMT2Prompt.maxTokens(forSource: text) : Self.liveTokenBudget,
            temperature: isFinal ? temperature : 0, stop: template.stop)
        // One sentence: anything after a line break is commentary.
        if prefix.isEmpty { continuation = String(continuation.drop { $0.isNewline }) }
        if let newline = continuation.firstIndex(where: \.isNewline) { continuation = String(continuation[..<newline]) }
        DebugLog.write(String(format: "LMSTUDIO %.0fms %@ | %@[%@]", (ProcessInfo.processInfo.systemUptime - started) * 1000,
                              isFinal ? "final" : "live ", prefix, continuation))
        return prefix + continuation
    }
}

/// Shows the recognized text unchanged (transcription-only mode).
@MainActor
final class PassthroughTranslator: SentenceTranslator {
    let supportsPrefix = false
    let qualityKey = "passthrough"
    func prepare() async throws {}
    func translate(source text: String, prefix: String, context: [TranslationContext], isFinal: Bool) async throws -> String { text }
}
