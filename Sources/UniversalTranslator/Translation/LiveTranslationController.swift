import Foundation
import os
import TranslatorCore

/// Runs simultaneous translation: feeds the sentence in progress to `SimulPolicy`, keeps one live
/// translation request in flight (the newest source wins), shows committed and provisional text, and
/// sends each finished sentence through an optional second pass that may revise it on screen.
@MainActor
final class LiveTranslationController {
    private let captions: CaptionStore
    private let settings: SettingsStore
    private let log = Logger(subsystem: "UniversalTranslator", category: "translation")

    private var live: SentenceTranslator = PassthroughTranslator()
    private var reviser: SentenceTranslator?
    private var policy = SimulPolicy(profile: .forTarget("en"), prefixForcing: false)
    private var revisionPolicy = RevisionPolicy()
    private var generation = 0

    private var latest: SourceFrontier.Sentence?
    private var inFlight: SimulRequest?
    /// Source tokens of each final request, handed back to the engine once the sentence is finished.
    private var finalTokens: [Int: [Token]] = [:]
    /// A finished sentence waiting for its second pass, which uses the recognizer's final transcript when it
    /// arrives (more accurate than the in-progress text the live pass translated).
    private struct RevisionJob {
        var id: UUID
        var sentence: FinishedSentence
        var context: [TranslationContext]
        var queuedAt: Double
        var finalSource: String?
        /// Cut mid-speech at the length cap: a second model tends to "complete" fragments, so they're skipped.
        var isFragment = false
        var source: String { finalSource ?? sentence.source }
    }
    /// Request ids of final requests for fragments.
    private var fragmentRequests: Set<Int> = []
    /// The utterance in progress continues one that was cut mid-speech. Its first words belong to the previous
    /// sentence, and with that sentence as "background" the model tends to translate the background again, so
    /// it's translated without context.
    private var continuesFragment = false
    /// Earlier sentences are given as context only once the utterance has this many words: with a couple of
    /// words and a long background, a small model translates the background instead ("Think we" → the previous
    /// sentence), and prefix forcing would then keep it.
    static let minWordsForContext = 6
    private var revisionQueue: [RevisionJob] = []
    private var revising: RevisionJob?
    /// Final transcripts that arrived before their sentence was queued for revision.
    private var finalSources: [UUID: String] = [:]
    /// The second pass waits this long for the final transcript before using the live text.
    static let finalSourceWait = 4.0
    private var revisionToken = 0
    private var speakerPaused = true
    private var metrics = SentenceMetrics()

    /// Called with the source tokens of every finished sentence (and the sentence's id) so the engine can
    /// drop them and later report their final transcript (`finalTranscript(_:for:)`).
    var onSentenceFinished: (([Token], UUID) -> Void)?
    private(set) var lastError: String?
    /// Explains a fallback (e.g. a model that isn't downloaded yet); shown in Settings.
    private(set) var notice: String?

    init(captions: CaptionStore, settings: SettingsStore) {
        self.captions = captions
        self.settings = settings
    }

    private var now: Double { ProcessInfo.processInfo.systemUptime }

