import AVFoundation
import os
import TranslatorCore

@MainActor
protocol SpeechEngine: AnyObject {
    func start() async throws
    func stop() async
    /// While paused, captured audio is dropped (models stay loaded); the utterance in progress is finished.
    func setPaused(_ paused: Bool)
}

/// Streaming speech → simultaneous translation.
///
/// Captured audio goes to the speech recognizer and to the `Endpointer` (voice activity and end-of-turn
/// detection). Recognizer results build a `TranscriptBuffer`; on every result and every 50 ms tick, the
/// `SourceFrontier` picks out the utterance in progress (stable words only) and hands it to the
/// `LiveTranslationController`. When the endpointer decides the speaker's turn is over, the utterance is
/// finished with the recognizer's text so far (once it has caught up with the end of speech), without waiting
/// for the recognizer's own finalization; the final transcript, when it arrives, feeds the second pass.
@MainActor
final class SpeechPipeline: SpeechEngine {
    private let settings: SettingsStore
    private let captions: CaptionStore
    private let translation: LiveTranslationController
    private let recognizer: SpeechRecognizer
    private let log = Logger(subsystem: "UniversalTranslator", category: "pipeline")

    private let capture = AudioCapture()
    private var endpointer: Endpointer?
    private var timer: Timer?

    private var transcript = TranscriptBuffer()
    private var frontier = SourceFrontier()
    private var latest = Endpointer.Snapshot()

    /// The end of the speaker's last turn, until its words have been translated. `resumedAt`: speech that
    /// started after the pause belongs to the next utterance.
    private struct Boundary {
        var endOfSpeech: Double
        var resumedAt: Double?
    }
    private var boundary: Boundary?
    private var handledTurnEnd: Double = -1
    private var handledLongPause: Double = -1
    /// The recognizer's text is complete up to the end of speech once its in-progress result covers this much
    /// audio past it (the last word needs some right context).
    static let rightContext = 0.2
    /// Silence after which the recognizer may finalize without clipping the next words.
    static let longPause = 2.0
    /// Results arrive in bursts that reveal a few words at a time within milliseconds ("the d", "the data",
    /// "the database"); the text is only complete once the burst is over.
    static let burstGap = 0.1
    private var lastResultAt: Double = 0
    /// Shared with the audio thread: drop audio while paused.
    private let paused = OSAllocatedUnfairLock(initialState: false)
    private var pausedAt: Double?

    init(settings: SettingsStore, captions: CaptionStore, translation: LiveTranslationController, recognizer: SpeechRecognizer) {
        self.settings = settings
        self.captions = captions
        self.translation = translation
        self.recognizer = recognizer
        settings.observe { [weak self] old, new in
            guard let self else { return }
            if old.micSensitivity != new.micSensitivity || old.timing != new.timing {
                self.endpointer?.update(sensitivity: new.micSensitivity, timing: new.timing)
                self.applyTiming(new.timing)
            }
        }
    }

    private func applyTiming(_ timing: TimingSettings) {
        frontier.holdBack = timing.holdBack
        frontier.maxSentenceWords = timing.maxSentenceWords
    }

    // MARK: Lifecycle

