import Testing
@testable import UniversalTranslator

// Settings → Permissions & About names the build, not just "0.1.0" (every build since that tag said only that).

@Suite struct AppVersionTests {
    @Test func namesTheBuildAndWhenItWasMade() {
        let info: [String: Any] = ["CFBundleShortVersionString": "0.1.0", "UTBuildDescription": "v0.1.0-23-gd7ab774",
                                   "CFBundleVersion": "202610270927"]
        #expect(AppVersion.text(info: info) == "0.1.0 (v0.1.0-23-gd7ab774, built 2026-10-27 09:27)")
    }

    @Test func makesDoWithWhatTheBundleHas() {
        #expect(AppVersion.text(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "202610270927"])
                == "0.1.0 (built 2026-10-27 09:27)")
        #expect(AppVersion.text(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7"]) == "0.1.0 (build 7)")
        #expect(AppVersion.text(info: ["CFBundleShortVersionString": "0.1.0", "UTBuildDescription": ""]) == "0.1.0")
        #expect(AppVersion.text(info: [:]) == "dev")
    }
}
