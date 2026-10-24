import AppKit
import CoreText
import Testing
import TranslatorCore
@testable import UniversalTranslator

// Reading aids in the app: which caption lines get one, how the setting loads, and readings drawn under the text.

@Suite struct ReadingAidSettingsTests {
    @Test func anAidAppliesToEveryLineInItsLanguage() {
        var o = OverlaySettings()
        #expect(o.readingAid(for: "ja") == nil, "off by default")
        o.readingAids["ja"] = "furigana"
        // The translation ("ja") and the original speech ("ja-JP") alike.
        #expect(o.readingAid(for: "ja") == .furigana)
        #expect(o.readingAid(for: "ja-JP") == .furigana)
        #expect(o.readingAid(for: "en-US") == nil)
    }

    @Test func anAidStoredUnderTheWrongLanguageOrUnknownIsIgnored() {
        var o = OverlaySettings()
        o.readingAids = ["en": "furigana", "ja": "someFutureAid"]
        #expect(o.readingAid(for: "en") == nil)
        #expect(o.readingAid(for: "ja") == nil)
    }

    @Test @MainActor func settingsNamingAnUnknownAidStillLoad() throws {
        // A newer build's aid (or a typo) mustn't reset everything else to the defaults.
        let data = Data(#"{"targetLanguage":"fr","overlay":{"fontSize":50,"readingAids":{"ja":"pinyinOrWhatever"}}}"#.utf8)
        let loaded = try SettingsStore.decodeMergingDefaults(data)
        #expect(loaded.targetLanguage == "fr" && loaded.overlay.fontSize == 50)
        #expect(loaded.overlay.readingAid(for: "ja") == nil)
    }

    @Test func settingsOfferAidsForTheLanguagesOnScreen() {
        #expect(ReadingAid.languages(offeredFor: ["ja", "en-US"]) == ["ja"])
        #expect(ReadingAid.languages(offeredFor: ["en", "ja-JP"]) == ["ja"])
        #expect(ReadingAid.languages(offeredFor: ["ja", "ja-JP"]) == ["ja"])
        #expect(ReadingAid.languages(offeredFor: ["fr", "en-US"]).isEmpty)
    }

    @Test func sampleCaptionsSpeakJapaneseWhenThatIsTheSpeechLanguage() {
        // So Preview shows the original-speech line's reading aid too.
        #expect(DemoText.sample(for: "en", from: "ja-JP").source1.contains("本日"))
        #expect(DemoText.sample(for: "en", from: "en-US").source1.hasPrefix("Thanks"))
        #expect(DemoText.sample(for: "ja", from: "ja-JP").target1.contains("本日"))
    }

    @Test @MainActor func readingsGoUnderTheKanjiOnly() throws {
        let color = NSColor(srgbRed: 1, green: 0.5, blue: 0, alpha: 1)
        let text = NSAttributedString(string: "今日は田中さんに会います", attributes: [
            .font: NSFont.systemFont(ofSize: 30), .foregroundColor: color,
        ])
        let annotated = Ruby.annotated(text, aid: .furigana)
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
