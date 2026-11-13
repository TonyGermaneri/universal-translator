import Foundation
import TranslatorCore

/// Saves each listening session's transcript to a text file as it goes (Settings → General → Transcript). The file
/// is written once the first sentence finishes, then rewritten shortly after each sentence finishes or is revised,
/// so it always holds every finished sentence in its latest form, whatever the overlay has scrolled away.
@MainActor
final class TranscriptAutosave {
    /// Documents › Universal Translator, or `UT_TRANSCRIPTS_DIR` (a test hook).
    nonisolated static var defaultFolder: URL {
        if let path = ProcessInfo.processInfo.environment["UT_TRANSCRIPTS_DIR"] {
            return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        }
        let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Documents")
        return documents.appendingPathComponent("Universal Translator")
    }

    let folder: URL
    /// Seconds between a change and the file being rewritten.
    var delay: TimeInterval = 1
    private(set) var fileURL: URL?
    private var began: Date?
    private var languages = ""
    private var order: [UUID] = []
    private var entries: [UUID: TranscriptText.Entry] = [:]
    private var pending: DispatchWorkItem?

    init(folder: URL = TranscriptAutosave.defaultFolder) {
        self.folder = folder
    }

    var isRecording: Bool { began != nil }

    /// Starts a new transcript (a new file) for a session beginning `date`.
    func begin(languages: String, at date: Date = Date()) {
        end()
        began = date
        self.languages = languages
        fileURL = folder.appendingPathComponent(TranscriptText.fileName(started: date))
    }

    /// A sentence finished or changed after finishing (second-pass revision, corrected original). Sentences from
    /// before the session began are left out.
    func record(id: UUID, started: Date, source: String, translation: String) {
        guard let began, started >= began.addingTimeInterval(-1) else { return }
        if entries[id] == nil { order.append(id) }
        entries[id] = TranscriptText.Entry(started: started, source: source, translation: translation)
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// Writes the file now, if there's anything to write.
    func flush() {
        pending?.cancel()
        pending = nil
        guard let began, let fileURL, !order.isEmpty else { return }
        let text = TranscriptText.text(started: began, languages: languages, entries: order.compactMap { entries[$0] })
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            DebugLog.write("TRANSCRIPT saved \(order.count) sentences to \(fileURL.path)")
        } catch {
            DebugLog.write("TRANSCRIPT failed: \(error.localizedDescription)")
        }
    }

    /// Writes what's pending and stops: the next session gets a new file.
    func end() {
        flush()
        began = nil
        fileURL = nil
        order = []
        entries = [:]
    }
}
