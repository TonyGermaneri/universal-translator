// Developer tool: measures on-device translation model speed outside the app.
// usage: llm-bench <model.gguf | MLX model folder> [Japanese]
//        llm-bench --compare <model.gguf> <MLX model folder> [Japanese]
//   --compare checks that both tokenizers agree, then runs the same live-caption workload on both engines.
// MLX models need the Metal shaders built by xcodebuild (see scripts/build-app.sh).
import Foundation
import LocalLLM
import LocalMLX
import TranslatorCore

var args = Array(CommandLine.arguments.dropFirst())
// --tokenize <tokenizer.json> <file>: token IDs of each line (\n and \r written as \\n, \\r), one JSON array per line, to
// check the MLX tokenizer against Hugging Face's reference implementation.
if args.first == "--tokenize", args.count == 3 { // before the other modes: no model to load
    let tokenizer = try BPETokenizer(url: URL(fileURLWithPath: args[1]))
    let started = Date()
    var lines: [String] = []
    for line in try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false) {
        let ids = tokenizer.encode(line.replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\r", with: "\r"))
        lines.append("[" + ids.map(String.init).joined(separator: ",") + "]")
    }
    print(lines.joined(separator: "\n"))
    FileHandle.standardError.write(String(format: "%.2f ms per line\n", Date().timeIntervalSince(started) * 1000 / Double(lines.count)).data(using: .utf8)!)
    exit(0)
}
let mode = args.first.flatMap { $0.hasPrefix("--") ? $0 : nil }
if mode != nil { args.removeFirst() }
let compare = mode == "--compare"
guard !args.isEmpty, !compare || args.count >= 2 else {
    print("usage: llm-bench <model.gguf | MLX model folder> [Japanese]\n       llm-bench --compare <model.gguf> <MLX model folder> [Japanese]\n       llm-bench --scaling|--consistency <model>...")
    exit(1)
}
// --scaling and --consistency take any number of models (target Japanese).
let modelPaths = mode == "--scaling" || mode == "--consistency" ? args : Array(args.prefix(compare ? 2 : 1))
// (--translate reads its own arguments.)
let target = args.count > modelPaths.count ? args[modelPaths.count] : "Japanese"
// The 7B model uses Hunyuan's original chat markers.
let format: HyMT2Prompt.Format = modelPaths[0].lowercased().contains("7b") ? .hunyuan : .hy

func load(_ path: String) async throws -> any CompletionRunner {
    let started = Date()
    var isDirectory: ObjCBool = false
    FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    let runner: any CompletionRunner = isDirectory.boolValue
        ? try await MLXRunner.load(directory: URL(fileURLWithPath: path))
        : try LlamaRunner(modelPath: path, contextLength: 4096)
    print(String(format: "%@: load %.2fs", isDirectory.boolValue ? "MLX" : "llama.cpp", Date().timeIntervalSince(started)))
    return runner
}

func prompt(_ source: String, context: [TranslationContext] = [], glossary: [GlossaryEntry] = []) -> String {
    HyMT2Prompt.make(source: source, targetName: target, targetCode: "ja", context: context, glossary: glossary, format: format)
}

let sentences = [
    "Could you recommend a good place for lunch nearby",
    "How long does it take to get there on foot",
    "New caching layer sits between the application servers and the database",
    "Good morning everyone, and thanks for joining the call.",
    "We were hoping to ship in March, but because the vendor delivered the hardware late, we are now looking at the end of April.",
    "That gives us about six weeks to finish testing, which is tight but doable if we keep the scope where it is.",
]

/// Whole-sentence translations: prompt processing and generation speed.
func sentenceSpeed(_ runner: any CompletionRunner) async throws {
    for sentence in sentences {
        let p = prompt(sentence)
        _ = try await runner.complete(prompt: p + " ", maxTokens: 1)
        let r = try await runner.complete(prompt: p, maxTokens: 128, draft: nil, healPrefix: false, stop: format.stop)
        print(String(format: "prompt %3d tok %5.1f ms | gen %3d tok %6.1f ms = %5.1f tok/s | %@", r.promptTokensProcessed,
                     r.promptMilliseconds, r.generatedTokens, r.generationMilliseconds,
                     Double(r.generatedTokens) / r.generationMilliseconds * 1000, r.text))
    }
}

