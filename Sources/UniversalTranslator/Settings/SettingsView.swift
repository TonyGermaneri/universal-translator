import ServiceManagement
import Speech
import SwiftUI
import Translation
import TranslatorCore

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, timing, translation, appearance, layout, shortcuts, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        case .timing: return "Timing"
        case .translation: return "Translation"
        case .appearance: return "Overlay Appearance"
        case .layout: return "Overlay Layout & Behavior"
        case .shortcuts: return "Shortcuts"
        case .about: return "Permissions & About"
        }
    }
    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .timing: return "text.word.spacing"
        case .translation: return "translate"
        case .appearance: return "textformat.size"
        case .layout: return "rectangle.inset.bottomleft.filled"
        case .shortcuts: return "command"
        case .about: return "lock.shield"
        }
    }
}

struct SettingsView: View {
    let app: AppController
    @State private var section: SettingsSection =
        SettingsSection(rawValue: ProcessInfo.processInfo.environment["UT_SETTINGS_SECTION"] ?? "") ?? .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $section) { item in
                Label(item.title, systemImage: item.symbol).tag(item)
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .safeAreaInset(edge: .bottom) { ListenButton(app: app).padding(12) }
        } detail: {
            Group {
                switch section {
                case .general: GeneralSettings(store: app.settings, captions: app.captions)
                case .timing: TimingSettingsView(store: app.settings)
                case .translation: TranslationSettingsView(store: app.settings)
                case .appearance: AppearanceSettings(store: app.settings, app: app)
                case .layout: LayoutSettings(store: app.settings, app: app)
                case .shortcuts: ShortcutSettings(store: app.settings)
                case .about: AboutSettings(store: app.settings)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(section.title)
        }
    }
}

/// Start/stop button with live status, pinned under the sidebar.
struct ListenButton: View {
    let app: AppController

