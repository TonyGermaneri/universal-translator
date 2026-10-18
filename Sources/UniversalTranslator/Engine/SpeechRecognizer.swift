import AVFoundation
import CoreMedia
import os
import Speech
import TranslatorCore

/// One recognizer result on the audio timeline: in-progress (volatile) text that may still change, or final
/// text that won't. `start`/`end` are seconds from the start of the audio fed to the recognizer.
struct RecognizerResult {
    var pieces: [TimedPiece]
    var isFinal: Bool
    var start: Double
    var end: Double
    var text: String { pieces.map(\.text).joined() }
}

/// A streaming speech recognizer behind the caption pipeline.
@MainActor
protocol SpeechRecognizer: AnyObject {
    var name: String { get }
    /// Delivers a final result for the turn right after `turnEnded(at:)`, so the pipeline waits for it instead of
    /// finishing the utterance with in-progress text.
    var finalizesTurns: Bool { get }
    /// Called with each result, on the main actor.
    var onResult: ((RecognizerResult) -> Void)? { get set }
    var onError: ((Error) -> Void)? { get set }
    /// Loads (and if needed downloads) the model for `locale`. `status` reports progress to the user.
    func prepare(locale: String, contextualStrings: [String], status: @escaping (String) -> Void) async throws
    /// Receives captured audio on the audio thread. Valid after `prepare`.
    func makeAudioSink() -> @Sendable (AVAudioPCMBuffer) -> Void
    /// The speaker's turn ended at this audio time (end of speech).
    func turnEnded(at endOfSpeech: Double)
    /// The speaker has been silent for a while since `endOfSpeech` (housekeeping: a recognizer that doesn't
    /// finalize on its own can do it now without clipping the next words).
    func longPause(after endOfSpeech: Double)
    /// No more audio: finalize the rest and deliver the last results.
    func finish() async
}

enum EngineError: LocalizedError {
    case speechUnavailable
    case unsupportedLocale(String)
    case noAudioFormat
    case microphoneDenied

    var errorDescription: String? {
        switch self {
        case .speechUnavailable: return "On-device speech recognition isn't available on this \(Platform.deviceName)."
        case .unsupportedLocale(let id): return "On-device speech recognition doesn't support \(id)."
        case .noAudioFormat: return "The speech model couldn't agree on an audio format."
        case .microphoneDenied:
            return Platform.isMac
                ? "Microphone access is off. Enable it in System Settings → Privacy & Security → Microphone."
                : "Microphone access is off. Enable it in Settings → Privacy & Security → Microphone."
        }
    }
}

// MARK: - Apple SpeechAnalyzer

/// Apple's on-device `SpeechTranscriber` through `SpeechAnalyzer`: punctuated, formatted text, with word
/// timings on final results. Runs on the Neural Engine in a system process, so it doesn't compete with the
/// translation model for the GPU. In-progress (volatile) results arrive about once per second of audio, as a
/// burst revealing a few words at a time; final results follow at pauses, about 0.7–1 s later.
///
/// It is never finalized early: forcing `finalize(through:)` while speech continues clips and garbles the next
/// words ("When a request comes in" → "in."; `DictationTranscriber` does the same). Instead, when the speaker's
/// turn ends, a second of silence is fed right away: the analyzer processes its pending audio immediately and
/// finalizes the way it does at any natural pause. Result times are mapped back to the real audio timeline.
///
/// iPhones and iPads without `SpeechTranscriber` use `DictationTranscriber`, the model behind keyboard dictation.
@MainActor
final class AppleRecognizer: SpeechRecognizer {
    let name = "Apple Speech"
    let finalizesTurns = false
    var onResult: ((RecognizerResult) -> Void)?
    var onError: ((Error) -> Void)?

    private var analyzer: SpeechAnalyzer?
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var format: AVAudioFormat?
    private let log = Logger(subsystem: "UniversalTranslator", category: "speech")
    /// Audio fed to the analyzer (real and injected), shared with the audio thread.
    private let timeline = OSAllocatedUnfairLock(initialState: AnalyzerTimeline())
    /// Silence fed at the end of each turn.
    nonisolated static let flushSilence = 1.0

    /// Whether this device only has the dictation model.
    static var usesDictation: Bool { !Platform.isMac && !SpeechTranscriber.isAvailable }

    static var supportedLocales: [Locale] {
        get async { usesDictation ? await DictationTranscriber.supportedLocales : await SpeechTranscriber.supportedLocales }
    }

    static var installedLocales: [Locale] {
        get async { usesDictation ? await DictationTranscriber.installedLocales : await SpeechTranscriber.installedLocales }
    }

