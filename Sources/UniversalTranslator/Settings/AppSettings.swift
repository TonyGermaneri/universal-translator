import AppKit
import SwiftUI
import TranslatorCore

// MARK: - Choices

/// Where the speech comes from.
enum AudioSource: String, Codable, CaseIterable, Identifiable {
    case microphone
    case systemAudio
    case app

    var id: String { rawValue }
    var title: String {
        switch self {
        case .microphone: return "Microphone (your voice)"
        case .systemAudio: return "All audio playing on this Mac"
        case .app: return "One app"
        }
    }
}

/// The speech recognizer that turns the audio into text.
enum SpeechRecognizerKind: String, Codable, CaseIterable, Identifiable {
    case nemotron
    case appleSpeech

    var id: String { rawValue }
    var title: String {
        switch self {
        case .nemotron: return "NVIDIA Nemotron (on-device streaming, most accurate)"
        case .appleSpeech: return "Apple Speech (on-device, built in)"
        }
    }
}

/// The translator that produces live captions while the speaker talks.
enum TranslatorKind: String, Codable, CaseIterable, Identifiable {
    case localLLM
    case apple
    case appleIntelligence
    case lmStudio
    case none

    var id: String { rawValue }
    var title: String {
        switch self {
        case .localLLM: return "Hy-MT2 1.8B (on-device translation LLM, steadiest)"
        case .apple: return "Apple Translation (on-device, fastest)"
        case .appleIntelligence: return "Apple Intelligence model (on-device LLM)"
        case .lmStudio: return "LM Studio (or another OpenAI-compatible server)"
        case .none: return "None (show transcription only)"
        }
    }
}

/// The runtime for the on-device Hy-MT2 models. Each has its own downloads.
enum LocalEngine: String, Codable, CaseIterable, Identifiable {
    case llamaCpp
    case mlx

    var id: String { rawValue }
    var title: String {
        switch self {
        case .llamaCpp: return "llama.cpp"
        case .mlx: return "MLX"
        }
    }
}

/// The translator that re-translates each finished sentence and may revise what's on screen.
enum RevisionBackend: String, Codable, CaseIterable, Identifiable {
    case off
    case localLLMLarge
    case localLLMSmall
    case appleHighFidelity
    case appleIntelligence
    case lmStudio

    var id: String { rawValue }
    var title: String {
        switch self {
        case .off: return "Off"
        case .localLLMLarge: return "Hy-MT2 7B (on-device translation LLM, best quality)"
        case .localLLMSmall: return "Hy-MT2 1.8B (on-device translation LLM)"
        case .appleHighFidelity: return "Apple Translation, high fidelity (on-device)"
        case .appleIntelligence: return "Apple Intelligence model (on-device LLM)"
        case .lmStudio: return "LM Studio (or another OpenAI-compatible server)"
        }
    }
}

struct RGBA: Codable, Equatable {
    var r: Double, g: Double, b: Double, a: Double

    init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: Color) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
    }

    var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }

    static let white = RGBA(1, 1, 1)
    static let black = RGBA(0, 0, 0)
    static func gray(_ v: Double, _ a: Double = 1) -> RGBA { RGBA(v, v, v, a) }
}

enum OverlayAnchor: String, Codable, CaseIterable, Identifiable {
    case topLeading, top, topTrailing, leading, center, trailing, bottomLeading, bottom, bottomTrailing, custom

    var id: String { rawValue }
    var title: String {
        switch self {
        case .topLeading: return "Top left"
        case .top: return "Top center"
        case .topTrailing: return "Top right"
        case .leading: return "Middle left"
        case .center: return "Center"
        case .trailing: return "Middle right"
        case .bottomLeading: return "Bottom left"
        case .bottom: return "Bottom center"
        case .bottomTrailing: return "Bottom right"
        case .custom: return "Custom (dragged)"
        }
    }

    var isTop: Bool { [.topLeading, .top, .topTrailing].contains(self) }
}

