import Foundation
import Testing
@testable import TranslatorCore

@Suite struct LanguageProfileTests {
    @Test func unitsAndAgreement() {
        let es = LanguageProfile.forTarget("es")
        #expect(es.units("Nosotros esperábamos enviar") == ["Nosotros", " esperábamos", " enviar"])
        #expect(es.agreedPrefix("Nosotros esperábamos enviar", "Nosotros esperábamos lanzar") == "Nosotros esperábamos")
        let ja = LanguageProfile.forTarget("ja")
        #expect(ja.agreedPrefix("まず、3月に出荷", "まず、3月の出荷") == "まず、3月")
        #expect(ja.trimToSafeBoundary("まず、3月") == "まず、")
        #expect(ja.trimToSafeBoundary("約6週間のテスト") == "約6週間の")
    }

    @Test func stabilityTuning() {
        let de = LanguageProfile.forTarget("de")
        #expect(de.tuned(stability: 0).maxDelay < de.maxDelay)
        #expect(de.tuned(stability: 1).maxDelay > de.maxDelay)
        #expect(de.tuned(stability: 0).maskK == de.maskK - 1)
        #expect(de.tuned(stability: 1).maskK == de.maskK + 1)
    }

    @Test func stripsPrematureFinalPunctuation() {
        let ja = LanguageProfile.forTarget("ja")
        #expect(ja.stripFinalPunctuation("望んでいました。") == "望んでいました")
        #expect(LanguageProfile.forTarget("en").stripFinalPunctuation("hoping to ship. ") == "hoping to ship")
    }
}

@Suite struct SimulPolicyTests {
    /// Runs one update/response round.
    @discardableResult
    func step(_ p: SimulPolicy, _ source: String, _ hypothesis: String, final: Bool = false, now: Double) -> SimulOutcome? {
        guard let request = p.update(source: source, isFinal: final, now: now) else { return nil }
        return p.receive(request, hypothesis: hypothesis, now: now)
    }

    @Test func commitsOnlyWhatConsecutiveTranslationsAgreeOn() {
        let p = SimulPolicy(profile: .forTarget("es"), prefixForcing: true)
        let first = step(p, "We were hoping", "Esperábamos", now: 0)!
        #expect(first.display.committed == "")
        let second = step(p, "We were hoping to ship", "Esperábamos enviar", now: 0.5)!
        #expect(second.display.committed == "Esperábamos")
        #expect(second.committedGrew)
        // The next request continues the committed prefix.
        let request = p.update(source: "We were hoping to ship in March", isFinal: false, now: 1)!
        #expect(request.prefix == "Esperábamos")
    }

    @Test func verbFinalTargetWaitsForTheVerb() {
        let p = SimulPolicy(profile: .forTarget("ja"), prefixForcing: true)
        step(p, "We were hoping", "私たちは望んでいました", now: 0)
        // The object arrives and the verb moves to the end: only the stable topic is committed.
        let out = step(p, "We were hoping to ship in March", "私たちは3月に出荷することを望んでいました", now: 0.5)!
        #expect(out.display.committed == "私たちは")
        #expect(out.display.ghost.hasPrefix("3月に"))
    }

    @Test func ghostHidesTheLeastStableUnits() {
        let p = SimulPolicy(profile: .forTarget("es"), prefixForcing: true)
        let out = step(p, "We were hoping to ship in", "Esperábamos enviar en", now: 0)!
        #expect(out.display.ghost == "Esperábamos") // last 2 words masked
    }

    @Test func finalFlushCompletesTheSentenceAndRecordsHistory() {
        let p = SimulPolicy(profile: .forTarget("es"), prefixForcing: true)
        step(p, "We were hoping", "Esperábamos", now: 0)
        step(p, "We were hoping to ship", "Esperábamos enviar", now: 0.5)
        let out = step(p, "We were hoping to ship in March.", "Esperábamos enviar en marzo.", final: true, now: 1)!
        #expect(out.finished?.translation == "Esperábamos enviar en marzo.")
        #expect(out.display.committed == "Esperábamos enviar en marzo.")
        #expect(p.history.last?.source == "We were hoping to ship in March.")
        #expect(p.committed.isEmpty)
    }

