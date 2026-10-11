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
    private let layout = OverlayLayout()
    private let settings: SettingsStore
    private let captions: CaptionStore

    private var contentHeight: CGFloat = 80
    private var userHidden = false
    private var isVisible = false
    private var lastMouseScreen: NSScreen?
    private var drag: (mouse: NSPoint, frame: NSRect)?
    private var timer: Timer?

    var isShownByUser: Bool { !userHidden }
    var isLocked: Bool { settings.settings.overlay.clickThrough }

    init(settings: SettingsStore, captions: CaptionStore) {
        self.settings = settings
        self.captions = captions
        super.init()

        let root = OverlayRootView(
            settings: settings, captions: captions, layout: layout,
            onHeightChange: { [weak self] in self?.contentHeightChanged($0) },
            onDrag: { [weak self] in self?.handleMove($0) },
            onResize: { [weak self] in self?.handleResize($0) }
        )
        let host = NSHostingView(rootView: root)
        host.sizingOptions = []
        panel.contentView = host
        panel.alphaValue = 0

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

    func toggleLock() {
        settings.settings.overlay.clickThrough.toggle()
        if !settings.settings.overlay.clickThrough { userHidden = false }
        updateVisibility()
    }

    // MARK: Window configuration

    private func applyWindowSettings() {
        let o = settings.settings.overlay
        panel.level = o.level.windowLevel
        var behavior: NSWindow.CollectionBehavior = [.fullScreenAuxiliary, .ignoresCycle, .stationary]
        behavior.insert(o.allSpaces ? .canJoinAllSpaces : .moveToActiveSpace)
        panel.collectionBehavior = behavior
        panel.ignoresMouseEvents = o.clickThrough
        panel.sharingType = o.hideFromScreenCapture ? .none : .readOnly
        layout.isUnlocked = !o.clickThrough
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

        let chrome: CGFloat = layout.isUnlocked ? 12 : 0
        let width = max(240, min(visible.width - 2 * min(o.marginX, visible.width / 4), visible.width * o.widthFraction))
        layout.width = width
        let height = min(contentHeight, visible.height - 2 * o.marginY)
        let size = NSSize(width: width + chrome, height: max(height, 20))

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
            let cx = visible.minX + visible.width * o.customX
            let by = visible.minY + visible.height * o.customY
            origin = NSPoint(x: cx - size.width / 2, y: by)
        }
        origin.x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }

    private func contentHeightChanged(_ height: CGFloat) {
        guard abs(height - contentHeight) > 0.5 else { return }
        contentHeight = height
        reposition()
    }

    // MARK: Dragging (only when unlocked)

    private func handleMove(_ phase: OverlayRootView.DragPhase) {
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

    private func handleResize(_ phase: OverlayRootView.DragPhase) {
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

    private func saveCustomPosition() {
        let visible = targetScreen().visibleFrame
        let frame = panel.frame
        var o = settings.settings.overlay
        o.anchor = .custom
        o.customX = Double((frame.midX - visible.minX) / visible.width)
        o.customY = Double((frame.minY - visible.minY) / visible.height)
        if o.screenMode == .main, let screen = panel.screen, screen != NSScreen.screens.first {
            o.screenMode = .specific
            o.screenName = screen.localizedName
        }
        settings.settings.overlay = o
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
        if o.autoClearAfter > 0, captions.hasVisibleText, !captions.isSpeaking, captions.liveSource.isEmpty,
           captions.paragraph.last?.isFinished ?? true, idle > max(o.autoClearAfter, reading) {
            captions.clear()
        }
        let hasContent = captions.hasVisibleText || captions.status != .idle
        var show = !userHidden && (hasContent || layout.isUnlocked)
        if show, o.autoHide, !layout.isUnlocked, !captions.isSpeaking, idle > max(o.autoHideDelay, reading) {
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
