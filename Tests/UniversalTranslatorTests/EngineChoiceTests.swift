import AppKit
import Foundation
import Testing
@testable import UniversalTranslator

// The Mac app's choices that differ between macOS 26 (Apple's speech, translation and language models) and earlier
// systems (Nemotron and Hy-MT2 only). Each takes `hasAppleModels`, so both answers are checked on any Mac: the
// macOS 26 rows pin upstream's behavior, the others pin the macOS 15 port.

@Suite struct EngineChoiceTests {
    private let small = LocalModel.hyMT2Small

    @Test func menusOfferAppleEnginesOnlyWithAppleModels() {
        #expect(SpeechRecognizerKind.choices(hasAppleModels: true) == SpeechRecognizerKind.allCases)
        #expect(TranslatorKind.choices(hasAppleModels: true) == TranslatorKind.allCases)
        #expect(RevisionBackend.choices(hasAppleModels: true) == RevisionBackend.allCases)
        #expect(SpeechRecognizerKind.choices(hasAppleModels: false) == [.nemotron])
        #expect(TranslatorKind.choices(hasAppleModels: false) == [.localLLM, .lmStudio, .none])
        #expect(RevisionBackend.choices(hasAppleModels: false) == [.off, .localLLMLarge, .localLLMSmall, .lmStudio])
    }

