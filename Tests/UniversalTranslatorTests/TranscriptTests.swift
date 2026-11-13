import Foundation
import Testing
import TranslatorCore
@testable import UniversalTranslator

// The saved transcript (one file per listening session, kept up to date) and sample captions that leave the
// session alone.

private let utc = TimeZone(identifier: "UTC")!
private let t0 = Date(timeIntervalSince1970: 1_761_400_992)   // 2025-10-25 14:03:12 UTC

@Suite struct TranscriptTextTests {
    @Test func eachSentenceHasItsClockTimeOriginalAndTranslation() {
        let text = TranscriptText.text(started: t0, languages: "English (United States) → Japanese", entries: [
            .init(started: t0.addingTimeInterval(3), source: "Thanks everyone.", translation: "皆さん、ありがとう。"),
            .init(started: t0.addingTimeInterval(65), source: "Let's start.", translation: "始めましょう。"),
        ], timeZone: utc)
        #expect(text == """
            Universal Translator transcript, 2025-10-25 14:03:12
            English (United States) → Japanese

            [14:03:15] Thanks everyone.
            → 皆さん、ありがとう。

            [14:04:17] Let's start.
            → 始めましょう。

            """)
    }

    @Test func filesAreNamedByWhenTheSessionStarted() {
        #expect(TranscriptText.fileName(started: t0, timeZone: utc) == "Transcript 2025-10-25 14.03.12.txt")
    }
}

@Suite @MainActor struct TranscriptAutosaveTests {
    private func folder() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("ut-transcripts-\(UUID().uuidString)")
    }

    private func files(_ folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
    }

    @Test func aRevisionReplacesTheSentenceInTheFile() throws {
        let dir = folder()
        let log = TranscriptAutosave(folder: dir)
        log.begin(languages: "English → Japanese", at: t0)
        let a = UUID(), b = UUID()
        log.record(id: a, started: t0.addingTimeInterval(2), source: "One.", translation: "一（初回）")
        log.record(id: b, started: t0.addingTimeInterval(5), source: "Two.", translation: "二")
        log.flush()
        // The second pass revises the first sentence: same place in the file, new text.
        log.record(id: a, started: t0.addingTimeInterval(2), source: "One.", translation: "一")
        log.flush()
        let text = try String(contentsOf: try #require(log.fileURL), encoding: .utf8)
        #expect(text.contains("One.\n→ 一\n"))
        #expect(!text.contains("初回"))
        #expect(text.components(separatedBy: "One.").count == 2, "listed once")
        #expect(text.range(of: "One.")!.lowerBound < text.range(of: "Two.")!.lowerBound)
        #expect(files(dir).count == 1)
    }

    @Test func eachSessionGetsItsOwnFileAndNothingIsWrittenForAnEmptyOne() throws {
        let dir = folder()
        let log = TranscriptAutosave(folder: dir)
        log.begin(languages: "", at: t0)
        log.end()
        #expect(files(dir).isEmpty, "a session without a finished sentence leaves no file")
        log.begin(languages: "", at: t0)
        log.record(id: UUID(), started: t0.addingTimeInterval(1), source: "A.", translation: "あ")
        log.end()   // stopping writes what's pending
        log.begin(languages: "", at: t0.addingTimeInterval(600))
        log.record(id: UUID(), started: t0.addingTimeInterval(601), source: "B.", translation: "び")
        log.end()
        let saved = files(dir)
        try #require(saved.count == 2)
        #expect(try String(contentsOf: saved[1], encoding: .utf8).contains("B.") && !String(contentsOf: saved[1], encoding: .utf8).contains("A."))
    }

    @Test func sentencesFromBeforeTheSessionAndAfterItEndsAreLeftOut() throws {
        let dir = folder()
        let log = TranscriptAutosave(folder: dir)
        log.record(id: UUID(), started: t0, source: "Not recording.", translation: "x")
        log.begin(languages: "", at: t0.addingTimeInterval(100))
        // A revision of a sentence spoken in an earlier session.
        log.record(id: UUID(), started: t0.addingTimeInterval(50), source: "Earlier.", translation: "x")
        log.record(id: UUID(), started: t0.addingTimeInterval(101), source: "Now.", translation: "y")
        log.end()
        let text = try String(contentsOf: try #require(files(dir).first), encoding: .utf8)
        #expect(text.contains("Now.") && !text.contains("Earlier.") && !text.contains("Not recording."))
    }

    @Test func finishedAndRevisedSentencesReachTheLogButSampleCaptionsDont() {
        let captions = CaptionStore()
        var seen: [String] = []
        captions.onFinishedSentenceChange = { seen.append($0.committed) }
        let id = captions.currentSentence(source: "Hello.")
        captions.updateCurrent(committed: "こん", ghost: "にちは")
        #expect(seen.isEmpty, "not until it finishes")
        captions.finishCurrent(source: "Hello.", translation: "こんにちは。")
        captions.revise(id, translation: "どうも。", changed: [0..<3])
        captions.showDemo(targetLanguage: "ja")
        #expect(seen == ["こんにちは。", "どうも。"])
    }
}

@Suite @MainActor struct SampleCaptionTests {
    private func session() -> CaptionStore {
        let captions = CaptionStore()
        captions.currentSentence(source: "First thing I said.")
        captions.finishCurrent(source: "First thing I said.", translation: "最初に言ったこと。")
        return captions
    }

    @Test func previewKeepsTheSession() {
        let captions = session()
        captions.showDemo(targetLanguage: "ja")
        #expect(captions.isDemo)
        #expect(captions.sentences.first?.committed == "本日はご参加いただきありがとうございます。", "the samples are on screen")
        // The transcript and its export still have the session.
        #expect(captions.sessionSentences.map(\.source) == ["First thing I said."])
        #expect(captions.sessionEntries.map(\.translation) == ["最初に言ったこと。"])
        // Hiding the samples brings it back, off screen like any cleared captions.
        captions.clear()
        #expect(!captions.isDemo)
        #expect(captions.sentences.map(\.source) == ["First thing I said."])
        #expect(captions.paragraph.isEmpty)
    }

    @Test func speakingAfterAPreviewCarriesOnTheSession() {
        let captions = session()
        captions.showDemo(targetLanguage: "ja")
        captions.showDemo(targetLanguage: "ja")   // shown twice: still the real session underneath
        captions.updateCurrent(committed: "x", ghost: "")   // stray update for a sentence the samples replaced
        captions.currentSentence(source: "Second.")
        captions.finishCurrent(source: "Second.", translation: "二つ目。")
        #expect(captions.sessionSentences.map(\.source) == ["First thing I said.", "Second."])
        #expect(captions.sessionEntries.map(\.translation) == ["最初に言ったこと。", "二つ目。"])
    }
}