    func start() async throws {
        let s = settings.settings
        guard await AudioCapture.requestPermission(for: s.audioSource) else { throw EngineError.microphoneDenied }
        let status: (String) -> Void = { [weak self] message in self?.captions.status = .preparing(message) }

        let terms = s.translation.glossary.map(\.source).filter { !$0.isEmpty }
        try await recognizer.prepare(locale: s.sourceLocale, contextualStrings: terms, status: status)
        status("Loading voice detection…")
        let (vad, turnModel) = await Endpointer.loadModels(timing: s.timing, status: status)
        endpointer = Endpointer(sensitivity: s.micSensitivity, timing: s.timing, vad: vad, turnModel: turnModel)

        transcript.reset()
        frontier = SourceFrontier()
        applyTiming(s.timing)
        boundary = nil
        handledTurnEnd = -1
        handledLongPause = -1
        translation.onSentenceFinished = { [weak self] tokens, id in self?.sentenceFinished(tokens, id: id) }
        recognizer.onResult = { [weak self] result in self?.handle(result) }
        recognizer.onError = { [weak self] error in self?.captions.status = .error(error.localizedDescription) }

        status(s.audioSource == .microphone ? "Starting microphone…" : "Starting audio capture…")
        try startCapture()
        captions.status = .listening
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() async {
        timer?.invalidate()
        timer = nil
        capture.stop()
        await recognizer.finish()

        // Translate whatever is left before stopping.
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline, !transcript.pending().tokens.isEmpty || translation.isBusy {
            evaluate(flushAll: true)
            try? await Task.sleep(for: .milliseconds(60))
        }
        captions.liveSource = ""
        captions.isSpeaking = false
    }

    private func startCapture() throws {
        guard let endpointer else { return }
        let sink = recognizer.makeAudioSink()
        let paused = paused
        capture.onBuffer = { @Sendable buffer in
            guard !paused.withLock({ $0 }) else { return }
            endpointer.process(buffer)
            sink(buffer)
        }
        capture.onConfigurationChange = { [weak self] in
            MainActor.assumeIsolated { self?.restartCapture() }
        }
        try capture.start(settings: settings.settings)
    }

    /// The input device changed under the engine (unplugged headset, new default mic).
    private func restartCapture() {
        capture.stop()
        do {
            try startCapture()
        } catch {
            captions.status = .error(error.localizedDescription)
        }
    }

    func setPaused(_ value: Bool) {
        paused.withLock { $0 = value }
        if value {
            pausedAt = ProcessInfo.processInfo.systemUptime
            // Finish what was being said.
            if boundary == nil { boundary = Boundary(endOfSpeech: latest.time) }
            recognizer.turnEnded(at: latest.time)
            captions.isSpeaking = false
            captions.status = .paused
            DebugLog.write("PAUSED")
        } else {
            pausedAt = nil
            captions.status = .listening
            DebugLog.write("RESUMED")
        }
    }

    // MARK: Recognition results

    private func handle(_ result: RecognizerResult) {
        lastResultAt = ProcessInfo.processInfo.systemUptime
        let tokens = Tokenizer.tokens(from: result.pieces, isFinal: result.isFinal,
                                      fallbackStart: result.start, fallbackEnd: result.end)
        DebugLog.write(String(format: "%@ %.2f-%.2f now=%.2f | %@", result.isFinal ? "FINAL   " : "volatile", result.start,
                              result.end, latest.time, result.text))
        if result.isFinal {
            DebugLog.write("   runs: " + result.pieces.map { p in
                "\(p.text)@\(p.start.map { String(format: "%.2f", $0) } ?? "-")-\(p.end.map { String(format: "%.2f", $0) } ?? "-")"
            }.joined(separator: "|"))
            transcript.applyFinal(tokens, rangeEnd: result.end)
            reportSettled()
        } else {
            transcript.applyVolatile(tokens, rangeEnd: result.end)
        }
        evaluate()
    }

    // MARK: Turns and utterances

    private func tick() {
        guard let endpointer else { return }
        latest = endpointer.snapshot()
        for event in latest.events { logTurn(event) }
        let isPaused = pausedAt != nil
        if isPaused { latest.isSpeaking = false }
        if captions.isSpeaking != latest.isSpeaking { captions.isSpeaking = latest.isSpeaking }
        captions.inputLevel = isPaused ? -120 : latest.levelDB
        if latest.isSpeaking { captions.touch() }
        if !isPaused { trackTurn() }
        evaluate()
        // Second-pass revisions can run while paused.
        translation.idle(silence: isPaused ? .infinity : latest.silence)
        if latest.silence >= settings.settings.overlay.paragraphBreak, captions.liveSource.isEmpty {
            captions.requestParagraphBreak()
        }
    }

    /// Records the end of each turn so the utterance can be finished there. Driven by the events, not the
    /// state: speech can resume within the same tick.
    private func trackTurn() {
        for case .turnEnded(let at, let endOfSpeech, _, _) in latest.events where at != handledTurnEnd {
            handledTurnEnd = at
            boundary = Boundary(endOfSpeech: endOfSpeech)
            recognizer.turnEnded(at: endOfSpeech)
        }
        if latest.turnEnded, latest.silence >= Self.longPause, latest.turnEndOfSpeech != handledLongPause {
            handledLongPause = latest.turnEndOfSpeech
            recognizer.longPause(after: latest.turnEndOfSpeech)
        }
        if var b = boundary, b.resumedAt == nil, latest.isSpeaking, latest.speechStartTime > b.endOfSpeech {
            b.resumedAt = latest.speechStartTime
            boundary = b
        }
    }

    private func logTurn(_ event: TurnDetector.Event) {
        switch event {
        case .turnEnded(let at, let endOfSpeech, let probability, let reason):
            DebugLog.write(String(format: "TURN end speech=%.2f at=%.2f (+%.0f ms) p=%@ %@", endOfSpeech, at,
                                  (at - endOfSpeech) * 1000, probability.map { String(format: "%.2f", $0) } ?? "-",
                                  reason.rawValue))
        case .speechStarted(let at):
            DebugLog.write(String(format: "TURN speech %.2f", at))
        case .pause(let at):
            DebugLog.write(String(format: "TURN pause %.2f", at))
        }
    }

    /// Hands the utterance in progress (stable words only) to the translation controller.
    private func evaluate(flushAll: Bool = false) {
        let (pending, stable) = transcript.pending()
        var utteranceEnd: SourceFrontier.UtteranceEnd?
        if let b = boundary {
            if let resumed = b.resumedAt {
                // New speech already started: split once the recognizer has finalized the earlier turn.
                if transcript.finalizedThrough >= b.endOfSpeech - 0.1 { utteranceEnd = .finalsBefore((b.endOfSpeech + resumed) / 2) }
            } else if pending.allSatisfy(\.isFinal)
                        || (!recognizer.finalizesTurns && transcript.volatileThrough >= b.endOfSpeech + Self.rightContext
                            && ProcessInfo.processInfo.systemUptime - lastResultAt >= Self.burstGap) {
                // The recognizer has heard everything up to the end of speech: its text is complete.
                utteranceEnd = .all
            }
        }
        // If the recognizer still hasn't finalized well after the turn ended, finish with what it has.
        let flush = flushAll || (latest.turnEnded && latest.time - latest.turnEndTime >= 1.2)
            || (pausedAt.map { ProcessInfo.processInfo.systemUptime - $0 >= 1.0 } ?? false)
        let sentence = frontier.currentSentence(pending: pending, stableCount: stable, utteranceEnd: utteranceEnd,
                                                flushAll: flush, now: latest.time)
        let speechEndedAgo: Double? = boundary.map { latest.time - $0.endOfSpeech } ?? (latest.isSpeaking ? nil : latest.silence)
        if utteranceEnd != nil, !sentence.isComplete {
            boundary = nil // the turn's words have all been handed over
        }
        translation.update(sentence, speechEndedAgo: sentence.isComplete ? speechEndedAgo : nil)
        let rest = pending.dropFirst(sentence.tokens.count).map(\.text).joined()
        captions.liveSource = rest.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The controller finished translating an utterance; drop its words from the transcript.
    private func sentenceFinished(_ tokens: [Token], id: UUID) {
        transcript.markCommitted(tokens, utterance: id)
        frontier.consume(tokens.count)
        transcript.trim()
        reportSettled()
        evaluate()
    }

    /// Hands the recognizer's final wording of finished utterances to the second pass.
    private func reportSettled() {
        for (id, tokens) in transcript.takeSettled() {
            let text = tokens.map(\.text).joined()
            DebugLog.write("SETTLED | " + text.trimmingCharacters(in: .whitespaces))
            translation.finalTranscript(text, for: id)
        }
    }
}
