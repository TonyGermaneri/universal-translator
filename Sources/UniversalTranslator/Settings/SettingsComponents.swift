import AppKit
import SwiftUI

/// A slider with its title, current value and optional explanation.
struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double? = nil
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(format(value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: $value, in: range, step: step)
            } else {
                Slider(value: $value, in: range)
            }
            if let help {
                Text(help)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

enum Fmt {
    static func seconds(_ v: Double) -> String { String(format: "%.2f s", v) }
    static func points(_ v: Double) -> String { String(format: "%.0f pt", v) }
    static func percent(_ v: Double) -> String { String(format: "%.0f%%", v * 100) }
    static func decimal(_ v: Double) -> String { String(format: "%.1f", v) }
}

struct ColorRow: View {
    let title: String
    @Binding var color: RGBA

    var body: some View {
        ColorPicker(title, selection: Binding(get: { color.color }, set: { color = RGBA($0) }), supportsOpacity: true)
    }
}

/// Explanatory text under a form section.
struct Note: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Click, then press a key combination to record a global shortcut.
struct HotkeyRecorder: View {
    let title: String
    @Binding var hotkey: Hotkey
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            Button {
                recording ? stopRecording() : startRecording()
            } label: {
                Text(recording ? "Press shortcut…" : (hotkey.isSet ? hotkey.display : "None"))
                    .frame(minWidth: 120)
                    .monospaced()
            }
            .buttonStyle(.bordered)
            .tint(recording ? .accentColor : nil)
            Button {
                hotkey = .none
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.borderless)
            .disabled(!hotkey.isSet)
            .help("Remove shortcut")
        }
        .onDisappear(perform: stopRecording)
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            if event.keyCode == 53 { // Escape cancels
                stopRecording()
                return nil
            }
            guard !flags.isEmpty else { return nil } // global shortcuts need a modifier
            hotkey = Hotkey(keyCode: UInt32(event.keyCode),
                            modifiers: HotkeyCenter.carbonModifiers(flags),
                            display: HotkeyCenter.display(keyCode: event.keyCode,
                                                          characters: event.charactersIgnoringModifiers,
                                                          flags: flags))
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

/// 3×3 grid for choosing where the overlay sits on screen.
struct AnchorPicker: View {
    @Binding var anchor: OverlayAnchor

    private let grid: [[OverlayAnchor]] = [
        [.topLeading, .top, .topTrailing],
        [.leading, .center, .trailing],
        [.bottomLeading, .bottom, .bottomTrailing],
    ]

    var body: some View {
        VStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 4) {
                    ForEach(grid[row]) { cell in
                        Button {
                            anchor = cell
                        } label: {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(anchor == cell ? Color.accentColor : Color.secondary.opacity(0.25))
                                .frame(width: 34, height: 20)
                        }
                        .buttonStyle(.plain)
                        .help(cell.title)
                    }
                }
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.4)))
    }
}

/// Horizontal input level bar in dBFS.
struct LevelMeter: View {
    let level: Double

    var body: some View {
        GeometryReader { geo in
            let fraction = max(0, min(1, (level + 70) / 70))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(LinearGradient(colors: [.green, .yellow, .red], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * fraction)
                    .mask(alignment: .leading) { Capsule().frame(width: geo.size.width) }
            }
        }
        .frame(height: 6)
        .animation(.linear(duration: 0.08), value: level)
    }
}
