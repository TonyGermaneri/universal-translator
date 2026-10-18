import SwiftUI
import TranslatorCore

/// The notepad's settings (stored on the device; the Mac app has no notepad).
enum Notepad {
    static let enabledKey = "notepad.enabled"
    static let showSourceKey = "notepad.showSource"
    static let fontSizeKey = "notepad.fontSize"
    static let defaultFontSize: Double = Platform.deviceName == "iPad" ? 24 : 19
}

/// A paragraph of the notepad: the finished sentences between two pauses.
struct NotepadParagraph: Identifiable, Equatable {
    let id: UUID
    let time: Date
    var translation: String
    var source: String

    /// The session's finished sentences, grouped into paragraphs at the long pauses the voice detector heard
    /// (`pauses`, where each began on the audio timeline). A paragraph ends with a sentence whose speech ended where
    /// a pause began, when the next sentence's speech ends after it. Nothing depends on when translations arrive,
    /// so the breaks land in the right place however far translation runs behind.
    static func paragraphs(of sentences: [CaptionStore.Sentence], pauses: [Double], transcriptionOnly: Bool) -> [NotepadParagraph] {
        var result: [NotepadParagraph] = []
        var previous: CaptionStore.Sentence?
        for s in sentences where s.isFinished && !s.committed.isEmpty {
            // When transcribing, the "translation" is what was said.
            let source = transcriptionOnly ? "" : s.source
            var startsParagraph = result.isEmpty
            if let end = previous?.speechEnd {
                let next = s.speechEnd ?? .infinity
                // The timeline starts again from zero when listening restarts (after the app was in the background).
                let restarted = next < end - 1
                startsParagraph = startsParagraph || restarted || pauses.contains { abs($0 - end) < 1 && next > $0 + 1 }
            }
            if startsParagraph {
                result.append(NotepadParagraph(id: s.id, time: s.startedAt, translation: s.committed, source: source))
            } else {
                result[result.count - 1].translation = TextJoiner.join(result[result.count - 1].translation, s.committed)
                result[result.count - 1].source = TextJoiner.join(result[result.count - 1].source, source)
            }
            previous = s
        }
        return result
    }
}

/// Everything translated since the microphone was turned on, in the space the captions leave empty: paragraphs
/// split at pauses, each with what was said under it. It follows the newest text until you scroll back to read,
/// and Latest takes it to the end again.
struct NotepadView: View {
    let paragraphs: [NotepadParagraph]
    let fontSize: Double
    let showSource: Bool
    let direction: CaptionBox.TextDirections
    /// Where a page shorter than the notepad sits: next to the captions.
    let alignment: VerticalAlignment

    @State private var following = true
    @State private var atEnd = true
    @State private var position = ScrollPosition(edge: .bottom)

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: fontSize * 1.1) {
                    ForEach(paragraphs) { paragraph in
                        ParagraphView(paragraph: paragraph, fontSize: fontSize, showSource: showSource, direction: direction)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .textSelection(.enabled)
            }
            .scrollPosition($position)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .defaultScrollAnchor(alignment == .top ? .top : .bottom, for: .alignment)
            .scrollEdgeEffectStyle(.soft, for: .vertical)
            .onScrollGeometryChange(for: Bool.self) { geometry in
                geometry.contentOffset.y + geometry.containerSize.height >= geometry.contentSize.height - 40
            } action: { _, isAtEnd in
                atEnd = isAtEnd
            }
            .onScrollPhaseChange { old, new in
                // Only the reader's own scrolling decides whether to follow: the page growing under them doesn't.
                if new == .interacting {
                    following = false
                } else if new == .idle, old == .interacting || old == .decelerating {
                    following = atEnd
                }
            }
            .onChange(of: contentVersion) {
                if following { scrollToEnd() }
            }
            .onChange(of: fontSize) {
                if following { scrollToEnd() }
            }

            if !following {
                Button {
                    following = true
                    scrollToEnd()
                } label: {
                    Label("Latest", systemImage: "arrow.down")
                }
                .buttonStyle(.glassProminent)
                .padding(12)
                .transition(.opacity)
            }
        }
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Color.white.opacity(0.07)))
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .animation(.easeInOut(duration: 0.2), value: following)
    }

    /// Changes when a paragraph is added or the newest one grows.
    private var contentVersion: Int {
        guard let last = paragraphs.last else { return 0 }
        return paragraphs.count &* 100_003 &+ last.translation.count &+ last.source.count
    }

    private func scrollToEnd() {
        withAnimation(.easeOut(duration: 0.25)) { position.scrollTo(edge: .bottom) }
    }
}

private struct ParagraphView: View {
    let paragraph: NotepadParagraph
    let fontSize: Double
    let showSource: Bool
    let direction: CaptionBox.TextDirections

    var body: some View {
        VStack(alignment: .leading, spacing: fontSize * 0.35) {
            Text(paragraph.time, format: .dateTime.hour().minute())
                .font(.system(size: max(11, fontSize * 0.5), weight: .semibold).monospacedDigit())
                .foregroundStyle(.tertiary)
            Text(paragraph.translation)
                .font(.system(size: fontSize))
                .lineSpacing(fontSize * 0.22)
                .reading(rightToLeft: direction.targetRightToLeft)
            if showSource, !paragraph.source.isEmpty, paragraph.source != paragraph.translation {
                Text(paragraph.source)
                    .font(.system(size: fontSize * 0.7))
                    .lineSpacing(fontSize * 0.15)
                    .foregroundStyle(.secondary)
                    .reading(rightToLeft: direction.sourceRightToLeft)
            }
        }
    }
}

private extension View {
    /// Starts lines on the right for Arabic and Hebrew.
    func reading(rightToLeft: Bool) -> some View {
        multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .environment(\.layoutDirection, rightToLeft ? .rightToLeft : .leftToRight)
    }
}

/// The notepad's section in Settings.
struct NotepadSettings: View {
    @AppStorage(Notepad.enabledKey) private var enabled = true
    @AppStorage(Notepad.showSourceKey) private var showSource = true
    @AppStorage(Notepad.fontSizeKey) private var fontSize = Notepad.defaultFontSize

    var body: some View {
        Section {
            Toggle("Keep a notepad of the session", isOn: $enabled)
            if enabled {
                Toggle("Show what was said", isOn: $showSource)
                SliderRow(title: "Text size", value: $fontSize, range: 14...44, step: 1, format: Fmt.points)
            }
        } header: {
            Text("Notepad")
        } footer: {
            Text("Everything translated since you turned on the microphone, in the space above the captions. Turning the microphone on again starts a new page; the transcript and its export cover the same session.")
        }
    }
}
