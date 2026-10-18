import AVFoundation
import CoreML
import FluidAudio
import os
import TranslatorCore

/// NVIDIA Nemotron 3.5 ASR Streaming 0.6B on the Neural Engine (Core ML, through FluidAudio).
///
/// A cache-aware streaming RNN-T: audio is processed in 560 ms chunks and words are emitted once and never
/// revised, with punctuation and capitalization. At the end of each of the speaker's turns the current chunk is
/// completed with silence and decoded right away (about 15 ms), and the words since the previous turn are
/// reported as final. The stream itself continues: resetting it at every turn costs the model its context and
/// the next turn's first word ("Any questions" → "questions"), so it's only reset during long pauses (which
/// keeps punctuation from thinning out over long sessions).
@MainActor
final class NemotronRecognizer: SpeechRecognizer {
    let name = "NVIDIA Nemotron"
    let finalizesTurns = true
    var onResult: ((RecognizerResult) -> Void)?
    var onError: ((Error) -> Void)?

    private enum Item {
        case audio([Float])
        /// Carries where the speaker stopped, when known.
        case endTurn(Double?)
        case reset
    }

    /// Silence after which the stream is reset.
    static let resetPause = 3.0

    private var feed: AsyncStream<Item>.Continuation?
    private var worker: Task<Void, Never>?
    private var resetWork: DispatchWorkItem?
    private let log = Logger(subsystem: "UniversalTranslator", category: "nemotron")
    private static let analysisFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                                      interleaved: false)!

    func prepare(locale identifier: String, contextualStrings: [String], status: @escaping (String) -> Void) async throws {
        let model = LocalModel.nemotron(for: identifier)
        let store = LocalModelStore.shared
        guard store.isDownloaded(model) else { throw LocalModelError.notDownloaded(model.name) }
        status("Loading \(model.name)…")
        let directory = store.path(model)
        let started = Date()
        let manager = StreamingNemotronMultilingualAsrManager()
        let shared = try await StreamingNemotronMultilingualAsrManager.preloadShared(from: directory)
        try await manager.loadFromShared(shared)
        await manager.setLanguage(Locale(identifier: identifier).identifier(.bcp47))
        if !contextualStrings.isEmpty {
            await manager.setCustomVocabulary(contextualStrings.prefix(100).map { CustomVocabularyTerm(text: $0) })
        }
        log.info("Nemotron ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")

        let (stream, continuation) = AsyncStream.makeStream(of: Item.self)
        feed = continuation
        let deliver: @Sendable (RecognizerResult) -> Void = { [weak self] result in
            Task { @MainActor in self?.onResult?(result) }
        }
        let fail: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor in self?.onError?(error) }
        }
        worker = Task.detached(priority: .userInitiated) {
            await Self.run(manager: manager, items: stream, emit: deliver, failed: fail)
        }
    }

    /// Decodes the audio stream in order. Text is monotonic: everything after `finalized` characters is the
    /// turn in progress.
    private nonisolated static func run(manager: StreamingNemotronMultilingualAsrManager, items: AsyncStream<Item>,
                                        emit: @escaping @Sendable (RecognizerResult) -> Void,
                                        failed: @escaping @Sendable (Error) -> Void) async {
        let chunkSamples = await manager.config.chunkSamples
        var fed = 0.0              // seconds of real audio received
        var turnStart = 0.0        // where the turn in progress began
        var streamSamples = 0      // samples (real and padding) since the last reset
        var finalized = 0          // characters of the stream's text already reported as final
        var partial = ""
        do {
            for await item in items {
                switch item {
                case .audio(let samples):
                    fed += Double(samples.count) / 16_000
                    streamSamples += samples.count
                    _ = try await manager.process(samples: samples)
                    let text = Self.turnText(String(await manager.getPartialTranscript().dropFirst(finalized)))
                    if text != partial {
                        partial = text
                        emit(RecognizerResult(pieces: [TimedPiece(text: text, start: nil, end: nil)], isFinal: false,
                                              start: turnStart, end: fed - Double(streamSamples % chunkSamples) / 16_000))
                    }
                case .endTurn(let endOfSpeech):
                    let started = ProcessInfo.processInfo.systemUptime
                    let padding = (chunkSamples - streamSamples % chunkSamples) % chunkSamples
                    if padding > 0 {
                        _ = try await manager.process(samples: [Float](repeating: 0, count: padding))
                        streamSamples += padding
                    }
                    let all = await manager.getPartialTranscript()
                    let text = Self.turnText(String(all.dropFirst(finalized)))
                    finalized = all.count
                    DebugLog.write(String(format: "NEMOTRON turn %.0f ms | %@",
                                          (ProcessInfo.processInfo.systemUptime - started) * 1000, text))
                    emit(RecognizerResult(pieces: [TimedPiece(text: text, start: nil, end: nil)], isFinal: true,
                                          start: turnStart, end: fed, endOfSpeech: endOfSpeech))
                    turnStart = fed
                    partial = ""
                case .reset:
                    let all = try await manager.finish()
                    let rest = Self.turnText(String(all.dropFirst(finalized)))
                    if !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                        emit(RecognizerResult(pieces: [TimedPiece(text: rest, start: nil, end: nil)], isFinal: true,
                                              start: turnStart, end: fed))
                    }
                    await manager.reset()
                    DebugLog.write("NEMOTRON reset")
                    turnStart = fed
                    streamSamples = 0
                    finalized = 0
                    partial = ""
                }
            }
        } catch {
            failed(error)
        }
        await manager.cleanup()
    }

    /// The model punctuates a sentence once it hears what follows, so a turn's text can start with the previous
    /// turn's "," or "?". Drop it, and start the turn with a capital letter.
    nonisolated static func turnText(_ raw: String) -> String {
        var text = Substring(raw).drop { $0.isWhitespace || ($0.isPunctuation && !"¿¡\"'(".contains($0)) }
        guard let first = text.first, first.isLowercase else { return String(text) }
        text = text.dropFirst()
        return first.uppercased() + text
    }

    func makeAudioSink() -> @Sendable (AVAudioPCMBuffer) -> Void {
        guard let feed else { return { _ in } }
        let converter = BufferConverter()
        let format = Self.analysisFormat
        return { buffer in
            guard let converted = try? converter.convert(buffer, to: format), let data = converted.floatChannelData else { return }
            feed.yield(.audio(Array(UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength)))))
        }
    }

    func turnEnded(at endOfSpeech: Double) {
        resetWork?.cancel()
        feed?.yield(.endTurn(endOfSpeech))
    }

    func longPause(after endOfSpeech: Double) {
        resetWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.feed?.yield(.reset) }
        resetWork = work
        // `longPause` comes after 2 s of silence; reset a little later, if the speaker is still quiet.
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, Self.resetPause - 2.0), execute: work)
    }

    func finish() async {
        resetWork?.cancel()
        feed?.yield(.endTurn(nil))
        feed?.finish()
        feed = nil
        if let worker {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await worker.value }
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
        }
        worker = nil
    }
}
