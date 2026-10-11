import AppKit
import TranslatorCore

/// The menu bar icon and its menu.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private unowned let app: AppController
    private var timer: Timer?
    private var lastSymbol = ""

    init(app: AppController) {
        self.app = app
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        updateIcon()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateIcon() }
        }
    }

    func updateIcon() {
        let captions = app.captions
        let symbol: String
        switch captions.status {
        case .error: symbol = "exclamationmark.bubble"
        case .preparing: symbol = "ellipsis.bubble"
        case .listening: symbol = captions.isSpeaking ? "waveform.badge.mic" : "captions.bubble.fill"
        case .idle: symbol = "captions.bubble"
        case .paused: symbol = "pause.circle"
        }
        guard symbol != lastSymbol, let button = item.button else { return }
        lastSymbol = symbol
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Universal Translator")
        image?.isTemplate = true
        button.image = image
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = app.settings.settings
        let controller: TranslatorController = app.controller

        menu.addItem(disabled(statusLine))
        let privacy = PrivacyStatus.of(s)
        let privacyItem = disabled(privacy.leavesMac ? privacy.summary : "Everything stays on this Mac")
        privacyItem.image = NSImage(systemSymbolName: privacy.symbol, accessibilityDescription: privacy.title)
        menu.addItem(privacyItem)
        menu.addItem(.separator())

        let listen = action(controller.isListening ? "Stop Listening" : "Start Listening", #selector(toggleListening))
        listen.toolTip = s.hotkeys.toggleListening.display
        menu.addItem(listen)
        if controller.isListening {
            let pause = action(controller.isPaused ? "Resume" : "Pause", #selector(togglePause))
            pause.toolTip = s.hotkeys.pauseResume.display
            menu.addItem(pause)
        }
        menu.addItem(.separator())

        menu.addItem(action(app.overlay.isShownByUser ? "Hide Overlay" : "Show Overlay", #selector(toggleOverlay)))
        let lock = action("Lock Overlay (Click-Through)", #selector(toggleLock))
        lock.state = s.overlay.clickThrough ? .on : .off
        menu.addItem(lock)
        menu.addItem(action("Clear Captions", #selector(clearCaptions)))
        menu.addItem(action("Show Sample Captions", #selector(showSample)))
        menu.addItem(.separator())

        menu.addItem(submenu("Listen To", items: listenItems(s)))
        menu.addItem(submenu("Translate To", items: Self.quickTargets.map { code in
            let item = action(LanguageNames.name(code), #selector(setTarget(_:)))
            item.representedObject = code
            item.state = s.targetLanguage == code ? .on : .off
            return item
        }))
        menu.addItem(submenu("Timing", items: Self.stabilityPresets.enumerated().map { index, preset in
            let item = action(preset.title, #selector(setStability(_:)))
            item.tag = index
            item.state = abs(s.timing.stability - preset.value) < 0.01 ? .on : .off
            return item
        }))
        menu.addItem(.separator())
        let transcript = action("Show Transcript", #selector(openTranscript))
        transcript.keyEquivalent = "t"
        menu.addItem(transcript)
        menu.addItem(action("Export Transcript…", #selector(exportTranscript)))
        let settingsItem = action("Settings…", #selector(openSettings))
        settingsItem.keyEquivalent = ","
        menu.addItem(settingsItem)
        menu.addItem(.separator())
        let quit = action("Quit Universal Translator", #selector(quit))
        quit.keyEquivalent = "q"
        menu.addItem(quit)
    }

    static let quickTargets = ["ja", "es", "fr", "de", "it", "pt", "zh", "ko", "ar", "hi", "ru", "en"]

    static let stabilityPresets: [(title: String, value: Double)] = [
        ("Responsive (shows words sooner)", 0.15),
        ("Balanced", 0.5),
        ("Stable (fewer changes on screen)", 0.85),
    ]

    private var statusLine: String {
        let s = app.settings.settings
        let pair = "\(LanguageNames.name(Locale(identifier: s.sourceLocale).language.languageCode?.identifier ?? s.sourceLocale)) → \(LanguageNames.name(s.targetLanguage))"
        switch app.captions.status {
        case .idle: return "Idle · \(pair)"
        case .preparing(let m): return m
        case .listening: return "Listening · \(pair)"
        case .paused: return "Paused · \(pair)"
        case .error(let m): return "⚠︎ \(m)"
        }
    }

    private func listenItems(_ s: AppSettings) -> [NSMenuItem] {
        let mic = action("Microphone", #selector(listenToMicrophone))
        mic.state = s.audioSource == .microphone ? .on : .off
        let system = action("All System Audio", #selector(listenToSystemAudio))
        system.state = s.audioSource == .systemAudio ? .on : .off
        var items = [mic, system]
        let playing = AudioProcesses.apps().filter { $0.isPlaying || $0.bundleID == s.sourceAppBundleID }
        if !playing.isEmpty {
            items.append(.separator())
            items.append(disabled("Apps playing audio"))
            for app in playing {
                let item = action(app.name, #selector(listenToApp(_:)))
                item.representedObject = app
                item.state = s.audioSource == .app && s.sourceAppBundleID == app.bundleID ? .on : .off
                items.append(item)
            }
        }
        return items
    }

    // MARK: Menu item helpers

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func submenu(_ title: String, items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu()
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    // MARK: Actions

    @objc private func toggleListening() { app.controller.toggle() }
    @objc private func togglePause() { app.controller.togglePause() }
    @objc private func toggleOverlay() { app.overlay.toggleShown() }
    @objc private func toggleLock() { app.overlay.toggleLock() }
    @objc private func clearCaptions() { app.captions.clear() }
    @objc private func showSample() { app.showSampleCaptions() }
    @objc private func openSettings() { app.openSettings() }
    @objc private func exportTranscript() { app.exportTranscript() }
    @objc private func openTranscript() { app.openTranscript() }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func listenToMicrophone() { app.settings.settings.audioSource = .microphone }
    @objc private func listenToSystemAudio() { app.settings.settings.audioSource = .systemAudio }

    @objc private func listenToApp(_ sender: NSMenuItem) {
        guard let source = sender.representedObject as? AudioApp else { return }
        app.settings.settings.sourceAppBundleID = source.bundleID
        app.settings.settings.sourceAppName = source.name
        app.settings.settings.audioSource = .app
    }

    @objc private func setTarget(_ sender: NSMenuItem) {
        if let code = sender.representedObject as? String { app.settings.settings.targetLanguage = code }
    }

    @objc private func setStability(_ sender: NSMenuItem) {
        app.settings.settings.timing.stability = Self.stabilityPresets[sender.tag].value
    }
}
