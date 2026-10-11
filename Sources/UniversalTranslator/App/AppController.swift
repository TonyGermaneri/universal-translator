import AppKit
import SwiftUI
import TranslatorCore
import UniformTypeIdentifiers

/// Application delegate: owns the long-lived components and wires them together.
@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    let settings = SettingsStore()
    let captions = CaptionStore()
    private(set) var controller: TranslatorController!
    private(set) var overlay: OverlayController!
    private var statusItem: StatusItemController!
    private var settingsWindow: NSWindow?
    private var transcriptWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = TranslatorController(settings: settings, captions: captions)
        overlay = OverlayController(settings: settings, captions: captions)
        statusItem = StatusItemController(app: self)
        controller.onStateChange = { [weak self] in self?.statusItem.updateIcon() }

        registerHotkeys()
        settings.observe { [weak self] old, new in
            if old.hotkeys != new.hotkeys { self?.registerHotkeys() }
        }

        // Debug hooks for screenshots: open a window at launch.
        switch ProcessInfo.processInfo.environment["UT_OPEN"] {
        case "settings": openSettings()
        case "transcript": openTranscript()
        default: break
        }
        if ProcessInfo.processInfo.environment["UT_AUTOSTART"] == "1" {
            controller.start()
            // Test hook: "9,14" pauses 9 s after launch and resumes at 14 s.
            for delay in (ProcessInfo.processInfo.environment["UT_PAUSE_AT"] ?? "").split(separator: ",").compactMap({ Double($0) }) {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.controller.togglePause() }
            }
        } else if !settings.settings.hasCompletedFirstRun {
            settings.settings.hasCompletedFirstRun = true
            openSettings()
            showSampleCaptions()
        } else if settings.settings.startListeningAtLaunch {
            controller.start()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        LocalModelStore.shared.unloadAll()
        settings.saveNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        openSettings()
        return true
    }

    private func registerHotkeys() {
        let h = settings.settings.hotkeys
        HotkeyCenter.shared.register([
            (h.toggleListening, { [weak self] in self?.controller.toggle() }),
            (h.toggleOverlay, { [weak self] in self?.overlay.toggleShown() }),
            (h.toggleLock, { [weak self] in self?.overlay.toggleLock() }),
            (h.clearCaptions, { [weak self] in self?.captions.clear() }),
            (h.pauseResume, { [weak self] in self?.controller.togglePause() }),
            (h.showTranscript, { [weak self] in self?.openTranscript() }),
        ])
    }

    func showSampleCaptions() {
        captions.showDemo(targetLanguage: settings.settings.targetLanguage)
        overlay.setShown(true)
    }

    func openSettings() {
        if settingsWindow == nil {
            let root = SettingsView(app: self)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.title = "Universal Translator"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.setContentSize(NSSize(width: 860, height: 640))
            window.minSize = NSSize(width: 760, height: 520)
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("SettingsWindow")
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    func openTranscript() {
        if transcriptWindow == nil {
            let hosting = NSHostingController(rootView: TranscriptView(captions: captions, app: self))
            let window = NSWindow(contentViewController: hosting)
            window.title = "Transcript"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 620, height: 720))
            window.isReleasedWhenClosed = false
            window.center()
            window.setFrameAutosaveName("TranscriptWindow")
            transcriptWindow = window
        }
        NSApp.activate()
        transcriptWindow?.makeKeyAndOrderFront(nil)
    }

    func exportTranscript() {
        let entries = captions.sessionEntries
        guard !entries.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nothing to export yet"
            alert.informativeText = "Translated captions from this session will be exportable once you've started speaking."
            NSApp.activate()
            alert.runModal()
            return
        }
        let panel = NSSavePanel()
        panel.title = "Export Transcript"
        panel.nameFieldStringValue = "Translation \(Date().formatted(date: .abbreviated, time: .shortened)).srt"
            .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText,
                                     UTType(filenameExtension: "vtt") ?? .plainText, .plainText]
        panel.allowsOtherFileTypes = true
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let text: String = switch url.pathExtension.lowercased() {
        case "srt": SubtitleExporter.srt(entries, includeSource: true)
        case "vtt": SubtitleExporter.vtt(entries, includeSource: true)
        default: SubtitleExporter.text(entries)
        }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}
