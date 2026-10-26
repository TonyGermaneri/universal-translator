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
        /// The n-th turn end, if it's still waiting for audio (listening paused): finish it with silence.
        case flushTurn(Int)
        case reset
    }

    /// Silence after which the stream is reset.
    static let resetPause = 3.0

    /// The speech locales the model has a language prompt for (the pinned revision's `prompt_dictionary` in
    /// metadata.json, one locale per prompt). The "I speak" list where Apple's `SpeechTranscriber` list isn't
    /// available (macOS 15). Left out: "or-KE" (Odia, Kenya: ambiguous) and "no-NO" (Bokmål and Nynorsk are listed);
    /// "ar-SA" stands in for the model's "ar-AR" and resolves to the same prompt through FluidAudio's bare-language
    /// fallback.
    static let supportedLocales = [
        "en-US", "en-GB", "es-ES", "es-US", "zh-CN", "zh-TW", "hi-IN", "ar-SA", "fr-FR", "fr-CA", "de-DE", "ja-JP",
        "ru-RU", "pt-BR", "pt-PT", "ko-KR", "it-IT", "nl-NL", "pl-PL", "tr-TR", "uk-UA", "ro-RO", "el-GR", "cs-CZ",
        "hu-HU", "sv-SE", "da-DK", "fi-FI", "nb-NO", "nn-NO", "sk-SK", "hr-HR", "bg-BG", "lt-LT", "et-EE", "lv-LV",
        "sl-SI", "th-TH", "vi-VN", "id-ID", "ms-MY", "bn-IN", "ur-PK", "fa-IR", "ta-IN", "te-IN", "mr-IN", "gu-IN",
        "kn-IN", "ml-IN", "si-LK", "ne-NP", "km-KH", "sw-KE", "am-ET", "ha-NG", "zu-ZA", "yo-NG", "ig-NG", "af-ZA",
        "rw-RW", "so-SO", "ny-MW", "ln-CD", "he-IL", "ku-TR", "az-AZ", "ka-GE", "hy-AM", "uz-UZ", "tg-TJ", "ky-KG",
        "qu-PE", "ay-BO", "gn-PY", "nah-MX", "mi-NZ", "haw-US", "sm-WS", "to-TO", "mt-MT",
    ]

    private var feed: AsyncStream<Item>.Continuation?
    private var worker: Task<Void, Never>?
    private var resetWork: DispatchWorkItem?
    /// Turn ends sent to the decoding task (it counts them too, to match a flush with its turn).
    private var turnEnds = 0
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
        await manager.setLanguage(Self.modelLanguage(identifier))
        if !contextualStrings.isEmpty {
            await manager.setCustomVocabulary(contextualStrings.prefix(100).map { CustomVocabularyTerm(text: $0) })
        }
        log.info("Nemotron ready in \(Date().timeIntervalSince(started), format: .fixed(precision: 2)) s")

        let (stream, continuation) = AsyncStream.makeStream(of: Item.self)
        feed = continuation
        turnEnds = 0
        let deliver: @Sendable (RecognizerResult) -> Void = { [weak self] result in
            Task { @MainActor in self?.onResult?(result) }
        }
        let fail: @Sendable (Error) -> Void = { [weak self] error in
            Task { @MainActor in self?.onError?(error) }
        }
        let deferTurnEnds = Self.defersTurnEnds(identifier), traditional = Self.writesTraditional(identifier)
        worker = Task.detached(priority: .userInitiated) {
            await Self.run(manager: manager, items: stream, locale: identifier, deferTurnEnds: deferTurnEnds,
                           traditional: traditional,
                           emit: deliver, failed: fail)
        }
    }

    /// The language prompt Nemotron is given. Its zh-TW prompt writes nothing but `<unk>` (CER 490 % on Taiwanese
    /// speech, 2026-10-25), while the zh-CN prompt recognizes the same Taiwanese voice at CER 1.6 %: Chinese written in
    /// Traditional characters is recognized as Mandarin and converted (`writesTraditional`).
    nonisolated static func modelLanguage(_ locale: String) -> String {
        writesTraditional(locale) ? "zh-CN" : Locale(identifier: locale).identifier(.bcp47)
    }

    /// Chinese read in Traditional characters: Taiwan, Hong Kong, Macau (Foundation infers their Hant script), or an
    /// explicit Hant script.
    nonisolated static func writesTraditional(_ locale: String) -> Bool {
        let language = Locale(identifier: locale).language
        return language.languageCode?.identifier == "zh" && language.script?.identifier == "Hant"
    }

    /// Recognized text as shown: in Traditional characters for `writesTraditional` speech (the model writes
    /// Simplified), character for character, so the text keeps its length.
    nonisolated static func presented(_ text: String, traditional: Bool) -> String {
        traditional ? ChineseScript.convert(text, toTraditional: true) : text
    }

    /// Speech languages whose turns end on the real audio that follows rather than on silence padding: in Japanese,
    /// the padding's extra silence cost the next turn its first word (三月の出荷 → の出荷, 歩いてどのくらい →
    /// どのくらい; 2026-10-26, scripts/evaluate.py). Other languages lose no words to it, and keep the faster finals.
    nonisolated static func defersTurnEnds(_ locale: String) -> Bool {
        locale.split(separator: "-").first.map { $0.lowercased() } == "ja"
    }

    /// Decodes the audio stream in order. Text is monotonic: everything after `finalized` characters is the
    /// turn in progress.
    ///
    /// At the end of a turn the chunk in progress has to be decoded before the turn's text is complete. With
    /// `deferTurnEnds` that waits for the real audio that follows (the pause, at most one 560 ms chunk), and the
    /// token timings decide which characters were spoken before the turn ended (the speaker may already have
    /// resumed); otherwise the chunk is completed with silence at once.
    private nonisolated static func run(manager: StreamingNemotronMultilingualAsrManager, items: AsyncStream<Item>,
                                        locale: String, deferTurnEnds: Bool, traditional: Bool, emit: @escaping @Sendable (RecognizerResult) -> Void,
                                        failed: @escaping @Sendable (Error) -> Void) async {
        let chunkSamples = await manager.config.chunkSamples
        var fed = 0.0              // seconds of real audio received
        var turnStart = 0.0        // where the turn in progress began
        var streamSamples = 0      // samples (real and padding) since the last reset
        var streamStart = 0.0      // `fed` at the last reset: token times count from there (no padding when deferring)
        var finalized = 0          // characters of the stream's text already reported as final
        var finalizedTokens = 0    // and the tokens behind them
        var partial = ""
        var pendingEnd: (endOfSpeech: Double, since: Double, turn: Int)?
        var turnEnds = 0           // turn ends received, in the order `turnEnded` and `finish` sent them

        func finishTurn(endOfSpeech: Double?, since started: Double, timed: Bool) async {
            let all = await manager.getPartialTranscript()
            let raw = String(all.dropFirst(finalized))
            let timings = await manager.getTokenTimings()
            finalized = all.count
            let text = Self.turnText(raw)
            // When deferred, the text may run past the turn's end into the next one; real word times let the pipeline
            // split it where the speaker paused (`SourceFrontier.UtteranceEnd.finalsBefore`).
            let pieces = timed && finalizedTokens <= timings.count
                ? Self.timedPieces(tokens: timings[finalizedTokens...].map { ($0.token, $0.startTime + streamStart) },
                                   raw: raw, text: text, locale: locale) : nil
            finalizedTokens = timings.count
            DebugLog.write(String(format: "NEMOTRON turn %.0f ms | %@",
                                  (ProcessInfo.processInfo.systemUptime - started) * 1000, text))
            emit(RecognizerResult(pieces: pieces ?? [TimedPiece(text: Self.presented(text, traditional: traditional),
                                                                 start: nil, end: nil)], isFinal: true,
                                  start: turnStart, end: fed, endOfSpeech: endOfSpeech))
            turnStart = fed
            partial = ""
        }

        do {
            for await item in items {
                switch item {
                case .audio(let samples):
                    let chunksBefore = streamSamples / chunkSamples
                    fed += Double(samples.count) / 16_000
                    streamSamples += samples.count
                    _ = try await manager.process(samples: samples)
                    if let end = pendingEnd, streamSamples / chunkSamples > chunksBefore {
                        pendingEnd = nil
                        await finishTurn(endOfSpeech: end.endOfSpeech, since: end.since, timed: true)
                    }
                    let text = Self.presented(Self.turnText(String(await manager.getPartialTranscript().dropFirst(finalized))),
                                              traditional: traditional)
                    if text != partial {
                        partial = text
                        emit(RecognizerResult(pieces: [TimedPiece(text: text, start: nil, end: nil)], isFinal: false,
                                              start: turnStart, end: fed - Double(streamSamples % chunkSamples) / 16_000))
                    }
                case .endTurn(let endOfSpeech):
                    turnEnds += 1
                    let started = pendingEnd?.since ?? ProcessInfo.processInfo.systemUptime
                    let padding = (chunkSamples - streamSamples % chunkSamples) % chunkSamples
                    if deferTurnEnds, let endOfSpeech {
                        // A turn end while another waits: one final covers both, cut at the later end.
                        if padding > 0 { pendingEnd = (endOfSpeech, started, turnEnds); continue }
                        pendingEnd = nil
                        await finishTurn(endOfSpeech: endOfSpeech, since: started, timed: true)
                        continue
                    }
                    // Stopping (no speech end) or a language that doesn't defer.
                    if padding > 0 {
                        _ = try await manager.process(samples: [Float](repeating: 0, count: padding))
                        streamSamples += padding
                        streamStart -= Double(padding) / 16_000
                    }
                    let waiting = pendingEnd?.endOfSpeech
                    pendingEnd = nil
                    await finishTurn(endOfSpeech: endOfSpeech ?? waiting, since: started, timed: false)
                case .flushTurn(let turn):
                    guard let end = pendingEnd, end.turn == turn else { break }
                    pendingEnd = nil
                    let padding = (chunkSamples - streamSamples % chunkSamples) % chunkSamples
                    if padding > 0 {
                        _ = try await manager.process(samples: [Float](repeating: 0, count: padding))
                        streamSamples += padding
                        streamStart -= Double(padding) / 16_000
                    }
                    await finishTurn(endOfSpeech: end.endOfSpeech, since: end.since, timed: false)
                case .reset:
                    let all = try await manager.finish()
                    let rest = Self.presented(Self.turnText(String(all.dropFirst(finalized))), traditional: traditional)
                    if !rest.trimmingCharacters(in: .whitespaces).isEmpty {
                        emit(RecognizerResult(pieces: [TimedPiece(text: rest, start: nil, end: nil)], isFinal: true,
                                              start: turnStart, end: fed))
                    }
                    await manager.reset()
                    DebugLog.write("NEMOTRON reset")
                    turnStart = fed
                    streamStart = fed
                    streamSamples = 0
                    finalized = 0
                    finalizedTokens = 0
                    partial = ""
                    pendingEnd = nil
                }
            }
        } catch {
            failed(error)
        }
        await manager.cleanup()
    }

    /// A turn's text as words with the times they were spoken: `raw` (the stream's text after what was already
    /// final) spelled out by `tokens` (SentencePiece pieces: "▁" is a space, "<0xE6>" one byte of a character), each
    /// character timed by the token it came from, then split into words as `Tokenizer` splits text, so the words
    /// match those of the in-progress text. `text` is `raw` after `turnText`. Spaces are left out of the match (the
    /// decoder merges "▁▁" into one); nil when the tokens don't spell out the rest of `raw` exactly.
    nonisolated static func timedPieces(tokens: [(text: String, start: Double)], raw: String, text: String,
                                        locale: String?) -> [TimedPiece]? {
        var timed: [(Character, Double)] = []
        var bytes: [UInt8] = [], bytesStart = 0.0
        func flushBytes() {
            for c in String(decoding: bytes, as: UTF8.self) where !c.isWhitespace { timed.append((c, bytesStart)) }
            bytes = []
        }
        for token in tokens {
            if token.text.count == 6, token.text.hasPrefix("<0x"), token.text.hasSuffix(">"),
               let byte = UInt8(token.text.dropFirst(3).prefix(2), radix: 16) {
                if bytes.isEmpty { bytesStart = token.start }
                bytes.append(byte)
                continue
            }
            flushBytes()
            for c in token.text where c != "▁" && !c.isWhitespace { timed.append((c, token.start)) }
        }
        flushBytes()
        let rawVisible = raw.filter { !$0.isWhitespace }, visible = text.filter { !$0.isWhitespace }
        let dropped = rawVisible.count - visible.count
        guard String(timed.map(\.0)) == rawVisible, dropped >= 0,
              rawVisible.dropFirst(dropped).lowercased() == visible.lowercased() else { return nil }
        let times = timed.dropFirst(dropped).map(\.1)
        var pieces: [TimedPiece] = [], offset = 0
        for word in Tokenizer.splitKeepingLeadingSpace(text).flatMap({ Tokenizer.splitSpaceless($0, locale: locale) }) {
            let count = word.filter { !$0.isWhitespace }.count
            guard count > 0, offset + count <= times.count else { return nil }
            // A frame (80 ms) after its last character started.
            pieces.append(TimedPiece(text: word, start: times[offset], end: times[offset + count - 1] + 0.08))
            offset += count
        }
        return offset == times.count ? pieces : nil
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
        turnEnds += 1
        // A deferred turn end waits for audio to complete its chunk (at most 560 ms); none comes while paused.
        let turn = turnEnds
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.feed?.yield(.flushTurn(turn)) }
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
        turnEnds += 1
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
