import SwiftUI
import TranslatorCore

struct TimingSettingsView: View {
    @Bindable var store: SettingsStore

    private var profile: LanguageProfile {
        LanguageProfile.forTarget(store.settings.targetLanguage).tuned(stability: store.settings.timing.stability)
    }

    var body: some View {
        Form {
            Section {
                Note("Your speech is re-translated continuously while you talk. A word becomes final only once consecutive translations agree on it, so the translation never has to take back committed text, and languages that put the verb last (Japanese, Korean, German) naturally wait for it. Provisional words are shown dimmed until they settle. A thought is finished, and translated in full, when you pause at the end of it.")
            }

            Section("Responsive ↔ Stable") {
                VStack(alignment: .leading, spacing: 6) {
                    Slider(value: $store.settings.timing.stability, in: 0...1) {
                        EmptyView()
                    } minimumValueLabel: {
                        Text("Responsive")
                    } maximumValueLabel: {
                        Text("Stable")
                    }
                    Note(profileSummary)
                }
            }

            Section {
                Toggle("Neural voice detection (Silero VAD)", isOn: $store.settings.timing.neuralVAD)
                Toggle("Hear when a thought is finished (Smart Turn)", isOn: $store.settings.timing.smartTurn)
                if store.settings.timing.smartTurn {
                    SliderRow(title: "Longest pause within a thought", value: $store.settings.timing.maxTurnPause, range: 0.6...3,
                              format: Fmt.seconds,
                              help: "Smart Turn listens to your intonation at every pause and finishes the thought as soon as it sounds complete (usually about 0.2 s after you stop). When it sounds unfinished (\"it's supposed to be… really nice\"), it waits up to this long.")
                } else {
                    SliderRow(title: "End of thought", value: $store.settings.timing.endOfThoughtPause, range: 0.3...2,
                              format: Fmt.seconds,
                              help: "Silence this long finishes the sentence and translates it in full.")
                }
                ForEach(LocalModel.speechModels) { model in
                    ModelRow(model: model, store: LocalModelStore.shared)
                }
                Note("Both models are small (18 MB together), take a few milliseconds per check, and are downloaded automatically the first time you start listening. Without them, a level-based detector and a fixed pause are used.")
            } header: {
                Text("End of thought")
            }

            Section("Words") {
                SliderRow(title: "Word settling time", value: $store.settings.timing.holdBack, range: 0...1,
                          format: Fmt.seconds,
                          help: "Newly recognized words are often revised; they're translated once they've survived this long.")
                Stepper("Longest sentence: \(store.settings.timing.maxSentenceWords) words",
                        value: $store.settings.timing.maxSentenceWords, in: 15...80, step: 5)
            }
        }
    }

    private var profileSummary: String {
        let p = profile
        let unit = p.unit == .character ? "characters" : "words"
        return String(format: "For %@: if nothing has settled for %.1f s, the most stable part is committed anyway; the last %d provisional %@ are hidden until they settle.",
                      LanguageNames.name(store.settings.targetLanguage), p.maxDelay, p.maskK, unit)
    }
}
