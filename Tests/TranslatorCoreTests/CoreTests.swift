import Foundation
import Testing
@testable import TranslatorCore

/// Builds tokens from "word@start-end" specs, e.g. "Hello@0.0-0.3".
private func tokens(_ spec: String, final: Bool = true) -> [Token] {
    spec.split(separator: " ").enumerated().map { i, part in
        let pieces = part.split(separator: "@")
        let times = pieces[1].split(separator: "-").map { Double($0)! }
        return Token(text: (i == 0 ? "" : " ") + pieces[0], start: times[0], end: times[1], isFinal: final)
    }
}

/// Evenly spaced words starting at `start`, 0.3 s per word, no gaps.
private func words(_ text: String, start: Double = 0, final: Bool = true) -> [Token] {
    text.split(separator: " ").enumerated().map { i, w in
        let s = start + Double(i) * 0.3
        return Token(text: (i == 0 ? "" : " ") + w, start: s, end: s + 0.28, isFinal: final)
    }
}

@Suite struct SentenceBoundaryTests {
    @Test func abbreviationsDoNotEndSentences() {
        #expect(!SentenceBoundary.endsSentence("Dr."))
        #expect(!SentenceBoundary.endsSentence("e.g."))
        #expect(!SentenceBoundary.endsSentence("J."))
        #expect(SentenceBoundary.endsSentence("done."))
        #expect(SentenceBoundary.endsSentence("本当？"))
        #expect(SentenceBoundary.endsSentence("です。"))
    }

    @Test func clauseEndings() {
        #expect(SentenceBoundary.endsClause("station,"))
        #expect(SentenceBoundary.endsClause("ので、"))
        #expect(!SentenceBoundary.endsClause("station"))
    }
}

@Suite struct TranscriptTests {
    @Test func splitsRunsIntoWordsWithInterpolatedTimes() {
        let t = Tokenizer.tokens(
            from: [TimedPiece(text: "Hello world,", start: 1.0, end: 2.1), TimedPiece(text: " again", start: 2.2, end: 2.6)],
            isFinal: true, fallbackStart: 1.0, fallbackEnd: 2.6
        )
        #expect(t.map(\.text) == ["Hello", " world,", " again"])
        #expect(t[0].start == 1.0)
        #expect(abs(t[1].end - 2.1) < 1e-9)
        #expect(t[2].start == 2.2)
    }

    @Test func whitespaceRunsAttachToNextWord() {
        let t = Tokenizer.tokens(
            from: [TimedPiece(text: "Hi", start: 0, end: 0.2), TimedPiece(text: " ", start: nil, end: nil),
                   TimedPiece(text: "there", start: 0.3, end: 0.5)],
            isFinal: true, fallbackStart: 0, fallbackEnd: 0.5
        )
        #expect(t.map(\.text) == ["Hi", " there"])
    }

    @Test func volatilePrefixNeedsAgreement() {
        var buffer = TranscriptBuffer()
        buffer.applyVolatile(words("we should go", final: false))
        #expect(buffer.pending().stableCount == 0)
        buffer.applyVolatile(words("we should go to", final: false))
        #expect(buffer.pending().stableCount == 3)
        buffer.applyVolatile(words("we could go to the", final: false))
        #expect(buffer.pending().stableCount == 1)
    }

    @Test func finalReplacesCoveredVolatile() {
        var buffer = TranscriptBuffer()
        buffer.applyVolatile(words("hello there friend", final: false))
        buffer.applyFinal(words("Hello there,"), rangeEnd: 0.6)
        #expect(buffer.allTokens.map(\.trimmed) == ["Hello", "there,", "friend"])
    }