/// The app's live loop: the sentence grows a word at a time, each update continues the committed translation
/// (the previous update's first half) for 12 tokens with the previous hypothesis as draft, then a final pass.
func liveLoop(_ runner: any CompletionRunner) async throws -> (updates: [Double], finals: [Double]) {
    var updates: [Double] = []
    var finals: [Double] = []
    var context: [TranslationContext] = []
    for sentence in sentences {
        let words = sentence.split(separator: " ")
        var hypothesis = ""
        for count in 2...words.count {
            let source = words.prefix(count).joined(separator: " ")
            let committed = String(hypothesis.prefix(hypothesis.count / 2))
            let draft = hypothesis.hasPrefix(committed) && hypothesis.count > committed.count
                ? String(hypothesis.dropFirst(committed.count)) : nil
            let started = Date()
            let r = try await runner.complete(prompt: prompt(source, context: context) + committed, maxTokens: 12, draft: draft,
                                              healPrefix: !committed.isEmpty, stop: format.stop)
            updates.append(Date().timeIntervalSince(started) * 1000)
            if ProcessInfo.processInfo.environment["LIVE_DETAIL"] != nil {
                print(String(format: "  update %5.1f ms: prompt %2d tok, %2d generated (%2d from draft of %2d) | %@", updates.last!,
                             r.promptTokensProcessed, r.generatedTokens, r.draftTokensAccepted, draft?.count ?? 0, committed + "[" + r.text + "]"))
            }
            hypothesis = committed + r.text.trimmingCharacters(in: .newlines)
        }
        let started = Date()
        let r = try await runner.complete(prompt: prompt(sentence, context: context), maxTokens: HyMT2Prompt.maxTokens(forSource: sentence),
                                          draft: hypothesis, healPrefix: false, stop: format.stop)
        finals.append(Date().timeIntervalSince(started) * 1000)
        if ProcessInfo.processInfo.environment["LIVE_DETAIL"] != nil { print("  final: \(r.text)") }
        context = Array((context + [TranslationContext(source: sentence, translation: r.text)]).suffix(2))
    }
    return (updates, finals)
}

func summary(_ label: String, _ values: [Double]) -> String {
    let sorted = values.sorted()
    let median = sorted[sorted.count / 2]
    let p90 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
    return String(format: "%@: median %.1f ms, p90 %.1f ms, mean %.1f ms (n=%d)", label, median, p90,
                  values.reduce(0, +) / Double(values.count), values.count)
}

// --scaling <model...>: wall time of a call that processes N new prompt tokens (on top of a cached prompt) and
// generates one token. (llama.cpp's own prompt timer stops before the GPU finishes, so wall time is compared.)
// --translate <model> <language> <file>: final-pass translation of each line (no context), one per line.
if mode == "--translate" {
    let runner = try await load(args[0])
    let lines = try String(contentsOfFile: args[2], encoding: .utf8).split(separator: "\n").map(String.init)
    let format: HyMT2Prompt.Format = args[0].lowercased().contains("7b") ? .hunyuan : .hy
    for line in lines {
        let p = HyMT2Prompt.make(source: line, targetName: args[1], targetCode: "", context: [], format: format)
        let r = try await runner.complete(prompt: p, maxTokens: HyMT2Prompt.maxTokens(forSource: line), draft: nil,
                                          healPrefix: false, stop: format.stop)
        print(r.text.replacingOccurrences(of: "\n", with: " "))
    }
    runner.close()
    exit(0)
}

if mode == "--scaling" {
    for path in modelPaths {
        let runner = try await load(path)
        let base = prompt("Could you recommend a good place for lunch nearby")
        let words = "the quick brown fox jumps over the lazy dog while seven tired engineers debug a flaky build on a rainy afternoon in early spring and nobody remembers who wrote the original tests or why they pass on some machines but fail on others".split(separator: " ")
        var line = ""
        for count in [1, 2, 4, 8, 12, 16, 24, 32, 48, 64] {
            var times: [Double] = []
            for _ in 0..<10 {
                _ = try await runner.complete(prompt: base, maxTokens: 1)
                let started = Date()
                _ = try await runner.complete(prompt: base + words.prefix(count).joined(separator: " "), maxTokens: 1)
                times.append(Date().timeIntervalSince(started) * 1000)
            }
            line += String(format: " %d:%.1f", count, times.min()!)
        }
        print("ms by new tokens:" + line)
        runner.close()
    }
    exit(0)
}

