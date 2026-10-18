import AVFoundation
import FoundationModels
import Speech
import SwiftUI
import Translation
import TranslatorCore
import UniformTypeIdentifiers

/// Settings, as a sheet over the captions (drag it halfway down to watch appearance changes live).
struct SettingsScreen: View {
    let app: AppController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                LanguagePickers(store: app.settings)
                ListeningSettings(store: app.settings, captions: app.captions)
                Section {
                    NavigationLink {
                        TranslationSettingsView(store: app.settings).navigationTitle("Translation")
                    } label: {
                        Label("Translation", systemImage: "translate")
                    }
                    NavigationLink {
                        TimingSettingsView(store: app.settings).navigationTitle("Timing")
                    } label: {
                        Label("Timing", systemImage: "text.word.spacing")
                    }
                    NavigationLink {
                        AppearanceSettings(store: app.settings, app: app).navigationTitle("Appearance")
                    } label: {
                        Label("Appearance", systemImage: "textformat.size")
                    }
                    NavigationLink {
                        LayoutSettings(store: app.settings, app: app).navigationTitle("Captions")
                    } label: {
                        Label("Captions", systemImage: "captions.bubble")
                    }
                    NavigationLink {
                        AboutScreen(store: app.settings).navigationTitle("Permissions & About")
                    } label: {
                        Label("Permissions & About", systemImage: "lock.shield")
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Languages

/// The languages speech recognition and translation support (loaded once).
@MainActor
@Observable
final class LanguageCatalog {
    static let shared = LanguageCatalog()

    private(set) var speechLocales: [Locale] = []
    private(set) var installedSpeech: Set<String> = []
    private(set) var targets: [Locale.Language] = []
    @ObservationIgnored private var loaded = false

    func load() async {
        guard !loaded else { return }
        loaded = true
        speechLocales = await AppleRecognizer.supportedLocales
            .sorted { Self.displayName($0.identifier(.bcp47)) < Self.displayName($1.identifier(.bcp47)) }
        installedSpeech = Set(await AppleRecognizer.installedLocales.map { $0.identifier(.bcp47) })
        var seen = Set<String>()
        targets = await LanguageAvailability().supportedLanguages
            .filter { seen.insert($0.minimalIdentifier).inserted }
            .sorted { LanguageNames.name($0.minimalIdentifier) < LanguageNames.name($1.minimalIdentifier) }
    }

    static func displayName(_ id: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: id) ?? id
    }

    /// The speech locale to listen for when a translation language becomes the spoken one ("ja" → "ja-JP"):
    /// this device's region if it's supported, otherwise the language's main region.
    func speechLocale(for language: String) -> String? {
        let wanted = Locale.Language(identifier: language)
        let candidates = speechLocales.filter { locale in
            guard locale.language.languageCode == wanted.languageCode else { return false }
            guard wanted.languageCode?.identifier == "zh" else { return true }
            // Traditional Chinese is spoken in Taiwan and Hong Kong, Simplified in mainland China.
            let traditional = ["TW", "HK", "MO"].contains(locale.region?.identifier ?? "")
            return traditional == (LanguageNames.translationLanguage(fromLocale: language).minimalIdentifier == "zh-Hant")
        }
        let mainRegion = Locale.Language(identifier: wanted.maximalIdentifier).region
        let best = candidates.first { $0.region == Locale.current.region }
            ?? candidates.first { $0.region == mainRegion }
            ?? candidates.first
        return best?.identifier(.bcp47)
    }

    /// Listens for the language it was translating into, and translates into the one it was listening for.
    func swap(_ store: SettingsStore) {
        guard let source = speechLocale(for: store.settings.targetLanguage) else { return }
        let target = LanguageNames.translationLanguage(fromLocale: store.settings.sourceLocale).minimalIdentifier
        store.settings.sourceLocale = source
        store.settings.targetLanguage = target
    }
}

struct LanguagePickers: View {
    @Bindable var store: SettingsStore
    private let catalog = LanguageCatalog.shared

    var body: some View {
        Section("Languages") {
            Picker("I speak", selection: $store.settings.sourceLocale) {
                if !catalog.speechLocales.contains(where: { $0.identifier(.bcp47) == store.settings.sourceLocale }) {
                    Text(LanguageCatalog.displayName(store.settings.sourceLocale)).tag(store.settings.sourceLocale)
                }
                ForEach(catalog.speechLocales, id: \.self) { locale in
                    let id = locale.identifier(.bcp47)
                    Text(LanguageCatalog.displayName(id) + (catalog.installedSpeech.contains(id) ? "" : " (downloads on first use)")).tag(id)
                }
            }
            Picker("Translate to", selection: $store.settings.targetLanguage) {
                if !catalog.targets.contains(where: { $0.minimalIdentifier == store.settings.targetLanguage }) {
                    Text(LanguageNames.name(store.settings.targetLanguage)).tag(store.settings.targetLanguage)
                }
                ForEach(catalog.targets, id: \.minimalIdentifier) { language in
                    Text(LanguageNames.name(language.minimalIdentifier)).tag(language.minimalIdentifier)
                }
            }
        }
        .pickerStyle(.navigationLink)
        .task { await catalog.load() }
    }
}

// MARK: - Listening

struct ListeningSettings: View {
    @Bindable var store: SettingsStore
    let captions: CaptionStore
    @State private var devices: [AudioInputDevice] = []

    var body: some View {
        Section("Speech recognition") {
            Picker("Recognizer", selection: $store.settings.recognizer) {
                ForEach(SpeechRecognizerKind.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.navigationLink)
            switch store.settings.recognizer {
            case .appleSpeech:
                Note(AppleRecognizer.usesDictation
                     ? "Built in, no download: the dictation model this \(Platform.deviceName) uses for the keyboard."
                     : "Built in, no download. Its text arrives about once a second; when you pause, the last words are finalized right away.")
            case .nemotron:
                let model = LocalModel.nemotron(for: store.settings.sourceLocale)
                ModelRow(model: model, store: LocalModelStore.shared)
                if LocalModelStore.shared.state(model) != .ready {
                    Label("Apple Speech is used until the model is downloaded.", systemImage: "arrow.down.circle")
                        .foregroundStyle(.orange)
                }
                Note("NVIDIA's streaming speech model on the Neural Engine. Words arrive every 0.56 s and are never revised, so captions start sooner and change less.")
            }
        }

        Section("Microphone") {
            Picker("Microphone", selection: $store.settings.inputDeviceUID) {
                Text("Automatic").tag("")
                if !store.settings.inputDeviceUID.isEmpty, !devices.contains(where: { $0.uid == store.settings.inputDeviceUID }) {
                    Text("Not connected").tag(store.settings.inputDeviceUID)
                }
                ForEach(devices) { Text($0.name).tag($0.uid) }
            }
            SliderRow(title: "Voice detection sensitivity", value: $store.settings.micSensitivity, range: 0...1,
                      format: Fmt.percent,
                      help: "Higher picks up quieter speech; lower ignores more background noise.")
            if captions.status == .listening {
                HStack {
                    Text("Level")
                    LevelMeter(level: captions.inputLevel)
                    Image(systemName: captions.isSpeaking ? "waveform" : "waveform.slash")
                        .foregroundStyle(captions.isSpeaking ? .green : .secondary)
                        .frame(width: 20)
                }
            }
            Toggle("Start listening when the app opens", isOn: $store.settings.startListeningAtLaunch)
        }
        .task { devices = AudioDevices.inputDevices() }
    }
}

// MARK: - About

struct AboutScreen: View {
    @Bindable var store: SettingsStore
    @Environment(\.openURL) private var openURL
    @State private var micPermission = AVAudioApplication.shared.recordPermission
    @State private var importing = false
    @State private var importError: String?

    var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("Microphone") {
                    switch micPermission {
                    case .granted:
                        Text("Allowed")
                    case .undetermined:
                        Button("Allow…") {
                            Task {
                                _ = await AudioCapture.requestPermission(for: .microphone)
                                micPermission = AVAudioApplication.shared.recordPermission
                            }
                        }
                    default:
                        Button("Open Settings") { openURL(URL(string: UIApplication.openSettingsURLString)!) }
                    }
                }
                LabeledContent("On-device speech recognition",
                               value: SpeechTranscriber.isAvailable ? "Available" : (AppleRecognizer.usesDictation ? "Dictation model" : "Unavailable"))
                LabeledContent("Apple Intelligence model", value: appleIntelligence)
                LabeledContent("Memory for models", value: ByteCountFormatter.string(fromByteCount: Platform.modelMemoryBudget, countStyle: .memory))
                Note("Captions stop while the app is in the background and start again when you come back: iOS doesn't let apps in the background use the GPU the translation models run on.")
            }

            Section("Settings file") {
                ShareLink(item: SettingsFile(store: store), preview: SharePreview("Universal Translator Settings")) {
                    Label("Export settings…", systemImage: "square.and.arrow.up")
                }
                Button {
                    importing = true
                } label: {
                    Label("Import settings…", systemImage: "square.and.arrow.down")
                }
                if let importError { Note("⚠︎ \(importError)") }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Note("Speech recognition: NVIDIA Nemotron 3.5 Streaming (Core ML, via FluidAudio) or Apple SpeechAnalyzer · Voice and end of turn: Silero VAD v6, Smart Turn v3.2 · Translation: Tencent Hy-MT2 (llama.cpp or MLX), Apple Translation, Apple Intelligence, or LM Studio · Policy: target-side local agreement with a forced prefix (IWSLT 2025/2026).")
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do {
                let url = try result.get()
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                try store.importJSON(Data(contentsOf: url))
                importError = nil
            } catch {
                importError = error.localizedDescription
            }
        }
        .onAppear { micPermission = AVAudioApplication.shared.recordPermission }
    }

    private var appleIntelligence: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "Available"
        case .unavailable(let reason): return "Unavailable (\(reason))"
        }
    }
}

/// The settings as a JSON file, for the share sheet.
struct SettingsFile: Transferable {
    let data: Data

    @MainActor init(store: SettingsStore) {
        data = (try? store.exportJSON()) ?? Data()
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .json) { file in
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Universal Translator Settings.json")
            try file.data.write(to: url)
            return SentTransferredFile(url)
        }
    }
}
