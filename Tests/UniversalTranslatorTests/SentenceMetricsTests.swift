import Foundation
import Testing
import TranslatorCore
@testable import UniversalTranslator

// The per-sentence measurements in the debug log (scripts/evaluate.py reads them). In Japanese and Chinese no word
// is stable until the utterance ends, so "first output" (from the first stable word) can't show how long the
// captions trail the speaker; the time from the first spoken word can.

@Suite struct SentenceMetricsTests {
    private func summary(_ m: SentenceMetrics, source: String = "今日は三つのことについてお話したいと思います") -> [String: Any] {
        let json = m.summaryJSON(source: source)
        return (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
    }

    @Test func firstCaptionIsTimedFromTheFirstSpokenWord() {
        var m = SentenceMetrics()
        m.speechStarted(at: 10)
        m.speechStarted(at: 11)          // later ticks see the same unit: the first time counts
        m.sourceSeen(at: 14)             // the utterance ended: its words are stable at last
        m.completed(at: 14)
        m.display(SimulDisplay(committed: "Today, I would like"), at: 14.25)
        m.speechEnded(at: 13.75)
        m.finished(at: 14.5, translation: "Today, I would like to discuss three matters.", replaced: false)
        let s = summary(m)
        #expect(s["firstOutputAfterSpeechStartMs"] as? Int == 4250)
        #expect(s["firstOutputMs"] as? Int == 250)
        #expect(s["finishAfterSpeechMs"] as? Int == 750)
    }

    @Test func theLogLineCarriesTheTranslation() {
        var m = SentenceMetrics()
        m.finished(at: 1, translation: "Where is the nearest station?", replaced: false)
        let s = summary(m, source: "一番近い駅はどこですか")
        #expect(s["translation"] as? String == "Where is the nearest station?")
        #expect(s["source"] as? String == "一番近い駅はどこですか")
    }

    @Test func noSpeechStartMeansNoMeasurement() {
        var m = SentenceMetrics()
        m.display(SimulDisplay(committed: "Hi"), at: 2)
        #expect(summary(m)["firstOutputAfterSpeechStartMs"] as? Int == -1)
    }
}
