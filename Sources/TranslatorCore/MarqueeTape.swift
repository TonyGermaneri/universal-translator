import Foundation

/// Positions for a scrolling-ticker caption lane. Pieces of text (one per sentence) sit end to end on a tape
/// that moves past the viewport at a steady speed. Text that arrives while the end of the tape is on screen
/// enters at the trailing edge; while text is waiting off screen the tape speeds up, so the newest words come
/// on screen within about `catchUpTime` and the ticker never falls far behind the speaker.
///
/// Coordinates are points along the reading direction: the viewport shows `offset ..< offset + viewport`.
public struct MarqueeTape<ID: Hashable & Sendable>: Sendable {
    public struct Segment: Equatable, Sendable {
        public let id: ID
        public internal(set) var start: Double
        public internal(set) var width: Double
        /// Where it entered the tape; it only moves further along to make room for what precedes it.
        var earliest: Double
        public var end: Double { start + width }
    }

    /// Steady speed in points per second.
    public var speed: Double
    /// Space between segments.
    public var gap: Double
    /// Where the newest text comes to rest, measured back from the trailing edge (e.g. clear of an edge fade).
    public var trailingInset: Double = 0
    /// Waiting text is brought on screen within about this many seconds.
    public var catchUpTime: Double = 1.5
    /// Catching up never goes faster than this (points per second).
    public var maximumSpeed: Double = .infinity
    /// How quickly the speed follows its target, in seconds.
    public var smoothing: Double = 0.3

    public private(set) var segments: [Segment] = []
    /// Tape position at the viewport's leading edge.
    public private(set) var offset: Double = 0
    public private(set) var velocity: Double
    private var gone: Set<ID> = []
    private var transient: ID?
    private var departedTransientWidth: Double?

    public init(speed: Double, gap: Double = 0) {
        self.speed = speed
        self.gap = gap
        velocity = speed
    }

    public var isEmpty: Bool { segments.isEmpty }

    /// Whether `id` has been on the tape and scrolled away (its width no longer matters).
    public func hasScrolledAway(_ id: ID) -> Bool { gone.contains(id) }

    /// Seconds until everything on the tape has scrolled away at the steady speed.
    public var remainingTime: Double {
        guard let last = segments.last, speed > 0 else { return 0 }
        return max(0, last.end - offset) / speed
    }

    /// Brings the tape in line with the current text: `items` in reading order with their widths. Known ids
    /// take their new width and new ones are appended; ids that already scrolled away aren't shown again.
    /// Segments no longer listed keep their last width until they scroll away.
    ///
    /// - Parameter transient: an id for text that isn't settled into its own piece yet (words still being
    ///   recognized). It always comes last, and the next new piece takes over its place on the tape.
    public mutating func update(_ items: [(id: ID, width: Double)], viewport: Double, transient: ID? = nil) {
        let listed = Set(items.map(\.id))
        gone.formIntersection(listed)
        self.transient = transient
        var inherited: Double?
        var tookOver = false
        if let transient, let i = segments.firstIndex(where: { $0.id == transient }) {
            tookOver = items.contains { $0.id != transient && !gone.contains($0.id) && !has($0.id) }
            if tookOver { inherited = segments[i].earliest }
            if tookOver || !listed.contains(transient) { segments.remove(at: i) }
        }
        let entry = offset + viewport
        for item in items where !gone.contains(item.id) {
            if let i = segments.firstIndex(where: { $0.id == item.id }) {
                segments[i].width = max(0, item.width)
                continue
            }
            let earliest: Double
            if item.id == transient {
                // Unchanged words that already scrolled away don't come round again.
                if !tookOver, item.width == departedTransientWidth { continue }
                departedTransientWidth = nil
                // What's left after a new piece took its place follows that piece.
                earliest = tookOver ? -.infinity : entry
            } else if let place = inherited {
                earliest = place
                inherited = nil
            } else {
                earliest = entry
            }
            segments.append(Segment(id: item.id, start: earliest, width: max(0, item.width), earliest: earliest))
        }
        if let transient, let i = segments.firstIndex(where: { $0.id == transient }), i != segments.count - 1 {
            segments.append(segments.remove(at: i))
        }
        flow()
    }

    /// Moves the tape on by `dt` seconds.
    public mutating func advance(by dt: Double, viewport: Double) {
        guard dt > 0 else { return }
        guard let last = segments.last else {
            velocity = speed
            return
        }
        let waiting = max(0, last.end - (offset + viewport - trailingInset))
        let target = min(max(speed, maximumSpeed), speed + waiting / max(catchUpTime, 0.1))
        velocity += (target - velocity) * min(1, dt / max(smoothing, 0.001))
        offset += velocity * dt
        while let first = segments.first, first.end < offset {
            // The transient id is reused for whatever words come next.
            if first.id == transient { departedTransientWidth = first.width } else { gone.insert(first.id) }
            segments.removeFirst()
        }
    }

    public mutating func reset() {
        segments = []
        gone = []
        departedTransientWidth = nil
        velocity = speed
    }

    private func has(_ id: ID) -> Bool { segments.contains { $0.id == id } }

    /// Each segment starts where it entered, or after the one before it if that has grown into its place.
    private mutating func flow() {
        var previousEnd = -Double.infinity
        for i in segments.indices {
            segments[i].start = max(segments[i].earliest, previousEnd + gap)
            previousEnd = segments[i].end
        }
    }
}
