import Foundation
import Testing
@testable import UniversalTranslator

// The memory Settings shows for the chosen engines (Translation → Memory while listening): the models they load, against
// the Mac's memory. Measured 2026-10-26: 1.6 GB with the second pass off, 6.4 GB with the 7B (resident, M4).

@Suite struct MemoryEstimateTests {
    private let gb: Int64 = 1_073_741_824

    private func settings(backend: TranslatorKind = .localLLM, revision: RevisionBackend = .localLLMLarge,
                          engine: LocalEngine = .llamaCpp, recognizer: SpeechRecognizerKind = .nemotron,
                          locale: String = "ja-JP") -> AppSettings {
        var s = AppSettings()
        s.translation.backend = backend
        s.translation.revision = revision
        s.translation.localEngine = engine
        s.recognizer = recognizer
        s.sourceLocale = locale
        return s
    }

    private func kinds(_ e: MemoryEstimate) -> [MemoryEstimate.Part.Kind] { e.parts.map(\.kind) }

    @Test func countsEachModelTheChoicesLoad() {
        let full = MemoryEstimate.of(settings(), physicalMemory: 24 * gb)
        #expect(kinds(full) == [.app, .speech, .live, .secondPass])
        let speech = LocalModel.nemotronMultilingual.bytes + LocalModel.sileroVAD.bytes + LocalModel.smartTurn.bytes
        #expect(full.bytes == MemoryEstimate.appBytes + speech + LocalModel.hyMT2Small.bytes + LocalModel.hyMT2Large.bytes)
        // English speech loads the smaller Latin-script Nemotron.
        let english = MemoryEstimate.of(settings(locale: "en-US"), physicalMemory: 24 * gb)
        #expect(english.parts[1].bytes == LocalModel.nemotronLatin.bytes + LocalModel.sileroVAD.bytes + LocalModel.smartTurn.bytes)
        // The second pass off takes the 7B away; MLX counts the MLX builds.
        #expect(kinds(MemoryEstimate.of(settings(revision: .off), physicalMemory: 24 * gb)) == [.app, .speech, .live])
        let mlx = MemoryEstimate.of(settings(engine: .mlx), physicalMemory: 24 * gb)
        #expect(mlx.parts.map(\.bytes).suffix(2) == [LocalModel.hyMT2SmallMLX.bytes, LocalModel.hyMT2LargeMLX.bytes])
    }

    @Test func modelsOutsideTheAppAreNotCounted() {
        // Apple's engines run in the system, LM Studio in its own app; a 1.8B second pass shares the live model.
        let apple = MemoryEstimate.of(settings(backend: .apple, revision: .appleHighFidelity, recognizer: .appleSpeech),
                                      physicalMemory: 24 * gb)
        #expect(kinds(apple) == [.app])
        #expect(kinds(MemoryEstimate.of(settings(backend: .lmStudio, revision: .lmStudio), physicalMemory: 24 * gb))
                == [.app, .speech])
        #expect(kinds(MemoryEstimate.of(settings(revision: .localLLMSmall), physicalMemory: 24 * gb)) == [.app, .speech, .live])
        let smallOnly = MemoryEstimate.of(settings(backend: .lmStudio, revision: .localLLMSmall), physicalMemory: 24 * gb)
        #expect(kinds(smallOnly) == [.app, .speech, .secondPass] && smallOnly.parts[2].bytes == LocalModel.hyMT2Small.bytes)
    }

    @Test func colorsWarnWhenLittleIsLeftForOtherApps() {
        // With the 7B (about 6.2 GB): fine on 24 GB, amber on 16 GB, red on 8 GB. Without it, fine on 8 GB.
        #expect(MemoryEstimate.of(settings(), physicalMemory: 24 * gb).level == .comfortable)
        #expect(MemoryEstimate.of(settings(), physicalMemory: 16 * gb).level == .tight)
        #expect(MemoryEstimate.of(settings(), physicalMemory: 8 * gb).level == .tooMuch)
        #expect(MemoryEstimate.of(settings(revision: .off), physicalMemory: 8 * gb).level == .comfortable)
    }

    @Test func gigabytesAreTheOnesAboutThisMacUses() {
        #expect(MemoryEstimate.gigabytes(16 * gb) == "16.0 GB")
        #expect(MemoryEstimate.gigabytes(LocalModel.hyMT2Large.bytes) == "4.3 GB")
    }
}
