import Accelerate
import AVFoundation
import CoreML
import os
import TranslatorCore

/// Silero VAD v6 (Core ML): the probability that a 32 ms frame of 16 kHz audio contains speech.
final class SileroVAD: @unchecked Sendable {
    static let frameSize = 512
    private static let contextSize = 64
    private let model: MLModel
    private let input: MLMultiArray
    private var hidden: MLMultiArray
    private var cell: MLMultiArray
    private var context = [Float](repeating: 0, count: contextSize)

    init(url: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuOnly // a tiny LSTM: the CPU beats the Neural Engine's dispatch cost
        model = try MLModel(contentsOf: url, configuration: config)
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.contextSize + Self.frameSize)], dataType: .float32)
        hidden = try Self.zeros()
        cell = try Self.zeros()
    }

    private static func zeros() throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 128], dataType: .float32)
        vDSP_vclr(array.dataPointer.assumingMemoryBound(to: Float.self), 1, 128)
        return array
    }

    /// `frame` must hold `frameSize` samples.
    func probability(_ frame: UnsafeBufferPointer<Float>) throws -> Float {
        let p = input.dataPointer.assumingMemoryBound(to: Float.self)
        context.withUnsafeBufferPointer { p.update(from: $0.baseAddress!, count: Self.contextSize) }
        (p + Self.contextSize).update(from: frame.baseAddress!, count: Self.frameSize)
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: [
            "audio_input": input, "hidden_state": hidden, "cell_state": cell,
        ]))
        guard let probability = output.featureValue(for: "vad_output")?.multiArrayValue,
              let h = output.featureValue(for: "new_hidden_state")?.multiArrayValue,
              let c = output.featureValue(for: "new_cell_state")?.multiArrayValue else { return 0 }
        hidden = h
        cell = c
        context = Array(frame.suffix(Self.contextSize))
        return probability.dataPointer.assumingMemoryBound(to: Float.self)[0]
    }
}

/// Smart Turn v3.2 (Core ML): the probability that the speaker has finished their turn, judged from the
/// last 8 seconds of 16 kHz audio (intonation, pace, trailing silence). About 3 ms on the Neural Engine.
final class SmartTurnModel: @unchecked Sendable {
    static let windowSize = 128_000
    private let model: MLModel
    private let input: MLMultiArray

    init(url: URL) throws {
        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        model = try MLModel(contentsOf: url, configuration: config)
        input = try MLMultiArray(shape: [1, NSNumber(value: Self.windowSize)], dataType: .float32)
    }

    /// `samples`: the turn so far, most recent last (only the last 8 s are used).
    func probability(_ samples: ArraySlice<Float>) throws -> Float {
        let p = input.dataPointer.assumingMemoryBound(to: Float.self)
        let tail = samples.suffix(Self.windowSize)
        let offset = Self.windowSize - tail.count
        vDSP_vclr(p, 1, vDSP_Length(offset))
        tail.withUnsafeBufferPointer { (p + offset).update(from: $0.baseAddress!, count: tail.count) }
        let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["audio": input]))
        return output.featureValue(for: "probability")?.multiArrayValue?[0].floatValue ?? 0
    }
}

/// Audio time, level, voice activity and end-of-turn decisions, shared between the audio thread, the
/// analysis queue and the main actor.
///
/// Every captured buffer advances the clock and the level-based detector on the audio thread. With the neural
/// models, a 16 kHz copy goes to a serial queue: Silero VAD scores each 32 ms frame and drives the
/// `TurnDetector`, and during pauses Smart Turn decides whether the thought is complete.
final class Endpointer: @unchecked Sendable {
    struct Snapshot {
        var time: Double = 0
        var levelDB: Double = -120
        var isSpeaking = false
        var silence: Double = 0
        var speechStartTime: Double = 0
        var turnEnded = false
        var turnEndTime: Double = 0
        var turnEndOfSpeech: Double = 0
        var events: [TurnDetector.Event] = []
    }

