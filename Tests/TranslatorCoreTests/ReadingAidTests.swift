import Foundation
import Testing
@testable import TranslatorCore

// Reading aids: which languages get which aid, and Japanese furigana (readings lined up with the kanji only).

private func show(_ segments: [ReadingSegment]) -> String {
    segments.map { s in s.reading.map { "\(s.text)(\($0))" } ?? s.text }.joined()
}

@Suite struct ReadingAidTests {
    @Test func aidsBelongToTheirLanguageWhateverTheRegion() {
        #expect(ReadingAid.choices(for: "ja") == [.furigana])
        #expect(ReadingAid.choices(for: "ja-JP") == [.furigana])
        #expect(ReadingAid.choices(for: "ja_JP") == [.furigana])
        #expect(ReadingAid.choices(for: "en-US").isEmpty)
        #expect(ReadingAid.choices(for: "").isEmpty)
        #expect(ReadingAid.baseLanguage("zh-Hant-TW") == "zh")
    }

    @Test func okuriganaKeepsNoReading() {
        #expect(show(Furigana.align("取り扱い", reading: "とりあつかい")) == "取(と)り扱(あつか)い")
        #expect(show(Furigana.align("新しい", reading: "あたらしい")) == "新(あたら)しい")
        #expect(show(Furigana.align("会い", reading: "あい")) == "会(あ)い")
        #expect(show(Furigana.align("東京", reading: "とうきょう")) == "東京(とうきょう)")
    }

    @Test func katakanaAndDigitsInAWordMatchTheReading() {
        #expect(show(Furigana.align("ご参加", reading: "ごさんか")) == "ご参加(さんか)")
        #expect(show(Furigana.align("三ヶ月", reading: "さんかげつ")) == "三ヶ月(さんかげつ)")
        #expect(show(Furigana.align("3月", reading: "3がつ")) == "3月(がつ)")
        #expect(show(Furigana.align("お茶", reading: "おちゃ")) == "お茶(ちゃ)")
        #expect(show(Furigana.align("ゴミ箱", reading: "ごみばこ")) == "ゴミ箱(ばこ)")
    }

    @Test func aReadingThatDoesNotFitGoesOverTheWholeWord() {
        // The tokenizer's reading doesn't contain the word's kana: the whole word gets it rather than a wrong split.
        #expect(Furigana.align("取り扱い", reading: "あいうえ") == [ReadingSegment("取り扱い", "あいうえ")])
    }

    @Test func sentencesFromTheSystemTokenizer() {
        let text = "今日は田中さんに会います。"
        let segments = Furigana.segments(text)
        #expect(segments.map(\.text).joined() == text)
        #expect(show(segments) == "今日(きょう)は田中(たなか)さんに会(あ)います。")
        // The overlay's Japanese sample captions.
        #expect(show(Furigana.segments("本日はご参加いただきありがとうございます。"))
                == "本日(ほんじつ)はご参加(さんか)いただきありがとうございます。")
        #expect(show(Furigana.segments("私は日本語を勉強しています")).hasPrefix("私(わたし)は"))
    }

    @Test func textWithoutKanjiOrNotJapaneseIsLeftAlone() {
        for text in ["ありがとう", "カタカナ", "Hello, world.", "", "  "] {
            let segments = Furigana.segments(text)
            #expect(segments.map(\.text).joined() == text)
            #expect(segments.allSatisfy { $0.reading == nil }, "\(text)")
        }
    }

    @Test func mixedTextKeepsEverySpaceAndSymbol() {
        let text = "Appleの新しい iPhone 17 を見た！"
        let segments = ReadingAid.furigana.segments(text)
        #expect(segments.map(\.text).joined() == text)
        #expect(segments.contains(ReadingSegment("新", "あたら")))
        #expect(segments.contains(ReadingSegment("見", "み")))
    }

    @Test func latinTranscriptionsBecomeHiragana() {
        #expect(Furigana.hiragana("toukyou") == "とうきょう")
        #expect(Furigana.hiragana("okona~tsu") == "おこなっ")
    }
}