enum ScreenMode: String, Codable, CaseIterable, Identifiable {
    case main, withMouse, specific
    var id: String { rawValue }
    var title: String {
        switch self {
        case .main: return "Main display"
        case .withMouse: return "Display with the mouse pointer"
        case .specific: return "Specific display"
        }
    }
}

enum OverlayLevel: String, Codable, CaseIterable, Identifiable {
    case floating, aboveMenuBar, aboveEverything
    var id: String { rawValue }
    var title: String {
        switch self {
        case .floating: return "Above app windows"
        case .aboveMenuBar: return "Above the menu bar and Dock"
        case .aboveEverything: return "Above everything (incl. full-screen apps)"
        }
    }
    var windowLevel: NSWindow.Level {
        switch self {
        case .floating: return .floating
        case .aboveMenuBar: return .statusBar
        case .aboveEverything: return .screenSaver
        }
    }
}

enum BackgroundStyle: String, Codable, CaseIterable, Identifiable {
    case box, none
    var id: String { rawValue }
    var title: String { self == .box ? "Box" : "None (text only)" }
}

enum CaptionLayout: String, Codable, CaseIterable, Identifiable {
    case rolling, stacked
    var id: String { rawValue }
    var title: String { self == .rolling ? "Rolling (live-caption style)" : "Stacked (one line per chunk)" }
}

enum TextAnimationStyle: String, Codable, CaseIterable, Identifiable {
    case none, fade, slideUp
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .fade: return "Cross-fade"
        case .slideUp: return "Slide up"
        }
    }
}

enum FontWeightChoice: String, Codable, CaseIterable, Identifiable {
    case light, regular, medium, semibold, bold, heavy, black
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var weight: Font.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
    var nsWeight: NSFont.Weight {
        switch self {
        case .light: return .light
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        case .heavy: return .heavy
        case .black: return .black
        }
    }
}