    @Test func forcesACommitAfterMaxDelay() {
        let p = SimulPolicy(profile: .forTarget("es"), prefixForcing: true)
        // Translations keep disagreeing from the first word, so nothing is agreed.
        step(p, "one two", "Uno dos tres cuatro", now: 0)
        step(p, "one two three", "Un dos tres cuatro cinco", now: 1)
        #expect(p.committed.isEmpty)
        #expect(p.tick(now: 2) == nil)
        let forced = p.tick(now: 3.0)
        #expect(forced?.committed == "Un dos tres") // latest hypothesis minus the masked tail
    }

    @Test func doesNotRequestTheSameSourceTwice() {
        let p = SimulPolicy(profile: .forTarget("es"), prefixForcing: true)
        #expect(p.update(source: "Hello there", isFinal: false, now: 0) != nil)
        #expect(p.update(source: "Hello there", isFinal: false, now: 0.2) == nil)
        #expect(p.update(source: "Hello there.", isFinal: true, now: 0.4) != nil)
    }

    @Test func translatorWithoutPrefixCommitsTheSharedPrefix() {
        let p = SimulPolicy(profile: .forTarget("es"), prefixForcing: false)
        step(p, "we are now", "ahora estamos", now: 0)
        step(p, "we are now looking", "ahora estamos mirando", now: 0.4)
        #expect(p.committed == "ahora estamos")
        // A re-translation that contradicts the committed text neither extends nor duplicates it.
        let out = step(p, "we are now looking at April", "y ahora estamos mirando a abril", now: 0.8)!
        #expect(out.display.committed == "ahora estamos")
        #expect(out.display.ghost.isEmpty)
        // A consistent one extends it again.
        let next = step(p, "we are now looking at the end of", "ahora estamos mirando el final de", now: 1.2)!
        #expect(next.display.committed == "ahora estamos")
        #expect(next.display.ghost == " mirando el") // last 2 words masked
    }

    @Test func contradictingFinalReplacesTheSentence() {
        let p = SimulPolicy(profile: .forTarget("es"), prefixForcing: false)
        step(p, "we are now", "ahora estamos", now: 0)
        step(p, "we are now looking", "ahora estamos mirando", now: 0.4)
        let final = step(p, "we are now looking at April.", "Actualmente miramos abril.", final: true, now: 1)!
        #expect(final.finished?.translation == "Actualmente miramos abril.")
        #expect(final.replacedCommitted)
    }

    @Test func historyIsCapped() {
        let p = SimulPolicy(profile: .forTarget("es"), prefixForcing: true)
        for i in 0..<6 {
            step(p, "Sentence \(i).", "Frase \(i).", final: true, now: Double(i))
        }
        #expect(p.history.count == p.historyLimit)
        #expect(p.history.first?.source == "Sentence 2.")
    }
}

@Suite struct RevisionPolicyTests {
    let policy = RevisionPolicy()

    @Test func ignoresCosmeticChanges() {
        let d = policy.evaluate(current: "今、4月末を見ています。", candidate: "今、４月末を見ています", unit: .character, revisionsSoFar: 0)
        if case .accept = d { Issue.record("cosmetic change should be rejected") }
    }

    @Test func acceptsMeaningfulChangesWithHighlights() {
        let d = policy.evaluate(current: "私たちは今、4月の終わりを見ています。", candidate: "現在、4月末を目指しています。",
                                unit: .character, revisionsSoFar: 0)
        guard case .accept(let ranges) = d else { Issue.record("expected accept: \(d)"); return }
        #expect(!ranges.isEmpty)
    }

