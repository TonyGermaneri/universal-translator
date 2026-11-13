#if os(macOS)
import AppKit
import SwiftUI

/// The phases of a drag on the grip.
enum DragPhase { case changed, ended }

/// The small handle that shows above the captions while the mouse is over them: drag it to move the captions (onto
/// another display too), or its ↔ end to change their width. It's a window of its own, a child of the caption panel
/// so it moves with it, and the only part of the overlay that takes the mouse: the captions always let clicks through.
final class GripPanel: NSPanel {
    static let size = NSSize(width: 92, height: 26)

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        isExcludedFromWindowsMenu = true
        // A control, not content: never in screen recordings or shares.
        sharingType = .none
        alphaValue = 0
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

struct GripView: View {
    var onMove: (DragPhase) -> Void
    var onResize: (DragPhase) -> Void

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                .frame(width: 57, height: GripPanel.size.height)
                .contentShape(Rectangle())
                .gesture(drag(onMove))
                .help("Drag to move the captions, onto another display too")
            Rectangle().fill(.white.opacity(0.45)).frame(width: 1, height: 14)
            Image(systemName: "arrow.left.and.right")
                .frame(width: 34, height: GripPanel.size.height)
                .contentShape(Rectangle())
                .gesture(drag(onResize))
                .help("Drag to change the captions' width")
        }
        .font(.system(size: 11, weight: .bold))
        .foregroundStyle(.white)
        .background(Capsule().fill(Color.accentColor))
        .frame(width: GripPanel.size.width, height: GripPanel.size.height)
    }

    private func drag(_ handler: @escaping (DragPhase) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { _ in handler(.changed) }
            .onEnded { _ in handler(.ended) }
    }
}

extension OverlayController {
    /// How long the grip stays after the mouse leaves, so it can travel from the captions to the grip.
    nonisolated static let gripLinger: TimeInterval = 0.6

    /// Where the grip goes: centered on the captions' top edge, half above it, kept on the display.
    nonisolated static func gripFrame(for overlay: NSRect, size: NSSize, in visible: NSRect) -> NSRect {
        var origin = NSPoint(x: overlay.midX - size.width / 2, y: overlay.maxY - size.height / 2)
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return NSRect(origin: origin, size: size)
    }

    /// Whether the grip shows: never with the position locked or the captions hidden; otherwise while dragging, while
    /// the mouse is over the captions or the grip, and for `gripLinger` after it leaves.
    nonisolated static func showsGrip(locked: Bool, captionsShown: Bool, dragging: Bool, mouseOver: Bool,
                                      secondsSinceOver: TimeInterval?) -> Bool {
        guard !locked, captionsShown else { return false }
        if dragging || mouseOver { return true }
        return (secondsSinceOver ?? .infinity) < gripLinger
    }
}
#endif
