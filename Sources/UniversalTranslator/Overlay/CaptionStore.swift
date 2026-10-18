import Foundation
import Observation
import TranslatorCore

/// Everything the overlay displays: translated sentences (committed text plus a provisional tail for the
/// sentence in progress), the untranslated source tail, and the engine status.
@MainActor
@Observable
final class CaptionStore {
    struct Sentence: Identifiable, Equatable {
        let id = UUID()
        var source: String
        /// Translation that won't change (except by one second-pass revision once finished).
        var committed = ""
        /// Provisional translation of the rest of the sentence so far; may change on every update.
        var ghost = ""
        var isFinished = false
        var startedAt: Date
        var finishedAt: Date?
        /// When `committed` last grew, and how long it was before (for fading new words in).
        var committedGrewAt = Date.distantPast
        var committedLengthBefore = 0
        /// Second-pass revision state.
        var revisions = 0
        var revisedAt: Date?
        var revisedRanges: [Range<Int>] = []
    }

    enum Status: Equatable {
        case idle
        case preparing(String)
        case listening
        case paused
        case error(String)

        var isActive: Bool {
            switch self {
            case .listening, .preparing, .paused: return true
            default: return false
            }
        }
    }

    private(set) var sentences: [Sentence] = []
    /// Index of the first sentence of the paragraph currently on screen.
    private(set) var paragraphStart = 0
    /// Recognized words not yet part of a sentence being translated (still settling).
    var liveSource = ""
    var isSpeaking = false
    /// Microphone level in dBFS (for the settings meter; the overlay doesn't observe it).
    var inputLevel: Double = -120
    /// Seconds the translation is behind the speaker (shown by the lag indicator).
    var lag: Double = 0
    var status: Status = .idle
    var isDemo = false
    @ObservationIgnored private var pendingBreak = false
    @ObservationIgnored private var sessionStart = Date()
    var sessionStartDate: Date { sessionStart }
    /// Bumped whenever something visible changes; drives overlay auto-hide.
    private(set) var lastActivity = Date()
    /// Bumped when time-based effects (word fade-in, revision highlight) have run their course, so the
    /// overlay re-renders once more and stops animating.
    private(set) var effectsVersion = 0
    @ObservationIgnored private var effectsEnd: DispatchWorkItem?

    /// Line timing for the reading-speed limit (updated while the overlay lays out captions).
    @ObservationIgnored var governor = ReadingGovernor()
    /// Bumped when a line held for reading may now scroll away.
    private(set) var refreshVersion = 0
    @ObservationIgnored private var refreshWork: DispatchWorkItem?
    @ObservationIgnored private var refreshAt: Double = .infinity
    /// Bumped when the captions are cleared on purpose (not by a paragraph break), so the marquee empties too.
    private(set) var clearCount = 0
    /// System uptime until which the marquee still has text scrolling across (for auto-hide and auto-clear).
    @ObservationIgnored var scrollingUntil: Double = 0

