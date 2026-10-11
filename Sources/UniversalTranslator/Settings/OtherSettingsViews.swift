import AppKit
import AVFoundation
import FoundationModels
import Speech
import SwiftUI
import UniformTypeIdentifiers

struct ShortcutSettings: View {
    @Bindable var store: SettingsStore

    var body: some View {
        Form {
            Section {
                HotkeyRecorder(title: "Start / stop listening", hotkey: $store.settings.hotkeys.toggleListening)
                HotkeyRecorder(title: "Pause / resume", hotkey: $store.settings.hotkeys.pauseResume)
                HotkeyRecorder(title: "Show / hide overlay", hotkey: $store.settings.hotkeys.toggleOverlay)
                HotkeyRecorder(title: "Lock / unlock overlay", hotkey: $store.settings.hotkeys.toggleLock)
                HotkeyRecorder(title: "Clear captions", hotkey: $store.settings.hotkeys.clearCaptions)
                HotkeyRecorder(title: "Show transcript", hotkey: $store.settings.hotkeys.showTranscript)
            } footer: {
                Note("These shortcuts work in any app. Click a shortcut, then press the new key combination (it must include ⌘, ⌥, ⌃ or ⇧). Press Esc to cancel.")
            }
        }
    }
}

struct AboutSettings: View {
    @Bindable var store: SettingsStore
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var importError: String?

    var body: some View {
        Form {
            Section("Permissions") {
                LabeledContent("Microphone") {
                    HStack {
                        Text(micText)
                        if micStatus == .notDetermined {
                            Button("Allow…") {
                                Task {
                                    _ = await AudioCapture.requestPermission(for: .microphone)
                                    micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
                                }
                            }
                        } else if micStatus != .authorized {
                            Button("Open System Settings") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                            }
                        }
                    }
                }
                LabeledContent("System audio") {
                    HStack {
                        Text("Asked when you first caption another app")
                        Button("Open System Settings") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
                        }
                    }
                }
                LabeledContent("On-device speech recognition", value: SpeechTranscriber.isAvailable ? "Available" : "Unavailable")
                LabeledContent("Apple Intelligence model", value: fmText)
                Note("Universal Translator doesn't need Accessibility or Input Monitoring access. It never reads or sends keystrokes.")
            }

            Section("Settings file") {
                HStack {
                    Button("Export settings…", action: exportSettings)
                    Button("Import settings…", action: importSettings)
                }
                if let importError { Note("⚠︎ \(importError)") }
            }

            Section("About") {
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")
                Note("Speech recognition: NVIDIA Nemotron 3.5 Streaming (Core ML, via FluidAudio) or Apple SpeechAnalyzer · Voice and end of turn: Silero VAD v6, Smart Turn v3.2 · Translation: Tencent Hy-MT2 1.8B / 7B (llama.cpp), Apple Translation, Apple Intelligence, or LM Studio · Policy: target-side local agreement with a forced prefix (IWSLT 2025/2026).")
            }
        }
        .onAppear { micStatus = AVCaptureDevice.authorizationStatus(for: .audio) }
    }

    private var micText: String {
        switch micStatus {
        case .authorized: return "Allowed"
        case .denied: return "Denied"
        case .restricted: return "Restricted"
        case .notDetermined: return "Not requested yet"
        @unknown default: return "Unknown"
        }
    }

    private var fmText: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "Available"
        case .unavailable(let reason): return "Unavailable (\(reason))"
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Universal Translator Settings.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? store.exportJSON().write(to: url)
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importJSON(Data(contentsOf: url))
            importError = nil
        } catch {
            importError = error.localizedDescription
        }
    }
}
