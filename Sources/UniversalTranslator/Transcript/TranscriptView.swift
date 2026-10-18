import SwiftUI
import TranslatorCore
import UniformTypeIdentifiers

/// The whole session as a scrollable transcript: every translated sentence with its original, the sentence in
/// progress at the bottom, search, copy and export. Follows the latest sentence until you scroll up.
struct TranscriptView: View {
    let captions: CaptionStore
    let app: AppController
    @State private var query = ""
    @State private var showOriginal = true
    @State private var following = true
    @State private var position = ScrollPosition(edge: .bottom)
    @AppStorage("transcript.fontSize") private var fontSize = 15.0

    private static let bottomID = "bottom"

    private var rows: [CaptionStore.Sentence] {
        let all = captions.isDemo ? [] : captions.sentences
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return all }
        return all.filter {
            $0.source.localizedCaseInsensitiveContains(q) || ($0.committed + $0.ghost).localizedCaseInsensitiveContains(q)
        }
    }

    var body: some View {
        let rows = rows
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    if rows.isEmpty {
                        Text(query.isEmpty ? "Translated sentences appear here as you speak." : "No matches.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 200)
                    }
                    ForEach(rows) { sentence in
                        TranscriptRow(sentence: sentence, sessionStart: captions.sessionStartDate,
                                      showOriginal: showOriginal, fontSize: fontSize)
                    }
                    if !captions.liveSource.isEmpty, query.isEmpty {
                        Text(captions.liveSource)
                            .font(.system(size: fontSize * 0.85))
                            .foregroundStyle(.tertiary)
                            .italic()
                    }
                    Color.clear.frame(height: 1).id(Self.bottomID)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
                .textSelection(.enabled)
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
            } action: { _, atBottom in
                following = atBottom
            }
            .onChange(of: captions.lastActivity) {
                if following, query.isEmpty { position.scrollTo(id: Self.bottomID, anchor: .bottom) }
            }

            if !following, query.isEmpty {
                Button {
                    following = true
                    withAnimation { position.scrollTo(id: Self.bottomID, anchor: .bottom) }
                } label: {
                    Label("Latest", systemImage: "arrow.down")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(16)
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 300)
        #endif
        .searchable(text: $query, placement: .toolbar, prompt: "Search transcript")
        .toolbar {
            ToolbarItemGroup(placement: Self.toolbarPlacement) {
                Toggle(isOn: $showOriginal) {
                    Label("Original", systemImage: "text.bubble")
                }
                .help("Show the original speech under each translation")
                Button {
                    fontSize = max(11, fontSize - 1)
                } label: {
                    Label("Smaller", systemImage: "textformat.size.smaller")
                }
                Button {
                    fontSize = min(28, fontSize + 1)
                } label: {
                    Label("Larger", systemImage: "textformat.size.larger")
                }
                Button(action: copyAll) {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .help("Copy the whole transcript")
                #if os(macOS)
                Button {
                    app.exportTranscript()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .help("Export as subtitles (.srt, .vtt) or text")
                #else
                Menu {
                    ForEach(TranscriptFile.Format.allCases, id: \.self) { format in
                        ShareLink(item: TranscriptFile(entries: captions.sessionEntries, format: format),
                                  preview: SharePreview(format.title)) {
                            Text(format.title)
                        }
                    }
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .disabled(captions.sessionEntries.isEmpty)
                #endif
            }
        }
    }

    #if os(macOS)
    private static let toolbarPlacement = ToolbarItemPlacement.automatic
    #else
    private static let toolbarPlacement = ToolbarItemPlacement.bottomBar
    #endif

    private func copyAll() {
        Platform.copyToPasteboard(SubtitleExporter.text(captions.sessionEntries))
    }
}

/// The session as a subtitle or text file, for the share sheet.
struct TranscriptFile: Transferable {
    enum Format: CaseIterable {
        case srt, vtt, text

        var title: String {
            switch self {
            case .srt: return "Subtitles (.srt)"
            case .vtt: return "Web subtitles (.vtt)"
            case .text: return "Text"
            }
        }

        var fileExtension: String {
            switch self {
            case .srt: return "srt"
            case .vtt: return "vtt"
            case .text: return "txt"
            }
        }
    }

    let entries: [SessionEntry]
    let format: Format

    var text: String {
        switch format {
        case .srt: return SubtitleExporter.srt(entries, includeSource: true)
        case .vtt: return SubtitleExporter.vtt(entries, includeSource: true)
        case .text: return SubtitleExporter.text(entries)
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(exportedContentType: .plainText) { file in
            let name = "Translation \(Date().formatted(date: .abbreviated, time: .shortened))"
                .replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: ".")
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name).\(file.format.fileExtension)")
            try file.text.write(to: url, atomically: true, encoding: .utf8)
            return SentTransferredFile(url)
        }
    }
}

private struct TranscriptRow: View {
    let sentence: CaptionStore.Sentence
    let sessionStart: Date
    let showOriginal: Bool
    let fontSize: Double

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(timestamp)
                .font(.system(size: fontSize * 0.7).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: fontSize * 3.2, alignment: .trailing)
            VStack(alignment: .leading, spacing: 4) {
                translation
                    .font(.system(size: fontSize))
                if showOriginal, !sentence.source.isEmpty {
                    Text(sentence.source)
                        .font(.system(size: fontSize * 0.8))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if sentence.revisions > 0 {
                Image(systemName: "pencil.circle")
                    .foregroundStyle(.secondary)
                    .help("Revised by the second pass")
            }
        }
    }

    private var translation: Text {
        if sentence.isFinished || sentence.ghost.isEmpty {
            return Text(sentence.committed.isEmpty && !sentence.isFinished ? "…" : sentence.committed)
        }
        return Text("\(sentence.committed)\(Text(sentence.ghost).foregroundStyle(.secondary).italic())")
    }

    private var timestamp: String {
        let seconds = Int(max(0, sentence.startedAt.timeIntervalSince(sessionStart)))
        return seconds >= 3600
            ? String(format: "%d:%02d:%02d", seconds / 3600, (seconds / 60) % 60, seconds % 60)
            : String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}
