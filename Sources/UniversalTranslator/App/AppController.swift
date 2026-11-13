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
            if old.menuBarOnly != new.menuBarOnly { self?.updateDockIcon() }
        }
        updateDockIcon()

        // Debug hooks for screenshots: open a window at launch.
        switch ProcessInfo.processInfo.environment["UT_OPEN"] {
        case "settings": openSettings()
        case "transcript": openTranscript()
        default: break
        }
        // Test hook: "<model id>=<path>" imports a hand-downloaded model at launch, as Settings' Choose button does.
        if let spec = ProcessInfo.processInfo.environment["UT_IMPORT_MODEL"],
           let split = spec.firstIndex(of: "="),
           let model = LocalModel.catalog.first(where: { $0.id == spec[..<split] }) {
            let path = String(spec[spec.index(after: split)...])
            Task { await LocalModelStore.shared.importModel(model, from: URL(fileURLWithPath: path)) }
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
        // First: unloading models has once taken over 10 s.
        controller.transcript.end()
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
        captions.showDemo(targetLanguage: settings.settings.targetLanguage, sourceLanguage: settings.settings.sourceLocale)
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
            observeClose(of: window)
        }
        NSApp.setActivationPolicy(.regular)
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
            observeClose(of: window)
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        transcriptWindow?.makeKeyAndOrderFront(nil)
    }

    /// In the Dock (and ⌘-Tab) like any app, until it's quit: a crowded menu bar can hide the menu bar icon entirely.
    /// With `menuBarOnly`, a menu bar app that's in the Dock only while one of its windows is open (minimized
    /// included), so it's still easy to get back to.
    private func updateDockIcon() {
        let windowOpen = [settingsWindow, transcriptWindow].contains { $0?.isVisible == true || $0?.isMiniaturized == true }
        let policy = Self.dockPolicy(menuBarOnly: settings.settings.menuBarOnly, windowOpen: windowOpen)
        if NSApp.activationPolicy() != policy { NSApp.setActivationPolicy(policy) }
    }

    nonisolated static func dockPolicy(menuBarOnly: Bool, windowOpen: Bool) -> NSApplication.ActivationPolicy {
        menuBarOnly && !windowOpen ? .accessory : .regular
    }

    // MARK: Dock menu

    /// What the Dock icon's menu offers, so the essentials don't depend on finding the menu bar icon. (Clicking the
    /// icon opens Settings; macOS adds Quit.)
    enum DockAction: Equatable {
        case startListening, stopListening, showCaptions, hideCaptions, showSampleCaptions, showTranscript

        var title: String {
            switch self {
            case .startListening: return "Start Listening"
            case .stopListening: return "Stop Listening"
            case .showCaptions: return "Show Captions"
            case .hideCaptions: return "Hide Captions"
            case .showSampleCaptions: return "Show Sample Captions"
            case .showTranscript: return "Show Transcript"
            }
        }
    }

    /// Sample captions are there to be positioned: hovering over them shows the move grip.
    nonisolated static func dockActions(listening: Bool, shown: Bool) -> [DockAction] {
        [listening ? .stopListening : .startListening, shown ? .hideCaptions : .showCaptions, .showSampleCaptions,
         .showTranscript]
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        for action in Self.dockActions(listening: controller.isListening, shown: overlay.isShownByUser) {
            menu.addItem(ClosureMenuItem(action.title) { [weak self] in self?.perform(action) })
        }
        return menu
    }

    private func perform(_ action: DockAction) {
        switch action {
        case .startListening, .stopListening: controller.toggle()
        case .showCaptions, .hideCaptions: overlay.toggleShown()
        case .showSampleCaptions: showSampleCaptions()
        case .showTranscript: openTranscript()
        }
    }

    private func observeClose(of window: NSWindow) {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
            // Still visible while closing; check once it's gone.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateDockIcon() } }
        }
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

/// A menu item that runs a closure (the Dock menu's items).
final class ClosureMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    required init(coder: NSCoder) { fatalError("not used from a nib") }

    @objc private func run() { handler() }
}
