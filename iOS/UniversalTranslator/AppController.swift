import SwiftUI
import TranslatorCore
import UIKit

/// Owns the long-lived components of the iPhone and iPad app and wires them together (the counterpart of the
/// Mac app's delegate; the shared settings views talk to it the same way).
@MainActor
final class AppController {
    let settings = SettingsStore()
    let captions = CaptionStore()
    private(set) var controller: TranslatorController!
    private var timer: Timer?
    /// Listening stopped because the app went to the background; it starts again when the app comes back.
    private var resumeWhenActive = false
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid

    init() {
        controller = TranslatorController(settings: settings, captions: captions)
        controller.onStateChange = { [weak self] in self?.stateChanged() }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        if ProcessInfo.processInfo.environment["UT_AUTOSTART"] == "1" || settings.settings.startListeningAtLaunch {
            controller.start()
        }
        settings.settings.hasCompletedFirstRun = true
    }

    /// Turns the microphone on or off. Turning it on starts a new session: the notepad, the transcript and its
    /// export begin again from there. Pausing, the app going to the background, and a settings change that
    /// restarts the engine all continue the same session.
    func toggleListening() {
        if controller.isListening {
            controller.stop()
        } else {
            captions.resetSession()
            controller.start()
        }
    }

    /// Sample captions for previewing the appearance settings. They'd replace the session's text, so they're only
    /// shown when there's none.
    func showSampleCaptions() {
        guard !controller.isListening, captions.isDemo || captions.sessionEntries.isEmpty else { return }
        captions.showDemo(targetLanguage: settings.settings.targetLanguage)
    }

    /// iOS doesn't let a background app use the GPU (the translation models), so listening stops in the
    /// background and starts again when the app is back on screen.
    func scenePhaseChanged(_ phase: ScenePhase) {
        switch phase {
        case .background:
            guard controller.isListening else { return }
            resumeWhenActive = true
            backgroundTask = UIApplication.shared.beginBackgroundTask { [weak self] in self?.endBackgroundTask() }
            controller.stop()
        case .active:
            if resumeWhenActive, !controller.isListening {
                resumeWhenActive = false
                controller.start()
            }
        default:
            break
        }
    }

    private func stateChanged() {
        // Keep the screen on while captioning.
        UIApplication.shared.isIdleTimerDisabled = controller.isListening
        if !controller.isListening { endBackgroundTask() }
    }

    private func endBackgroundTask() {
        guard backgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTask)
        backgroundTask = .invalid
    }

    private func tick() {
        let o = settings.settings.overlay
        if captions.shouldAutoClear(after: o.autoClearAfter, readingSpeed: o.readingSpeed) {
            captions.clear()
        }
    }
}
