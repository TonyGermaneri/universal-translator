import AppKit
import SwiftUI
import TranslatorCore

/// Layout values the window controller shares with the SwiftUI content.
@MainActor
@Observable
final class OverlayLayout {
    var width: CGFloat = 900
    var isUnlocked = false
}

struct OverlayRootView: View {
    let settings: SettingsStore
    let captions: CaptionStore
    let layout: OverlayLayout
    var onHeightChange: (CGFloat) -> Void
    var onDrag: (DragPhase) -> Void
    var onResize: (DragPhase) -> Void

    enum DragPhase { case changed, ended }

    private var o: OverlaySettings { settings.settings.overlay }

    var body: some View {
        VStack(alignment: o.alignment.horizontal, spacing: 0) {
            if showsContent {
                CaptionBox(o: o, captions: captions, privacy: PrivacyStatus.of(settings.settings), isUnlocked: layout.isUnlocked,
                           textWidth: layout.width - (o.backgroundStyle == .box ? 2 * o.paddingH : 0))
                    .frame(maxWidth: o.backgroundStyle == .box && !fixedWidth ? nil : .infinity, alignment: o.alignment.frame)
            }
        }
        .frame(width: layout.width, alignment: o.alignment.frame)
        .fixedSize(horizontal: false, vertical: true)
        .padding(layout.isUnlocked ? 6 : 0)
        .overlay { if layout.isUnlocked { unlockedChrome } }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { onHeightChange($0) }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: o.anchor.isTop ? .top : .bottom)
        .opacity(o.opacity)
    }

    private var fixedWidth: Bool { o.fixedWidthBox }

    private var showsContent: Bool {
        captions.hasVisibleText || captions.status != .idle || layout.isUnlocked
    }

    private var unlockedChrome: some View {
        ZStack(alignment: .bottomTrailing) {
            RoundedRectangle(cornerRadius: max(o.cornerRadius, 8) + 4)
                .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                .background(Color.accentColor.opacity(0.06), in: RoundedRectangle(cornerRadius: max(o.cornerRadius, 8) + 4))
                .contentShape(Rectangle())
                .gesture(windowDrag(onDrag))
            Image(systemName: "arrow.left.and.right")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .padding(6)
                .background(Circle().fill(Color.accentColor))
                .padding(4)
                .gesture(windowDrag(onResize))
                .help("Drag to change the overlay width")
        }
        .overlay(alignment: .top) {
            Text("Drag to position · lock with the menu bar icon")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Capsule().fill(Color.accentColor))
                .offset(y: -10)
                .allowsHitTesting(false)
        }
    }

    private func windowDrag(_ handler: @escaping (DragPhase) -> Void) -> some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { _ in handler(.changed) }
            .onEnded { _ in handler(.ended) }
    }
}

