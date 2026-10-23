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

            if !Platform.hasAppleModels, requiredModels.contains(where: { LocalModelStore.shared.state($0) != .ready }) {
                Section("Before you start") {
                    ForEach(requiredModels) { ModelRow(model: $0, store: LocalModelStore.shared) }
                    Note("Apple's built-in speech recognition and translation need macOS 26, so on this Mac these models do the work. Download them to start listening.")
                }
            }

            Section("Languages") {
                Picker("I speak", selection: $store.settings.sourceLocale) {
                    if !speechLocales.contains(where: { $0.identifier(.bcp47) == store.settings.sourceLocale }) {
                        Text(displayName(store.settings.sourceLocale)).tag(store.settings.sourceLocale)
                    }
                    ForEach(speechLocales, id: \.self) { locale in
                        let id = locale.identifier(.bcp47)
                        Text(displayName(id) + (installedSpeech.contains(id) || !Platform.hasAppleModels ? "" : "  (downloads on first use)")).tag(id)
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
                    ForEach(SpeechRecognizerKind.selectable) { Text($0.title).tag($0) }
                }
                switch store.settings.recognizer {
                case .appleSpeech:
                    Note("Built into macOS, no download. Its text arrives about once a second; when you pause, the last words are finalized right away.")
                case .nemotron:
                    let model = LocalModel.nemotron(for: store.settings.sourceLocale)
                    ModelRow(model: model, store: LocalModelStore.shared)
                    if LocalModelStore.shared.state(model) != .ready {
                        Label(Platform.hasAppleModels ? "Apple Speech is used until the model is downloaded."
                                                      : "Download the model to start listening.",
                              systemImage: "arrow.down.circle")
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
                Toggle("Menu bar only (no Dock icon while no window is open)", isOn: $store.settings.menuBarOnly)
                Toggle("Open at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }
                Note("Closing this window keeps Universal Translator running, in the Dock and the menu bar; quit it with ⌘Q or from either menu. In menu bar only mode, note that on a Mac with a notch macOS hides menu bar icons that don't fit; open the app again from Spotlight or Finder to bring back Settings.")
            }
        }
        .task {
            devices = AudioDevices.inputDevices()
            apps = AudioProcesses.apps()
            let locales: [Locale]
            if #available(macOS 26, *) {
                locales = await SpeechTranscriber.supportedLocales
                installedSpeech = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
            } else {
                // Nemotron's languages: it's the only recognizer before macOS 26.
                locales = NemotronRecognizer.supportedLocales.map(Locale.init(identifier:))
            }
            speechLocales = locales.sorted { displayName($0.identifier(.bcp47)) < displayName($1.identifier(.bcp47)) }
            var seen = Set<String>()
            targets = await LanguageAvailability().supportedLanguages
                .filter { seen.insert($0.minimalIdentifier).inserted }
                .sorted { LanguageNames.name($0.minimalIdentifier) < LanguageNames.name($1.minimalIdentifier) }
        }
    }

    private func displayName(_ id: String) -> String {
        Locale(identifier: "en").localizedString(forIdentifier: id) ?? id
    }

    /// What listening needs before macOS 26, where there's no Apple Speech or Translation to fall back on.
    private var requiredModels: [LocalModel] { TranslatorController.requiredModels(for: store.settings) }
}