    func prepare(locale identifier: String, contextualStrings: [String], status: @escaping (String) -> Void) async throws {
        guard SpeechTranscriber.isAvailable || Self.usesDictation else { throw EngineError.speechUnavailable }
        status("Loading speech model…")
        let module: any SpeechModule
        let locale: Locale
        if Self.usesDictation {
            guard let supported = await DictationTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
                throw EngineError.unsupportedLocale(identifier)
            }
            let transcriber = DictationTranscriber(locale: supported, contentHints: [], transcriptionOptions: [.punctuation],
                                                   reportingOptions: [.volatileResults, .frequentFinalization],
                                                   attributeOptions: [.audioTimeRange])
            resultsTask = Task { [weak self] in
                do {
                    for try await r in transcriber.results { self?.handle(r.text, range: r.range, isFinal: r.isFinal) }
                } catch {
                    self?.failed(error)
                }
            }
            (module, locale) = (transcriber, supported)
        } else {
            guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: identifier)) else {
                throw EngineError.unsupportedLocale(identifier)
            }
            let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [],
                                                reportingOptions: [.volatileResults, .fastResults],
                                                attributeOptions: [.audioTimeRange])
            resultsTask = Task { [weak self] in
                do {
                    for try await r in transcriber.results { self?.handle(r.text, range: r.range, isFinal: r.isFinal) }
                } catch {
                    self?.failed(error)
                }
            }
            (module, locale) = (transcriber, supported)
        }
        try await ensureAssets(for: module, locale: locale, status: status)

        let analyzer = SpeechAnalyzer(modules: [module],
                                      options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw EngineError.noAudioFormat
        }
        try await analyzer.prepareToAnalyze(in: format)
        // Glossary terms help recognition (names, products, jargon).
        if !contextualStrings.isEmpty {
            let context = AnalysisContext()
            context.contextualStrings[.general] = Array(contextualStrings.prefix(100))
            try? await analyzer.setContext(context)
        }
        let (stream, continuation) = AsyncStream.makeStream(of: AnalyzerInput.self)
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        self.continuation = continuation
        self.format = format
    }

    private func failed(_ error: Error) {
        log.error("Transcriber failed: \(error.localizedDescription)")
        onError?(error)
    }

    func makeAudioSink() -> @Sendable (AVAudioPCMBuffer) -> Void {
        guard let format, let continuation else { return { _ in } }
        let converter = BufferConverter()
        let log = log
        let timeline = timeline
        return { buffer in
            do {
                let converted = try converter.convert(buffer, to: format)
                timeline.withLock { t in
                    continuation.yield(AnalyzerInput(buffer: converted))
                    t.fed += Double(converted.frameLength) / format.sampleRate
                }
            } catch {
                log.error("Audio conversion failed: \(String(describing: error))")
            }
        }
    }

    /// Feeds a second of silence so the analyzer catches up and finalizes now (see the type's documentation).
    func turnEnded(at endOfSpeech: Double) {
        guard let format, let continuation,
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(format.sampleRate * Self.flushSilence))
        else { return }
        silence.frameLength = silence.frameCapacity
        let list = UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList)
        for buffer in list { if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) } }
        let at = timeline.withLock { t -> Double in
            continuation.yield(AnalyzerInput(buffer: silence))
            let at = t.fed
            t.injections.append((at, Self.flushSilence))
            t.fed += Self.flushSilence
            return at
        }
        DebugLog.write(String(format: "FLUSH %.1f s of silence at analyzer time %.2f (speech ended %.2f)", Self.flushSilence, at, endOfSpeech))
    }

    /// Nothing to do: `SpeechTranscriber` finalizes on its own at pauses.
    func longPause(after endOfSpeech: Double) {}

    func finish() async {
        continuation?.finish()
        continuation = nil
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        // Let the last results arrive, but don't hang if the stream never ends.
        if let task = resultsTask {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await task.value }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
            task.cancel()
        }
        resultsTask = nil
        analyzer = nil
    }

    private func handle(_ text: AttributedString, range: CMTimeRange, isFinal: Bool) {
        var pieces: [TimedPiece] = []
        for run in text.runs {
            let runRange = run.audioTimeRange
            pieces.append(TimedPiece(text: String(text[run.range].characters),
                                     start: runRange.flatMap { finite($0.start.seconds) },
                                     end: runRange.flatMap { finite($0.end.seconds) }))
        }
        let start = finite(range.start.seconds) ?? 0
        let end = finite(range.end.seconds) ?? start
        // Back to the real audio timeline (without the injected silence).
        let t = timeline.withLock { $0 }
        pieces = pieces.map { TimedPiece(text: $0.text, start: $0.start.map(t.real), end: $0.end.map(t.real)) }
        onResult?(RecognizerResult(pieces: pieces, isFinal: isFinal, start: t.real(start), end: t.real(end)))
    }

    private func finite(_ value: Double) -> Double? { value.isFinite ? value : nil }

    private func ensureAssets(for module: any SpeechModule, locale: Locale, status: @escaping (String) -> Void) async throws {
        let installed = await Self.installedLocales
        if !installed.contains(where: { $0.identifier(.bcp47) == locale.identifier(.bcp47) }) {
            do {
                try await AssetInventory.reserve(locale: locale)
            } catch {
                // Too many reserved locales: free one we aren't using and try again.
                for other in await AssetInventory.reservedLocales where other.identifier(.bcp47) != locale.identifier(.bcp47) {
                    await AssetInventory.release(reservedLocale: other)
                    break
                }
                try await AssetInventory.reserve(locale: locale)
            }
        }
        guard let request = try await AssetInventory.assetInstallationRequest(supporting: [module]) else { return }
        let name = LanguageNames.name(locale.identifier)
        let progress = request.progress
        let reporter = Task {
            while !Task.isCancelled {
                status("Downloading \(name) speech model… \(Int(progress.fractionCompleted * 100))%")
                try? await Task.sleep(for: .milliseconds(300))
            }
        }
        defer { reporter.cancel() }
        try await request.downloadAndInstall()
    }
}

/// The analyzer's timeline: real audio plus silence injected at the end of turns.
struct AnalyzerTimeline {
    /// Seconds of audio fed so far.
    var fed: Double = 0
    /// Where silence was injected (analyzer time) and for how long.
    var injections: [(at: Double, duration: Double)] = []

    /// Analyzer time → real audio time.
    func real(_ time: Double) -> Double {
        var shift = 0.0
        for injection in injections where injection.at < time {
            shift += min(injection.duration, time - injection.at)
        }
        return time - shift
    }
}
