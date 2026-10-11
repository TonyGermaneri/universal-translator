import Foundation

/// Energy-based voice activity detection with an adaptive noise floor.
///
/// Feed it one level reading per audio buffer. Speech starts when the level stays above the noise floor
/// by `startMargin` dB for `attack` seconds, and ends after `release` seconds below `endMargin`.
/// The noise floor follows quiet passages, so the detector adapts to fans, rooms and microphones.
public struct VoiceActivityDetector: Sendable {
    public struct Config: Codable, Equatable, Sendable {
        /// 0 (needs loud speech) … 1 (triggers on quiet speech).
        public var sensitivity: Double = 0.6
        public var attack: Double = 0.08
        public var release: Double = 0.25
        public var absoluteFloorDB: Double = -62

        public init() {}

        var startMargin: Double { 16 - 10 * sensitivity } // 6 dB … 16 dB above the noise floor
        var endMargin: Double { startMargin - 4 }
    }

    public var config: Config
    public private(set) var isSpeaking = false
    public private(set) var noiseFloorDB: Double = -55
    /// Audio time at which the last voiced buffer ended.
    public private(set) var lastVoiceTime: Double = 0
    public private(set) var speechStartTime: Double = 0

    private var aboveSince: Double?
    private var belowSince: Double?

    public init(config: Config = Config()) {
        self.config = config
    }

    public enum Event: Equatable, Sendable {
        case speechStarted(at: Double)
        case speechEnded(at: Double)
    }

    /// - Parameters:
    ///   - levelDB: RMS level of the buffer in dBFS.
    ///   - time: audio time at the *end* of the buffer.
    ///   - duration: buffer duration in seconds.
    @discardableResult
    public mutating func process(levelDB: Double, time: Double, duration: Double) -> Event? {
        let level = levelDB.isFinite ? levelDB : -120
        let startThreshold = max(noiseFloorDB + config.startMargin, config.absoluteFloorDB)
        let endThreshold = max(noiseFloorDB + config.endMargin, config.absoluteFloorDB - 4)

        // Track the floor: drop quickly to quieter levels, rise slowly so speech doesn't drag it up.
        if !isSpeaking {
            let rate = level < noiseFloorDB ? 0.25 : 0.015
            noiseFloorDB += (level - noiseFloorDB) * rate * min(duration / 0.02, 5)
            noiseFloorDB = min(max(noiseFloorDB, -90), -25)
        }

        if isSpeaking {
            if level >= endThreshold {
                belowSince = nil
                lastVoiceTime = time
            } else {
                if belowSince == nil { belowSince = time - duration }
                if time - belowSince! >= config.release {
                    isSpeaking = false
                    aboveSince = nil
                    belowSince = nil
                    return .speechEnded(at: lastVoiceTime)
                }
            }
        } else {
            if level >= startThreshold {
                if aboveSince == nil { aboveSince = time - duration }
                if time - aboveSince! >= config.attack {
                    isSpeaking = true
                    speechStartTime = aboveSince!
                    lastVoiceTime = time
                    belowSince = nil
                    return .speechStarted(at: aboveSince!)
                }
            } else {
                aboveSince = nil
            }
        }
        return nil
    }

    /// Seconds of silence at `time` (0 while speaking).
    public func silence(at time: Double) -> Double {
        isSpeaking ? 0 : max(0, time - lastVoiceTime)
    }

    public mutating func reset() {
        isSpeaking = false
        aboveSince = nil
        belowSince = nil
        lastVoiceTime = 0
    }
}

public enum AudioLevel {
    /// RMS level of float samples in dBFS.
    public static func rmsDB(_ samples: UnsafeBufferPointer<Float>) -> Double {
        guard !samples.isEmpty else { return -120 }
        var sum: Float = 0
        for s in samples { sum += s * s }
        let rms = sqrt(sum / Float(samples.count))
        return rms > 0 ? Double(20 * log10(rms)) : -120
    }
}
