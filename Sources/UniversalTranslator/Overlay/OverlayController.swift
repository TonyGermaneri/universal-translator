import AppKit
import SwiftUI

/// A borderless, transparent, non-activating panel that floats above other apps and never takes focus.
final class OverlayPanel: NSPanel {
    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 900, height: 120),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        becomesKeyOnlyIfNeeded = true
        isExcludedFromWindowsMenu = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Places, shows and hides the caption overlay according to the overlay settings.
@MainActor
final class OverlayController: NSObject {
    private let panel = OverlayPanel()
    private let grip = GripPanel()
    private var gripShown = false
    private var mouseLastOver: Date?
    private let layout = OverlayLayout()
    private let settings: SettingsStore
    private let captions: CaptionStore

    private var contentHeight: CGFloat = 80
    private var userHidden = false
    private var isVisible = false
    private var lastMouseScreen: NSScreen?
    private var drag: (mouse: NSPoint, frame: NSRect)?
    private var timer: Timer?
    private var hoverTimer: Timer?

    var isShownByUser: Bool { !userHidden }
    var isPositionLocked: Bool { settings.settings.overlay.lockPosition }

    init(settings: SettingsStore, captions: CaptionStore) {
        self.settings = settings
        self.captions = captions
        super.init()

        let root = OverlayRootView(
            settings: settings, captions: captions, layout: layout,
            onHeightChange: { [weak self] in self?.contentHeightChanged($0) }
        )
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        panel.alphaValue = 0
        grip.contentView = NSHostingView(rootView: GripView(onMove: { [weak self] in self?.handleMove($0) },
                                                            onResize: { [weak self] in self?.handleResize($0) }))

        applyWindowSettings()
        reposition()

        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }
        settings.observe { [weak self] old, new in
            guard let self, old.overlay != new.overlay else { return }
            self.applyWindowSettings()
            self.reposition()
            self.updateVisibility()
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // The grip follows the mouse more closely than captions need to.
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateGrip() }
        }
    }

    // MARK: Public controls

    func toggleShown() {
        userHidden.toggle()
        updateVisibility()
    }

    func setShown(_ shown: Bool) {
        userHidden = !shown
        updateVisibility()
    }

    /// Locks or unlocks the captions' position (whether hovering shows the move grip).
    func toggleLock() {
        settings.settings.overlay.lockPosition.toggle()
        updateGrip()
    }

    // MARK: Window configuration

    private func applyWindowSettings() {
        let o = settings.settings.overlay
        panel.level = o.level.windowLevel
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .stationary]
        behavior.insert(o.allSpaces ? .canJoinAllSpaces : .moveToActiveSpace)
        panel.collectionBehavior = behavior
        // The captions never take the mouse; only the grip does.
        panel.ignoresMouseEvents = true
        panel.sharingType = o.hideFromScreenCapture ? .none : .readOnly
        grip.level = panel.level
        grip.collectionBehavior = behavior
    }

    private func targetScreen() -> NSScreen {
        let o = settings.settings.overlay
        switch o.screenMode {
        case .main:
            return NSScreen.screens.first ?? NSScreen.main!
        case .withMouse:
            let mouse = NSEvent.mouseLocation
            return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main!
        case .specific:
            return NSScreen.screens.first { $0.localizedName == o.screenName } ?? NSScreen.screens.first ?? NSScreen.main!
        }
    }

    func reposition() {
        let o = settings.settings.overlay
        let screen = targetScreen()
        lastMouseScreen = screen
        let area = o.level == .aboveEverything ? screen.frame.insetBy(dx: 0, dy: 0) : screen.visibleFrame
        let visible = screen.visibleFrame

        let width = max(240, min(visible.width - 2 * min(o.marginX, visible.width / 4), visible.width * o.widthFraction))
        layout.width = width
        let height = min(contentHeight, visible.height - 2 * o.marginY)
        let size = NSSize(width: width, height: max(height, 20))

        var origin = NSPoint.zero
        let left = visible.minX + o.marginX
        let right = visible.maxX - o.marginX - size.width
        let centerX = visible.midX - size.width / 2
        let top = visible.maxY - o.marginY - size.height
        let bottom = (o.level == .aboveEverything ? max(area.minY, visible.minY) : visible.minY) + o.marginY
        let middleY = visible.midY - size.height / 2

        switch o.anchor {
        case .topLeading: origin = NSPoint(x: left, y: top)
        case .top: origin = NSPoint(x: centerX, y: top)
        case .topTrailing: origin = NSPoint(x: right, y: top)
        case .leading: origin = NSPoint(x: left, y: middleY)
        case .center: origin = NSPoint(x: centerX, y: middleY)
        case .trailing: origin = NSPoint(x: right, y: middleY)
        case .bottomLeading: origin = NSPoint(x: left, y: bottom)
        case .bottom: origin = NSPoint(x: centerX, y: bottom)
        case .bottomTrailing: origin = NSPoint(x: right, y: bottom)
        case .custom:
            // Keep the bottom edge fixed so the caption grows upward as lines are added.
            origin = Self.customOrigin(x: o.customX, y: o.customY, size: size, in: visible)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        if gripShown { grip.setFrame(Self.gripFrame(for: panel.frame, size: GripPanel.size, in: visible), display: true) }
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        reposition()
    }

    // MARK: The grip: shown while the mouse is over the captions; dragging it moves them

    private func updateGrip() {
        let mouse = NSEvent.mouseLocation
        let over = isVisible && (panel.frame.insetBy(dx: -8, dy: -8).contains(mouse) || (gripShown && grip.frame.contains(mouse)))
        if over { mouseLastOver = Date() }
        let show = Self.showsGrip(locked: isPositionLocked, captionsShown: isVisible, dragging: drag != nil, mouseOver: over,
                                  secondsSinceOver: mouseLastOver.map { Date().timeIntervalSince($0) })
        guard show != gripShown else { return }
        gripShown = show
        if show {
            let visible = (panel.screen ?? targetScreen()).visibleFrame
            grip.setFrame(Self.gripFrame(for: panel.frame, size: GripPanel.size, in: visible), display: true)
            panel.addChildWindow(grip, ordered: .above)
            grip.orderFrontRegardless()
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.15
            grip.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.gripShown else { return }
                self.panel.removeChildWindow(self.grip)
                self.grip.orderOut(nil)
            }
        })
    }

    // MARK: Dragging (from the grip)

    private func handleMove(_ phase: DragPhase) {
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .changed:
            if drag == nil { drag = (mouse, panel.frame) }
            guard let drag else { return }
            panel.setFrameOrigin(NSPoint(x: drag.frame.minX + mouse.x - drag.mouse.x,
                                         y: drag.frame.minY + mouse.y - drag.mouse.y))
        case .ended:
            drag = nil
            saveCustomPosition()
        }
    }

    private func handleResize(_ phase: DragPhase) {
        let mouse = NSEvent.mouseLocation
        switch phase {
        case .changed:
            if drag == nil { drag = (mouse, panel.frame) }
            guard let drag else { return }
            let o = settings.settings.overlay
            let centered = [.top, .center, .bottom, .custom].contains(o.anchor)
            let delta = (mouse.x - drag.mouse.x) * (centered ? 2 : 1)
            let visible = targetScreen().visibleFrame
            settings.settings.overlay.widthFraction = min(1, max(0.2, (drag.frame.width + delta) / visible.width))
        case .ended:
            drag = nil
        }
    }

    /// Remembers where the overlay was dropped, measured on the display it was dropped on (which may not be the one
    /// it started on), and switches to that display if the display setting would put it elsewhere.
    private func saveCustomPosition() {
        let screen = panel.screen ?? targetScreen()
        var o = settings.settings.overlay
        let position = Self.customPosition(of: panel.frame, in: screen.visibleFrame)
        o.anchor = .custom
        (o.customX, o.customY) = (position.x, position.y)
        (o.screenMode, o.screenName) = Self.screenSetting(afterDropOn: screen.localizedName,
                                                          target: targetScreen().localizedName,
                                                          mode: o.screenMode, name: o.screenName)
        settings.settings.overlay = o
    }

    /// A frame's place on a display as `customX`/`customY`: its bottom center, as fractions of the visible area.
    nonisolated static func customPosition(of frame: NSRect, in visible: NSRect) -> (x: Double, y: Double) {
        (Double((frame.midX - visible.minX) / visible.width), Double((frame.minY - visible.minY) / visible.height))
    }

    /// The inverse: the origin of a frame of `size` placed at `x`, `y` (before clamping to the display).
    nonisolated static func customOrigin(x: Double, y: Double, size: NSSize, in visible: NSRect) -> NSPoint {
        NSPoint(x: visible.minX + visible.width * x - size.width / 2, y: visible.minY + visible.height * y)
    }

    /// The display setting after a drop: unchanged if it already picks the display the overlay landed on, otherwise
    /// that display by name (so "main display" or "display with the mouse" doesn't pull it back).
    nonisolated static func screenSetting(afterDropOn dropped: String, target: String, mode: ScreenMode,
                                          name: String) -> (mode: ScreenMode, name: String) {
        dropped == target ? (mode, name) : (.specific, dropped)
    }

    // MARK: Visibility

    private func tick() {
        if settings.settings.overlay.screenMode == .withMouse {
            let mouse = NSEvent.mouseLocation
            if let current = lastMouseScreen, !NSMouseInRect(mouse, current.frame, false) { reposition() }
        }
        updateVisibility()
    }

    private func updateVisibility() {
        let o = settings.settings.overlay
        let idle = Date().timeIntervalSince(captions.lastActivity)
        // Never hide or clear text before it's had time to be read.
        let reading = captions.readingTimeOfLatest(charactersPerSecond: o.readingSpeed)
        // Marquee text that is still crossing the screen isn't cut off either.
        let scrolling = captions.isScrolling
        if captions.shouldAutoClear(after: o.autoClearAfter, readingSpeed: o.readingSpeed) {
            captions.clear()
        }
        let hasContent = captions.hasVisibleText || captions.status != .idle
        var show = !userHidden && hasContent
        // Not while the mouse is on the grip: the captions shouldn't fade out from under a drag.
        if show, o.autoHide, !gripShown, !captions.isSpeaking, !scrolling, idle > max(o.autoHideDelay, reading) {
            if case .preparing = captions.status {} else { show = false }
        }
        guard show != isVisible else { return }
        isVisible = show
        if show {
            panel.orderFrontRegardless()
        }
        let fade = max(0.05, o.animationDuration)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = show ? fade : fade * 2
            panel.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isVisible else { return }
                self.panel.orderOut(nil)
                // Text that faded out with the window shouldn't reappear when it comes back.
                self.captions.breakParagraph()
            }
        })
    }
}
