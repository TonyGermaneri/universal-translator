import Foundation

/// Appends timestamped lines to the file named by `UT_DEBUG_LOG` (no-op otherwise). Used for testing.
enum DebugLog {
    /// "~" is the app's own folder on iOS.
    private static let url = ProcessInfo.processInfo.environment["UT_DEBUG_LOG"].map {
        URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
    }
    private static let start = Date()
    private static let queue = DispatchQueue(label: "debug-log")

    static func write(_ message: @autoclosure () -> String) {
        guard let url else { return }
        let line = String(format: "[%7.2f] ", Date().timeIntervalSince(start)) + message() + "\n"
        queue.async {
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? line.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
