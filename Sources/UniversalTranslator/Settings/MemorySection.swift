import SwiftUI

/// How much of the device's memory the chosen engines are expected to take, as a stacked bar (one segment per model)
/// with a legend, next to the choices that change it. Amber and red when little is left for everything else.
struct MemorySection: View {
    let estimate: MemoryEstimate

    init(settings: AppSettings) { estimate = MemoryEstimate.of(settings) }
    init(estimate: MemoryEstimate) { self.estimate = estimate }

    var body: some View {
        Section {
            MemoryGauge(estimate: estimate)
                .padding(.vertical, 2)
            Note(Self.advice(estimate))
        } header: {
            Text("Memory while listening")
        }
    }

    static func levelColor(_ level: MemoryEstimate.Level) -> Color {
        switch level {
        case .comfortable: return .primary
        case .tight: return .orange
        case .tooMuch: return .red
        }
    }

    static func color(_ kind: MemoryEstimate.Part.Kind) -> Color {
        switch kind {
        case .app: return .gray
        case .speech: return .blue
        case .live: return .teal
        case .secondPass: return .purple
        }
    }

    static func advice(_ estimate: MemoryEstimate) -> String {
        let base = "Estimated from the sizes of the models these choices load; Activity Monitor shows within about 20 % of it. Apple's engines and LM Studio run outside the app and aren't counted."
        switch estimate.level {
        case .comfortable:
            return "Plenty is left for a meeting app and a browser. " + base
        case .tight:
            return "Tight with a meeting app and a browser open: if things slow down, turn the second pass off. " + base
        case .tooMuch:
            return "More than this \(Platform.deviceName) can spare alongside other apps: turn the second pass off, or use Hy-MT2 1.8B for it. " + base
        }
    }
}

/// The track with one segment per part, side by side, scaled to the device's memory.
struct MemoryBar: View {
    let estimate: MemoryEstimate

    var body: some View {
        GeometryReader { geometry in
            let scale = geometry.size.width / CGFloat(max(1, estimate.physicalMemory))
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.18))
                HStack(spacing: 1) {
                    ForEach(estimate.parts) { part in
                        Rectangle()
                            .fill(MemorySection.color(part.kind))
                            .frame(width: max(2, CGFloat(part.bytes) * scale))
                            .help("\(part.title): \(MemoryEstimate.gigabytes(part.bytes))")
                    }
                }
                .frame(maxWidth: geometry.size.width, alignment: .leading)
                .clipShape(Capsule())
                .animation(.easeInOut(duration: 0.25), value: estimate.parts)
            }
        }
    }
}

/// The headline, bar and legend of `MemorySection` (a view of its own so it can be drawn offscreen for tests).
struct MemoryGauge: View {
    let estimate: MemoryEstimate

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("About \(MemoryEstimate.gigabytes(estimate.bytes))")
                    .font(.title3.weight(.semibold).monospacedDigit())
                    .foregroundStyle(MemorySection.levelColor(estimate.level))
                Text("of \(MemoryEstimate.gigabytes(estimate.physicalMemory)) on this \(Platform.deviceName)")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(String(format: "%.0f %%", estimate.fraction * 100))
                    .monospacedDigit()
                    .foregroundStyle(MemorySection.levelColor(estimate.level))
            }
            MemoryBar(estimate: estimate)
                .frame(height: 8)
                .accessibilityElement()
                .accessibilityLabel("Memory while listening")
                .accessibilityValue("About \(MemoryEstimate.gigabytes(estimate.bytes)) of \(MemoryEstimate.gigabytes(estimate.physicalMemory))")
            ForEach(estimate.parts) { part in
                HStack(spacing: 6) {
                    Circle().fill(MemorySection.color(part.kind)).frame(width: 8, height: 8)
                    Text(part.title)
                    Spacer()
                    Text(MemoryEstimate.gigabytes(part.bytes)).monospacedDigit().foregroundStyle(.secondary)
                }
                .font(.callout)
            }
            HStack(spacing: 6) {
                Circle().strokeBorder(.secondary, lineWidth: 1).frame(width: 8, height: 8)
                Text("Left for macOS and your other apps")
                Spacer()
                Text(MemoryEstimate.gigabytes(max(0, estimate.physicalMemory - estimate.bytes)))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.callout)
        }
    }
}