/// The styled caption block: original text, translation (committed, fading-in, revised and provisional
/// runs), background, status dot and lag badge.
struct CaptionBox: View {
    let o: OverlaySettings
    let captions: CaptionStore
    let privacy: PrivacyStatus
    let isUnlocked: Bool
    /// Widest the text can be laid out, used to keep only the last N lines of rolling captions.
    let textWidth: CGFloat

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var body: some View {
        // Re-render at animation rate only while words are fading in or a revision is highlighted.
        let _ = captions.effectsVersion
        let _ = captions.refreshVersion
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !captions.hasActiveEffects(at: Date()))) { context in
            content(now: context.date)
        }
    }

    private func content(now: Date) -> some View {
        VStack(alignment: o.alignment.horizontal, spacing: o.fontSize * 0.18) {
            if o.showSource, o.sourceAbove, !sourceLine.isEmpty { source }
            translation(now: now)
            if o.showSource, !o.sourceAbove, !sourceLine.isEmpty { source }
        }
        .multilineTextAlignment(o.alignment.text)
        .padding(.horizontal, o.backgroundStyle == .box ? o.paddingH : 0)
        .padding(.vertical, o.backgroundStyle == .box ? o.paddingV : 0)
        .frame(minWidth: o.backgroundStyle == .box ? o.fontSize * 3 : 0)
        .background { background }
        .overlay(alignment: .topLeading) { statusDot }
        .overlay(alignment: .topTrailing) { lagBadge }
    }

    // MARK: Runs

    /// A piece of caption text with its style.
    struct Run {
        enum Kind { case committed, fresh(Double), revised(Double), ghost }
        var text: String
        var kind: Kind
    }

    private var paragraph: ArraySlice<CaptionStore.Sentence> { captions.paragraph }

    /// The paragraph as styled runs, in reading order.
    private func runs(now: Date) -> [Run] {
        var result: [Run] = []
        var previousText = ""
        for sentence in paragraph {
            var pieces = sentenceRuns(sentence, now: now)
            if !o.showProvisional { pieces.removeAll { if case .ghost = $0.kind { return true }; return false } }
            let text = pieces.map(\.text).joined()
            guard !text.isEmpty else { continue }
            // Separate sentences the way the target script does.
            if !previousText.isEmpty, TextJoiner.join(previousText, text) != previousText + text,
               let first = pieces.first, !first.text.hasPrefix(" ") {
                pieces[0].text = " " + first.text
            }
            result += pieces
            previousText = text
        }
        return result
    }

    private func sentenceRuns(_ s: CaptionStore.Sentence, now: Date) -> [Run] {
        let chars = Array(s.committed)
        var runs: [Run] = []
        // Fade-in: characters committed in the last moments go from provisional to full strength.
        let sinceGrew = now.timeIntervalSince(s.committedGrewAt)
        let fadeStart = (o.fadeInNewWords && !reduceMotion && sinceGrew < CaptionStore.fadeInDuration)
            ? min(s.committedLengthBefore, chars.count) : chars.count
        let fade = min(1, max(0, sinceGrew / CaptionStore.fadeInDuration))
        // Revision highlight: changed characters glow, then fade back to the text color.
        var highlighted = Set<Int>()
        var glow = 0.0
        if o.highlightRevisions, let revisedAt = s.revisedAt {
            let t = now.timeIntervalSince(revisedAt)
            if t < CaptionStore.highlightDuration {
                // Hold briefly, then ease back to the text color; never fully saturated.
                glow = 0.75 * (reduceMotion ? 1 : 1 - max(0, (t - 0.5) / (CaptionStore.highlightDuration - 0.5)))
                for range in s.revisedRanges { highlighted.formUnion(range.clamped(to: 0..<chars.count)) }
            }
        }
        var current = ""
        var currentKind: Run.Kind = .committed
        func kindAt(_ i: Int) -> Run.Kind {
            if highlighted.contains(i) { return .revised(glow) }
            if i >= fadeStart { return .fresh(fade) }
            return .committed
        }
        func same(_ a: Run.Kind, _ b: Run.Kind) -> Bool {
            switch (a, b) {
            case (.committed, .committed), (.ghost, .ghost): return true
            case (.fresh, .fresh), (.revised, .revised): return true
            default: return false
            }
        }
        for (i, ch) in chars.enumerated() {
            let kind = kindAt(i)
            if !current.isEmpty, !same(kind, currentKind) {
                runs.append(Run(text: current, kind: currentKind))
                current = ""
            }
            currentKind = kind
            current.append(ch)
        }
        if !current.isEmpty { runs.append(Run(text: current, kind: currentKind)) }
        if !s.isFinished, !s.ghost.isEmpty { runs.append(Run(text: s.ghost, kind: .ghost)) }
        return runs
    }

    /// Keeps only the runs that fall on the last `maxLines` wrapped lines.
    private func fitted(_ runs: [Run], maxLines: Int) -> [Run] {
        let measured = NSMutableAttributedString()
        for run in runs {
            let italic: Bool = { if case .ghost = run.kind { return o.provisionalItalic }; return false }()
            measured.append(NSAttributedString(string: run.text, attributes: [
                .font: nsFont(scale: 1, italic: italic), .paragraphStyle: paragraphStyle,
            ]))
        }
        let lines = CaptionFitter.lines(measured, width: textWidth)
        guard lines.count > maxLines else { return runs }
        // The reading-speed limit may keep a line that hasn't been on screen long enough.
        captions.governor.charactersPerSecond = o.readingSpeed
        captions.governor.extraLines = o.readingExtraLines
        let now = ProcessInfo.processInfo.systemUptime
        let (count, recheck) = captions.governor.visibleCount(lines: lines.map(\.text), maxLines: maxLines, now: now)
        if let recheck { captions.scheduleRefresh(at: recheck) }
        let start = lines[lines.count - count].start
        guard start > 0 else { return runs }
        var remaining = start
        var result: [Run] = []
        for run in runs {
            let length = run.text.utf16.count
            if remaining >= length {
                remaining -= length
                continue
            }
            var trimmed = run
            if remaining > 0 {
                trimmed.text = String(run.text.utf16.dropFirst(remaining)) ?? run.text
                remaining = 0
            }
            result.append(trimmed)
        }
        return result
    }

    private func attributed(_ runs: [Run], override: Color?) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            switch run.kind {
            case .committed:
                piece.foregroundColor = override ?? o.textColor.color
            case .fresh(let t):
                let opacity = o.provisionalOpacity + (1 - o.provisionalOpacity) * t
                piece.foregroundColor = override ?? o.textColor.color.opacity(opacity)
            case .revised(let glow):
                piece.foregroundColor = override ?? mix(o.textColor, o.revisionColor, glow)
            case .ghost:
                piece.foregroundColor = override ?? o.textColor.color.opacity(o.provisionalOpacity)
                if o.provisionalItalic { piece.font = font(scale: 1).italic() }
            }
            out += piece
        }
        return out
    }

    private func mix(_ a: RGBA, _ b: RGBA, _ t: Double) -> Color {
        let t = min(max(t, 0), 1)
        return RGBA(a.r + (b.r - a.r) * t, a.g + (b.g - a.g) * t, a.b + (b.b - a.b) * t, a.a + (b.a - a.a) * t).color
    }

    // MARK: Translation

    private var statusMessage: String? {
        switch captions.status {
        case .preparing(let message): return message
        case .error(let message): return message
        case .listening where !captions.hasVisibleText: return isUnlocked ? "Caption preview" : "Listening…"
        case .paused where !captions.hasVisibleText: return "Paused"
        case .idle where isUnlocked && !captions.hasVisibleText: return "Caption preview"
        default: return nil
        }
    }

    @ViewBuilder private func translation(now: Date) -> some View {
        if let statusMessage {
            styled { color in
                Text(statusMessage).foregroundColor(color ?? o.textColor.color.opacity(0.7))
            }
            .font(font(scale: 0.6))
        } else if o.layout == .rolling {
            let visible = fitted(runs(now: now), maxLines: o.maxLines)
            styled { color in Text(attributed(visible, override: color)) }
                .fixedSize(horizontal: false, vertical: true)
                .font(font(scale: 1))
                .transaction { $0.animation = nil }
        } else {
            stackedLines(now: now)
        }
    }

    @ViewBuilder private func stackedLines(now: Date) -> some View {
        let lines = Array(paragraph.suffix(max(1, o.maxLines)))
        VStack(alignment: o.alignment.horizontal, spacing: o.lineSpacing + 2) {
            ForEach(Array(lines.enumerated()), id: \.element.id) { index, sentence in
                let isLatest = index == lines.count - 1
                styled { color in
                    Text(attributed(sentenceRuns(sentence, now: now), override: color))
                }
                .font(font(scale: 1))
                .opacity(isLatest ? 1 : o.olderLineOpacity)
                .transition(lineTransition)
            }
        }
        .animation(o.textAnimation == .none ? nil : .easeOut(duration: o.animationDuration), value: lines.map(\.id))
    }

    private var lineTransition: AnyTransition {
        switch o.textAnimation {
        case .none: return .identity
        case .fade: return .opacity
        case .slideUp: return .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity)
        }
    }

    // MARK: Source

    private var sourceLine: String {
        let committed = paragraph.reduce("") { TextJoiner.join($0, $1.source) }
        return TextJoiner.join(committed, captions.liveSource)
    }

    private var source: some View {
        let text = CaptionFitter.recentTail(sourceLine)
        let attributed = NSAttributedString(string: text, attributes: [
            .font: nsFont(scale: o.sourceScale, weight: .regular), .paragraphStyle: paragraphStyle,
        ])
        let start = CaptionFitter.tailStart(attributed, width: textWidth, maxLines: o.sourceMaxLines)
        let visible = start > 0 ? (String(text.utf16.dropFirst(start)) ?? text) : text
        return styled { color in
            Text(visible).foregroundColor(color ?? o.sourceColor.color)
        }
        .fixedSize(horizontal: false, vertical: true)
        .font(font(scale: o.sourceScale, weight: .regular))
        .transaction { $0.animation = nil }
    }

    // MARK: Styling

    private var paragraphStyle: NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineSpacing = o.lineSpacing
        return style
    }

    private func font(scale: Double, weight: Font.Weight? = nil) -> Font {
        let size = max(8, o.fontSize * scale)
        let w = weight ?? o.fontWeight.weight
        if o.fontFamily.isEmpty { return .system(size: size, weight: w) }
        return .custom(o.fontFamily, size: size).weight(w)
    }

    /// AppKit equivalent of `font(scale:weight:)`, for measuring line breaks.
    private func nsFont(scale: Double, weight: NSFont.Weight? = nil, italic: Bool = false) -> NSFont {
        let size = max(8, o.fontSize * scale)
        let w = weight ?? o.fontWeight.nsWeight
        var font: NSFont
        if o.fontFamily.isEmpty {
            font = .systemFont(ofSize: size, weight: w)
        } else {
            let descriptor = NSFontDescriptor(fontAttributes: [.family: o.fontFamily])
                .addingAttributes([.traits: [NSFontDescriptor.TraitKey.weight: w]])
            font = NSFont(descriptor: descriptor, size: size) ?? .systemFont(ofSize: size, weight: w)
        }
        if italic {
            font = NSFont(descriptor: font.fontDescriptor.withSymbolicTraits(.italic), size: size) ?? font
        }
        return font
    }

    /// Renders text with optional outline (stroke) and shadow.
    private func styled(_ make: @escaping (Color?) -> Text) -> some View {
        OutlinedText(make: make, strokeWidth: o.strokeWidth, strokeColor: o.strokeColor.color, lineSpacing: o.lineSpacing)
            .compositingGroup()
            .shadow(color: o.shadowEnabled ? o.shadowColor.color : .clear, radius: o.shadowEnabled ? o.shadowRadius : 0, x: 0, y: 1)
    }

    @ViewBuilder private var background: some View {
        if o.backgroundStyle == .box {
            let shape = RoundedRectangle(cornerRadius: o.cornerRadius, style: .continuous)
            ZStack {
                if o.backgroundBlur {
                    VisualEffectBackground().clipShape(shape)
                }
                shape.fill(o.backgroundColor.color)
            }
            .overlay {
                if o.borderWidth > 0 { shape.strokeBorder(o.borderColor.color, lineWidth: o.borderWidth) }
            }
        }
    }

    @ViewBuilder private var statusDot: some View {
        if o.showStatusIndicator, captions.status != .idle {
            HStack(spacing: 4) {
                StatusDot(status: captions.status, speaking: captions.isSpeaking)
                if o.showPrivacyIndicator {
                    Image(systemName: privacy.symbol)
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(privacy.leavesMac ? Color.orange : Color.white.opacity(0.45))
                        .help(privacy.summary)
                }
            }
            .padding(o.backgroundStyle == .box ? 7 : 0)
            .offset(x: o.backgroundStyle == .box ? 0 : -24)
        }
    }

    @ViewBuilder private var lagBadge: some View {
        if captions.status == .paused, captions.hasVisibleText {
            Label("Paused", systemImage: "pause.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.gray.opacity(0.6)))
                .padding(6)
        } else if o.showLagIndicator, captions.status == .listening, captions.lag >= 2.5 {
            Text(String(format: "%.0f s behind", captions.lag))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Color.orange.opacity(0.55)))
                .padding(6)
        }
    }
}