    @Test func settingsNamingAppleEnginesAreRewrittenOnlyWithoutAppleModels() {
        var s = AppSettings.defaults
        s.recognizer = .appleSpeech
        s.translation.backend = .apple
        s.translation.revision = .appleIntelligence
        let kept = s.withoutUnavailableEngines(hasAppleModels: true)
        #expect(kept.recognizer == .appleSpeech && kept.translation.backend == .apple
                && kept.translation.revision == .appleIntelligence)
        let rewritten = s.withoutUnavailableEngines(hasAppleModels: false)
        #expect(rewritten.recognizer == .nemotron)
        #expect(rewritten.translation.backend == .localLLM)
        #expect(rewritten.translation.revision == .localLLMLarge)
        s.translation.backend = .appleIntelligence
        s.translation.revision = .appleHighFidelity
        #expect(s.withoutUnavailableEngines(hasAppleModels: false).translation.backend == .localLLM)
        #expect(s.withoutUnavailableEngines(hasAppleModels: false).translation.revision == .localLLMLarge)
    }

    @Test @MainActor func storedSettingsLoadThroughTheRewrite() throws {
        // The import/load path, not just the helper: `decodeMergingDefaults` applies it on this system.
        let data = Data(#"{"recognizer":"appleSpeech","translation":{"backend":"apple","revision":"appleHighFidelity"}}"#.utf8)
        let loaded = try SettingsStore.decodeMergingDefaults(data)
        if Platform.hasAppleModels {
            #expect(loaded.recognizer == .appleSpeech && loaded.translation.backend == .apple)
        } else {
            #expect(loaded.recognizer == .nemotron && loaded.translation.backend == .localLLM)
            #expect(loaded.translation.revision == .localLLMLarge)
        }
    }

    // MARK: Translators

    private func pick(_ backend: TranslatorKind, _ revision: RevisionBackend, smallReady: Bool = true,
                      largeReady: Bool = true, apple: Bool) throws -> (TranslatorKind, RevisionBackend, String?) {
        let c = try LiveTranslationController.translators(backend: backend, revision: revision, small: small,
                                                         smallReady: smallReady, largeReady: largeReady,
                                                         hasAppleModels: apple)
        return (c.backend, c.revision, c.notice)
    }

    @Test func withAppleModelsMissingHyMT2FallsBackToAppleTranslation() throws {
        let (backend, revision, notice) = try pick(.localLLM, .localLLMLarge, smallReady: false, largeReady: false, apple: true)
        #expect(backend == .apple)
        #expect(revision == .appleHighFidelity)
        #expect(notice?.contains("Using Apple Translation until Hy-MT2 1.8B is downloaded") == true)
        // Live Hy-MT2 ready, 7B missing: the second pass is off rather than Apple's reviser.
        #expect(try pick(.localLLM, .localLLMLarge, largeReady: false, apple: true).1 == .off)
        // Another live translator with the 7B missing: Apple's high-fidelity reviser.
        #expect(try pick(.lmStudio, .localLLMLarge, largeReady: false, apple: true).1 == .appleHighFidelity)
        #expect(try pick(.lmStudio, .localLLMSmall, smallReady: false, apple: true).1 == .appleHighFidelity)
    }

    @Test func withoutAppleModelsMissingHyMT2StopsInsteadOfFallingBack() {
        #expect(throws: LocalModelError.self) {
            try pick(.localLLM, .off, smallReady: false, apple: false)
        }
        do {
            _ = try pick(.localLLM, .off, smallReady: false, apple: false)
        } catch {
            #expect(error.localizedDescription.contains("Hy-MT2 1.8B isn't downloaded yet"))
        }
    }

    @Test func withoutAppleModelsNoTranslatorIsApple() throws {
        #expect(try pick(.apple, .appleHighFidelity, apple: false).0 == .localLLM)
        #expect(try pick(.appleIntelligence, .appleIntelligence, apple: false).0 == .localLLM)
        #expect(try pick(.apple, .appleHighFidelity, apple: false).1 == .off)
        #expect(try pick(.lmStudio, .localLLMLarge, largeReady: false, apple: false).1 == .off)
        #expect(try pick(.lmStudio, .localLLMSmall, smallReady: false, apple: false).1 == .off)
        // An imported Apple choice with Hy-MT2 missing still stops, naming the model.
        #expect(throws: LocalModelError.self) { try pick(.apple, .off, smallReady: false, apple: false) }
    }

    @Test func everythingDownloadedKeepsTheChoiceOnBothSystems() throws {
        for apple in [true, false] {
            let (backend, revision, notice) = try pick(.localLLM, .localLLMLarge, apple: apple)
            #expect(backend == .localLLM && revision == .localLLMLarge && notice == nil)
            #expect(try pick(.lmStudio, .lmStudio, apple: apple).0 == .lmStudio)
            #expect(try pick(.none, .off, smallReady: false, largeReady: false, apple: apple).0 == .none)
        }
    }

    // MARK: Recognizer and required downloads

    @Test func recognizerFallsBackToAppleSpeechOnlyWithAppleModels() {
        #expect(TranslatorController.recognizer(chosen: .nemotron, nemotronReady: true, hasAppleModels: true) == .nemotron)
        #expect(TranslatorController.recognizer(chosen: .nemotron, nemotronReady: false, hasAppleModels: true) == .appleSpeech)
        #expect(TranslatorController.recognizer(chosen: .appleSpeech, nemotronReady: true, hasAppleModels: true) == .appleSpeech)
        for chosen in SpeechRecognizerKind.allCases {
            for ready in [true, false] {
                #expect(TranslatorController.recognizer(chosen: chosen, nemotronReady: ready, hasAppleModels: false) == .nemotron)
            }
        }
    }

    @Test func requiredModelsFollowTheSpeechLanguageAndLiveTranslator() {
        var s = AppSettings.defaults
        s.sourceLocale = "en-US"
        s.translation.backend = .localLLM
        s.translation.localEngine = .llamaCpp
        #expect(TranslatorController.requiredModels(for: s) == [.nemotronLatin, .hyMT2Small])
        s.translation.localEngine = .mlx
        #expect(TranslatorController.requiredModels(for: s) == [.nemotronLatin, .hyMT2SmallMLX])
        s.sourceLocale = "ja-JP"
        #expect(TranslatorController.requiredModels(for: s).first == .nemotronMultilingual)
        s.translation.backend = .lmStudio
        #expect(TranslatorController.requiredModels(for: s) == [.nemotronMultilingual])
        s.translation.backend = .apple
        #expect(TranslatorController.requiredModels(for: s).contains(.hyMT2SmallMLX))
    }

    @Test func missingModelsErrorNamesThemAndWhereToGetThem() {
        let message = EngineError.modelsRequired(["NVIDIA Nemotron Speech (Latin-script languages)", "Hy-MT2 1.8B"])
            .localizedDescription
        #expect(message.contains("NVIDIA Nemotron Speech (Latin-script languages) and Hy-MT2 1.8B"))
        #expect(message.contains("Settings → General"))
        #expect(message.contains("macOS 26"))
    }

    // MARK: Nemotron languages

    @Test func nemotronLocalesAreDistinctWellFormedAndIncludeTheDefault() {
        let ids = NemotronRecognizer.supportedLocales
        #expect(Set(ids).count == ids.count)
        // The "I speak" picker tags each row with this form, and Nemotron is handed the same string.
        for id in ids { #expect(Locale(identifier: id).identifier(.bcp47) == id, "\(id)") }
        #expect(ids.contains(AppSettings.defaults.sourceLocale))
        #expect(!ids.contains("or-KE") && !ids.contains("no-NO") && !ids.contains("ar-AR"))
    }

    @Test func latinLanguagesUseTheSmallerNemotronBuild() {
        for id in ["en-US", "en-GB", "es-ES", "fr-CA", "de-DE", "it-IT", "pt-BR"] {
            #expect(LocalModel.nemotron(for: id) == .nemotronLatin, "\(id)")
        }
        for id in ["ja-JP", "zh-CN", "ko-KR", "ar-SA", "ru-RU", "nl-NL"] {
            #expect(LocalModel.nemotron(for: id) == .nemotronMultilingual, "\(id)")
        }
    }

    // MARK: Dock

    @Test func dockIconWhileAWindowIsOpenOrWhenAskedFor() {
        #expect(AppController.dockPolicy(showInDock: false, windowOpen: false) == .accessory)
        #expect(AppController.dockPolicy(showInDock: false, windowOpen: true) == .regular)
        #expect(AppController.dockPolicy(showInDock: true, windowOpen: false) == .regular)
        #expect(AppController.dockPolicy(showInDock: true, windowOpen: true) == .regular)
        #expect(AppSettings.defaults.showInDock == false)
    }
}