    private struct State {
        /// Seconds of audio captured so far (accumulated per buffer, so device rate changes don't skew it).
        var time: Double = 0
        var levelDB: Double = -120
        var energy: VoiceActivityDetector
        var turn: TurnDetector
        var events: [TurnDetector.Event] = []
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let vad: SileroVAD?
    private let turnModel: SmartTurnModel?
    private let queue = DispatchQueue(label: "endpointing", qos: .userInteractive)
    private let converter = BufferConverter()
    private let analysisFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1,
                                               interleaved: false)!
    private let log = Logger(subsystem: "UniversalTranslator", category: "endpointing")

    // Analysis queue only.
    private var frame: [Float] = []
    private var neuralTime: Double = 0
    /// Recent 16 kHz audio for the turn model, and the absolute index of its first sample.
    private var ring: [Float] = []
    private var ringStart = 0

    var usesNeuralVAD: Bool { vad != nil }
    var usesTurnModel: Bool { turnModel != nil }

    init(sensitivity: Double, timing: TimingSettings, vad: SileroVAD?, turnModel: SmartTurnModel?) {
        self.vad = vad
        self.turnModel = turnModel
        var energyConfig = VoiceActivityDetector.Config()
        energyConfig.sensitivity = sensitivity
        var turn = TurnDetector()
        turn.config = Self.turnConfig(sensitivity: sensitivity, timing: timing, neural: vad != nil, model: turnModel != nil)
        lock = OSAllocatedUnfairLock(initialState: State(energy: VoiceActivityDetector(config: energyConfig), turn: turn))
    }

    private static func turnConfig(sensitivity: Double, timing: TimingSettings, neural: Bool, model: Bool) -> TurnDetector.Config {
        var config = TurnDetector.Config()
        config.usesTurnModel = model
        config.fixedPause = timing.endOfThoughtPause
        config.maxPause = max(timing.maxTurnPause, 0.3)
        if neural {
            config.setSensitivity(sensitivity)
        } else {
            // The level detector already applies its attack; use its release for pauses.
            config.attack = 0
            config.release = VoiceActivityDetector.Config().release
        }
        return config
    }

    func update(sensitivity: Double, timing: TimingSettings) {
        let config = Self.turnConfig(sensitivity: sensitivity, timing: timing, neural: vad != nil, model: turnModel != nil)
        lock.withLock {
            $0.energy.config.sensitivity = sensitivity
            $0.turn.config = config
        }
    }

    /// Called on the audio thread for every captured buffer.
    func process(_ buffer: AVAudioPCMBuffer) {
        let rate = buffer.format.sampleRate
        guard rate > 0 else { return }
        let duration = Double(buffer.frameLength) / rate
        let level = buffer.floatChannelData.map {
            AudioLevel.rmsDB(UnsafeBufferPointer(start: $0[0], count: Int(buffer.frameLength)))
        } ?? -120
        let neural = vad != nil
        lock.withLock { s in
            s.time += duration
            s.levelDB = level
            s.energy.process(levelDB: level, time: s.time, duration: duration)
            if !neural {
                // A buffer is voiced when the level detector is in speech and this buffer kept it there.
                let voiced = s.energy.isSpeaking && s.energy.lastVoiceTime >= s.time - 1e-6
                s.events += s.turn.process(probability: voiced ? 1 : 0, time: s.time, duration: duration)
            }
        }
        guard vad != nil || turnModel != nil,
              let converted = try? converter.convert(buffer, to: analysisFormat),
              let data = converted.floatChannelData else { return }
        let samples = Array(UnsafeBufferPointer(start: data[0], count: Int(converted.frameLength)))
        queue.async { self.analyze(samples) }
    }

