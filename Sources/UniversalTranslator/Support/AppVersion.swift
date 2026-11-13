import Foundation

/// Which build this is, as Settings → Permissions & About shows it: "0.1.0 (v0.1.0-23-gd7ab774, built 2026-10-27
/// 09:27)". The marketing version alone said "0.1.0" for every build since that tag; scripts/build-app.sh stamps the
/// git description (`UTBuildDescription`, also the release zip's name) and the build time (`CFBundleVersion`,
/// yyyyMMddHHmm).
enum AppVersion {
    static var current: String { text(info: Bundle.main.infoDictionary ?? [:]) }

    static func text(info: [String: Any]) -> String {
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        var details: [String] = []
        if let describe = info["UTBuildDescription"] as? String, !describe.isEmpty { details.append(describe) }
        if let build = info["CFBundleVersion"] as? String { details.append(builtText(build)) }
        return details.isEmpty ? version : "\(version) (\(details.joined(separator: ", ")))"
    }

    /// "202610270927" → "built 2026-10-27 09:27"; anything else as "build <value>".
    static func builtText(_ build: String) -> String {
        let digits = Array(build)
        guard digits.count == 12, digits.allSatisfy(\.isNumber) else { return "build \(build)" }
        func part(_ r: Range<Int>) -> String { String(digits[r]) }
        return "built \(part(0..<4))-\(part(4..<6))-\(part(6..<8)) \(part(8..<10)):\(part(10..<12))"
    }
}
