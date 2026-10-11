import Foundation
import Observation

/// Owns the app settings, persists them to UserDefaults, and tells listeners what changed.
@MainActor
@Observable
final class SettingsStore {
    var settings: AppSettings {
        didSet {
            guard settings != oldValue else { return }
            scheduleSave()
            for observer in observers { observer(oldValue, settings) }
        }
    }

    @ObservationIgnored private var observers: [(AppSettings, AppSettings) -> Void] = []
    @ObservationIgnored private var saveWork: DispatchWorkItem?
    @ObservationIgnored private let defaults: UserDefaults
    private static let key = "settings.v1"

    /// `UT_DEFAULTS_SUITE` (testing) keeps settings in a separate defaults domain so evaluation runs
    /// start from defaults and never touch the user's settings.
    init(defaults: UserDefaults = ProcessInfo.processInfo.environment["UT_DEFAULTS_SUITE"]
        .flatMap { UserDefaults(suiteName: $0) } ?? .standard) {
        self.defaults = defaults
        settings = Self.load(from: defaults)
    }

    func observe(_ handler: @escaping (_ old: AppSettings, _ new: AppSettings) -> Void) {
        observers.append(handler)
    }

    func resetOverlay() { settings.overlay = OverlaySettings() }

    func exportJSON() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }

    func importJSON(_ data: Data) throws {
        settings = try Self.decodeMergingDefaults(data)
    }

    func saveNow() {
        saveWork?.cancel()
        if let data = try? JSONEncoder().encode(settings) {
            defaults.set(data, forKey: Self.key)
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private static func load(from defaults: UserDefaults) -> AppSettings {
        guard let data = defaults.data(forKey: key) else { return AppSettings() }
        return (try? decodeMergingDefaults(data)) ?? AppSettings()
    }

    /// Decodes stored settings on top of the current defaults, so settings saved by an older
    /// version (missing newer keys) still load instead of resetting everything.
    static func decodeMergingDefaults(_ data: Data) throws -> AppSettings {
        let defaultsObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AppSettings()))
        let stored = try JSONSerialization.jsonObject(with: data)
        let merged = merge(defaultsObject, stored)
        return try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: merged))
    }

    private static func merge(_ base: Any, _ overlay: Any) -> Any {
        guard let b = base as? [String: Any], let o = overlay as? [String: Any] else { return overlay }
        var result = b
        for (key, value) in o {
            result[key] = b[key].map { merge($0, value) } ?? value
        }
        return result
    }
}
