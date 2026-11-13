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

    @Test func chineseHasPinyinZhuyinAndBothScripts() {
        #expect(ReadingAid.choices(for: "zh-Hant-TW") == [.pinyin, .zhuyin, .traditional, .simplified])
        #expect(ReadingAid.choices(for: "zh", kind: .readings) == [.pinyin, .zhuyin])
        #expect(ReadingAid.choices(for: "zh-CN", kind: .script) == [.traditional, .simplified])
        #expect(ReadingAid.choices(for: "ja", kind: .script).isEmpty)
    }

    @Test func aStoredSettingKeepsOneAidOfEachKindForItsLanguage() {
        #expect(ReadingAid.parse("pinyin,traditional", language: "zh-TW") == [.pinyin, .traditional])
        // Another language's aid, a second script and an unknown name are all skipped.
        #expect(ReadingAid.parse("furigana,simplified, pinyin,traditional,zhuyin,wadeGiles", language: "zh") == [.simplified, .pinyin])
        #expect(ReadingAid.parse("zhuyin,traditional", language: "zh-TW") == [.zhuyin, .traditional])
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

    @Test func zhuyinSpellsEachSyllableWithItsTone() {
        let cases: [(String, String)] = [
            // Tones: first unmarked, the mark after the syllable, the neutral tone's dot before it.
            ("mā", "ㄇㄚ"), ("má", "ㄇㄚˊ"), ("mǎ", "ㄇㄚˇ"), ("mà", "ㄇㄚˋ"), ("men", "˙ㄇㄣ"), ("de", "˙ㄉㄜ"),
            // zhi, chi, shi, ri, zi, ci, si: the consonant alone.
            ("zhī", "ㄓ"), ("shì", "ㄕˋ"), ("rì", "ㄖˋ"), ("sì", "ㄙˋ"),
            // y and w aren't consonants; u after j, q, x and y is ü.
            ("yī", "ㄧ"), ("yǒu", "ㄧㄡˇ"), ("yòng", "ㄩㄥˋ"), ("yuán", "ㄩㄢˊ"), ("wǒ", "ㄨㄛˇ"), ("wèi", "ㄨㄟˋ"),
            ("jú", "ㄐㄩˊ"), ("qù", "ㄑㄩˋ"), ("xué", "ㄒㄩㄝˊ"), ("nǚ", "ㄋㄩˇ"), ("lüè", "ㄌㄩㄝˋ"),
            // Finals written short in pinyin: iu = iou, ui = uei, un = uen; ong is ㄨㄥ, iong ㄩㄥ.
            ("liù", "ㄌㄧㄡˋ"), ("guì", "ㄍㄨㄟˋ"), ("dūn", "ㄉㄨㄣ"), ("dōng", "ㄉㄨㄥ"), ("jiǒng", "ㄐㄩㄥˇ"),
            ("ér", "ㄦˊ"), ("zhuāng", "ㄓㄨㄤ"),
        ]
        for (pinyin, zhuyin) in cases {
            #expect(Zhuyin.syllable(pinyin) == zhuyin, "\(pinyin)")
        }
        // No vowel (the interjections 嗯 ng, 噷 hm), or not a syllable, which the transform leaves partly in Latin
        // letters (küe → ㄎüㄜ˙, mā! → ㄇㄚ!) or with tone marks inside (bia → ㄅㄧ˙ㄚ˙): no reading.
        for nonsense in ["ng", "hm", "ê", "küe", "mā!", "bia"] {
            #expect(Zhuyin.syllable(nonsense) == nil, "\(nonsense)")
        }
    }

    @Test func zhuyinGoesUnderEachCharacter() {
        #expect(show(Zhuyin.segments("我們先快速看一下")) == "我(ㄨㄛˇ)們(˙ㄇㄣ)先(ㄒㄧㄢ)快(ㄎㄨㄞˋ)速(ㄙㄨˋ)看(ㄎㄢˋ)一(ㄧ)下(ㄒㄧㄚˋ)")
        // The overlay's sample caption, and text that isn't Chinese is left alone.
        #expect(show(ReadingAid.segments("感谢大家", aids: [.zhuyin, .traditional])) == "感(ㄍㄢˇ)謝(ㄒㄧㄝˋ)大(ㄉㄚˋ)家(ㄐㄧㄚ)")
        #expect(show(Zhuyin.segments("Apple公司, OK?")) == "Apple公(ㄍㄨㄥ)司(ㄙ), OK?")
    }

    @Test func zhuyinUsesTaiwansReadings() {
        // Where Taiwan's standard reading differs from the mainland's. macOS gives it in some words (星期 xīngqí,
        // 危险 wéixiǎn) but not in others or alone (究竟 jiūjìng, 期 qī, 储存 chǔcún); zhuyin uses it throughout.
        #expect(show(Zhuyin.segments("星期")) == "星(ㄒㄧㄥ)期(ㄑㄧˊ)")
        #expect(show(Zhuyin.segments("期")) == "期(ㄑㄧˊ)")
        #expect(show(Zhuyin.segments("究竟")).hasPrefix("究(ㄐㄧㄡˋ)"))
        #expect(show(Pinyin.segments("储存")) == "储(chǔ)存(cún)", "pinyin keeps macOS's reading")
        #expect(show(Zhuyin.segments("研究")) == "研(ㄧㄢˊ)究(ㄐㄧㄡˋ)")
        #expect(show(Zhuyin.segments("垃圾")) == "垃(ㄌㄜˋ)圾(ㄙㄜˋ)")
        #expect(show(Zhuyin.segments("危險")).hasPrefix("危(ㄨㄟˊ)"))
        #expect(show(Zhuyin.segments("企業")).hasPrefix("企(ㄑㄧˋ)"))
        // Both scripts.
        #expect(show(Zhuyin.segments("儲存")).hasPrefix("儲(ㄔㄨˊ)"))
        #expect(show(Zhuyin.segments("储存")).hasPrefix("储(ㄔㄨˊ)"))
        // 伺 is sì only in 伺服.
        #expect(show(Zhuyin.segments("伺服器")).hasPrefix("伺(ㄙˋ)服(ㄈㄨˊ)"))
        #expect(show(Zhuyin.segments("伺候")).hasPrefix("伺(ㄘˋ)"))
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
