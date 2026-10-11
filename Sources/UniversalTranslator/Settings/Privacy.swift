import Foundation
import SystemConfiguration

/// Whether anything leaves this Mac with the current settings, for the privacy indicator.
///
/// Speech recognition, voice detection and the built-in translators (Hy-MT2, Apple Translation, Apple
/// Intelligence) all run on this Mac. The only way recognized text leaves it is an LM Studio server on another
/// machine. Audio never leaves the Mac. (Model downloads are a one-time fetch, not part of a session.)
struct PrivacyStatus: Equatable {
    /// Hosts that receive recognized text.
    var remoteHosts: [String]

    var leavesMac: Bool { !remoteHosts.isEmpty }
    var symbol: String { leavesMac ? "network" : "lock.fill" }
    var title: String { leavesMac ? "Sends text off this Mac" : "On this Mac only" }
    var summary: String {
        leavesMac
            ? "Recognized text (not audio) is sent to \(remoteHosts.joined(separator: ", ")) for translation."
            : "Audio, transcripts and translations never leave this Mac."
    }

    static func of(_ settings: AppSettings) -> PrivacyStatus {
        let t = settings.translation
        let usesLMStudio = t.backend == .lmStudio || (t.revision == .lmStudio && t.backend != .none)
        guard usesLMStudio, let host = host(of: t.lmStudioURL), !isLoopback(host) else { return PrivacyStatus(remoteHosts: []) }
        return PrivacyStatus(remoteHosts: [host])
    }

    static func host(of url: String) -> String? {
        var text = url.trimmingCharacters(in: .whitespaces)
        if !text.contains("://") { text = "http://" + text }
        return URL(string: text)?.host()
    }

    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h == "::1" || h.hasPrefix("127.") || h == "0.0.0.0" { return true }
        // This Mac's Bonjour name ("name.local"). Not `ProcessInfo.hostName`: that resolves DNS and blocks.
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String? {
            return h == local.lowercased() + ".local" || h == local.lowercased()
        }
        return false
    }
}