    /// Re-renders the overlay at `uptime` (system uptime seconds).
    func scheduleRefresh(at uptime: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        guard uptime > now, uptime < refreshAt - 0.01 || refreshAt <= now else { return }
        refreshWork?.cancel()
        refreshAt = uptime
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshAt = .infinity
                self?.refreshVersion += 1
            }
        }
        refreshWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (uptime - now) + 0.02, execute: work)
    }

    /// Whether the marquee still has text on screen.
    var isScrolling: Bool { scrollingUntil > ProcessInfo.processInfo.systemUptime }

    /// Reading time of the newest caption text on screen (for auto-hide and auto-clear).
    func readingTimeOfLatest(charactersPerSecond: Double) -> Double {
        guard charactersPerSecond > 0, let last = paragraph.last else { return 0 }
        let text = last.committed + last.ghost
        let reader = ReadingGovernor(charactersPerSecond: charactersPerSecond)
        let since = Date().timeIntervalSince(last.finishedAt ?? last.committedGrewAt)
        return max(0, reader.readingTime(text) - max(0, since))
    }

    /// Whether the captions have been quiet long enough to clear (`after` seconds of silence, 0 = never). Text is
    /// never cleared before it's had time to be read, or while marquee text is still crossing the screen.
    func shouldAutoClear(after delay: Double, readingSpeed: Double) -> Bool {
        guard delay > 0, hasVisibleText, !isSpeaking, liveSource.isEmpty, !isScrolling,
              paragraph.last?.isFinished ?? true else { return false }
        let idle = Date().timeIntervalSince(lastActivity)
        return idle > max(delay, readingTimeOfLatest(charactersPerSecond: readingSpeed))
    }

    /// Time-based effects on new and revised text last this long.
    static let fadeInDuration: TimeInterval = 0.35
    static let highlightDuration: TimeInterval = 1.4

    var paragraph: ArraySlice<Sentence> { sentences[min(paragraphStart, sentences.count)...] }

    var hasVisibleText: Bool {
        paragraph.contains { !$0.committed.isEmpty || !$0.ghost.isEmpty || !$0.source.isEmpty } || !liveSource.isEmpty
    }

    // MARK: Sentence lifecycle (driven by the live translation controller)

    /// The sentence being translated, created when it first appears.
    @discardableResult
    func currentSentence(source: String) -> UUID {
        if isDemo { clear() }
        if let last = sentences.last, !last.isFinished {
            if last.source != source {
                sentences[sentences.count - 1].source = source
                touch()
            }
            return last.id
        }
        if pendingBreak { breakParagraph() }
        sentences.append(Sentence(source: source, startedAt: Date()))
        trimHistory()
        touch()
        return sentences[sentences.count - 1].id
    }

    func updateCurrent(committed: String, ghost: String) {
        guard let i = sentences.indices.last, !sentences[i].isFinished else { return }
        var s = sentences[i]
        if committed.count > s.committed.count {
            s.committedLengthBefore = s.committed.count
            s.committedGrewAt = Date()
            scheduleEffectsEnd(after: Self.fadeInDuration)
        }
        s.committed = committed
        s.ghost = ghost
        guard s != sentences[i] else { return }
        sentences[i] = s
        touch()
    }

    /// Finishes the sentence in progress. When the final translation doesn't continue what was committed
    /// (`replaced`), the change is highlighted like a revision instead of swapping text silently.
    func finishCurrent(source: String, translation: String, replaced: Bool = false) {
        guard let i = sentences.indices.last, !sentences[i].isFinished else { return }
        var s = sentences[i]
        if replaced, !s.committed.isEmpty {
            markRevision(&s, old: s.committed, new: translation)
        } else if translation.count > s.committed.count || !translation.hasPrefix(s.committed) {
            s.committedLengthBefore = translation.hasPrefix(s.committed) ? s.committed.count : 0
            s.committedGrewAt = Date()
            scheduleEffectsEnd(after: Self.fadeInDuration)
        }
        s.source = source
        s.committed = translation
        s.ghost = ""
        s.isFinished = true
        s.finishedAt = Date()
        sentences[i] = s
        touch()
    }

    func sentence(_ id: UUID) -> Sentence? { sentences.first { $0.id == id } }

    /// Replaces a finished sentence's original text with the recognizer's final (more accurate) transcript.
    func correctSource(_ id: UUID, source: String) {
        guard let i = sentences.lastIndex(where: { $0.id == id }), sentences[i].source != source else { return }
        sentences[i].source = source
        touch()
    }

    /// The id of the sentence about to be finished (the one in progress).
    func sentence(forFinishing source: String) -> UUID? {
        if let last = sentences.last, !last.isFinished { return last.id }
        return currentSentence(source: source)
    }

    /// A second-pass revision may only touch a sentence the reader can still see near the end.
    func canRevise(_ id: UUID) -> Bool {
        guard let index = sentences.firstIndex(where: { $0.id == id }), index >= paragraphStart else { return false }
        return sentences.count - index <= 2
    }

    func revise(_ id: UUID, translation: String, changed: [Range<Int>]) {
        guard let i = sentences.firstIndex(where: { $0.id == id }) else { return }
        var s = sentences[i]
        markRevision(&s, old: s.committed, new: translation, changed: changed)
        s.committed = translation
        s.revisions += 1
        sentences[i] = s
        touch()
    }

    /// Highlights the edited words of a revision. When most of the text changed, highlighting would light
    /// up whole lines, so the new text fades in instead.
    private func markRevision(_ s: inout Sentence, old: String, new: String, changed: [Range<Int>]? = nil) {
        let ranges = changed ?? RevisionPolicy.changedRanges(old: old, new: new)
        let changedCount = ranges.reduce(0) { $0 + $1.count }
        if Double(changedCount) <= 0.4 * Double(max(new.count, 1)) {
            s.revisedRanges = ranges
            s.revisedAt = Date()
            scheduleEffectsEnd(after: Self.highlightDuration)
        } else {
            s.revisedRanges = []
            s.revisedAt = nil
            s.committedLengthBefore = 0
            s.committedGrewAt = Date()
            scheduleEffectsEnd(after: Self.fadeInDuration)
        }
    }

    private func scheduleEffectsEnd(after delay: TimeInterval) {
        effectsEnd?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.effectsVersion += 1 }
        }
        effectsEnd = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.05, execute: work)
    }

    /// Whether any visible sentence is mid-fade or mid-highlight at `date`.
    func hasActiveEffects(at date: Date) -> Bool {
        paragraph.contains { s in
            date.timeIntervalSince(s.committedGrewAt) < Self.fadeInDuration
                || (s.revisedAt.map { date.timeIntervalSince($0) < Self.highlightDuration } ?? false)
        }
    }

    // MARK: Paragraphs and clearing

    /// Starts a fresh paragraph so old captions leave the screen after a long pause.
    func breakParagraph() {
        pendingBreak = false
        guard paragraphStart < sentences.count, liveSource.isEmpty, sentences.last?.isFinished ?? true else { return }
        paragraphStart = sentences.count
    }

    /// The next sentence starts a fresh paragraph; until then the old one stays readable.
    func requestParagraphBreak() {
        if paragraphStart < sentences.count { pendingBreak = true }
    }

    func clear() {
        isDemo = false
        paragraphStart = sentences.count
        liveSource = ""
        clearCount += 1
        scrollingUntil = 0
        touch()
    }

    func resetSession() {
        sentences = []
        paragraphStart = 0
        liveSource = ""
        isDemo = false
        lag = 0
        clearCount += 1
        scrollingUntil = 0
        sessionStart = Date()
    }

    func touch() { lastActivity = Date() }

    private func trimHistory() {
        // Keep memory bounded in very long sessions; export keeps the most recent 5000 sentences.
        guard sentences.count > 5000 else { return }
        sentences.removeFirst(500)
        paragraphStart = max(0, paragraphStart - 500)
    }

    // MARK: Export

    var sessionEntries: [SessionEntry] {
        sentences.filter(\.isFinished).map {
            SessionEntry(start: $0.startedAt.timeIntervalSince(sessionStart),
                         end: ($0.finishedAt ?? $0.startedAt).timeIntervalSince(sessionStart),
                         source: $0.source, translation: $0.committed)
        }
    }

    // MARK: Demo

    func showDemo(targetLanguage: String) {
        resetSession()
        isDemo = true
        let samples = DemoText.sample(for: targetLanguage)
        var first = Sentence(source: samples.source1, startedAt: Date())
        first.committed = samples.target1
        first.isFinished = true
        var second = Sentence(source: samples.source2, startedAt: Date())
        second.committed = samples.target2Committed
        second.ghost = samples.target2Ghost
        sentences = [first, second]
        touch()
    }
}