    /// Regression: a clause committed from volatile text must not swallow or repeat words once the
    /// recognizer finalizes the sentence with different punctuation.
    @Test func commitFromVolatileSurvivesFinalization() {
        var buffer = TranscriptBuffer()
        let v1 = words("today I want to walk through 3 things the launch timeline, the budget", final: false)
        buffer.applyVolatile(v1)
        buffer.applyVolatile(v1)
        let pending = buffer.pending()
        #expect(pending.stableCount == v1.count)
        buffer.markCommitted(Array(pending.tokens.prefix(11))) // "... launch timeline,"
        #expect(buffer.pending().tokens.map(\.trimmed) == ["the", "budget"])

        // More volatile text, then the final with an extra comma.
        buffer.applyVolatile(words("today I want to walk through 3 things the launch timeline, the budget, and the hiring", final: false))
        #expect(buffer.pending().tokens.map(\.trimmed) == ["the", "budget,", "and", "the", "hiring"])
        buffer.applyFinal(words("Today I want to walk through 3 things, the launch timeline, the budget, and the hiring plan."), rangeEnd: 9)
        #expect(buffer.pending().tokens.map(\.trimmed) == ["the", "budget,", "and", "the", "hiring", "plan."])
        #expect(buffer.pending().stableCount == 6)

        buffer.markCommitted(buffer.pending().tokens)
        #expect(buffer.pending().tokens.isEmpty)
        buffer.applyVolatile(words("First", start: 9, final: false))
        #expect(buffer.pending().tokens.map(\.trimmed) == ["First"])
    }

    /// Utterances translated from in-progress text get the recognizer's final wording once it arrives, even
    /// when one final result covers several of them.
    @Test func reportsFinalTextOfCommittedUtterances() {
        var buffer = TranscriptBuffer()
        let first = UUID(), second = UUID()
        buffer.applyVolatile(words("when a request comes in", final: false))
        buffer.markCommitted(buffer.pending().tokens, utterance: first)
        buffer.applyVolatile(words("when a request comes in we firstst check the cash", final: false))
        buffer.markCommitted(buffer.pending().tokens, utterance: second)
        #expect(buffer.pending().tokens.isEmpty)
        #expect(buffer.takeSettled().isEmpty)

        buffer.applyFinal(words("When a request comes in, we first check the cache."), rangeEnd: 4)
        let settled = buffer.takeSettled()
        #expect(settled.map(\.id) == [first, second])
        #expect(settled.map { $0.tokens.map(\.text).joined() } == ["When a request comes in,", " we first check the cache."])
        #expect(buffer.pending().tokens.isEmpty)
        #expect(buffer.takeSettled().isEmpty)
    }

    /// Partially finalized utterances are reported once the rest of their words are final.
    @Test func settlesAcrossSeveralFinals() {
        var buffer = TranscriptBuffer()
        let id = UUID()
        buffer.applyVolatile(words("thanks for joining the call", final: false))
        buffer.markCommitted(buffer.pending().tokens, utterance: id)
        buffer.applyFinal(words("Thanks for joining"), rangeEnd: 1)
        #expect(buffer.takeSettled().isEmpty)
        buffer.applyFinal(words("the call.", start: 1.5), rangeEnd: 2)
        let settled = buffer.takeSettled()
        #expect(settled.first?.tokens.map(\.trimmed) == ["Thanks", "for", "joining", "the", "call."])
    }

    /// Regression: a sentence committed from the final result must not reappear from a lagging volatile one.
    @Test func noDuplicateAfterFinalCommit() {
        var buffer = TranscriptBuffer()
        buffer.applyVolatile(words("any questions so", final: false))
        buffer.applyFinal(words("Any questions so far?"), rangeEnd: 2)
        buffer.markCommitted(buffer.pending().tokens)
        #expect(buffer.pending().tokens.isEmpty)
        buffer.applyVolatile([])
        #expect(buffer.pending().tokens.isEmpty)
    }

    @Test func revisedCommittedWordIsNotRepeated() {
        var buffer = TranscriptBuffer()
        let v = words("we were hoping to ship in march", final: false)
        buffer.applyVolatile(v)
        buffer.applyVolatile(v)
        buffer.markCommitted(Array(buffer.pending().tokens.prefix(7)))
        // The recognizer revises a committed word and adds more.
        buffer.applyVolatile(words("we were hoping to ship in March, but because", final: false))
        #expect(buffer.pending().tokens.map(\.trimmed) == ["but", "because"])
    }