    private func analyze(_ samples: [Float]) {
        ring.append(contentsOf: samples)
        let keep = SmartTurnModel.windowSize + 16_000
        if ring.count > 2 * keep {
            let drop = ring.count - keep
            ring.removeFirst(drop)
            ringStart += drop
        }

        if let vad {
            frame.append(contentsOf: samples)
            var offset = 0
            while frame.count - offset >= SileroVAD.frameSize {
                let probability = frame.withUnsafeBufferPointer { all in
                    (try? vad.probability(UnsafeBufferPointer(rebasing: all[offset..<(offset + SileroVAD.frameSize)])))
                } ?? 0
                offset += SileroVAD.frameSize
                neuralTime += Double(SileroVAD.frameSize) / 16_000
                let t = neuralTime
                lock.withLock { $0.events += $0.turn.process(probability: Double(probability), time: t, duration: 0.032) }
            }
            frame.removeFirst(offset)
        }

        guard let turnModel else { return }
        let now = vad != nil ? neuralTime : Double(ringStart + ring.count) / 16_000
        let (check, turnStart) = lock.withLock { s in (s.turn.needsTurnCheck(at: now), s.turn.turnStartTime ?? 0) }
        guard check else { return }
        // The whole turn so far (with a little lead-in), at most the model's 8 s window.
        let first = max(Int((turnStart - 0.2) * 16_000) - ringStart, ring.count - SmartTurnModel.windowSize, 0)
        let started = ProcessInfo.processInfo.systemUptime
        let probability = (try? turnModel.probability(ring[first...])) ?? 0
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        lock.withLock { s in
            if let event = s.turn.turnChecked(probability: Double(probability), at: now) { s.events.append(event) }
        }
        DebugLog.write(String(format: "TURN check p=%.2f at %.2f (silence %.2f, %.1f ms)", probability, now,
                              lock.withLock { $0.turn.silence(at: now) }, elapsed))
    }

    /// Current state, plus the turn events since the last snapshot.
    func snapshot() -> Snapshot {
        lock.withLock { s in
            let neural = vad != nil
            if let event = s.turn.endTurnIfDue(at: neural ? s.turn.time : s.time) { s.events.append(event) }
            let events = s.events
            s.events.removeAll()
            return Snapshot(time: s.time, levelDB: s.levelDB, isSpeaking: s.turn.isSpeaking,
                            silence: s.turn.silence(at: neural ? max(s.turn.time, s.time - 0.04) : s.time),
                            speechStartTime: s.turn.speechStartTime, turnEnded: s.turn.turnEnded,
                            turnEndTime: s.turn.turnEndTime, turnEndOfSpeech: s.turn.turnEndOfSpeech, events: events)
        }
    }

    /// Loads the neural models that are enabled and downloaded (downloading them first; they're small).
    @MainActor
    static func loadModels(timing: TimingSettings, status: (String) -> Void) async -> (SileroVAD?, SmartTurnModel?) {
        let store = LocalModelStore.shared
        var wanted: [LocalModel] = []
        if timing.neuralVAD { wanted.append(.sileroVAD) }
        if timing.smartTurn { wanted.append(.smartTurn) }
        for model in wanted where !store.isDownloaded(model) {
            status("Downloading \(model.name)…")
            do {
                try await store.ensureDownloaded(model)
            } catch {
                DebugLog.write("ENDPOINT \(model.name) unavailable: \(error.localizedDescription)")
            }
        }
        let vadURL = store.path(.sileroVAD)
        let turnURL = store.path(.smartTurn)
        let useVAD = timing.neuralVAD && store.isDownloaded(.sileroVAD)
        let useTurn = timing.smartTurn && store.isDownloaded(.smartTurn)
        return await Task.detached(priority: .userInitiated) {
            let vad = useVAD ? try? SileroVAD(url: vadURL) : nil
            var turn = useTurn ? try? SmartTurnModel(url: turnURL) : nil
            // The first Neural Engine prediction compiles the model; do it now rather than at the first pause.
            if let model = turn, (try? model.probability(ArraySlice(repeating: 0, count: 16_000))) == nil { turn = nil }
            DebugLog.write("ENDPOINT vad=\(vad != nil ? "silero" : "energy") turn=\(turn != nil ? "smart-turn" : "fixed pause")")
            return (vad, turn)
        }.value
    }
}
