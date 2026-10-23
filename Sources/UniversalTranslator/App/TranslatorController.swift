import Foundation
import os

/// Starts, stops and reconfigures the active speech engine and translation pipeline.
@MainActor
final class TranslatorController {
    let settings: SettingsStore
    let captions: CaptionStore
    let translation: LiveTranslationController
    private let log = Logger(subsystem: "UniversalTranslator", category: "controller")

    private var engine: SpeechEngine?
    private(set) var isListening = false
    /// Listening, but audio is ignored until resumed (models stay loaded).
    private(set) var isPaused = false
    private var isTransitioning = false
    private var restartWork: DispatchWorkItem?
    var onStateChange: (() -> Void)?

    init(settings: SettingsStore, captions: CaptionStore) {
        self.settings = settings
        self.captions = captions
        translation = LiveTranslationController(captions: captions, settings: settings)
        settings.observe { [weak self] old, new in self?.settingsChanged(old, new) }
    }

    func toggle() {
        isListening ? stop() : start()
    }

    /// Pauses or resumes; starts listening if it isn't.
    func togglePause() {
        guard isListening else { return start() }
        guard !isTransitioning, let engine else { return }
        isPaused.toggle()
        engine.setPaused(isPaused)
        onStateChange?()
    }

    func start() {
        guard !isListening, !isTransitioning else { return }
        isTransitioning = true
        isListening = true
        onStateChange?()
        Task {
            await startEngine()
            isTransitioning = false
            onStateChange?()
        }
    }

    func stop() {
        guard isListening, !isTransitioning else { return }
        isTransitioning = true
        Task {
            await stopEngine()
            isTransitioning = false
            onStateChange?()
        }
    }

    private func startEngine() async {
        captions.status = .preparing("Preparing translation…")
        do {
            try checkRequiredModels()
            try await translation.configure()
            let recognizer = makeRecognizer()
            DebugLog.write("RECOGNIZER \(recognizer.name)")
            let engine = SpeechPipeline(settings: settings, captions: captions, translation: translation,
                                        recognizer: recognizer)
            self.engine = engine
            try await engine.start()
            log.info("Listening")
        } catch {
            log.error("Start failed: \(error.localizedDescription, privacy: .public)")
            DebugLog.write("START failed: \(error.localizedDescription)")
            await engine?.stop()
            engine = nil
            isListening = false
            captions.status = .error(error.localizedDescription)
            captions.touch()
        }
    }

    private func makeRecognizer() -> SpeechRecognizer {
        let kind = Self.recognizer(chosen: settings.settings.recognizer,
                                   nemotronReady: LocalModelStore.shared.isDownloaded(.nemotron(for: settings.settings.sourceLocale)),
                                   hasAppleModels: Platform.hasAppleModels)
        if #available(macOS 26, *), kind == .appleSpeech { return AppleRecognizer() }
        // Before macOS 26 Nemotron is the only recognizer; `checkRequiredModels()` made sure it's downloaded.
        return NemotronRecognizer()
    }

    /// Apple Speech when it's chosen or while Nemotron isn't downloaded, if the system has it; otherwise Nemotron.
    nonisolated static func recognizer(chosen: SpeechRecognizerKind, nemotronReady: Bool, hasAppleModels: Bool) -> SpeechRecognizerKind {
        hasAppleModels && (chosen == .appleSpeech || !nemotronReady) ? .appleSpeech : .nemotron
    }

    /// Before macOS 26 there's no Apple Speech or Translation to use while Nemotron or Hy-MT2 isn't downloaded, so
    /// listening needs them first.
    private func checkRequiredModels() throws {
        guard !Platform.hasAppleModels else { return }
        let missing = Self.requiredModels(for: settings.settings).filter { !LocalModelStore.shared.isDownloaded($0) }
        if !missing.isEmpty { throw EngineError.modelsRequired(missing.map(\.name)) }
    }

    /// The downloads listening needs where nothing can stand in for them (before macOS 26): Nemotron for the speech
    /// language, and the live Hy-MT2 model when it's the live translator.
    nonisolated static func requiredModels(for s: AppSettings) -> [LocalModel] {
        var required: [LocalModel] = [.nemotron(for: s.sourceLocale)]
        if s.translation.backend == .localLLM || s.translation.backend.needsAppleModels {
            required.append(.live(s.translation.localEngine))
        }
        return required
    }

    private func stopEngine() async {
        await engine?.stop()
        engine = nil
        isListening = false
        isPaused = false
        captions.status = .idle
        captions.isSpeaking = false
    }

    /// Restarts listening when a setting that the running engine depends on changes.
    private func settingsChanged(_ old: AppSettings, _ new: AppSettings) {
        if case .error = captions.status, !isListening { captions.status = .idle }
        guard isListening else { return }
        let needsRestart = old.sourceLocale != new.sourceLocale
            || old.recognizer != new.recognizer
            || old.targetLanguage != new.targetLanguage
            || old.inputDeviceUID != new.inputDeviceUID
            || old.audioSource != new.audioSource
            || old.sourceAppBundleID != new.sourceAppBundleID
            || old.translation.backend != new.translation.backend
            || old.translation.revision != new.translation.revision
            || old.translation.localEngine != new.translation.localEngine
            || old.timing.stability != new.timing.stability
            || old.timing.neuralVAD != new.timing.neuralVAD
            || old.timing.smartTurn != new.timing.smartTurn
            || old.translation.lmStudioURL != new.translation.lmStudioURL
            || old.translation.lmStudioModel != new.translation.lmStudioModel
            || old.translation.lmStudioTemplate != new.translation.lmStudioTemplate
            || old.translation.customInstructions != new.translation.customInstructions
            || old.translation.glossary != new.translation.glossary
            || old.translation.contextSentences != new.translation.contextSentences
        guard needsRestart else { return }
        // Debounced: text fields change on every keystroke.
        restartWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restart() }
        }
        restartWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    private func restart() {
        guard isListening, !isTransitioning else { return }
        isTransitioning = true
        Task {
            await engine?.stop()
            engine = nil
            await startEngine()
            if isPaused { engine?.setPaused(true) }
            isTransitioning = false
            onStateChange?()
        }
    }
}