    @Test func joinsSpacelessScriptsWithoutSpaces() {
        #expect(TextJoiner.join("こんにちは。", "元気ですか") == "こんにちは。元気ですか")
        #expect(TextJoiner.join("Hello.", "How are you?") == "Hello. How are you?")
        #expect(TextJoiner.wordCount("hello there") == 2)
        #expect(TextJoiner.wordCount("今日は晴れです") == 4)
        #expect(TextJoiner.normalizeSpacelessSpacing("です。 まず、 3月") == "です。まず、3月")
        #expect(TextJoiner.normalizeSpacelessSpacing("Mac 用の アプリ") == "Mac 用のアプリ")
    }
}

@Suite struct VADTests {
    @Test func detectsSpeechAndSilence() {
        var vad = VoiceActivityDetector()
        var t = 0.0
        for _ in 0..<50 { t += 0.02; vad.process(levelDB: -60, time: t, duration: 0.02) }
        #expect(!vad.isSpeaking)
        var started: Double?
        for _ in 0..<20 {
            t += 0.02
            if case .speechStarted(let at)? = vad.process(levelDB: -25, time: t, duration: 0.02) { started = at }
        }
        #expect(vad.isSpeaking)
        #expect(started != nil)
        var ended = false
        for _ in 0..<30 {
            t += 0.02
            if case .speechEnded? = vad.process(levelDB: -60, time: t, duration: 0.02) { ended = true }
        }
        #expect(ended)
        #expect(vad.silence(at: t) > 0.3)
    }
}

@Suite struct PromptTests {
    @Test func stripsReasoningAndQuotes() {
        #expect(Prompts.stripReasoning("<think>x</think>\n\"Hola\"") == "Hola")
        #expect(Prompts.stripReasoning("「こんにちは」") == "こんにちは")
    }

    @Test func hyMT2PromptFormats() {
        let plain = HyMT2Prompt.make(source: "Hello there", targetName: "Japanese", targetCode: "ja", context: [])
        #expect(plain.hasPrefix("<｜hy_begin▁of▁sentence｜><｜hy_User｜>Translate the following text into Japanese."))
        #expect(plain.hasSuffix("Hello there<｜hy_Assistant｜>"))
        let withContext = HyMT2Prompt.make(source: "How are you?", targetName: "German", targetCode: "de",
                                           context: [TranslationContext(source: "Good morning.", translation: "Guten Morgen.")])
        #expect(withContext.contains("[Background Information]\nGood morning."))
        #expect(withContext.hasSuffix("[Source Text]\nHow are you?<｜hy_Assistant｜>"))
        let large = HyMT2Prompt.make(source: "Hello there", targetName: "Japanese", targetCode: "ja", context: [], format: .hunyuan)
        #expect(large.hasPrefix("<|startoftext|>Translate the following text into Japanese."))
        #expect(large.hasSuffix("Hello there<|extra_0|>"))
        #expect(HyMT2Prompt.withoutBOS(large).hasPrefix("Translate"))
        let chinese = HyMT2Prompt.make(source: "Hi", targetName: "Chinese", targetCode: "zh-Hans", context: [])
        #expect(chinese.contains("将以下文本翻译为中文"))
    }

    @Test func glossaryMatchesWholeTermsOnly() {
        let entries = [GlossaryEntry(source: "Acme", target: ""), GlossaryEntry(source: "launch", target: "ローンチ"),
                       GlossaryEntry(source: "東京", target: "Tokyo")]
        #expect(Glossary.matches(entries, in: "The Acme launch is next week").map(\.source) == ["Acme", "launch"])
        #expect(Glossary.matches(entries, in: "Relaunching soon").isEmpty)
        #expect(Glossary.matches(entries, in: "東京駅で").map(\.source) == ["東京"])
        let prompt = HyMT2Prompt.make(source: "The Acme launch", targetName: "Japanese", targetCode: "ja", context: [],
                                      glossary: entries, style: "polite")
        #expect(prompt.contains("Reference the following translations:\nAcme translates to Acme\nlaunch translates to ローンチ"))
        #expect(prompt.contains("[polite]"))
    }

    @Test func formatsVTT() {
        let vtt = SubtitleExporter.vtt([SessionEntry(start: 1.5, end: 3.25, source: "Hello", translation: "Hola")], includeSource: false)
        #expect(vtt == "WEBVTT\n\n1\n00:00:01.500 --> 00:00:03.250\nHola\n")
    }

