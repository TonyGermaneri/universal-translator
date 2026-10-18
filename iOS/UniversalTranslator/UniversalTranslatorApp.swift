import SwiftUI

@main
struct UniversalTranslatorApp: App {
    @State private var app = AppController()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            CaptionScreen(app: app)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in app.scenePhaseChanged(phase) }
    }
}
