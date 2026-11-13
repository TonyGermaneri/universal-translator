#if os(macOS)
import AppKit
import CoreText
import SwiftUI
import TranslatorCore

/// Caption text with readings (furigana, pinyin, zhuyin) under it, or in another script. SwiftUI's Text doesn't draw ruby, so text with a reading aid
/// on is drawn by Core Text instead.
enum Ruby {
    /// Readings take this fraction of the text size.
    static let sizeFactor: CGFloat = 0.5

    /// `text` with the aids applied: characters in the script chosen, and each reading attached under its piece of
    /// text, in that piece's color.
    @MainActor
    static func annotated(_ text: NSAttributedString, aids: [ReadingAid]) -> NSAttributedString {
        guard !aids.isEmpty else { return text }
        let out = NSMutableAttributedString(attributedString: text)
        var location = 0
        for segment in segments(text.string, aids: aids) {
            let length = segment.text.utf16.count
            defer { location += length }
            guard length > 0, location + length <= out.length else { continue }
            let range = NSRange(location: location, length: length)
            if out.attributedSubstring(from: range).string != segment.text {
                // Same length: replace style run by style run so each keeps its own color and font.
                let replacement = segment.text as NSString
                var runs: [NSRange] = []
                out.enumerateAttributes(in: range) { _, run, _ in runs.append(run) }
                for run in runs {
                    out.replaceCharacters(in: run, with: replacement.substring(with: NSRange(location: run.location - location, length: run.length)))
                }
            }
            guard let reading = segment.reading else { continue }
            let color = out.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor ?? .white
            out.addAttribute(.ctRuby, value: annotation(spaced(reading, aids: aids), color: color),
                             range: NSRange(location: location, length: length))
        }
        return out
    }

    /// Pinyin syllables are about as wide as their characters, so side by side they run together ("menxiān"): a thin
    /// space either side keeps them apart (the characters spread a little to make room). Zhuyin symbols have no word
    /// shapes to tell syllables apart, and with thin spaces ㄐㄧㄚㄐㄧㄣㄊㄧㄢ read as one run: they get an en space.
    static func spaced(_ reading: String, aids: [ReadingAid]) -> String {
        if aids.contains(.zhuyin) { return "\u{2002}" + reading + "\u{2002}" }
        return aids.contains(.pinyin) ? "\u{2009}" + reading + "\u{2009}" : reading
    }

    /// A reading under its text (Core Text's "after" side, which is below for horizontal text).
    static func annotation(_ reading: String, color: NSColor) -> CTRubyAnnotation {
        let attributes: [CFString: Any] = [
            kCTRubyAnnotationSizeFactorAttributeName: sizeFactor,
            kCTForegroundColorAttributeName: color.cgColor,
        ]
        return CTRubyAnnotationCreateWithAttributes(.center, .auto, .after, reading as CFString, attributes as CFDictionary)
    }

    /// Segments are worked out once per distinct text; captions re-render many times a second.
    @MainActor private static var cache: [String: [ReadingSegment]] = [:]

    @MainActor
    static func segments(_ text: String, aids: [ReadingAid]) -> [ReadingSegment] {
        let name = ReadingAid.stored(aids)
        let key = name + "|" + text
        if let hit = cache[key] { return hit }
        if cache.count > 400 { cache.removeAll() }
        let segments = ReadingAid.segments(text, aids: aids)
        cache[key] = segments
        let shown = segments.map { s in s.reading.map { "\(s.text)(\($0))" } ?? s.text }.joined()
        if shown != text {
            DebugLog.write("READING \(name) " + shown)
        }
        return segments
    }

    /// Size of `text` laid out at most `width` wide (unlimited when nil), readings included.
    static func size(of text: NSAttributedString, width: CGFloat?) -> CGSize {
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let fit = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter, CFRange(), nil, CGSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude), nil)
        return CGSize(width: ceil(fit.width) + 1, height: ceil(fit.height))
    }

    /// Single-line width, as the marquee measures its pieces.
    static func lineWidth(of text: NSAttributedString) -> Double {
        Double(ceil(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)))
    }

    /// How much taller a line with readings is than one without, in `font`.
    static func extraHeight(font: NSFont) -> CGFloat {
        let plain = NSAttributedString(string: "漢", attributes: [.font: font])
        let annotated = NSMutableAttributedString(attributedString: plain)
        annotated.addAttribute(.ctRuby, value: annotation("かん", color: .white), range: NSRange(location: 0, length: 1))
        return max(0, size(of: annotated, width: nil).height - size(of: plain, width: nil).height)
    }
}

extension NSAttributedString.Key {
    static let ctRuby = NSAttributedString.Key(kCTRubyAnnotationAttributeName as String)
}

/// Attributed text (with readings) drawn by Core Text, wrapping to the width it's offered.
struct RubyText: NSViewRepresentable {
    let text: NSAttributedString

    func makeNSView(context: Context) -> RubyTextView { RubyTextView() }

    func updateNSView(_ view: RubyTextView, context: Context) {
        view.text = text
        view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: RubyTextView, context: Context) -> CGSize? {
        Ruby.size(of: text, width: proposal.width)
    }
}

final class RubyTextView: NSView {
    var text = NSAttributedString()

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let framesetter = CTFramesetterCreateWithAttributedString(text)
        let frame = CTFramesetterCreateFrame(framesetter, CFRange(), CGPath(rect: bounds, transform: nil), nil)
        context.textMatrix = .identity
        CTFrameDraw(frame, context)
    }
}

/// `RubyText` with an outline: drawn several times around itself in the stroke color, then once on top, as
/// `OutlinedText` does for SwiftUI text.
struct OutlinedRubyText: View {
    let make: (NSColor?) -> NSAttributedString
    let strokeWidth: Double
    let strokeColor: NSColor

    var body: some View {
        ZStack {
            if strokeWidth > 0 {
                let offsets = OutlinedText.offsets(strokeWidth: strokeWidth)
                ForEach(offsets.indices, id: \.self) { i in
                    RubyText(text: make(strokeColor)).offset(x: offsets[i].width, y: offsets[i].height)
                }
            }
            RubyText(text: make(nil))
        }
    }
}
#endif