    @Test func formatsSRT() {
        let srt = SubtitleExporter.srt([SessionEntry(start: 1.5, end: 3.25, source: "Hello", translation: "Hola")], includeSource: true)
        #expect(srt == "1\n00:00:01,500 --> 00:00:03,250\nHola\nHello\n")
    }
}

@Suite struct PromptTemplateTests {
    @Test func detectsTemplatesFromModelNames() {
        #expect(PromptTemplate.detect(modelID: "qwen/qwen3-8b") == .qwen3)
        #expect(PromptTemplate.detect(modelID: "lmstudio-community/Qwen2.5-7B-Instruct-GGUF") == .chatML)
        #expect(PromptTemplate.detect(modelID: "google/gemma-3-12b") == .gemma)
        #expect(PromptTemplate.detect(modelID: "meta-llama-3.1-8b-instruct") == .llama3)
        #expect(PromptTemplate.detect(modelID: "tencent/hy-mt2-1.8b") == .hyMT2)
        #expect(PromptTemplate.detect(modelID: "some-unknown-model") == .chatAPI)
        #expect(!PromptTemplate.chatAPI.supportsPrefix)
    }

    @Test func prefillsTheAssistantTurn() {
        let prompt = PromptTemplate.qwen3.render(system: "S", user: "U", prefix: "Hola,")
        #expect(prompt.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\nHola,"))
        #expect(PromptTemplate.gemma.render(system: "S", user: "U", prefix: "").hasSuffix("<start_of_turn>model\n"))
    }
}

@Suite struct MarqueeTapeTests {
    private func tape() -> MarqueeTape<Int> { MarqueeTape(speed: 100, gap: 10) }

    @Test func newTextEntersAtTheTrailingEdgeAndScrollsAway() {
        var t = tape()
        t.update([(1, 200)], viewport: 1000)
        #expect(t.segments.first?.start == 1000)
        for _ in 0..<600 { t.advance(by: 1.0 / 60, viewport: 1000) }
        #expect(t.offset > 1000)
        for _ in 0..<1200 { t.advance(by: 1.0 / 60, viewport: 1000) }
        #expect(t.isEmpty)
        // Gone for good, even though the caption paragraph still lists it.
        t.update([(1, 200)], viewport: 1000)
        #expect(t.isEmpty)
    }

    @Test func followingTextQueuesBehindAndGrowthPushesItAlong() {
        var t = tape()
        t.update([(1, 300), (2, 100)], viewport: 1000)
        #expect(t.segments.map(\.start) == [1000, 1310])
        t.update([(1, 400), (2, 100)], viewport: 1000)
        #expect(t.segments.map(\.start) == [1000, 1410])
    }

    @Test func catchesUpWhenTextIsWaiting() {
        var t = tape()
        t.maximumSpeed = 600
        t.update([(1, 3000)], viewport: 1000)
        for _ in 0..<60 { t.advance(by: 1.0 / 60, viewport: 1000) }
        #expect(t.velocity > 300)
        #expect(t.velocity <= 600)
        // Steady speed once nothing is waiting.
        var calm = tape()
        calm.update([(1, 100)], viewport: 1000)
        for _ in 0..<600 { calm.advance(by: 1.0 / 60, viewport: 1000) }
        #expect(abs(calm.velocity - 100) < 1)
    }

    @Test func aNewSentenceTakesOverTheLiveWordsPlace() {
        var t = tape()
        let live = -1
        t.update([(1, 200), (live, 150)], viewport: 1000, transient: live)
        let liveStart = t.segments[1].start
        for _ in 0..<30 { t.advance(by: 1.0 / 60, viewport: 1000) }
        // The live words became sentence 2; new live words follow it instead of jumping to the edge.
        t.update([(1, 200), (2, 150), (live, 80)], viewport: 1000, transient: live)
        #expect(t.segments.map(\.id) == [1, 2, live])
        #expect(t.segments[1].start == liveStart)
        #expect(t.segments[2].start == t.segments[1].end + 10)
        // No live words: the transient segment goes away without blocking later ones.
        t.update([(1, 200), (2, 150)], viewport: 1000, transient: live)
        #expect(t.segments.map(\.id) == [1, 2])
        t.update([(1, 200), (2, 150), (live, 60)], viewport: 1000, transient: live)
        #expect(t.segments.last?.id == live)
    }
}
