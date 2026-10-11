import Foundation

/// Voice activity and end-of-turn decisions.
///
/// Fed one speech probability per audio frame (from Silero VAD, or 0/1 from the energy detector). A pause
/// starts when the probability stays below `endThreshold` for `release` seconds. Whether the pause ends the
/// speaker's turn (the thought is complete and can be finalized and translated in full) is decided by:
/// - an end-of-turn model (Smart Turn), asked at each of `checkDelays` seconds into the pause: a probability
///   of at least `turnThreshold` ends the turn right away, so finished sentences don't wait for a fixed timer
///   and hesitations mid-sentence ("supposed to be … really nice") don't split the thought;
/// - otherwise a timeout: `maxPause` with the model, `fixedPause` without it.
public struct TurnDetector: Sendable {
    public struct Config: Equatable, Sendable {
        public var startThreshold: Double = 0.5
        public var endThreshold: Double = 0.35
        /// Speech must last this long before it counts (filters clicks).
        public var attack: Double = 0.064
        /// Silence this long is a pause.
        public var release: Double = 0.1
        /// Ask the end-of-turn model this many seconds into a pause (each delay once).
        public var checkDelays: [Double] = [0.2, 0.5]
        public var turnThreshold: Double = 0.5
        /// Longest pause within a turn when the end-of-turn model is in use.
        public var maxPause: Double = 1.4
        /// Pause that ends a turn without the model.
        public var fixedPause: Double = 0.7
        public var usesTurnModel = false

        public init() {}

        /// Thresholds for a 0…1 microphone sensitivity (0.6 is the default 0.5 / 0.35).
        public mutating func setSensitivity(_ sensitivity: Double) {
            startThreshold = min(0.85, max(0.2, 0.5 + (0.6 - sensitivity) * 0.6))
            endThreshold = max(0.1, startThreshold - 0.15)
        }
    }

    public enum Reason: String, Sendable {
        case model, timeout
    }

    public enum Event: Equatable, Sendable {
        case speechStarted(at: Double)
        case pause(at: Double)
        case turnEnded(at: Double, endOfSpeech: Double, probability: Double?, reason: Reason)
    }

    public var config: Config
    public private(set) var isSpeaking = false
    /// End of the last voiced frame.
    public private(set) var lastVoiceTime: Double = 0
    /// Start of the current stretch of speech.
    public private(set) var speechStartTime: Double = 0
    /// Start of the turn in progress (nil between turns).
    public private(set) var turnStartTime: Double?
    /// The turn ended during the current pause (cleared when speech resumes).
    public private(set) var turnEnded = false
    /// When the end of the last turn was declared, and its speech ended.
    public private(set) var turnEndTime: Double = 0
    public private(set) var turnEndOfSpeech: Double = 0
    public private(set) var lastTurnProbability: Double?
    /// Latest audio time seen.
    public private(set) var time: Double = 0

    private var aboveSince: Double?
    private var belowSince: Double?
    private var checksDone = 0
    private var checkInFlight = false

    public init(config: Config = Config()) {
        self.config = config
    }

    /// Seconds of silence at `time` (0 while speaking).
    public func silence(at time: Double) -> Double {
        isSpeaking ? 0 : max(0, time - lastVoiceTime)
    }

    /// - Parameters:
    ///   - probability: speech probability of the frame.
    ///   - time: audio time at the *end* of the frame.
    ///   - duration: frame length in seconds.
    public mutating func process(probability: Double, time: Double, duration: Double) -> [Event] {
        self.time = max(self.time, time)
        var events: [Event] = []
        if isSpeaking {
            if probability >= config.endThreshold {
                belowSince = nil
                lastVoiceTime = time
            } else {
                if belowSince == nil { belowSince = time - duration }
                if time - belowSince! >= config.release {
                    isSpeaking = false
                    belowSince = nil
                    aboveSince = nil
                    checksDone = 0
                    events.append(.pause(at: lastVoiceTime))
                }
            }
        } else if probability >= config.startThreshold {
            if aboveSince == nil { aboveSince = time - duration }
            if time - aboveSince! >= config.attack - 1e-9 {
                isSpeaking = true
                speechStartTime = aboveSince!
                lastVoiceTime = time
                belowSince = nil
                if turnStartTime == nil || turnEnded { turnStartTime = speechStartTime }
                turnEnded = false
                checkInFlight = false
                lastTurnProbability = nil
                events.append(.speechStarted(at: speechStartTime))
            }
        } else {
            aboveSince = nil
        }
        if let event = endTurnIfDue(at: time) { events.append(event) }
        return events
    }

    /// True when the end-of-turn model should be asked now (call `turnChecked` with its answer).
    public mutating func needsTurnCheck(at time: Double) -> Bool {
        guard config.usesTurnModel, !isSpeaking, !turnEnded, !checkInFlight, turnStartTime != nil,
              checksDone < config.checkDelays.count,
              silence(at: time) >= config.checkDelays[checksDone] else { return false }
        checkInFlight = true
        checksDone += 1
        return true
    }

    /// The end-of-turn model's answer for the current pause.
    public mutating func turnChecked(probability: Double, at time: Double) -> Event? {
        guard checkInFlight else { return nil } // speech resumed meanwhile
        checkInFlight = false
        lastTurnProbability = probability
        guard !isSpeaking, !turnEnded, probability >= config.turnThreshold else { return nil }
        return endTurn(at: time, probability: probability, reason: .model)
    }

    /// Ends the turn when the pause has outlasted the timeout.
    public mutating func endTurnIfDue(at time: Double) -> Event? {
        guard !isSpeaking, !turnEnded, turnStartTime != nil else { return nil }
        let limit = config.usesTurnModel ? config.maxPause : config.fixedPause
        guard silence(at: time) >= limit else { return nil }
        return endTurn(at: time, probability: lastTurnProbability, reason: .timeout)
    }

    private mutating func endTurn(at time: Double, probability: Double?, reason: Reason) -> Event {
        turnEnded = true
        turnEndTime = time
        turnEndOfSpeech = lastVoiceTime
        checkInFlight = false
        return .turnEnded(at: time, endOfSpeech: lastVoiceTime, probability: probability, reason: reason)
    }

    public mutating func reset() {
        self = TurnDetector(config: config)
    }
}
