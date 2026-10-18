import SwiftUI
import Translation
import TranslatorCore

struct TranslationSettingsView: View {
    @Bindable var store: SettingsStore
    private let localModels = LocalModelStore.shared
    @State private var appleStatus: LanguageAvailability.Status?
    @State private var fastStatus: LanguageAvailability.Status?
    @State private var downloadConfig: TranslationSession.Configuration?
    @State private var fastDownloadConfig: TranslationSession.Configuration?
    @State private var models: [String] = []
    @State private var modelError: String?
    @State private var testResult: String?
    @State private var testing = false

    private var source: Locale.Language { LanguageNames.translationLanguage(fromLocale: store.settings.sourceLocale) }
    private var target: Locale.Language { Locale.Language(identifier: store.settings.targetLanguage) }
    private var pairName: String {
        "\(LanguageNames.name(source.minimalIdentifier)) → \(LanguageNames.name(store.settings.targetLanguage))"
    }

    var body: some View {
        Form {
            Section {
                let privacy = PrivacyStatus.of(store.settings)
                Label(privacy.summary, systemImage: privacy.symbol)
                    .foregroundStyle(privacy.leavesMac ? .orange : .green)
            }

            Section {
                Picker("Live translation", selection: $store.settings.translation.backend) {
                    ForEach(TranslatorKind.allCases) { Text($0.title).tag($0) }
                }
                Note(backendNote)
                if store.settings.translation.backend == .localLLM, localModels.state(smallModel) != .ready {
                    HStack {
                        Label("Apple Translation is used until \(smallModel.name) is downloaded.",
                              systemImage: "arrow.down.circle")
                            .foregroundStyle(.orange)
                        Spacer()
                        if case .notDownloaded = localModels.state(smallModel) {
                            Button("Download now") { localModels.download(smallModel) }
                        }
                    }
                }
            } header: {
                Text("While you speak")
            }

            Section {
                Picker("Second pass", selection: $store.settings.translation.revision) {
                    ForEach(RevisionBackend.allCases) { Text($0.title).tag($0) }
                }
                if store.settings.translation.revision == .localLLMLarge, localModels.state(largeModel) != .ready {
                    HStack {
                        Label("The second pass is off until \(largeModel.name) is downloaded.",
                              systemImage: "arrow.down.circle")
                            .foregroundStyle(.orange)
                        Spacer()
                        if case .notDownloaded = localModels.state(largeModel) {
                            Button("Download now") { localModels.download(largeModel) }
                        }
                    }
                }
                Note("When a sentence ends, a stronger translator translates it again with the earlier sentences as context. If the meaning changed, the caption is revised in place and the changed words are briefly highlighted. That happens at most once per sentence, and only while the sentence is still on screen.")
            } header: {
                Text("After each sentence")
            }

            Section {
                Picker("Engine", selection: $store.settings.translation.localEngine) {
                    ForEach(LocalEngine.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                ForEach(LocalModel.translationModels(store.settings.translation.localEngine)) { model in
                    ModelRow(model: model, store: localModels)
                }
                Note("On-device translation models run on your \(Platform.deviceName)'s GPU. They continue the translation already on screen instead of starting over each time, so live captions change far less. Nothing leaves your \(Platform.deviceName).")
                Note(engineNote)
            } header: {
                Text("On-device translation models")
            }

            Section("Apple Translation · \(pairName)") {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Standard model")
                        Text(appleStatusText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if appleStatus == .supported {
                        Button("Download…") { requestDownload() }
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Low-latency model")
                        Text(fastStatusText).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if fastStatus == .supported {
                        Button("Download…") { requestFastDownload() }
                    }
                }
                Note("Live captions use the low-latency model (about 30–150 ms per update) when it's downloaded, and the standard model otherwise. The high-fidelity second pass uses the standard model.")
            }
            .translationTask(downloadConfig) { session in
                try? await session.prepareTranslation()
                await refreshAppleStatus()
            }
            .translationTask(fastDownloadConfig) { session in
                try? await session.prepareTranslation()
                await refreshAppleStatus()
            }

            Section {
                GlossaryEditor(entries: $store.settings.translation.glossary)
                Note("Terms you always want translated a particular way (leave the translation blank to keep a name or product as is). They're given to the language-model translators whenever they come up, and also help speech recognition. Apple Translation doesn't support glossaries.")
            } header: {
                Text("Glossary")
            }

            if usesLMStudio {
                lmStudioSection
            }

            if usesLLM || store.settings.translation.backend == .localLLM || store.settings.translation.revision == .localLLMLarge {
                Section("Language model translation") {
                    Stepper("Context: previous \(store.settings.translation.contextSentences) sentences",
                            value: $store.settings.translation.contextSentences, in: 0...8)
                    SliderRow(title: "Temperature", value: $store.settings.translation.temperature, range: 0...1,
                              format: { String(format: "%.2f", $0) })
                    VStack(alignment: .leading) {
                        Text("Style and instructions")
                        TextEditor(text: $store.settings.translation.customInstructions)
                            .font(.body)
                            .frame(minHeight: 70)
                        Note("For example: \"polite and formal\", \"casual\", or \"Use desu/masu form.\" Hy-MT2 applies it as its translation style.")
                    }
                }
            }
        }
        .task(id: "\(store.settings.sourceLocale)|\(store.settings.targetLanguage)") { await refreshAppleStatus() }
        .task(id: store.settings.translation.lmStudioURL) { if usesLMStudio { await loadModels() } }
    }

    private var smallModel: LocalModel { LocalModel.live(store.settings.translation.localEngine) }
    private var largeModel: LocalModel { LocalModel.reviser(store.settings.translation.localEngine) }

    private var engineNote: String {
        switch store.settings.translation.localEngine {
        case .llamaCpp: return "llama.cpp runs Tencent's own 4-bit builds (1.1 GB and 4.6 GB). Recommended: the fastest live captions."
        case .mlx: return "MLX is Apple's machine-learning framework. Its 1.8B model is 8-bit (1.9 GB), which stays closer to Tencent's full-precision model, but live captions are about 20% slower than with llama.cpp. The 7B is 4-bit (4.2 GB). Both are community conversions of Tencent's models."
        }
    }

    private var usesLMStudio: Bool {
        store.settings.translation.backend == .lmStudio || store.settings.translation.revision == .lmStudio
    }

    private var usesLLM: Bool {
        usesLMStudio || store.settings.translation.backend == .appleIntelligence || store.settings.translation.revision == .appleIntelligence
    }

    private var lmStudioSection: some View {
        Section("LM Studio") {
            TextField("Server URL", text: $store.settings.translation.lmStudioURL)
            SecureField("API key (optional)", text: $store.settings.translation.lmStudioAPIKey)
            HStack {
                Picker("Model", selection: $store.settings.translation.lmStudioModel) {
                    Text("Choose…").tag("")
                    if !store.settings.translation.lmStudioModel.isEmpty, !models.contains(store.settings.translation.lmStudioModel) {
                        Text(store.settings.translation.lmStudioModel).tag(store.settings.translation.lmStudioModel)
                    }
                    ForEach(models, id: \.self) { Text($0).tag($0) }
                }
                Button {
                    Task { await loadModels() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Reload models")
            }
            Picker("Prompt format", selection: $store.settings.translation.lmStudioTemplate) {
                ForEach(PromptTemplate.allCases, id: \.self) { template in
                    if template == .automatic, !store.settings.translation.lmStudioModel.isEmpty {
                        Text("Automatic: \(PromptTemplate.detect(modelID: store.settings.translation.lmStudioModel).title)").tag(template)
                    } else {
                        Text(template.title).tag(template)
                    }
                }
            }
            Note(store.settings.translation.lmStudioTemplate.resolved(modelID: store.settings.translation.lmStudioModel).supportsPrefix
                 ? "Fast mode: the model continues the translation already on screen (prefix forcing), generating only a few words per update, and LM Studio reuses its prompt cache."
                 : "Chat mode: each update re-translates the whole sentence, so captions are slower and change more. Pick the model's prompt format to enable the fast mode.")
            if let modelError { Note("⚠︎ \(modelError)") }
            if models.isEmpty, modelError == nil {
                Note("No chat models found. In LM Studio, download a model (e.g. Gemma 3 12B or Qwen3 14B), load it, and start the local server (Developer tab).")
            }
            HStack {
                Button(testing ? "Testing…" : "Test translation") { Task { await test() } }
                    .disabled(testing || store.settings.translation.lmStudioModel.isEmpty)
                if let testResult { Text(testResult).foregroundStyle(.secondary).lineLimit(2) }
            }
        }
    }

    private var backendNote: String {
        switch store.settings.translation.backend {
        case .localLLM: return "Tencent's Hy-MT2 translation model running on your \(Platform.deviceName). It continues the committed translation as you speak (the approach of the top systems in the IWSLT simultaneous translation evaluations), with earlier sentences as context, so captions are steady and consistent. Download it below."
        case .apple: return "Fastest and fully on-device. The sentence so far is re-translated as you speak, and only the words that consecutive translations agree on are committed, so word order differences (like Japanese verbs coming last) settle before they're shown as final."
        case .appleIntelligence: return "Apple's on-device language model, with earlier sentences as context. Noticeably slower than Apple Translation for live captions; better suited to the second pass."
        case .lmStudio: return "A model loaded in LM Studio, with earlier sentences as context. Speed depends on the model; small translation models (about 2B parameters) keep up best."
        case .none: return "Shows the recognized speech without translating it (live transcription)."
        }
    }

    private var appleStatusText: String {
        switch appleStatus {
        case .installed?: return "Ready (installed on this \(Platform.deviceName))"
        case .supported?: return "Supported. Language files need to be downloaded."
        case .unsupported?: return "Not supported by Apple Translation. Choose another translator."
        case nil: return "Checking…"
        @unknown default: return "Unknown"
        }
    }

    private var fastStatusText: String {
        switch fastStatus {
        case .installed?: return "Installed: used for live captions"
        case .supported?: return "Not downloaded: live captions use the standard model"
        case .unsupported?: return "Not available for this language pair"
        case nil: return "Checking…"
        @unknown default: return "Unknown"
        }
    }

    private func requestFastDownload() {
        if fastDownloadConfig == nil {
            fastDownloadConfig = TranslationSession.Configuration(source: source, target: target, preferredStrategy: .lowLatency)
        } else {
            fastDownloadConfig?.invalidate()
        }
    }

    private func requestDownload() {
        if downloadConfig == nil {
            downloadConfig = TranslationSession.Configuration(source: source, target: target)
        } else {
            downloadConfig?.invalidate()
        }
    }

    private func refreshAppleStatus() async {
        appleStatus = await LanguageAvailability().status(from: source, to: target)
        fastStatus = await LanguageAvailability(preferredStrategy: .lowLatency).status(from: source, to: target)
    }

    private func loadModels() async {
        let client = OpenAICompatibleClient(baseURL: store.settings.translation.lmStudioURL,
                                            apiKey: store.settings.translation.lmStudioAPIKey, timeout: 3)
        do {
            models = try await client.listModels()
            modelError = nil
        } catch {
            models = []
            modelError = "Couldn't reach LM Studio at \(store.settings.translation.lmStudioURL). Is the local server running?"
        }
    }

    private func test() async {
        testing = true
        defer { testing = false }
        let translator = LMStudioTranslator(settings: store.settings.translation,
                                            sourceName: LanguageNames.name(source.minimalIdentifier),
                                            targetName: LanguageNames.name(store.settings.targetLanguage),
                                            targetCode: store.settings.targetLanguage, hint: "")
        let started = Date()
        do {
            let result = try await translator.translate(source: "Thanks for joining. Let's get started with today's agenda.",
                                                        prefix: "", context: [], isFinal: true)
            testResult = String(format: "%.0f ms: %@", Date().timeIntervalSince(started) * 1000, result)
        } catch {
            testResult = "Failed: \(error.localizedDescription)"
        }
    }
}

/// One downloadable on-device model with its status and actions.
struct ModelRow: View {
    let model: LocalModel
    let store: LocalModelStore

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name)
                Text(model.summary).font(.caption).foregroundStyle(.secondary)
                if case .failed(let message) = store.state(model) {
                    Text("Download failed: \(message)").font(.caption).foregroundStyle(.red)
                }
                if tooLarge, store.state(model) != .ready {
                    Text("Needs more memory than this \(Platform.deviceName) lets an app use.")
                        .font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            switch store.state(model) {
            case .ready:
                Label("Downloaded", systemImage: "checkmark.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(.green)
                    .font(.caption)
                Button("Delete", role: .destructive) { store.delete(model) }
                    .buttonStyle(.borderless)
            case .downloading(let fraction):
                ProgressView(value: fraction).frame(width: 110)
                Text(Fmt.percent(fraction)).font(.caption).monospacedDigit().frame(width: 36)
                Button("Cancel") { store.cancelDownload(model) }.buttonStyle(.borderless)
            case .notDownloaded, .failed:
                Button("Download (\(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file)))") {
                    store.download(model)
                }
                .disabled(tooLarge)
            }
        }
    }

    private var tooLarge: Bool { !LocalModelStore.fitsInMemory(model) }
}

/// Editable list of glossary terms.
struct GlossaryEditor: View {
    @Binding var entries: [GlossaryEntry]
    @State private var newSource = ""
    @State private var newTarget = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach($entries) { $entry in
                HStack {
                    TextField("Term", text: $entry.source)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Translation (blank = keep as is)", text: $entry.target)
                    Button {
                        entries.removeAll { $0.id == entry.id }
                    } label: {
                        Image(systemName: "minus.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
            HStack {
                TextField("New term", text: $newSource)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                TextField("Translation", text: $newTarget)
                Button {
                    let source = newSource.trimmingCharacters(in: .whitespaces)
                    guard !source.isEmpty else { return }
                    entries.append(GlossaryEntry(source: source, target: newTarget))
                    newSource = ""
                    newTarget = ""
                } label: {
                    Image(systemName: "plus.circle.fill")
                }
                .buttonStyle(.borderless)
                .disabled(newSource.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .textFieldStyle(.roundedBorder)
    }
}
