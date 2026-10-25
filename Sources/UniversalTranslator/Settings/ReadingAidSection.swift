#if os(macOS)
import SwiftUI
import TranslatorCore

/// Reading aids (furigana for Japanese; pinyin and Traditional/Simplified characters for Chinese) for the languages
/// on screen: the translation's and the original speech's. They're drawn by Core Text, which the overlay uses only on
/// the Mac.
struct ReadingAidSection: View {
    @Bindable var store: SettingsStore

    var body: some View {
        let languages = ReadingAid.languages(offeredFor: [store.settings.targetLanguage, store.settings.sourceLocale])
        Section("Reading aid") {
            ForEach(languages, id: \.self) { code in
                let name = Locale.current.localizedString(forLanguageCode: code) ?? code
                let readings = ReadingAid.choices(for: code, kind: .readings)
                if !readings.isEmpty {
                    Picker("\(name) readings", selection: aid(code, .readings)) {
                        Text("Off").tag(ReadingAid?.none)
                        ForEach(readings, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                }
                let scripts = ReadingAid.choices(for: code, kind: .script)
                if !scripts.isEmpty {
                    Picker("\(name) characters", selection: aid(code, .script)) {
                        Text("As written").tag(ReadingAid?.none)
                        ForEach(scripts, id: \.self) { Text($0.title).tag(Optional($0)) }
                    }
                }
            }
            Note(languages.isEmpty
                 ? "Reading aids are offered for Japanese (furigana) and Chinese (pinyin, Traditional or Simplified characters) captions, in the translation or the original speech."
                 : "Readings come from macOS's dictionary and can be wrong for names and some words. Lines with readings are taller.")
        }
    }

    /// The language's aid of one kind; setting it keeps the language's aid of the other kind.
    private func aid(_ code: String, _ kind: ReadingAid.Kind) -> Binding<ReadingAid?> {
        Binding(get: { store.settings.overlay.readingAids(for: code).first { $0.kind == kind } },
                set: { new in
                    let others = store.settings.overlay.readingAids(for: code).filter { $0.kind != kind }
                    let aids = (new.map { [$0] } ?? []) + others
                    store.settings.overlay.readingAids[code] = aids.isEmpty ? nil : ReadingAid.stored(aids)
                })
    }
}
#endif
