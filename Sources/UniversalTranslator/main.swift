import AppKit

// Quit normally on SIGTERM (e.g. `kill`), so models are released and settings saved.
signal(SIGTERM, SIG_IGN)
let terminationSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminationSource.setEventHandler { NSApp.terminate(nil) }
terminationSource.resume()

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppController()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
