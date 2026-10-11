import Foundation

/// A translation the policy wants: translate `source` (the current sentence so far), continuing `prefix`.
public struct SimulRequest: Equatable, Sendable {
    public var id: Int
    public var source: String
    /// Already-committed target text the translator should continue (empty for translators that can't).
    public var prefix: String
    /// The sentence is complete: translate all of it and finish.
    public var isFinal: Bool
}

/// What the overlay should show for the sentence in progress.
public struct SimulDisplay: Equatable, Sendable {
    /// Text that won't change again (except by a second-pass revision once the sentence is finished).
    public var committed: String
    /// Provisional tail, already masked; it may change on the next update.
    public var ghost: String

    public init(committed: String = "", ghost: String = "") {
        self.committed = committed
        self.ghost = ghost
    }
}

public struct FinishedSentence: Equatable, Sendable {
    public var source: String
    public var translation: String
}

public struct SimulOutcome: Equatable, Sendable {
    public var display: SimulDisplay
    /// Set when this response completed the sentence.
    public var finished: FinishedSentence?
    /// Committed text grew (for latency metrics).
    public var committedGrew: Bool
    /// The final translation didn't continue what was shown, so the committed text was replaced.
    public var replacedCommitted: Bool
}

/// Simultaneous translation policy for one sentence at a time: target-side LocalAgreement with a forced
/// prefix (the approach of the IWSLT 2025/2026 winning systems).
///
/// Each time the stable source grows, the translator is asked to continue the committed translation. Only
/// the part two consecutive translations agree on is committed; the rest is shown as a provisional ghost
/// with its last few units hidden. Reordering in the target language (verb-final Japanese, German
/// participles) shows up as disagreement, so it waits naturally. If nothing has been committed for the
/// profile's `maxDelay`, a commit is forced, minus the unstable tail.
///
/// Translators that can't continue a prefix (e.g. Apple Translation) return a full re-translation each time.
/// Committing works the same way (the shared prefix of consecutive translations), but a translation that
/// contradicts what's already committed can't extend it; if the final translation contradicts it, the
/// sentence is replaced in full (and shown as a revision).
public final class SimulPolicy {
    public var profile: LanguageProfile
    public let prefixForcing: Bool
    public var historyLimit = 4

    public private(set) var committed = ""
    public private(set) var source = ""
    /// Recent finished sentences, oldest first, for translator context.
    public private(set) var history: [TranslationContext] = []

    private var previousHypothesis: String?
    private var lastRequested: (source: String, isFinal: Bool)?
    private var nextID = 1
    /// When the current stretch of uncommitted source started (drives forced commits).
    private var stallSince: Double?

    public init(profile: LanguageProfile, prefixForcing: Bool) {
        self.profile = profile
        self.prefixForcing = prefixForcing
    }

    /// The current sentence's stable source changed (or became final). Returns a request when there's
    /// something new to translate.
    public func update(source newSource: String, isFinal: Bool, now: Double) -> SimulRequest? {
        let text = newSource.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text != source {
            source = text
            if stallSince == nil { stallSince = now }
        }
        if let last = lastRequested, last.source == text, last.isFinal == isFinal { return nil }
        lastRequested = (text, isFinal)
        defer { nextID += 1 }
        return SimulRequest(id: nextID, source: text, prefix: prefixForcing ? committed : "", isFinal: isFinal)
    }

    /// Applies a translator response.
    public func receive(_ request: SimulRequest, hypothesis raw: String, now: Double) -> SimulOutcome {
        var hypothesis = raw.trimmingCharacters(in: .newlines)
        if prefixForcing, !request.prefix.isEmpty, !hypothesis.hasPrefix(request.prefix) {
            // Some translators return only the continuation.
            hypothesis = request.prefix + hypothesis
        }

        if request.isFinal {
            return finish(request: request, hypothesis: hypothesis)
        }

        hypothesis = profile.stripFinalPunctuation(hypothesis)
        var grew = false
        if let previous = previousHypothesis,
           let current = continuation(of: hypothesis), let prior = continuation(of: previous) {
            let agreed = trimCommit(profile.agreedPrefix(current, prior))
            if !agreed.isEmpty {
                committed += agreed
                grew = true
            }
        }
        previousHypothesis = hypothesis
        if !grew, let forced = forcedCommit(now: now) {
            committed += forced
            grew = true
        }
        let remaining = continuation(of: hypothesis) ?? ""
        if grew {
            stallSince = remaining.trimmingCharacters(in: .whitespaces).isEmpty ? nil : now
        }
        return SimulOutcome(display: display(remaining: remaining), finished: nil, committedGrew: grew, replacedCommitted: false)
    }

    /// Forces a commit from the latest hypothesis if nothing has been committed for too long.
    /// Call periodically; returns the new display when something was committed.
    public func tick(now: Double) -> SimulDisplay? {
        guard let forced = forcedCommit(now: now) else { return nil }
        committed += forced
        let remaining = previousHypothesis.flatMap(continuation(of:)) ?? ""
        stallSince = remaining.trimmingCharacters(in: .whitespaces).isEmpty ? nil : now
        return display(remaining: remaining)
    }

    /// Discards the sentence in progress (e.g. when listening stops without a final result).
    public func reset() {
        committed = ""
        source = ""
        previousHypothesis = nil
        lastRequested = nil
        stallSince = nil
    }

    public func clearHistory() { history = [] }

    /// Replaces a finished sentence's translation in the context history (after a second-pass revision).
    /// Replaces a finished sentence's translation in the context history (after a second-pass revision),
    /// optionally with the recognizer's corrected source text.
    public func replaceHistory(source: String, translation: String, correctedSource: String? = nil) {
        guard let i = history.lastIndex(where: { $0.source == source }) else { return }
        history[i].translation = translation
        if let correctedSource { history[i].source = correctedSource }
    }

    // MARK: - Internals

    private func finish(request: SimulRequest, hypothesis: String) -> SimulOutcome {
        var replaced = false
        let translation: String
        if let rest = continuation(of: hypothesis) {
            translation = committed + rest
        } else {
            // The final translation doesn't continue what's on screen: show it in full.
            translation = hypothesis
            replaced = true
        }
        let finished = FinishedSentence(source: request.source, translation: translation.trimmingCharacters(in: .whitespaces))
        history.append(TranslationContext(source: finished.source, translation: finished.translation))
        if history.count > historyLimit { history.removeFirst(history.count - historyLimit) }
        reset()
        return SimulOutcome(display: SimulDisplay(committed: finished.translation), finished: finished,
                            committedGrew: true, replacedCommitted: replaced)
    }

    private func forcedCommit(now: Double) -> String? {
        guard let since = stallSince, now - since >= profile.maxDelay,
              let previous = previousHypothesis, let rest = continuation(of: previous) else { return nil }
        let candidate = trimCommit(profile.dropLast(rest, units: max(1, profile.maskK)))
        return candidate.trimmingCharacters(in: .whitespaces).isEmpty ? nil : candidate
    }

    private func trimCommit(_ text: String) -> String {
        profile.trimToSafeBoundary(text)
    }

    private func display(remaining: String) -> SimulDisplay {
        SimulDisplay(committed: committed, ghost: profile.dropLast(remaining, units: profile.maskK))
    }

    /// The part of `hypothesis` after the committed text, or nil if the hypothesis contradicts it.
    /// (Splicing a contradicting translation onto committed text duplicates or drops words.)
    func continuation(of hypothesis: String) -> String? {
        guard !committed.isEmpty else { return hypothesis }
        guard hypothesis.hasPrefix(committed) else { return nil }
        return String(hypothesis.dropFirst(committed.count))
    }
}