    @Test func rejectsInventedContent() {
        // "Where is the nearest train station" → the second pass answers its own question.
        let added = policy.evaluate(current: "最寄りの駅はどこですか？", candidate: "最寄りの駅はどこですか？ここから徒歩10分です。",
                                    unit: .character, revisionsSoFar: 0)
        #expect(added == .reject("adds a sentence"))
        let longer = policy.evaluate(current: "最寄りの駅がどこか", candidate: "最寄りの駅は、ここから徒歩10分ほどの距離にあります",
                                     unit: .character, revisionsSoFar: 0)
        if case .accept = longer { Issue.record("a much longer revision should be rejected") }
    }

    @Test func paraphraseNeedsACorrectedSource() {
        let current = "皆さん、おはようございます。参加してくださりありがとうございます。"
        let paraphrase = "おはようございます。ご参加いただき、ありがとうございます。"
        if case .accept = policy.evaluate(current: current, candidate: paraphrase, unit: .character, revisionsSoFar: 0,
                                          sourceChanged: false) {
            Issue.record("a paraphrase of the same source should be rejected")
        }
        #expect(RevisionPolicy.sourceDiffers("we first check whether the result is cashed", "We first check whether the result is cached."))
        #expect(!RevisionPolicy.sourceDiffers("any questions so far", "Any questions so far?"))
        #expect(RevisionPolicy.sentenceCount("Hello. How are you") == 2)
    }

    @Test func respectsRevisionBudget() {
        let d = policy.evaluate(current: "uno dos tres", candidate: "cuatro cinco seis", unit: .word, revisionsSoFar: 1)
        #expect(d == .reject("revision budget used"))
    }

    @Test func changedRangesAreRelativeToNewText() {
        #expect(RevisionPolicy.changedRanges(old: "abcdef", new: "abXYef") == [2..<4])
        #expect(RevisionPolicy.changedRanges(old: "", new: "ab") == [0..<2])
    }
}

@Suite struct SourceFrontierTests {
    private func tok(_ text: String, _ final: Bool, at i: Int) -> Token {
        Token(text: (i == 0 ? "" : " ") + text, start: Double(i) * 0.3, end: Double(i) * 0.3 + 0.25, isFinal: final)
    }

    @Test func holdsBackYoungVolatileWords() {
        var f = SourceFrontier(holdBack: 0.25)
        let pending = ["we", "were", "hoping"].enumerated().map { tok($1, false, at: $0) }
        #expect(f.currentSentence(pending: pending, stableCount: 3, now: 1.0).tokens.isEmpty)
        let later = f.currentSentence(pending: pending, stableCount: 3, now: 1.3)
        #expect(later.tokens.count == 3)
        #expect(!later.isComplete)
    }

    @Test func sentencePunctuationDoesNotEndTheUtterance() {
        // Speech continues past "everyone." with no pause: the unit keeps going (utterance-based units).
        var f = SourceFrontier(holdBack: 0)
        let pending = [tok("Thanks", true, at: 0), tok("everyone.", true, at: 1), tok("Today", true, at: 2)]
        let s = f.currentSentence(pending: pending, stableCount: 3, now: 0)
        #expect(!s.isComplete)
        #expect(s.text == "Thanks everyone. Today")
    }

    @Test func utteranceEndCompletesFinalizedText() {
        var f = SourceFrontier()
        let pending = [tok("any", true, at: 0), tok("questions", true, at: 1)]
        #expect(f.currentSentence(pending: pending, stableCount: 2, utteranceEnd: .all, now: 0).isComplete)
        let volatile = [tok("any", false, at: 0)]
        #expect(!f.currentSentence(pending: volatile, stableCount: 0, utteranceEnd: .finalsBefore(9), now: 0).isComplete)
        #expect(f.currentSentence(pending: volatile, stableCount: 0, utteranceEnd: .all, now: 0).isComplete)
        #expect(f.currentSentence(pending: volatile, stableCount: 1, flushAll: true, now: 0).isComplete)
    }