/// Text drawn several times around itself in the stroke color, then once on top in its own colors.
struct OutlinedText: View {
    let make: (Color?) -> Text
    let strokeWidth: Double
    let strokeColor: Color
    let lineSpacing: Double

    var body: some View {
        ZStack {
            if strokeWidth > 0 {
                ForEach(offsets.indices, id: \.self) { i in
                    make(strokeColor).lineSpacing(lineSpacing).offset(x: offsets[i].width, y: offsets[i].height)
                }
            }
            make(nil).lineSpacing(lineSpacing)
        }
    }

    private var offsets: [CGSize] {
        let steps = strokeWidth > 2 ? 16 : 8
        return (0..<steps).map { i in
            let angle = Double(i) / Double(steps) * 2 * .pi
            return CGSize(width: cos(angle) * strokeWidth, height: sin(angle) * strokeWidth)
        }
    }
}

struct StatusDot: View {
    let status: CaptionStore.Status
    let speaking: Bool
    @State private var pulse = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .scaleEffect(speaking && pulse ? 1.35 : 1)
            .opacity(speaking ? 1 : 0.75)
            .shadow(color: color.opacity(0.8), radius: speaking ? 4 : 0)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { pulse = true }
            }
    }

    private var color: Color {
        switch status {
        case .error: return .red
        case .preparing: return .orange
        case .listening: return speaking ? Color(red: 1, green: 0.27, blue: 0.27) : .green
        case .idle: return .gray
        case .paused: return .yellow
        }
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Works out which part of a caption is visible when only the last N wrapped lines fit.
enum CaptionFitter {
    /// UTF-16 offset where the last `maxLines` lines of `text` begin when wrapped to `width` (0 if it all fits).
    static func tailStart(_ text: NSAttributedString, width: CGFloat, maxLines: Int) -> Int {
        let all = lines(text, width: width)
        guard maxLines > 0, all.count > maxLines else { return 0 }
        return all[all.count - maxLines].start
    }

    /// The wrapped lines of `text` at `width`: UTF-16 start offset and text of each.
    static func lines(_ text: NSAttributedString, width: CGFloat) -> [(start: Int, text: String)] {
        guard text.length > 0, width > 20 else { return text.length > 0 ? [(0, text.string)] : [] }
        let storage = NSTextStorage(attributedString: text)
        let layoutManager = NSLayoutManager()
        // A couple of points of slack so SwiftUI never wraps where TextKit didn't.
        let container = NSTextContainer(size: NSSize(width: width - 3, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: container)

        var lineStarts: [Int] = []
        var glyphIndex = 0
        while glyphIndex < layoutManager.numberOfGlyphs {
            var range = NSRange()
            layoutManager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &range)
            lineStarts.append(layoutManager.characterIndexForGlyph(at: range.location))
            glyphIndex = max(NSMaxRange(range), glyphIndex + 1)
        }
        let string = text.string as NSString
        return lineStarts.enumerated().map { i, start in
            let end = i + 1 < lineStarts.count ? lineStarts[i + 1] : string.length
            return (start, string.substring(with: NSRange(location: start, length: max(0, end - start))))
        }
    }

    /// Bounds the text measured on every update during a long, pause-free monologue.
    static func recentTail(_ text: String, limit: Int = 1200) -> String {
        guard text.count > limit else { return text }
        let tail = text.suffix(limit)
        if let space = tail.firstIndex(where: { $0.isWhitespace }), tail.distance(from: tail.startIndex, to: space) < 40 {
            return String(tail[tail.index(after: space)...])
        }
        return String(tail)
    }
}
