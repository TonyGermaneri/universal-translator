import Foundation
import Testing
import TranslatorCore
@testable import UniversalTranslator

// How a Nemotron turn ends. Completing the chunk with silence cost a Japanese turn its first word (三月の出荷 → の出荷);
// waiting for the real audio instead means the turn's text can run into the next one, so its words carry the times
// the model gives them, and the pipeline splits where the speaker paused.

@Suite struct NemotronTurnTests {
    @Test func onlyJapaneseWaitsForTheRealAudio() {
        #expect(NemotronRecognizer.defersTurnEnds("ja-JP") && NemotronRecognizer.defersTurnEnds("ja"))
        for locale in ["en-US", "zh-CN", "zh-TW", "ko-KR", "de-DE"] {
            #expect(!NemotronRecognizer.defersTurnEnds(locale), "\(locale)")
        }
    }

    /// Tokens as Nemotron gave them for "…どこですか。 歩いて": the previous turn's "。", two space pieces the decoder
    /// merges into one, a character spelled as UTF-8 bytes, then the next turn's first word.
    @Test func wordsGetTheTimesTheirCharactersWereSpoken() throws {
        let tokens: [(text: String, start: Double)] = [("。", 2.32), ("▁", 2.32), ("▁", 2.64), ("一", 2.64), ("番", 2.80),
                                                       ("<0xE8>", 2.96), ("<0xBF>", 2.96), ("<0x91>", 2.96), ("い", 3.12),
                                                       ("駅", 3.28), ("は", 3.44), ("ま", 5.20), ("ず", 5.28)]
        let raw = "。 一番近い駅はまず"
        let pieces = try #require(NemotronRecognizer.timedPieces(tokens: tokens, raw: raw, text: "一番近い駅はまず",
                                                                 locale: "ja-JP"))
        #expect(pieces.map(\.text).joined() == "一番近い駅はまず")
        let words = Dictionary(pieces.map { ($0.text, $0) }, uniquingKeysWith: { a, _ in a })
        #expect(words["近い"]?.start == 2.96)                       // the byte-spelled 近
        #expect(words["まず"]?.start == 5.20 && abs((words["まず"]?.end ?? 0) - 5.36) < 1e-9)
        #expect(pieces.first?.start == 2.64)
    }

    @Test func tokensThatDontSpellTheTextGiveNoTimes() {
        let tokens: [(text: String, start: Double)] = [("今", 0.1), ("日", 0.2)]
        #expect(NemotronRecognizer.timedPieces(tokens: tokens, raw: "今日は", text: "今日は", locale: "ja-JP") == nil)
        #expect(NemotronRecognizer.timedPieces(tokens: tokens, raw: "明日", text: "明日", locale: "ja-JP") == nil)
    }

    /// With those times the pipeline's split (halfway between the end of speech and where it resumed) keeps
    /// "まず" for the next utterance, where the guessed even spread put it in the earlier one.
    @Test func theNextTurnsWordsStayForTheNextUtterance() throws {
        let tokens: [(text: String, start: Double)] = [("一", 2.64), ("番", 2.80), ("近", 2.96), ("い", 3.12),
                                                       ("駅", 3.28), ("は", 3.44), ("ま", 4.20), ("ず", 4.28)]
        let pieces = try #require(NemotronRecognizer.timedPieces(tokens: tokens, raw: "一番近い駅はまず",
                                                                 text: "一番近い駅はまず", locale: "ja-JP"))
        let final = Tokenizer.tokens(from: pieces, isFinal: true, fallbackStart: 2.5, fallbackEnd: 4.6, locale: "ja-JP")
        var frontier = SourceFrontier(holdBack: 0)
        // Speech ended at 3.6 s and resumed at 4.1 s.
        let s = frontier.currentSentence(pending: final, stableCount: final.count, utteranceEnd: .finalsBefore(3.85),
                                         now: 5)
        #expect(s.isComplete && s.text == "一番近い駅は")
        let guessed = Tokenizer.tokens(from: [TimedPiece(text: "一番近い駅はまず", start: nil, end: nil)], isFinal: true,
                                       fallbackStart: 2.5, fallbackEnd: 4.6, locale: "ja-JP")
        var old = SourceFrontier(holdBack: 0)
        #expect(old.currentSentence(pending: guessed, stableCount: guessed.count, utteranceEnd: .finalsBefore(3.85),
                                    now: 5).text != "一番近い駅は")
    }
}

/// Chinese read in Traditional characters: Nemotron's zh-TW prompt wrote nothing but `<unk>` (CER 490 % on Taiwanese
/// speech, 2026-10-25), so it's recognized with the zh-CN prompt and shown converted.
@Suite struct NemotronLanguageTests {
    @Test func traditionalChineseIsRecognizedAsMandarin() {
        for locale in ["zh-TW", "zh-HK", "zh-MO", "zh-Hant-TW", "zh-Hant"] {
            #expect(NemotronRecognizer.modelLanguage(locale) == "zh-CN", "\(locale)")
            #expect(NemotronRecognizer.writesTraditional(locale), "\(locale)")
        }
        for (locale, prompt) in [("zh-CN", "zh-CN"), ("ja-JP", "ja-JP"), ("ko-KR", "ko-KR"), ("en-US", "en-US")] {
            #expect(NemotronRecognizer.modelLanguage(locale) == prompt)
            #expect(!NemotronRecognizer.writesTraditional(locale), "\(locale)")
        }
        #expect(!NemotronRecognizer.writesTraditional("zh-Hans-HK"))
    }

    @Test func recognizedTextIsShownInTraditionalCharacters() {
        #expect(NemotronRecognizer.presented("感谢各位参加这次电话会议", traditional: true) == "感謝各位參加這次電話會議")
        #expect(NemotronRecognizer.presented("感谢各位", traditional: false) == "感谢各位")
        #expect(NemotronRecognizer.presented("Mac 用", traditional: true) == "Mac 用")
    }
}