    @Test func speechAfterTheTurnEndStaysForTheNextUtterance() {
        // "any questions" ended a turn at 0.55 s; the speaker resumed at 0.6 s before the unit was finished.
        var f = SourceFrontier(holdBack: 0)
        let pending = [tok("any", true, at: 0), tok("questions", true, at: 1), tok("so", true, at: 2), tok("next", false, at: 3)]
        let s = f.currentSentence(pending: pending, stableCount: 4, utteranceEnd: .finalsBefore(0.575), now: 0)
        #expect(s.isComplete)
        #expect(s.text == "any questions")
    }

    @Test func finishesLongUtterancesAtTheStableEdge() {
        var f = SourceFrontier(holdBack: 0, maxSentenceWords: 10)
        let words = (0..<14).map { tok("word\($0)", $0 < 12, at: $0) }
        let s = f.currentSentence(pending: words, stableCount: 12, now: 0)
        #expect(s.isComplete)
        #expect(s.tokens.count == 12) // everything stable, not the unstable tail
    }

    @Test func keepsAgesAfterConsumingASentence() {
        var f = SourceFrontier(holdBack: 0.25)
        let pending = ["a", "b", "c", "d"].enumerated().map { tok($1, false, at: $0) }
        _ = f.currentSentence(pending: pending, stableCount: 4, now: 0)
        f.consume(2)
        let rest = Array(pending.dropFirst(2))
        #expect(f.currentSentence(pending: rest, stableCount: 2, now: 0.3).tokens.count == 2)
    }
}

@Suite struct TurnDetectorTests {
    /// Feeds 32 ms frames: `pattern` characters are speech ("#") or silence (".").
    private func feed(_ d: inout TurnDetector, _ pattern: String, from start: Double = 0) -> [TurnDetector.Event] {
        var events: [TurnDetector.Event] = []
        for (i, c) in pattern.enumerated() {
            events += d.process(probability: c == "#" ? 0.9 : 0.05, time: start + Double(i + 1) * 0.032, duration: 0.032)
        }
        return events
    }

    @Test func fixedPauseEndsTheTurnWithoutAModel() {
        var d = TurnDetector()
        let events = feed(&d, String(repeating: "#", count: 20) + String(repeating: ".", count: 30))
        #expect(events.first == .speechStarted(at: 0))
        guard case .turnEnded(_, let endOfSpeech, _, let reason) = events.last else { Issue.record("no turn end"); return }
        #expect(abs(endOfSpeech - 0.64) < 0.001)
        #expect(reason == .timeout)
        #expect(d.turnEnded)
    }

    @Test func modelEndsTheTurnEarly() {
        var config = TurnDetector.Config()
        config.usesTurnModel = true
        var d = TurnDetector(config: config)
        _ = feed(&d, String(repeating: "#", count: 20) + String(repeating: ".", count: 7)) // 0.22 s of silence
        let check1 = d.needsTurnCheck(at: d.time)
        #expect(check1)
        let check2 = d.needsTurnCheck(at: d.time)
        #expect(!check2) // one check per delay
        let event = d.turnChecked(probability: 0.9, at: d.time)
        guard case .turnEnded(_, _, let p, let reason)? = event else { Issue.record("no turn end"); return }
        #expect(reason == .model)
        #expect(p == 0.9)
    }