    var body: some View {
        let captions = app.captions
        VStack(alignment: .leading, spacing: 6) {
            Button {
                app.controller.toggle()
            } label: {
                Label(captions.status == .idle || isError ? "Start Listening" : "Stop Listening",
                      systemImage: captions.status == .idle || isError ? "mic.fill" : "stop.fill")
                    .frame(maxWidth: .infinity)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
            .tint(captions.status == .idle || isError ? .accentColor : .red)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(isError ? .red : .secondary)
                .lineLimit(3)
        }
    }

    private var isError: Bool {
        if case .error = app.captions.status { return true }
        return false
    }

    private var statusText: String {
        switch app.captions.status {
        case .idle: return "Not listening"
        case .preparing(let m): return m
        case .listening: return app.captions.isSpeaking ? "Hearing speech…" : "Listening"
        case .paused: return "Paused"
        case .error(let m): return m
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @Bindable var store: SettingsStore
    let captions: CaptionStore
    @State private var speechLocales: [Locale] = []
    @State private var installedSpeech: Set<String> = []
    @State private var targets: [Locale.Language] = []
    @State private var devices: [AudioInputDevice] = []
    @State private var apps: [AudioApp] = []
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private var appSelection: Binding<String> {
        Binding {
            store.settings.sourceAppBundleID
        } set: { id in
            store.settings.sourceAppBundleID = id
            store.settings.sourceAppName = apps.first { $0.bundleID == id }?.name ?? ""
        }
    }

    var body: some View {
        Form {
            Section {
                Note("Recognizes your speech on your Mac and translates it while you're still talking. Nothing leaves your Mac unless you pick a translator on another machine.")
            }

            Section("Languages") {
                Picker("I speak", selection: $store.settings.sourceLocale) {
                    if !speechLocales.contains(where: { $0.identifier(.bcp47) == store.settings.sourceLocale }) {
                        Text(displayName(store.settings.sourceLocale)).tag(store.settings.sourceLocale)
                    }
                    ForEach(speechLocales, id: \.self) { locale in
                        let id = locale.identifier(.bcp47)
                        Text(displayName(id) + (installedSpeech.contains(id) ? "" : "  (downloads on first use)")).tag(id)
                    }
                }
                Picker("Translate to", selection: $store.settings.targetLanguage) {
                    if !targets.contains(where: { $0.minimalIdentifier == store.settings.targetLanguage }) {
                        Text(LanguageNames.name(store.settings.targetLanguage)).tag(store.settings.targetLanguage)
                    }
                    ForEach(targets, id: \.minimalIdentifier) { lang in
                        Text(LanguageNames.name(lang.minimalIdentifier)).tag(lang.minimalIdentifier)
                    }
                }
            }

            Section("Speech recognition") {
                Picker("Recognizer", selection: $store.settings.recognizer) {
                    ForEach(SpeechRecognizerKind.allCases) { Text($0.title).tag($0) }
                }
                switch store.settings.recognizer {
                case .appleSpeech:
                    Note("Built into macOS, no download. Its text arrives about once a second; when you pause, the last words are finalized right away.")
                case .nemotron:
                    let model = LocalModel.nemotron(for: store.settings.sourceLocale)
                    ModelRow(model: model, store: LocalModelStore.shared)
                    if LocalModelStore.shared.state(model) != .ready {
                        Label("Apple Speech is used until the model is downloaded.", systemImage: "arrow.down.circle")
                            .foregroundStyle(.orange)
                    }
                    Note("NVIDIA's streaming speech model on the Neural Engine. Words arrive every 0.56 s and are never revised, so captions start sooner and change less, and it was the most accurate in our tests.")
                }
            }

            Section("Listen to") {
                Picker("Source", selection: $store.settings.audioSource) {
                    ForEach(AudioSource.allCases) { Text($0.title).tag($0) }
                }
                switch store.settings.audioSource {
                case .microphone:
                    Picker("Microphone", selection: $store.settings.inputDeviceUID) {
                        Text("System default").tag("")
                        ForEach(devices) { Text($0.name).tag($0.uid) }
                    }
                case .systemAudio:
                    Note("Captions whatever your Mac is playing: a video call, a video, a podcast. The audio keeps playing normally. macOS asks once for permission to record system audio.")
                case .app:
                    HStack {
                        Picker("App", selection: appSelection) {
                            if store.settings.sourceAppBundleID.isEmpty { Text("Choose…").tag("") }
                            if !store.settings.sourceAppBundleID.isEmpty, !apps.contains(where: { $0.bundleID == store.settings.sourceAppBundleID }) {
                                Text(store.settings.sourceAppName.isEmpty ? store.settings.sourceAppBundleID : store.settings.sourceAppName)
                                    .tag(store.settings.sourceAppBundleID)
                            }
                            ForEach(apps) { app in
                                Text(app.isPlaying ? "\(app.name)  ♪" : app.name).tag(app.bundleID)
                            }
                        }
                        Button {
                            apps = AudioProcesses.apps()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .help("Refresh the list of apps")
                    }
                    Note("Captions one app (for example Zoom, FaceTime or a browser), including its helper processes. ♪ marks apps playing audio now. macOS asks once for permission to record system audio.")
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
            }

            Section("Startup") {
                Toggle("Start listening when the app launches", isOn: $store.settings.startListeningAtLaunch)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
            }
        }
        .task {
            devices = AudioDevices.inputDevices()
            apps = AudioProcesses.apps()
            speechLocales = await SpeechTranscriber.supportedLocales
                .sorted { displayName($0.identifier(.bcp47)) < displayName($1.identifier(.bcp47)) }
            installedSpeech = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
            var seen = Set<String>()
            targets = await LanguageAvailability().supportedLanguages
                .filter { seen.insert($0.minimalIdentifier).inserted }
                .sorted { LanguageNames.name($0.minimalIdentifier) < LanguageNames.name($1.minimalIdentifier) }
        }
    }

    private func displayName(_ id: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: id) ?? id
    }
}

// MARK: - Timing

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
