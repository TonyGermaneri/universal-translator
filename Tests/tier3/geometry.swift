// Prints the displays and (given a process id) that process's windows as JSON, all in global screen coordinates
// with the origin at the top left of the main display, for tier3's overlay placement test.
//   swift Tests/tier3/geometry.swift [pid]
import AppKit

var screens: [[String: Any]] = []
for screen in NSScreen.screens {
    guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { continue }
    let b = CGDisplayBounds(id)
    screens.append(["name": screen.localizedName, "x": b.minX, "y": b.minY, "w": b.width, "h": b.height])
}
var windows: [[String: Any]] = []
if CommandLine.arguments.count > 1, let pid = Int32(CommandLine.arguments[1]) {
    let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        let b = w[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
        windows.append(["layer": w[kCGWindowLayer as String] as? Int ?? -1,
                        "onscreen": w[kCGWindowIsOnscreen as String] as? Bool ?? false,
                        "x": b["X"] ?? 0, "y": b["Y"] ?? 0, "w": b["Width"] ?? 0, "h": b["Height"] ?? 0])
    }
}
let data = try JSONSerialization.data(withJSONObject: ["screens": screens, "windows": windows])
print(String(decoding: data, as: UTF8.self))
