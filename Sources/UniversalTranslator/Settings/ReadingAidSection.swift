#if os(macOS)
import SwiftUI
import TranslatorCore

/// Reading aids (furigana for Japanese; pinyin and Traditional/Simplified characters for Chinese) for the languages
/// on screen: the translation's and the original speech's. They're drawn by Core Text, which the overlay uses only on
/// the Mac.
///
/// The pickers show in two places, General → Languages (beside the languages they're for) and Overlay Appearance →
/// Reading aid (beside the caption text), and both edit the one setting, `overlay.readingAids`.
struct ReadingAidPickers: View {
    @Bindable var store: SettingsStore
    /// The Settings page showing them, for the test log.
    let place: SettingsSection

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
        .onAppear { DebugLog.write("READING AID pickers in \(place.rawValue): \(languages.joined(separator: ","))") }
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
    static let generalNote = "Readings or other characters for the captions in these languages. The same choices "
        + "are in \(SettingsSection.appearance.title) → Reading aid."
}

/// Overlay Appearance → Reading aid: the pickers, with what the aids are and what they do to the captions.
struct ReadingAidSection: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Section("Reading aid") {
            ReadingAidPickers(store: store, place: .appearance)
            Note(Self.note(anyOnScreen: !ReadingAidPickers.languages(store.settings).isEmpty))
        }
    }

    /// Says which languages have aids at all: only those of the languages on screen are listed above, which looked
    /// like the app supporting just one.
    static func note(anyOnScreen: Bool) -> String {
        let available = "Reading aids exist for \(ReadingAid.summary). Only the languages you speak and translate to "
            + "are listed here, for the original speech and the translation alike; the same choices are under "
            + "\(SettingsSection.general.title) → Languages."
        return anyOnScreen
            ? available + " Readings come from macOS's dictionary and can be wrong for names and some words. Lines with readings are taller."
            : available
    }
}
#endif