    /// Builds translators and the policy from settings. Throws if the live translator can't be used.
    func configure() async throws {
        generation += 1
        let s = settings.settings
        let source = LanguageNames.translationLanguage(fromLocale: s.sourceLocale)
        let target = Locale.Language(identifier: s.targetLanguage)
        let sourceName = LanguageNames.name(source.minimalIdentifier)
        let targetName = LanguageNames.name(s.targetLanguage)
        let profile = LanguageProfile.forTarget(s.targetLanguage).tuned(stability: s.timing.stability)
        lastError = nil
        notice = nil
        let models = LocalModelStore.shared
        let small = LocalModel.live(s.translation.localEngine)
        let large = LocalModel.reviser(s.translation.localEngine)
        var backend = s.translation.backend
        if backend == .localLLM, !models.isDownloaded(small) {
            backend = .apple
            notice = "Using Apple Translation until \(small.name) is downloaded (Settings → Translation)."
        }
        var revision = s.translation.revision
        if revision == .localLLMLarge, !models.isDownloaded(large) {
            // Apple's reviser disagrees with an LLM's wording too often to be worth the churn.
            revision = backend == .localLLM ? .off : .appleHighFidelity
        }
        if revision == .localLLMSmall, !models.isDownloaded(small) { revision = .appleHighFidelity }

        let live: SentenceTranslator = switch backend {
        case .localLLM:
            LocalLLMTranslator(model: small, targetName: targetName, targetCode: s.targetLanguage,
                               glossary: s.translation.glossary, style: s.translation.customInstructions)
        case .apple: AppleTranslator(source: source, target: target, lowLatency: true)
        case .appleIntelligence:
            FoundationModelTranslator(sourceName: sourceName, targetName: targetName,
                                      customInstructions: s.translation.customInstructions, hint: profile.promptHint,
                                      glossary: s.translation.glossary)
        case .lmStudio:
            LMStudioTranslator(settings: s.translation, sourceName: sourceName, targetName: targetName,
                               targetCode: s.targetLanguage, hint: profile.promptHint)
        case .none: PassthroughTranslator()
        }
        try await live.prepare()
        self.live = live

        reviser = nil
        if backend != .none {
            let candidate: SentenceTranslator? = switch revision {
            case .off: nil
            case .localLLMLarge:
                LocalLLMTranslator(model: large, targetName: targetName, targetCode: s.targetLanguage,
                                   glossary: s.translation.glossary, style: s.translation.customInstructions)
            case .localLLMSmall:
                LocalLLMTranslator(model: small, targetName: targetName, targetCode: s.targetLanguage,
                                   glossary: s.translation.glossary, style: s.translation.customInstructions)
            case .appleHighFidelity: AppleTranslator(source: source, target: target, lowLatency: false)
            case .appleIntelligence:
                FoundationModelTranslator(sourceName: sourceName, targetName: targetName,
                                          customInstructions: s.translation.customInstructions, hint: "",
                                          glossary: s.translation.glossary)
            case .lmStudio: LMStudioTranslator(settings: s.translation, sourceName: sourceName, targetName: targetName,
                                               targetCode: s.targetLanguage, hint: "")
            }
            if let candidate, candidate.qualityKey != live.qualityKey {
                do {
                    try await candidate.prepare()
                    reviser = candidate
                } catch {
                    log.info("Second pass unavailable: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        policy = SimulPolicy(profile: profile, prefixForcing: live.supportsPrefix)
        policy.historyLimit = max(0, s.translation.contextSentences)
        revisionPolicy = RevisionPolicy()
        reset()
    }

    /// The engine reports the sentence in progress (stable source only) on every tick. `speechEndedAgo`: for a
    /// complete utterance, how long ago its speech ended (for latency metrics).
    func update(_ sentence: SourceFrontier.Sentence, speechEndedAgo: Double? = nil) {
        guard !sentence.tokens.isEmpty else { return }
        latest = sentence
        captions.currentSentence(source: sentence.text)
        metrics.sourceSeen(at: now)
        if let ago = speechEndedAgo { metrics.speechEnded(at: now - ago) }
        pump()
        if inFlight == nil, let display = policy.tick(now: now) {
            show(display)
        }
        refreshLag()
    }

    /// Called every engine tick: second-pass revisions run while the speaker pauses, so they never hold
    /// up live captions (Apple's translation service handles one request at a time).
    func idle(silence: Double) {
        speakerPaused = silence >= 0.5
        pumpRevisions()
    }

    /// True while a final request is outstanding or queued (used to drain on stop).
    var isBusy: Bool { inFlight != nil }

    func reset() {
        generation += 1
        latest = nil
        inFlight = nil
        finalTokens = [:]
        fragmentRequests = []
        continuesFragment = false
        revisionQueue = []
        revising = nil
        finalSources = [:]
        policy.reset()
        policy.clearHistory()
        metrics = SentenceMetrics()
        captions.lag = 0
    }

    // MARK: Live pass

    private func pump() {
        guard inFlight == nil, let sentence = latest,
              let request = policy.update(source: sentence.text, isFinal: sentence.isComplete, now: now) else { return }
        if request.isFinal {
            finalTokens[request.id] = sentence.tokens
            if sentence.isCut { fragmentRequests.insert(request.id) }
            metrics.completed(at: now)
        }
        preemptRevision()
        inFlight = request
        let gen = generation
        let translator = live
        let context = continuesFragment || TextJoiner.wordCount(request.source) < Self.minWordsForContext ? [] : policy.history
        let started = now
        Task {
            var hypothesis: String
            do {
                hypothesis = try await translator.translate(source: request.source, prefix: request.prefix,
                                                            context: context, isFinal: request.isFinal)
            } catch {
                guard gen == generation else { return }
                log.error("Live translation failed: \(error.localizedDescription, privacy: .public)")
                lastError = error.localizedDescription
                // A failed final still finishes the sentence (showing the original) so captions keep flowing.
                hypothesis = request.isFinal ? request.source : ""
            }
            guard gen == generation else { return }
            if policy.profile.unit == .character { hypothesis = TextJoiner.normalizeSpacelessSpacing(hypothesis) }
            DebugLog.write(String(format: "LIVE %4.0fms %@ | %@ → %@", (now - started) * 1000,
                                  request.isFinal ? "final" : "     ", request.source, hypothesis))
            inFlight = nil
            if !hypothesis.isEmpty || request.isFinal {
                apply(policy.receive(request, hypothesis: hypothesis, now: now), request: request)
            }
            pump()
        }
    }

    private func apply(_ outcome: SimulOutcome, request: SimulRequest) {
        if let finished = outcome.finished {
            let id = captions.sentence(forFinishing: finished.source)
            metrics.display(outcome.display, at: now)
            captions.finishCurrent(source: finished.source, translation: finished.translation,
                                   replaced: outcome.replacedCommitted)
            metrics.finished(at: now, translation: finished.translation, replaced: outcome.replacedCommitted)
            DebugLog.write("SENTENCE " + metrics.summaryJSON(source: finished.source))
            metrics = SentenceMetrics()
            let sentenceID = id ?? UUID()
            latest = nil
            let isFragment = fragmentRequests.remove(request.id) != nil
            continuesFragment = isFragment
            if let id, reviser != nil, !isFragment {
                revisionQueue.append(RevisionJob(id: id, sentence: finished, context: Array(policy.history.dropLast()),
                                                 queuedAt: now, finalSource: finalSources.removeValue(forKey: id)))
            }
            if let tokens = finalTokens.removeValue(forKey: request.id) { onSentenceFinished?(tokens, sentenceID) }
            pumpRevisions()
        } else {
            show(outcome.display)
        }
        refreshLag()
    }

    private func show(_ display: SimulDisplay) {
        let ghost = settings.settings.overlay.showProvisional ? display.ghost : ""
        metrics.display(SimulDisplay(committed: display.committed, ghost: ghost), at: now)
        captions.updateCurrent(committed: display.committed, ghost: ghost)
    }

    private func refreshLag() {
        captions.lag = metrics.lag(now: now)
    }

    // MARK: Second pass

    /// The recognizer finalized a finished sentence's words: show the accurate transcript and use it for the
    /// second pass.
    func finalTranscript(_ text: String, for id: UUID) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        captions.correctSource(id, source: text)
        if let i = revisionQueue.firstIndex(where: { $0.id == id }) {
            revisionQueue[i].finalSource = text
        } else if revising?.id != id {
            finalSources[id] = text
            if finalSources.count > 20 { finalSources.removeAll() }
        }
        pumpRevisions()
    }

    /// Live captions come first: a running revision is cancelled and retried at the next pause.
    private func preemptRevision() {
        guard let job = revising else { return }
        reviser?.cancelInFlight()
        revisionToken += 1
        revising = nil
        revisionQueue.insert(job, at: 0)
        DebugLog.write("REVISE preempted by live translation")
    }

    private func pumpRevisions() {
        // Only when nothing live is pending: the speaker paused and the last utterance is finished.
        guard revising == nil, let reviser, let next = revisionQueue.first, speakerPaused, inFlight == nil, latest == nil else { return }
        guard captions.canRevise(next.id) else {
            revisionQueue.removeFirst()
            return pumpRevisions()
        }
        // Wait (briefly) for the recognizer's final transcript.
        guard next.finalSource != nil || now - next.queuedAt >= Self.finalSourceWait else { return }
        let job = revisionQueue.removeFirst()
        revising = job
        revisionToken += 1
        let token = revisionToken
        let gen = generation
        let unit = policy.profile.unit
        Task {
            let started = now
            let candidate = try? await reviser.translate(source: job.source, prefix: "", context: job.context, isFinal: true)
            guard gen == generation, token == revisionToken else { return } // cancelled or superseded
            revising = nil
            defer { pumpRevisions() }
            guard var candidate, let current = captions.sentence(job.id), captions.canRevise(job.id) else { return }
            if unit == .character { candidate = TextJoiner.normalizeSpacelessSpacing(candidate) }
            let sourceChanged = job.finalSource.map { RevisionPolicy.sourceDiffers($0, job.sentence.source) } ?? false
            let decision = revisionPolicy.evaluate(current: current.committed, candidate: candidate, unit: unit,
                                                   revisionsSoFar: current.revisions, sourceChanged: sourceChanged)
            DebugLog.write(String(format: "REVISE %4.0fms %@ | %@%@ | %@ → %@", (now - started) * 1000,
                                  String(describing: decision), job.finalSource == nil ? "" : "[final] ", job.source,
                                  current.committed, candidate))
            if case .accept(let changed) = decision {
                captions.revise(job.id, translation: candidate, changed: changed)
                policy.replaceHistory(source: job.sentence.source, translation: candidate, correctedSource: job.finalSource)
            }
        }
    }
}

/// Per-sentence timing and stability measurements, written to the debug log.
struct SentenceMetrics {
    private var firstSourceAt: Double?
    private var firstOutputAt: Double?
    private var lastCommitAt: Double?
    private var completedAt: Double?
    private var finishedAt: Double?
    private var speechEndedAt: Double?
    private var displayed = ""
    private var displayedCommitted = ""
    private var committedLength = 0
    private var erased = 0
    private var committedErased = 0
    private var finalLength = 0
    private var replaced = false

    mutating func sourceSeen(at t: Double) {
        if firstSourceAt == nil { firstSourceAt = t }
    }

    mutating func display(_ d: SimulDisplay, at t: Double) {
        let text = d.committed + d.ghost
        if firstOutputAt == nil, !text.isEmpty { firstOutputAt = t }
        if d.committed.count > committedLength {
            committedLength = d.committed.count
            lastCommitAt = t
        }
        // Erasure: visible characters taken back (they were shown, then replaced), overall and for
        // committed text only (which should only change through replacements).
        let common = zip(displayed, text).prefix { $0 == $1 }.count
        erased += displayed.count - common
        displayed = text
        let commonCommitted = zip(displayedCommitted, d.committed).prefix { $0 == $1 }.count
        committedErased += displayedCommitted.count - commonCommitted
        displayedCommitted = d.committed
    }

    mutating func completed(at t: Double) { if completedAt == nil { completedAt = t } }
    mutating func speechEnded(at t: Double) { if speechEndedAt == nil { speechEndedAt = t } }

    mutating func finished(at t: Double, translation: String, replaced: Bool) {
        finishedAt = t
        finalLength = translation.count
        self.replaced = replaced
    }

    /// Seconds since the translation last moved forward while source is waiting.
    func lag(now: Double) -> Double {
        guard let start = firstSourceAt, finishedAt == nil else { return 0 }
        return now - max(lastCommitAt ?? start, start)
    }

    func summaryJSON(source: String) -> String {
        func ms(_ a: Double?, _ b: Double?) -> Int { guard let a, let b else { return -1 }; return Int((b - a) * 1000) }
        let fields: [String: Any] = [
            "source": source,
            "words": source.split(separator: " ").count,
            "firstOutputMs": ms(firstSourceAt, firstOutputAt),
            "finishAfterCompleteMs": ms(completedAt, finishedAt),
            "finishAfterSpeechMs": ms(speechEndedAt, finishedAt),
            "durationMs": ms(firstSourceAt, finishedAt),
            "erasedChars": erased,
            "finalChars": finalLength,
            "normalizedErasure": finalLength > 0 ? Double(erased) / Double(finalLength) : 0,
            "committedErasure": finalLength > 0 ? Double(committedErased) / Double(finalLength) : 0,
            "replacedCommitted": replaced,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
