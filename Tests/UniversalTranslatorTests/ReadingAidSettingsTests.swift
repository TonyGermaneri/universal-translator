import AppKit
import CoreText
import Testing
import TranslatorCore
@testable import UniversalTranslator

// Reading aids in the app: which caption lines get one, how the setting loads, and readings drawn under the text.

@Suite struct ReadingAidSettingsTests {
    @Test func anAidAppliesToEveryLineInItsLanguage() {
        var o = OverlaySettings()
        #expect(o.readingAids(for: "ja").isEmpty, "off by default")
        o.readingAids["ja"] = "furigana"
        // The translation ("ja") and the original speech ("ja-JP") alike.
        #expect(o.readingAids(for: "ja") == [.furigana])
        #expect(o.readingAids(for: "ja-JP") == [.furigana])
        #expect(o.readingAids(for: "en-US").isEmpty)
    }

    @Test func anAidStoredUnderTheWrongLanguageOrUnknownIsIgnored() {
        var o = OverlaySettings()
        o.readingAids = ["en": "furigana", "ja": "someFutureAid"]
        #expect(o.readingAids(for: "en").isEmpty)
        #expect(o.readingAids(for: "ja").isEmpty)
    }

    @Test @MainActor func settingsNamingAnUnknownAidStillLoad() throws {
        // A newer build's aid (or a typo) mustn't reset everything else to the defaults.
        let data = Data(#"{"targetLanguage":"fr","overlay":{"fontSize":50,"readingAids":{"ja":"pinyinOrWhatever"}}}"#.utf8)
        let loaded = try SettingsStore.decodeMergingDefaults(data)
        #expect(loaded.targetLanguage == "fr" && loaded.overlay.fontSize == 50)
        #expect(loaded.overlay.readingAids(for: "ja").isEmpty)
    }

    @Test func theNoteNamesEveryLanguageWithAnAidAndWhyOnlySomeAreListed() {
        // Only the languages on screen get a picker, so with Japanese set the Chinese aids were invisible.
        for onScreen in [true, false] {
            let note = ReadingAidSection.note(anyOnScreen: onScreen)
            for aid in ReadingAid.allCases {
                #expect(note.contains(aid.name), "\(aid) missing from: \(note)")
            }
            #expect(note.contains("Japanese") && note.contains("Chinese"))
            #expect(note.contains("General → Languages"))
        }
        #expect(ReadingAid.summary == "Japanese (furigana); Chinese (pinyin, zhuyin, Traditional characters, Simplified characters)")
    }

    @Test @MainActor func bothPlacesEditTheOneSetting() throws {
        // General → Languages and Overlay Appearance → Reading aid each make their own pickers from the same store.
        let suite = "ut.tier1.reading-aid-both"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(defaults: defaults)
        store.settings.sourceLocale = "zh-TW"
        store.settings.targetLanguage = "en"
        #expect(ReadingAidPickers.languages(store.settings) == ["zh"])
        let general = (readings: ReadingAidPickers.aid(store, "zh", .readings), script: ReadingAidPickers.aid(store, "zh", .script))
        let overlay = (readings: ReadingAidPickers.aid(store, "zh", .readings), script: ReadingAidPickers.aid(store, "zh", .script))
        general.readings.wrappedValue = .pinyin
        #expect(overlay.readings.wrappedValue == .pinyin, "a change in General didn't show in Overlay Appearance")
        overlay.script.wrappedValue = .traditional
        #expect(general.script.wrappedValue == .traditional, "a change in Overlay Appearance didn't show in General")
        #expect(general.readings.wrappedValue == .pinyin, "setting the characters dropped the readings")
        // The captions read the same setting, for the speech's locale.
        #expect(Set(store.settings.overlay.readingAids(for: "zh-TW")) == [.pinyin, .traditional])
        general.readings.wrappedValue = nil
        #expect(overlay.readings.wrappedValue == nil && overlay.script.wrappedValue == .traditional)
        overlay.script.wrappedValue = nil
        #expect(store.settings.overlay.readingAids["zh"] == nil, "all off leaves nothing stored")
        // Japanese spoken and translated to: one set of pickers.
        store.settings.sourceLocale = "ja-JP"
        store.settings.targetLanguage = "ja"
        #expect(ReadingAidPickers.languages(store.settings) == ["ja"])
    }

    @Test func anAidSetForALocaleIsStoredUnderItsLanguage() {
        var o = OverlaySettings()
        o.setReadingAid(.pinyin, .readings, for: "zh-TW")
        #expect(o.readingAids == ["zh": "pinyin"])
        #expect(o.readingAid(.readings, for: "zh-CN") == .pinyin)
        #expect(o.readingAid(.script, for: "zh-CN") == nil)
    }

    @Test func theGeneralNoteNamesTheOtherPlace() {
        #expect(ReadingAidPickers.generalNote.contains("Overlay Appearance → Reading aid"))
    }

    @Test func settingsOfferAidsForTheLanguagesOnScreen() {
        #expect(ReadingAid.languages(offeredFor: ["ja", "en-US"]) == ["ja"])
        #expect(ReadingAid.languages(offeredFor: ["en", "ja-JP"]) == ["ja"])
        #expect(ReadingAid.languages(offeredFor: ["ja", "ja-JP"]) == ["ja"])
        #expect(ReadingAid.languages(offeredFor: ["fr", "en-US"]).isEmpty)
    }

    @Test func chineseCanHaveReadingsAndAScriptTogether() {
        var o = OverlaySettings()
        o.readingAids["zh"] = "pinyin,traditional"
        #expect(o.readingAids(for: "zh-Hans") == [.pinyin, .traditional])
        #expect(o.readingAids(for: "zh-TW") == [.pinyin, .traditional])
        #expect(o.readingAids(for: "ja").isEmpty)
    }

    @Test @MainActor func anotherScriptKeepsEachRunsStyle() {
        // Fade-in and revision highlights color runs of characters: converting must keep them where they were.
        let red = NSColor.red, blue = NSColor.blue
        let text = NSMutableAttributedString(string: "我们", attributes: [.foregroundColor: red])
        text.append(NSAttributedString(string: "软件", attributes: [.foregroundColor: blue]))
        let shown = Ruby.annotated(text, aids: [.traditional])
        #expect(shown.string == "我們軟件")
        #expect(shown.attribute(.foregroundColor, at: 1, effectiveRange: nil) as? NSColor == red)
        #expect(shown.attribute(.foregroundColor, at: 2, effectiveRange: nil) as? NSColor == blue)
        #expect(shown.attribute(.ctRuby, at: 0, effectiveRange: nil) == nil, "a script aid alone adds no readings")
    }

    @Test @MainActor func pinyinSyllablesKeepApart() {
        let text = NSAttributedString(string: "我们先", attributes: [.font: NSFont.systemFont(ofSize: 30)])
        let shown = Ruby.annotated(text, aids: [.pinyin])
        let ruby = shown.attribute(.ctRuby, at: 1, effectiveRange: nil) as! CTRubyAnnotation
        #expect(CTRubyAnnotationGetTextForPosition(ruby, .after) as String? == "\u{2009}men\u{2009}")
        // Zhuyin, with no word shapes, gets more room: thin spaces left ㄐㄧㄚㄐㄧㄣ reading as one run.
        #expect(Ruby.spaced("ㄇㄣ", aids: [.zhuyin, .traditional]) == "\u{2002}ㄇㄣ\u{2002}")
        // Furigana sits over whole words and keeps its spacing.
        #expect(Ruby.spaced("きょう", aids: [.furigana]) == "きょう")
    }

    @Test func sampleCaptionsSpeakJapaneseOrChineseWhenThatIsTheSpeechLanguage() {
        // So Preview shows the original-speech line's reading aid too.
        #expect(DemoText.sample(for: "en", from: "ja-JP").source1.contains("本日"))
        #expect(DemoText.sample(for: "en", from: "en-US").source1.hasPrefix("Thanks"))
        #expect(DemoText.sample(for: "ja", from: "ja-JP").target1.contains("本日"))
        #expect(DemoText.sample(for: "en", from: "zh-CN").source1 == "感谢大家今天的参与。")
        #expect(DemoText.sample(for: "en", from: "zh-CN").source2 == "我们先快速看一下")
    }

    @Test @MainActor func readingsGoUnderTheKanjiOnly() throws {
        let color = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)
        let text = NSAttributedString(string: "今日は田中さんに会います", attributes: [
            .font: NSFont.systemFont(ofSize: 30), .foregroundColor: color,
        ])
        let annotated = Ruby.annotated(text, aids: [.furigana])
        var found: [String: String] = [:]
        annotated.enumerateAttribute(.ctRuby, in: NSRange(location: 0, length: annotated.length)) { value, range, _ in
            guard let value else { return }
            let ruby = value as! CTRubyAnnotation
            let base = (annotated.string as NSString).substring(with: range)
            // Below the text (Core Text's "after" side), nothing above.
            #expect(CTRubyAnnotationGetTextForPosition(ruby, .before) == nil, "\(base)")
            found[base] = CTRubyAnnotationGetTextForPosition(ruby, .after) as String?
        }
        #expect(found == ["今日": "きょう", "田中": "たなか", "会": "あ"])
        // Lines with readings are taller, by about the readings' size.
        let extra = Ruby.extraHeight(font: .systemFont(ofSize: 30))
        #expect(extra >= 30 * Ruby.sizeFactor * 0.8 && extra <= 30 * Ruby.sizeFactor * 2, "\(extra)")
        #expect(Ruby.size(of: annotated, width: nil).height >= Ruby.size(of: text, width: nil).height + extra - 1)
    }
}
