import SwiftUI
import TranslatorCore

/// The main screen: live captions across the whole screen, with the controls above and below them. Tap the
/// captions to hide the controls; flip them to face someone across the table.
struct CaptionScreen: View {
    let app: AppController
    @State private var showSettings = false
    @State private var showTranscript = false
    @State private var showLanguages = false
    @State private var settingsDetent = PresentationDetent.large
    @AppStorage("captions.flipped") private var flipped = false
    @State private var controlsHidden = false

    private var captions: CaptionStore { app.captions }
    private var settings: SettingsStore { app.settings }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            CaptionStage(app: app)
                .rotationEffect(.degrees(flipped ? 180 : 0))
                .animation(.easeInOut(duration: 0.35), value: flipped)
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { controlsHidden.toggle() } }
                .accessibilityAction(named: controlsHidden ? "Show controls" : "Hide controls") { controlsHidden.toggle() }
        }
        .safeAreaInset(edge: .top) {
            if !controlsHidden { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .safeAreaInset(edge: .bottom) {
            if !controlsHidden { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .statusBarHidden(controlsHidden)
        .persistentSystemOverlays(controlsHidden ? .hidden : .automatic)
        .sheet(isPresented: $showSettings) {
            SettingsScreen(app: app)
                .presentationDetents([.medium, .large], selection: $settingsDetent)
                .presentationBackgroundInteraction(.enabled(upThrough: .medium))
        }
        .sheet(isPresented: $showTranscript) {
            NavigationStack {
                TranscriptView(captions: captions, app: app)
                    .navigationTitle("Transcript")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showTranscript = false }
                        }
                    }
            }
        }
        .sheet(isPresented: $showLanguages) {
            LanguageSheet(store: settings)
                .presentationDetents([.medium])
        }
    }

    // MARK: Controls

    private var topBar: some View {
        HStack(spacing: 12) {
            Spacer(minLength: 44)
            Button {
                showLanguages = true
            } label: {
                Text(languagePair)
                    .font(.headline)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .padding(.horizontal, 6)
            }
            .buttonStyle(.glass)
            .accessibilityHint("Choose the languages")
            Spacer(minLength: 0)
            Button {
                captions.clear()
            } label: {
                Image(systemName: "eraser")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .disabled(!captions.hasVisibleText)
            .accessibilityLabel("Clear captions")
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private var bottomBar: some View {
        HStack(alignment: .center) {
            roundButton("text.bubble", label: "Transcript") { showTranscript = true }
            Spacer()
            roundButton(flipped ? "arrow.down" : "arrow.up.arrow.down", label: flipped ? "Face me" : "Flip for the other person") {
                flipped.toggle()
            }
            Spacer()
            MicButton(app: app)
            Spacer()
            roundButton(captions.status == .paused ? "play.fill" : "pause.fill", label: captions.status == .paused ? "Resume" : "Pause") {
                app.controller.togglePause()
            }
            .disabled(!app.controller.isListening || captions.status.isPreparing)
            Spacer()
            roundButton("gearshape", label: "Settings") {
                settingsDetent = .large
                showSettings = true
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 8)
    }

    private func roundButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.title3)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel(label)
    }

    private var languagePair: String {
        let s = settings.settings
        let source = LanguageNames.name(LanguageNames.translationLanguage(fromLocale: s.sourceLocale).minimalIdentifier)
        if s.translation.backend == .none { return "\(source) (transcription)" }
        return "\(source) → \(LanguageNames.name(s.targetLanguage))"
    }
}

private extension CaptionStore.Status {
    var isPreparing: Bool {
        if case .preparing = self { return true }
        return false
    }
}

/// Start and stop listening; shows the input level while it listens.
private struct MicButton: View {
    let app: AppController

    var body: some View {
        let captions = app.captions
        let active = !(captions.status == .idle || isError)
        Button {
            app.controller.toggle()
        } label: {
            ZStack {
                if case .preparing = captions.status {
                    ProgressView().tint(.white)
                } else {
                    Image(systemName: active ? "stop.fill" : "mic.fill")
                        .font(.system(size: 28, weight: .semibold))
                }
            }
            .frame(width: 64, height: 64)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.circle)
        .tint(active ? .red : .accentColor)
        .background {
            // Grows with the voice while listening.
            Circle()
                .stroke(Color.white.opacity(captions.isSpeaking ? 0.55 : 0), lineWidth: 3)
                .scaleEffect(1.08 + 0.25 * level)
                .animation(.linear(duration: 0.08), value: level)
        }
        .accessibilityLabel(active ? "Stop listening" : "Start listening")
    }

    private var level: Double {
        guard app.captions.status == .listening else { return 0 }
        return max(0, min(1, (app.captions.inputLevel + 60) / 60))
    }

    private var isError: Bool {
        if case .error = app.captions.status { return true }
        return false
    }
}

/// The caption block, placed at the top, middle or bottom of the screen.
struct CaptionStage: View {
    let app: AppController

    var body: some View {
        let s = app.settings.settings
        let o = s.overlay
        GeometryReader { geo in
            // A ticker runs edge to edge; other layouts keep clear of the screen edges.
            let inset: CGFloat = o.layout == .marquee ? 0 : 20
            let width = max(100, geo.size.width - 2 * inset)
            Group {
                if app.captions.status == .idle, !app.captions.hasVisibleText {
                    hint(s)
                } else {
                    CaptionBox(o: o, captions: app.captions, privacy: PrivacyStatus.of(s), isUnlocked: false,
                               textWidth: width - (o.backgroundStyle == .box ? 2 * o.paddingH : 0),
                               direction: .init(source: s.sourceLocale, target: s.targetLanguage))
                        .frame(maxWidth: o.backgroundStyle == .box && !o.fixedWidthBox ? nil : .infinity, alignment: o.alignment.frame)
                }
            }
            .frame(width: width)
            .padding(.horizontal, inset)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: verticalAlignment(o.anchor))
            .opacity(o.opacity)
        }
    }

    private func hint(_ s: AppSettings) -> some View {
        let source = LanguageNames.name(LanguageNames.translationLanguage(fromLocale: s.sourceLocale).minimalIdentifier)
        let message = s.translation.backend == .none
            ? "Tap the microphone and speak \(source). What you say appears here."
            : "Tap the microphone and speak \(source). The \(LanguageNames.name(s.targetLanguage)) translation appears here as you talk."
        return VStack(spacing: 12) {
            Image(systemName: "captions.bubble")
                .font(.system(size: 44))
            Text(message)
                .font(.title3)
                .multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.55))
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }

    private func verticalAlignment(_ anchor: OverlayAnchor) -> Alignment {
        switch anchor {
        case .topLeading, .top, .topTrailing: return .top
        case .bottomLeading, .bottom, .bottomTrailing: return .bottom
        case .leading, .center, .trailing, .custom: return .center
        }
    }
}

/// Quick switch between languages, without opening settings.
struct LanguageSheet: View {
    @Bindable var store: SettingsStore
    @Environment(\.dismiss) private var dismiss
    private let catalog = LanguageCatalog.shared

    var body: some View {
        NavigationStack {
            Form {
                LanguagePickers(store: store)
                Section {
                    Button {
                        catalog.swap(store)
                    } label: {
                        Label("Swap languages", systemImage: "arrow.left.arrow.right")
                    }
                    .disabled(catalog.speechLocale(for: store.settings.targetLanguage) == nil)
                } footer: {
                    Text("Swap when the other person wants to speak.")
                }
            }
            .navigationTitle("Languages")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
