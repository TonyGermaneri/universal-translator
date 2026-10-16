import Foundation
import TranslatorCore

/// What the marquee layout keeps between renders: one tape per line (translation and original speech) and
/// the last text of every sentence on them, so a sentence keeps scrolling after it leaves the caption paragraph.
@MainActor
final class MarqueeState {
    enum Lane { case translation, source }

    /// Stands for the recognized words that aren't part of a sentence yet.
    static let liveID = UUID()

    var translation = MarqueeTape<UUID>(speed: 0)
    var source = MarqueeTape<UUID>(speed: 0)
    var sentences: [UUID: CaptionStore.Sentence] = [:]
    var liveSource = ""
    var clearCount = -1
    var fontKey = ""
    var widths: [Lane: [UUID: (key: String, width: Double)]] = [:]
    /// Timeline date of each line's last frame (seconds since the reference date).
    var lastFrame: [Lane: Double] = [:]

    func tape(_ lane: Lane) -> MarqueeTape<UUID> { lane == .translation ? translation : source }

    func setTape(_ lane: Lane, _ tape: MarqueeTape<UUID>) {
        if lane == .translation { translation = tape } else { source = tape }
    }

    func hasText(includingSource: Bool) -> Bool {
        !translation.isEmpty || (includingSource && !source.isEmpty)
    }

    func sourceText(_ id: UUID) -> String {
        id == Self.liveID ? liveSource : sentences[id]?.source ?? ""
    }

    /// The width of a segment, measured again only when its text (`key`) changes.
    func width(_ lane: Lane, _ id: UUID, key: String, measure: () -> Double) -> Double {
        if let cached = widths[lane]?[id], cached.key == key { return cached.width }
        let width = measure()
        widths[lane, default: [:]][id] = (key, width)
        return width
    }

    /// Forgets sentences that have scrolled away.
    func prune() {
        let onTape = Set(translation.segments.map(\.id)).union(source.segments.map(\.id))
        guard sentences.count > onTape.count + 8 else { return }
        sentences = sentences.filter { onTape.contains($0.key) }
        for lane in widths.keys { widths[lane] = widths[lane]?.filter { onTape.contains($0.key) } }
    }

    func reset() {
        translation.reset()
        source.reset()
        sentences = [:]
        liveSource = ""
        widths = [:]
    }
}
