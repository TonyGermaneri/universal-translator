import Foundation
import Testing
@testable import UniversalTranslator

// Downloading a model by hand and importing it: the pinned checksums, the commands shown in Settings, and the
// verify-then-install path that both imports and the app's own downloads go through.

@Suite struct ModelImportTests {
    @Test func everyModelFileHasAPinnedChecksumAtAPinnedCommit() {
        for model in LocalModel.catalog {
            #expect(model.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
                    "\(model.id) follows '\(model.revision)', not a commit: its checksums would break on the next push")
            for file in model.files {
                let hash = model.sha256[file]
                #expect(hash?.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, "\(model.id): \(file)")
            }
        }
    }

    @Test func singleFileCommandsDownloadTheFileAtTheModelsPinnedRevision() {
        let model = LocalModel.hyMT2Small
        let commands = model.downloadCommands()
        #expect(commands == "curl -L --fail -o ~/Downloads/Hy-MT2-1.8B-Q4_K_M.gguf "
                + "\"https://huggingface.co/tencent/Hy-MT2-1.8B-GGUF/resolve/\(model.revision)/Hy-MT2-1.8B-Q4_K_M.gguf\"")
    }

    @Test func folderModelsGetOneShortLineToPaste() {
        // Dozens of long curl lines pasted into Terminal at once came out garbled (2026-10-23).
        #expect(LocalModel.nemotronMultilingual.downloadCommands() == "bash ~/Downloads/get-nemotron-asr-multilingual-560ms.sh")
        #expect(!LocalModel.hyMT2SmallMLX.downloadCommands().contains("\n"))
    }

    /// Runs a folder model's real download script with macOS's bash, against a stand-in curl that records its
    /// arguments and writes each file.
    private func runScript(_ model: LocalModel, arguments: [String], in dir: URL) throws -> (status: Int32, curlCalls: [String]) {
        let bin = dir.appendingPathComponent("bin"), log = dir.appendingPathComponent("curl.log")
        try write("""
            #!/bin/bash
            echo "$*" >> "\(log.path)"
            while [ $# -gt 0 ]; do if [ "$1" = "-o" ]; then out="$2"; shift; fi; shift; done
            mkdir -p "$(dirname "$out")"; echo placeholder > "$out"
            """, bin.appendingPathComponent("curl"))
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.appendingPathComponent("curl").path)
        let script = try model.saveDownloadScript(in: dir)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + arguments
        process.environment = ["PATH": "\(bin.path):/usr/bin:/bin", "HOME": dir.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let calls = (try? String(contentsOf: log, encoding: .utf8))?.split(separator: "\n").map(String.init) ?? []
        return (process.terminationStatus, calls)
    }

    @Test func theDownloadScriptRecreatesTheFolderAndPassesOptionsToEveryCurl() throws {
        let model = LocalModel.nemotronLatin
        let dir = try scratch()
        let run = try runScript(model, arguments: ["--cacert", "proxy root.pem"], in: dir)
        #expect(run.status == 0)
        #expect(run.curlCalls.count == model.files.count)
        for (call, file) in zip(run.curlCalls, model.files) {
            #expect(call.contains("--cacert proxy root.pem"), "\(call)")
            #expect(call.contains("--fail") && call.contains("--create-dirs"), "\(call)")
            #expect(call.contains("/resolve/\(model.revision)/latin/560ms/\(file)"), "\(call)")
            #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent("nemotron-asr-latin-560ms/\(file)").path), "\(file)")
        }
    }

    @Test func theDownloadScriptRunsWithNoOptionsOnMacOSBash() throws {
        // With no options at all (most users), under set -euo pipefail, on macOS's bash 3.2.
        let run = try runScript(.sileroVAD, arguments: [], in: try scratch())
        #expect(run.status == 0)
        #expect(run.curlCalls.count == LocalModel.sileroVAD.files.count)
    }

    // MARK: Verify and install, with a small fake model

    private let folderModel = LocalModel(id: "test-folder", name: "Test Folder", summary: "", repository: "x/y",
                                         files: ["a.bin", "sub/b.bin"], localName: "test-folder", bytes: 6)
    private let fileModel = LocalModel(id: "test-file", name: "Test File", summary: "", repository: "x/y",
                                       files: ["one.gguf"], localName: "one.gguf", bytes: 3)
    private let sums = ["a.bin": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",   // "abc"
                        "sub/b.bin": "2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae",  // "foo"
                        "one.gguf": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"]

    private func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ut-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    @Test func checksumsAreSHA256() throws {
        let dir = try scratch()
        try write("abc", dir.appendingPathComponent("f"))
        #expect(try LocalModelStore.sha256(of: dir.appendingPathComponent("f")) == sums["a.bin"])
    }

    @Test func aVerifiedFolderIsInstalledWithOnlyItsOwnFiles() throws {
        let source = try scratch(), models = try scratch()
        try write("abc", source.appendingPathComponent("a.bin"))
        try write("foo", source.appendingPathComponent("sub/b.bin"))
        try write("stray", source.appendingPathComponent(".DS_Store"))
        try LocalModelStore.install(folderModel, from: source, into: models, checksums: sums)
        let installed = models.appendingPathComponent("test-folder")
        #expect(FileManager.default.fileExists(atPath: installed.appendingPathComponent("sub/b.bin").path))
        #expect(!FileManager.default.fileExists(atPath: installed.appendingPathComponent(".DS_Store").path))
        #expect(!FileManager.default.fileExists(atPath: models.appendingPathComponent(".import-test-folder").path))
        // The user's download is copied, not moved.
        #expect(FileManager.default.fileExists(atPath: source.appendingPathComponent("a.bin").path))
    }

    @Test func aVerifiedSingleFileIsInstalledUnderItsName() throws {
        let source = try scratch(), models = try scratch()
        let file = source.appendingPathComponent("renamed-download.gguf")
        try write("abc", file)
        try LocalModelStore.install(fileModel, from: file, into: models, checksums: sums)
        #expect(FileManager.default.fileExists(atPath: models.appendingPathComponent("one.gguf").path))
    }

    @Test func aCorruptOrIncompleteDownloadIsRefusedAndNothingIsInstalled() throws {
        let source = try scratch(), models = try scratch()
        try write("abd", source.appendingPathComponent("a.bin"))   // one byte off
        do {
            try LocalModelStore.install(folderModel, from: source, into: models, checksums: sums)
            Issue.record("a corrupt, incomplete folder was installed")
        } catch {
            let message = error.localizedDescription
            #expect(message.contains("a.bin doesn't match its checksum"))
            #expect(message.contains("sub/b.bin is missing"))
            #expect(message.contains("Test Folder didn't pass its checksum check"))
        }
        #expect(!FileManager.default.fileExists(atPath: models.appendingPathComponent("test-folder").path))
    }

    @Test func aFileWithNoPinnedChecksumIsRefused() throws {
        let source = try scratch(), models = try scratch()
        try write("abc", source.appendingPathComponent("a.bin"))
        try write("foo", source.appendingPathComponent("sub/b.bin"))
        #expect(throws: LocalModelError.self) {
            try LocalModelStore.install(folderModel, from: source, into: models, checksums: ["a.bin": sums["a.bin"]!])
        }
    }
}
