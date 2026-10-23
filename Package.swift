// swift-tools-version: 6.2
import PackageDescription

// Swift < 6.3 (Xcode 26.3, the newest that runs on macOS 15) can't read mlx-swift's 6.3 manifest. A local copy at the
// pinned revision with only the tools-version line lowered (scripts/vendor-mlx-swift.sh) stands in for it; a root
// path dependency with the same identity overrides the one mlx-swift-lm declares. Swift 6.3+ builds are unaffected.
#if compiler(>=6.3)
let legacyToolchainOverrides: [Package.Dependency] = []
#else
let legacyToolchainOverrides: [Package.Dependency] = [.package(path: ".build/vendor/mlx-swift")]
#endif

let package = Package(
    name: "UniversalTranslator",
    platforms: [.macOS(.v15), .iOS("26.4")],
    products: [
        .executable(name: "UniversalTranslator", targets: ["UniversalTranslator"]),
        // Everything the iPhone and iPad app (iOS/UniversalTranslator.xcodeproj) links.
        .library(name: "AppDependencies", targets: ["AppDependencies"]),
    ],
    dependencies: [
        // NVIDIA Nemotron streaming speech recognition (Core ML) and friends. Pinned; the NeMo text-normalization
        // engine (only used by its text-to-speech) is left out.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
        // MLX: the alternative on-device engine for the translation models. The Foundation Models adapter is left out.
        .package(url: "https://github.com/ml-explore/mlx-swift-lm.git", exact: "3.32.3", traits: []),
    ] + legacyToolchainOverrides,
    targets: [
        // Platform-agnostic logic: transcript model, chunking, VAD math, prompts, LM Studio client.
        .target(
            name: "TranslatorCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // llama.cpp (prebuilt, Metal) for on-device translation LLMs. Pinned to a tested build.
        .binaryTarget(
            name: "llama",
            url: "https://github.com/ggml-org/llama.cpp/releases/download/b11552/llama-b11552-xcframework.zip",
            checksum: "ac195b4693da8e250ed778bc66a137912b912c0a6733f9c3e52153d7258172b8"
        ),
        // Swift wrapper around llama.cpp: model loading, prompt-cache reuse, greedy decoding.
        .target(
            name: "LocalLLM",
            dependencies: ["llama"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The same contract on MLX (Hugging Face MLX model folders). MLX's Metal shaders are compiled by
        // xcodebuild, not `swift build` (scripts/build-app.sh).
        .target(
            name: "LocalMLX",
            dependencies: [
                "LocalLLM",
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The macOS app: audio capture, speech engines, translation backends, overlay, settings UI.
        .executableTarget(
            name: "UniversalTranslator",
            dependencies: ["TranslatorCore", "LocalLLM", "LocalMLX", .product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The libraries the iOS app's Xcode project links, as one product: the project compiles the app's shared
        // sources itself, and a project-level FluidAudio reference couldn't leave out its default traits.
        .target(
            name: "AppDependencies",
            dependencies: ["TranslatorCore", "LocalLLM", "LocalMLX", .product(name: "FluidAudio", package: "FluidAudio")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Developer tool: on-device model speed outside the app.
        .executableTarget(
            name: "llm-bench",
            dependencies: ["LocalLLM", "LocalMLX", "TranslatorCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "TranslatorCoreTests",
            dependencies: ["TranslatorCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