// --consistency <model...>: greedy output for each growing prompt after reusing the cache vs from scratch (they
// should match; a mismatch means cache reuse changes the model's computation).
if mode == "--consistency" {
    for path in modelPaths {
        let runner = try await load(path)
        var same = 0
        var total = 0
        for sentence in sentences {
            let words = sentence.split(separator: " ")
            for count in 2...words.count {
                let p = prompt(words.prefix(count).joined(separator: " "))
                let reused = try await runner.complete(prompt: p, maxTokens: 16)
                _ = try await runner.complete(prompt: "x", maxTokens: 1)
                let fresh = try await runner.complete(prompt: p, maxTokens: 16)
                total += 1
                if reused.text == fresh.text { same += 1 } else { print("  reused [\(reused.text)] fresh [\(fresh.text)]") }
                _ = try await runner.complete(prompt: p, maxTokens: 1) // leave the cache at p for the next prefix
            }
        }
        print("same output with and without cache reuse: \(same)/\(total)")
        runner.close()
    }
    exit(0)
}

if compare {
    let llama = try await load(modelPaths[0])
    let mlx = try await load(modelPaths[1])
    // Tokenizers must agree, or the prompt cache, healing and drafts would behave differently.
    let samples = sentences.map { prompt($0) } + [
        prompt("Today I want to explain three things.") + "今日は3つのことについて説明したいと",
        "Über 1.000 Menschen – ¿verdad? «Ça va» 東京タワー 🙂 100,000 3.14159",
    ]
    var mismatches = 0
    for text in samples {
        let a = try (llama as! LlamaRunner).tokenIDs(text)
        let b = (mlx as! MLXRunner).tokenIDs(text)
        if a != b {
            mismatches += 1
            let at = zip(a, b).prefix { $0 == $1 }.count
            print("tokenizers differ at token \(at): llama \(Array(a[at...].prefix(6))) mlx \(Array(b[at...].prefix(6))) in \(text.suffix(60))")
        }
    }
    print("tokenizer agreement: \(samples.count - mismatches)/\(samples.count)")
    var started = Date()
    for text in samples { _ = try (llama as! LlamaRunner).tokenIDs(text) }
    let llamaMs = Date().timeIntervalSince(started) * 1000 / Double(samples.count)
    started = Date()
    for text in samples { _ = (mlx as! MLXRunner).tokenIDs(text + " ") }
    print(String(format: "tokenize: llama.cpp %.2f ms, MLX %.2f ms per prompt", llamaMs, Date().timeIntervalSince(started) * 1000 / Double(samples.count)))
    for (name, runner) in [("llama.cpp", llama), ("MLX", mlx)] {
        print("== \(name)")
        try await sentenceSpeed(runner)
        _ = try await liveLoop(runner) // warm-up
        let (updates, finals) = try await liveLoop(runner)
        print(summary("live update", updates))
        print(summary("final pass ", finals))
    }
    llama.close() // before exit: llama.cpp's Metal backend asserts if a model is still loaded at teardown
    mlx.close()
    exit(0)
}

let runner = try await load(modelPaths[0])
defer { runner.close() }
try await sentenceSpeed(runner)

// LIVE_RUNS=n: the live-caption workload n times after a warm-up (compare engines in separate processes).
if let runs = ProcessInfo.processInfo.environment["LIVE_RUNS"].flatMap(Int.init) {
    _ = try await liveLoop(runner)
    var updates: [Double] = []
    var finals: [Double] = []
    for _ in 0..<runs {
        let result = try await liveLoop(runner)
        updates += result.updates
        finals += result.finals
    }
    print(summary("live update", updates))
    print(summary("final pass ", finals))
}

// Token healing: forced prefixes that end in the middle of a token.
let cases: [(String, String)] = [
    ("Today I want to walk through three things: the timeline, the budget, and the hiring plan.", "今日は、タイムライン、予算、採用計画で"),
    ("Today I want to explain three things.", "今日は3つのことについて説明したいと"),
]
for (source, prefix) in cases {
    for heal in [false, true] {
        let r = try await runner.complete(prompt: prompt(source) + prefix, maxTokens: 24, draft: nil, healPrefix: heal, stop: format.stop)
        print("heal=\(heal) | \(prefix)【\(r.text)】")
    }
}

// Glossary: the terminology template should force "launch" → ローンチ and keep "Acme" as is.
let glossary = [GlossaryEntry(source: "launch", target: "ローンチ"), GlossaryEntry(source: "Acme", target: "")]
let glossarySource = "The Acme launch timeline slipped by two weeks."
for terms in [[GlossaryEntry](), glossary] {
    let r = try await runner.complete(prompt: prompt(glossarySource, glossary: terms), maxTokens: 48)
    print("glossary=\(!terms.isEmpty) | \(r.text)")
}