enum AlignmentChoice: String, Codable, CaseIterable, Identifiable {
    case leading, center, trailing
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var text: TextAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
    var horizontal: HorizontalAlignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
    var frame: Alignment {
        switch self {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}

// MARK: - Settings groups

struct OverlaySettings: Codable, Equatable {
    // Placement
    var screenMode: ScreenMode = .main
    var screenName: String = ""
    var anchor: OverlayAnchor = .bottom
    /// Window center as a fraction of the screen's visible frame (used when `anchor == .custom`).
    var customX: Double = 0.5
    var customY: Double = 0.15
    var marginX: Double = 48
    var marginY: Double = 64
    var widthFraction: Double = 0.72

    // Content
    var layout: CaptionLayout = .rolling
    var maxLines: Int = 2
    var showSource: Bool = true
    var sourceMaxLines: Int = 1
    var sourceAbove: Bool = true
    var showProvisional: Bool = true
    var provisionalOpacity: Double = 0.6
    var provisionalItalic: Bool = true
    /// Newly committed words fade in from the provisional style.
    var fadeInNewWords: Bool = true
    /// Words changed by a second-pass revision are briefly highlighted.
    var highlightRevisions: Bool = true
    var revisionColor: RGBA = RGBA(1, 0.84, 0.35)
    /// Shows how far behind the speaker the translation is when it falls behind.
    var showLagIndicator: Bool = true
    var olderLineOpacity: Double = 0.7
    var alignment: AlignmentChoice = .center

    // Typography
    var fontFamily: String = ""
    var fontSize: Double = 34
    var fontWeight: FontWeightChoice = .semibold
    var textColor: RGBA = .white
    var lineSpacing: Double = 3
    var sourceScale: Double = 0.55
    var sourceColor: RGBA = .gray(0.85, 0.85)
    var strokeWidth: Double = 0
    var strokeColor: RGBA = .black
    var shadowEnabled: Bool = true
    var shadowColor: RGBA = RGBA(0, 0, 0, 0.85)
    var shadowRadius: Double = 5

    // Background
    var backgroundStyle: BackgroundStyle = .box
    /// Box spans the full overlay width instead of hugging the text.
    var fixedWidthBox: Bool = false
    var backgroundColor: RGBA = RGBA(0.05, 0.05, 0.07, 0.62)
    var backgroundBlur: Bool = true
    var cornerRadius: Double = 16
    var paddingH: Double = 24
    var paddingV: Double = 14
    var borderWidth: Double = 0
    var borderColor: RGBA = .gray(1, 0.25)

    // Window behavior
    var level: OverlayLevel = .aboveEverything
    var clickThrough: Bool = true
    var allSpaces: Bool = true
    var hideFromScreenCapture: Bool = false
    var autoHide: Bool = true
    var autoHideDelay: Double = 8
    /// Silence (seconds) after which the next caption starts a fresh paragraph.
    var paragraphBreak: Double = 3.5
    /// Reading speed (characters per second, 0 = off): rolling captions hold a line that hasn't been on screen
    /// long enough to read, growing by up to `readingExtraLines` instead of scrolling it away.
    var readingSpeed: Double = 17
    var readingExtraLines: Int = 1
    /// Clear the captions after this much silence (0 = never), once the last one has had time to be read.
    var autoClearAfter: Double = 12
    var textAnimation: TextAnimationStyle = .fade
    var animationDuration: Double = 0.25
    var opacity: Double = 1
    var showStatusIndicator: Bool = true
    /// A lock (everything stays on this Mac) or network symbol (text is sent elsewhere) beside the status dot.
    var showPrivacyIndicator: Bool = true
}

struct TranslationSettings: Codable, Equatable {
    /// Live translator. Hy-MT2 falls back to Apple Translation until it's downloaded.
    var backend: TranslatorKind = .localLLM
    /// Second pass over finished sentences. Falls back when the model isn't downloaded.
    var revision: RevisionBackend = .localLLMLarge
    /// Runtime for the on-device Hy-MT2 models.
    var localEngine: LocalEngine = .llamaCpp
    /// Finished sentences passed to LLM translators as context.
    var contextSentences: Int = 4
    var customInstructions: String = ""
    /// Required term translations (blank translation = keep the term as is).
    var glossary: [GlossaryEntry] = []
    var lmStudioURL: String = "http://localhost:1234"
    var lmStudioModel: String = ""
    var lmStudioAPIKey: String = ""
    /// Chat template for raw completions with prefix forcing (`.chatAPI` uses the chat endpoint instead).
    var lmStudioTemplate: PromptTemplate = .automatic
    var temperature: Double = 0.2
}

/// When text is stable enough to translate and commit.
struct TimingSettings: Codable, Equatable {
    /// Responsive (0) ↔ Stable (1): how long translations may wait to settle and how much of the
    /// provisional tail is hidden.
    var stability: Double = 0.5
    /// Neural voice detection (Silero VAD). Falls back to the level-based detector when off or unavailable.
    var neuralVAD: Bool = true
    /// The Smart Turn model decides whether a pause ends the thought.
    var smartTurn: Bool = true
    /// With Smart Turn: the longest pause inside a thought before it's finished anyway.
    var maxTurnPause: Double = 1.4
    /// Without Smart Turn: silence (seconds) that ends a thought.
    var endOfThoughtPause: Double = 0.7
    /// Volatile (still revisable) words must exist this long before they're translated.
    var holdBack: Double = 0.25
    /// Run-on speech is split into sentences of at most this many words.
    var maxSentenceWords: Int = 40
}

struct Hotkey: Codable, Equatable {
    var keyCode: UInt32
    /// Carbon modifier mask (cmdKey, optionKey, controlKey, shiftKey).
    var modifiers: UInt32
    var display: String

    /// Explicit "no shortcut" value (kept non-optional so a cleared shortcut survives the defaults merge).
    static let none = Hotkey(keyCode: 0, modifiers: 0, display: "")
    var isSet: Bool { !display.isEmpty }
}

struct HotkeySettings: Codable, Equatable {
    var toggleListening: Hotkey = Hotkey(keyCode: 17, modifiers: 0x1000 | 0x0800 | 0x0100, display: "⌃⌥⌘T")
    var toggleOverlay: Hotkey = Hotkey(keyCode: 31, modifiers: 0x1000 | 0x0800 | 0x0100, display: "⌃⌥⌘O")
    var toggleLock: Hotkey = Hotkey(keyCode: 37, modifiers: 0x1000 | 0x0800 | 0x0100, display: "⌃⌥⌘L")
    var clearCaptions: Hotkey = Hotkey(keyCode: 40, modifiers: 0x1000 | 0x0800 | 0x0100, display: "⌃⌥⌘K")
    var pauseResume: Hotkey = Hotkey(keyCode: 35, modifiers: 0x1000 | 0x0800 | 0x0100, display: "⌃⌥⌘P")
    var showTranscript: Hotkey = .none
}

struct AppSettings: Codable, Equatable {
    var sourceLocale: String = Locale.current.identifier(.bcp47)
    /// Nemotron falls back to Apple Speech until its model is downloaded.
    var recognizer: SpeechRecognizerKind = .nemotron
    var targetLanguage: String = "ja"
    var audioSource: AudioSource = .microphone
    /// The app captured when `audioSource == .app`.
    var sourceAppBundleID: String = ""
    var sourceAppName: String = ""
    var inputDeviceUID: String = ""
    var micSensitivity: Double = 0.6
    var startListeningAtLaunch: Bool = false
    var timing = TimingSettings()
    var translation = TranslationSettings()
    var overlay = OverlaySettings()
    var hotkeys = HotkeySettings()
    var hasCompletedFirstRun = false
}

// MARK: - Overlay presets

enum OverlayPreset: String, CaseIterable, Identifiable {
    case subtitles, lowerThird, teleprompter, minimal, highContrast

    var id: String { rawValue }
    var title: String {
        switch self {
        case .subtitles: return "Subtitles"
        case .lowerThird: return "Broadcast lower third"
        case .teleprompter: return "Teleprompter"
        case .minimal: return "Minimal outline"
        case .highContrast: return "High contrast"
        }
    }

    /// Applies the preset's look while keeping the user's display and behavior choices.
    func apply(to o: inout OverlaySettings) {
        let keep = (o.screenMode, o.screenName, o.level, o.clickThrough, o.allSpaces, o.hideFromScreenCapture)
        let base = OverlaySettings()
        o = base
        (o.screenMode, o.screenName, o.level, o.clickThrough, o.allSpaces, o.hideFromScreenCapture) = keep
        switch self {
        case .subtitles:
            break
        case .lowerThird:
            o.anchor = .bottomLeading
            o.alignment = .leading
            o.widthFraction = 0.55
            o.fontSize = 30
            o.fontWeight = .bold
            o.backgroundColor = RGBA(0.06, 0.17, 0.42, 0.9)
            o.backgroundBlur = false
            o.cornerRadius = 6
            o.borderWidth = 0
            o.sourceColor = RGBA(0.75, 0.85, 1, 0.9)
            o.marginX = 64
            o.marginY = 96
        case .teleprompter:
            o.anchor = .top
            o.marginY = 40
            o.widthFraction = 0.8
            o.fontSize = 44
            o.maxLines = 4
            o.layout = .rolling
            o.backgroundColor = RGBA(0, 0, 0, 0.78)
            o.sourceMaxLines = 2
        case .minimal:
            o.backgroundStyle = .none
            o.strokeWidth = 2.5
            o.strokeColor = .black
            o.shadowRadius = 3
            o.fontWeight = .bold
            o.showSource = false
        case .highContrast:
            o.textColor = RGBA(1, 0.92, 0.2)
            o.backgroundColor = RGBA(0, 0, 0, 0.95)
            o.backgroundBlur = false
            o.fontWeight = .heavy
            o.fontSize = 38
            o.cornerRadius = 4
            o.sourceColor = .white
            o.provisionalOpacity = 0.75
        }
    }
}
