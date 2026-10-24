#if os(macOS)
import SwiftUI
import TranslatorCore

/// Reading aids (furigana for Japanese, …) for the languages on screen: the translation's and the original
/// speech's. Readings are drawn by Core Text, which the overlay uses only on the Mac.
struct ReadingAidSection: View {
    @Bindable var store: SettingsStore

    var body: some View {
        let languages = ReadingAid.languages(offeredFor: [store.settings.targetLanguage, store.settings.sourceLocale])
        Section("Reading aid") {
            ForEach(languages, id: \.self) { code in
                Picker("\(Locale.current.localizedString(forLanguageCode: code) ?? code) captions", selection: aid(code)) {
                    Text("Off").tag("")
                    ForEach(ReadingAid.choices(for: code), id: \.self) { Text($0.title).tag($0.rawValue) }
                }
            }
            Note(languages.isEmpty
                 ? "Reading aids are offered for Japanese captions (furigana), in the translation or the original speech."
                 : "Readings come from macOS's dictionary and can be wrong for names and some words. Lines with readings are taller.")
        }
    }

    private func aid(_ code: String) -> Binding<String> {
        Binding(get: { store.settings.overlay.readingAids[code] ?? "" },
                set: { store.settings.overlay.readingAids[code] = $0.isEmpty ? nil : $0 })
    }
}
#endif
