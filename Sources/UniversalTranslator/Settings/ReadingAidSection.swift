#if os(macOS)
import SwiftUI
import TranslatorCore

/// Reading aids (furigana for Japanese; pinyin or zhuyin, and Traditional/Simplified characters, for Chinese) for the
/// languages on screen: the translation's and the original speech's. They're drawn by Core Text, which the overlay
/// uses only on the Mac.
///
/// The pickers live in General → Languages, under the languages they're for (which decide which pickers there are).
/// Overlay Appearance, where they used to be, has a note pointing there (`ReadingAidSection`): having the
/// pickers in both places was redundant.
struct ReadingAidPickers: View {
    @Bindable var store: SettingsStore

    var body: some View {
        let languages = Self.languages(store.settings)
        ForEach(languages, id: \.self) { code in
            let name = Locale.current.localizedString(forLanguageCode: code) ?? code
            let readings = ReadingAid.choices(for: code, kind: .readings)
            if !readings.isEmpty {
                Picker("\(name) readings", selection: Self.aid(store, code, .readings)) {
                    Text("Off").tag(ReadingAid?.none)
                    ForEach(readings, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
            }
            let scripts = ReadingAid.choices(for: code, kind: .script)
            if !scripts.isEmpty {
                Picker("\(name) characters", selection: Self.aid(store, code, .script)) {
                    Text("As written").tag(ReadingAid?.none)
                    ForEach(scripts, id: \.self) { Text($0.title).tag(Optional($0)) }
                }
            }
        }
        .onAppear { DebugLog.write("READING AID pickers: \(languages.joined(separator: ","))") }
    }

    /// The languages on screen that have aids, each once (a language spoken and translated to alike).
    static func languages(_ settings: AppSettings) -> [String] {
        ReadingAid.languages(offeredFor: [settings.targetLanguage, settings.sourceLocale])
    }

    /// The language's aid of one kind; setting it keeps the language's aid of the other kind.
    static func aid(_ store: SettingsStore, _ code: String, _ kind: ReadingAid.Kind) -> Binding<ReadingAid?> {
        Binding(get: { store.settings.overlay.readingAid(kind, for: code) },
                set: { store.settings.overlay.setReadingAid($0, kind, for: code) })
    }

    /// Under the pickers in General → Languages.
    static let note = "Reading aids for the captions in these languages, the original speech and the translation "
        + "alike. Readings come from macOS's dictionary and can be wrong for names and some words. Lines with readings "
        + "are taller."
}

/// Overlay Appearance → Reading aid: no pickers, just what the aids are and where they're set.
struct ReadingAidSection: View {
    var body: some View {
        Section("Reading aid") {
            Note(Self.note)
        }
        .onAppear { DebugLog.write("READING AID note in \(SettingsSection.appearance.rawValue)") }
    }

    /// Names every language with an aid, since General lists pickers only for the languages chosen there (with
    /// Japanese set it once looked as if only Japanese had an aid).
    static let note = "Reading aids exist for \(ReadingAid.summary). They're set in \(SettingsSection.general.title) → "
        + "Languages, under the languages you speak and translate to, and apply to the original speech and the "
        + "translation alike. Lines with readings are taller."
}
#endif
