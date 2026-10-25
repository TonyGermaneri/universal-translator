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

    @Test func chineseHasPinyinAndBothScripts() {
        #expect(ReadingAid.choices(for: "zh-Hant-TW") == [.pinyin, .traditional, .simplified])
        #expect(ReadingAid.choices(for: "zh", kind: .readings) == [.pinyin])
        #expect(ReadingAid.choices(for: "zh-CN", kind: .script) == [.traditional, .simplified])
        #expect(ReadingAid.choices(for: "ja", kind: .script).isEmpty)
    }

    @Test func aStoredSettingKeepsOneAidOfEachKindForItsLanguage() {
        #expect(ReadingAid.parse("pinyin,traditional", language: "zh-TW") == [.pinyin, .traditional])
        // Another language's aid, a second script and an unknown name are all skipped.
        #expect(ReadingAid.parse("furigana,simplified, pinyin,traditional,zhuyin", language: "zh") == [.simplified, .pinyin])
        #expect(ReadingAid.parse("furigana", language: "ja") == [.furigana])
        #expect(ReadingAid.parse("", language: "ja").isEmpty)
        #expect(ReadingAid.stored([.pinyin, .traditional]) == "pinyin,traditional")
    }

    @Test func pinyinGoesOverEachCharacterWithTheWordsReading() {
        // 行 alone is xíng; in 银行 it's háng.
        #expect(show(Pinyin.segments("我们今天去银行。")) == "我(wǒ)们(men)今(jīn)天(tiān)去(qù)银(yín)行(háng)。")
        // The overlay's Chinese sample captions.
        #expect(show(Pinyin.segments("感谢大家今天的参与。")) == "感(gǎn)谢(xiè)大(dà)家(jiā)今(jīn)天(tiān)的(de)参(cān)与(yù)。")
    }

    @Test func aWordsPinyinSplitsWhereTheCharactersSay() {
        // Both xīā|n and xī|ān are syllables; 安's own reading decides. Likewise fān|gàn vs fāng|àn.
        #expect(Pinyin.split("xīān", into: Array("西安")) == ["xī", "ān"])
        #expect(Pinyin.split("fāngàn", into: Array("方案")) == ["fāng", "àn"])
        // The tokenizer writes ü as v.
        #expect(Pinyin.split("nv̌ér", into: Array("女儿")) == ["nǚ", "ér"])
        #expect(Pinyin.split("xyz", into: Array("西安")) == nil)
    }

    @Test func traditionalTextGetsTheSameReadings() {
        // Tokenized through a Simplified copy: the tokenizer reads 參與 as one word only that way.
        #expect(show(Pinyin.segments("我們今天去銀行。")) == "我(wǒ)們(men)今(jīn)天(tiān)去(qù)銀(yín)行(háng)。")
        #expect(show(Pinyin.segments("感謝大家的參與")).hasSuffix("參(cān)與(yù)"))
    }

    @Test func pinyinLeavesEverythingElseAlone() {
        let text = "Apple公司有3个人, OK?"
        let segments = Pinyin.segments(text)
        #expect(segments.map(\.text).joined() == text)
        #expect(show(segments) == "Apple公(gōng)司(sī)有(yǒu)3个(gè)人(rén), OK?")
    }

    @Test func scriptConversionKeepsTheTextsLength() {
        #expect(ChineseScript.convert("我们的软件发展", toTraditional: true) == "我們的軟件發展")
        #expect(ChineseScript.convert("我們的軟件發展", toTraditional: false) == "我们的软件发展")
        // 僤's Simplified form is outside the main block (two UTF-16 units): it stays, so styled ranges line up.
        let rare = "我們僤們"
        #expect(ChineseScript.convert(rare, toTraditional: false).utf16.count == rare.utf16.count)
        #expect(ChineseScript.convert(rare, toTraditional: false) == "我们僤们")
        #expect(ChineseScript.convert("Hello, 日本", toTraditional: true) == "Hello, 日本")
    }

    @Test func scriptThenReadings() {
        let text = "我们去银行"
        let segments = ReadingAid.segments(text, aids: [.pinyin, .traditional])
        #expect(show(segments) == "我(wǒ)們(men)去(qù)銀(yín)行(háng)")
        #expect(segments.map(\.text).joined().utf16.count == text.utf16.count)
        #expect(ReadingAid.segments(text, aids: [.traditional]) == [ReadingSegment("我們去銀行")])
        #expect(ReadingAid.segments(text, aids: []) == [ReadingSegment(text)])
    }

    @Test func latinTranscriptionsBecomeHiragana() {
        #expect(Furigana.hiragana("toukyou") == "とうきょう")
        #expect(Furigana.hiragana("okona~tsu") == "おこなっ")
    }
}
