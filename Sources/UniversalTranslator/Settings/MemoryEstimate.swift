import Foundation

/// The memory the chosen engines are expected to take while listening, against the device's physical memory: the
/// files of the models they load, plus the app itself. Apple's engines (run by the system) and LM Studio (another app)
/// aren't counted. Measured 2026-10-26 on an M4 (resident memory, Japanese → English, llama.cpp): 1.6 GB with the
/// second pass off, 6.4 GB with the 7B; this estimate says 1.9 and 6.2, close (binary GB throughout).
struct MemoryEstimate: Equatable {
    struct Part: Equatable, Identifiable {
        enum Kind: String { case app, speech, live, secondPass }
        let kind: Kind
        let title: String
        let bytes: Int64
        var id: String { kind.rawValue }
    }

    enum Level: Equatable { case comfortable, tight, tooMuch }

    let parts: [Part]
    let physicalMemory: Int64

    /// The app's own code, caches and buffers, without any model.
    static let appBytes: Int64 = 200_000_000

    var bytes: Int64 { parts.reduce(0) { $0 + $1.bytes } }
    var fraction: Double { physicalMemory > 0 ? Double(bytes) / Double(physicalMemory) : 1 }

    /// Room left for macOS (3-4 GB), the meeting app (1-2 GB) and a browser (2-4 GB): amber from 30 % of the
    /// memory, red from 50 %. With the 7B, a 16 GB Mac is amber (39 %), an 8 GB one red; without it, both are fine.
    var level: Level { fraction < 0.3 ? .comfortable : fraction < 0.5 ? .tight : .tooMuch }

    /// The device's memory; test hook `UT_PHYSICAL_MEMORY` (in GB) shows another size (screenshots, tier3).
    static var devicePhysicalMemory: Int64 {
        if let gb = ProcessInfo.processInfo.environment["UT_PHYSICAL_MEMORY"].flatMap(Double.init) {
            return Int64(gb * 1_073_741_824)
        }
        return Int64(ProcessInfo.processInfo.physicalMemory)
    }

    static func of(_ s: AppSettings, physicalMemory: Int64 = devicePhysicalMemory) -> MemoryEstimate {
        var parts = [Part(kind: .app, title: "Universal Translator", bytes: appBytes)]
        if s.recognizer == .nemotron {
            let model = LocalModel.nemotron(for: s.sourceLocale)
            let endpointing = (s.timing.neuralVAD ? LocalModel.sileroVAD.bytes : 0)
                + (s.timing.smartTurn ? LocalModel.smartTurn.bytes : 0)
            parts.append(Part(kind: .speech, title: "Speech recognition: \(model.name)", bytes: model.bytes + endpointing))
        }
        let engine = s.translation.localEngine
        let live = s.translation.backend == .localLLM ? LocalModel.live(engine) : nil
        if let live {
            parts.append(Part(kind: .live, title: "Live translation: \(live.name)", bytes: live.bytes))
        }
        // A second pass with the live model shares it (LiveTranslationController loads it once).
        let second: LocalModel? = switch s.translation.revision {
        case .localLLMLarge: LocalModel.reviser(engine)
        case .localLLMSmall: live == nil ? LocalModel.live(engine) : nil
        default: nil
        }
        if let second {
            parts.append(Part(kind: .secondPass, title: "Second pass: \(second.name)", bytes: second.bytes))
        }
        return MemoryEstimate(parts: parts, physicalMemory: physicalMemory)
    }

    /// "6.2 GB", in the binary gigabytes About This Mac and Activity Monitor use for memory (a 16 GB Mac reads 16.0).
    static func gigabytes(_ bytes: Int64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
    }
}
