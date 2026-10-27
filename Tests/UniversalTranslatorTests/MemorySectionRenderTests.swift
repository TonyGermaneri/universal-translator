#if os(macOS)
import AppKit
import SwiftUI
import Testing
@testable import UniversalTranslator

// Settings → Translation → Memory while listening, drawn offscreen for a few Macs. With UT_PREVIEW_DIR set, each
// state is saved as a PNG there to look at (Tests/tier1/run.sh --filter MemorySectionRenderTests). (A Form can't be
// drawn offscreen: the gauge is drawn on its own, with the advice under it.)

@MainActor
@Suite struct MemorySectionRenderTests {
    /// Pixels of the second-pass segment's purple.
    private func purplePixels(_ image: NSImage) -> Int {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff) else { return 0 }
        var count = 0
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if c.redComponent > 0.5, c.blueComponent > 0.6, c.greenComponent < 0.45 { count += 1 }
            }
        }
        return count
    }

    @Test func drawsTheBarForEachMemorySize() throws {
        var s = AppSettings()
        s.sourceLocale = "ja-JP"
        for (name, memory, revision) in [("24GB-7B", 24.0, RevisionBackend.localLLMLarge), ("16GB-7B", 16, .localLLMLarge),
                                         ("8GB-7B", 8, .localLLMLarge), ("8GB-off", 8, .off)] {
            s.translation.revision = revision
            let estimate = MemoryEstimate.of(s, physicalMemory: Int64(memory * 1_073_741_824))
            let view = VStack(alignment: .leading, spacing: 10) {
                MemoryGauge(estimate: estimate)
                Text(MemorySection.advice(estimate)).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16).frame(width: 560).background(Color.white).environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.nsImage, "\(name) didn't render")
            let purple = purplePixels(image)
            if revision == .localLLMLarge {
                #expect(purple > 50, "\(name): no second-pass segment drawn")
            } else {
                #expect(purple == 0, "\(name): a second-pass segment with the second pass off")
            }
            if let dir = ProcessInfo.processInfo.environment["UT_PREVIEW_DIR"],
               let tiff = image.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(fileURLWithPath: dir).appendingPathComponent("memory-\(name).png"))
            }
        }
    }
}
#endif