enum DemoText {
    struct Sample { var source1, target1, source2, target2Committed, target2Ghost: String }

    static func sample(for language: String) -> Sample {
        let s1 = "Thanks everyone for joining today."
        let s2 = "Let's start with a quick look at the"
        switch String(language.prefix(2)) {
        case "ja": return Sample(source1: s1, target1: "本日はご参加いただきありがとうございます。", source2: s2, target2Committed: "まずは", target2Ghost: "簡単に")
        case "es": return Sample(source1: s1, target1: "Gracias a todos por acompañarnos hoy.", source2: s2, target2Committed: "Empecemos con", target2Ghost: " un vistazo rápido")
        case "fr": return Sample(source1: s1, target1: "Merci à tous d'être présents aujourd'hui.", source2: s2, target2Committed: "Commençons par", target2Ghost: " un rapide aperçu")
        case "de": return Sample(source1: s1, target1: "Vielen Dank an alle, die heute dabei sind.", source2: s2, target2Committed: "Beginnen wir", target2Ghost: " mit einem kurzen Blick")
        case "zh": return Sample(source1: s1, target1: "感谢大家今天的参与。", source2: s2, target2Committed: "我们先", target2Ghost: "快速看一下")
        case "ko": return Sample(source1: s1, target1: "오늘 참석해 주신 모든 분께 감사드립니다.", source2: s2, target2Committed: "먼저", target2Ghost: " 간단히 살펴보겠습니다")
        default: return Sample(source1: s1, target1: s1, source2: s2, target2Committed: "Let's start", target2Ghost: " with a quick look")
        }
    }
}