    @Test func unfinishedThoughtWaitsThroughAHesitation() {
        var config = TurnDetector.Config()
        config.usesTurnModel = true
        var d = TurnDetector(config: config)
        // "the weather is supposed to be" … 0.9 s … "really nice"
        _ = feed(&d, String(repeating: "#", count: 20) + String(repeating: ".", count: 9))
        let check3 = d.needsTurnCheck(at: d.time)
        #expect(check3)
        let answer6 = d.turnChecked(probability: 0.1, at: d.time)
        #expect(answer6 == nil)
        let more = feed(&d, String(repeating: ".", count: 19), from: d.time) // ~0.9 s of silence in total
        let check4 = d.needsTurnCheck(at: d.time)
        #expect(check4)
        let answer7 = d.turnChecked(probability: 0.2, at: d.time)
        #expect(answer7 == nil)
        #expect(!more.contains { if case .turnEnded = $0 { return true } else { return false } })
        let resumed = feed(&d, String(repeating: "#", count: 10), from: d.time)
        #expect(resumed.contains { if case .speechStarted = $0 { return true } else { return false } })
        #expect(d.turnStartTime == 0) // still the same turn
    }

    @Test func timeoutEndsTheTurnWhenTheModelKeepsWaiting() {
        var config = TurnDetector.Config()
        config.usesTurnModel = true
        var d = TurnDetector(config: config)
        let events = feed(&d, String(repeating: "#", count: 20) + String(repeating: ".", count: 50))
        #expect(events.contains { if case .turnEnded(_, _, _, .timeout) = $0 { return true } else { return false } })
    }

    @Test func aCheckAnsweredAfterSpeechResumedIsIgnored() {
        var config = TurnDetector.Config()
        config.usesTurnModel = true
        var d = TurnDetector(config: config)
        _ = feed(&d, String(repeating: "#", count: 20) + String(repeating: ".", count: 8))
        let check5 = d.needsTurnCheck(at: d.time)
        #expect(check5)
        _ = feed(&d, String(repeating: "#", count: 4), from: d.time)
        let answer8 = d.turnChecked(probability: 0.95, at: d.time)
        #expect(answer8 == nil)
        #expect(!d.turnEnded)
    }

    @Test func clicksDoNotStartSpeech() {
        var d = TurnDetector()
        let events = feed(&d, "#....#....")
        #expect(events.isEmpty)
        #expect(!d.isSpeaking)
    }
}

@Suite struct ReadingGovernorTests {
    private let lines = ["The first line of the caption,", "the second line that follows,", "and a third one arrives."]

    @Test func holdsALineUntilItHasBeenRead() {
        var g = ReadingGovernor(charactersPerSecond: 17, extraLines: 1)
        // Two lines on screen at t=0.
        #expect(g.visibleCount(lines: Array(lines.prefix(2)), maxLines: 2, now: 0).count == 2)
        // A third line arrives 0.5 s later: the first hasn't been read (30 chars ≈ 1.6 s), so it stays.
        let held = g.visibleCount(lines: lines, maxLines: 2, now: 0.5)
        #expect(held.count == 3)
        #expect(abs((held.recheckAt ?? 0) - ReadingGovernor.readingUnits(lines[0]) / 17) < 0.01)
        // Once read, it scrolls away.
        #expect(g.visibleCount(lines: lines, maxLines: 2, now: 2.0).count == 2)
    }

    @Test func offShowsTheUsualLines() {
        var g = ReadingGovernor(charactersPerSecond: 0)
        _ = g.visibleCount(lines: Array(lines.prefix(2)), maxLines: 2, now: 0)
        #expect(g.visibleCount(lines: lines, maxLines: 2, now: 0.1).count == 2)
    }

    @Test func linesNeverShownAreNotHeld() {
        var g = ReadingGovernor()
        // A burst of three lines at once: the oldest was never on screen.
        #expect(g.visibleCount(lines: lines, maxLines: 2, now: 0).count == 2)
    }

    @Test func japaneseReadsSlower() {
        #expect(ReadingGovernor.readingUnits("今日は") == 6)
        #expect(ReadingGovernor.readingUnits("Hi there") == 7)
        let g = ReadingGovernor(charactersPerSecond: 17)
        #expect(g.readingTime("本日はご参加いただきありがとうございます。") > 2)
    }
}
