import SwiftUI
import UniformTypeIdentifiers

struct AppearanceSettings: View {
    @Bindable var store: SettingsStore
    let app: AppController
    @State private var families: [String] = []

    var body: some View {
        Form {
            Section {
                HStack {
                    Picker("Preset", selection: Binding<OverlayPreset?>(get: { nil }, set: { preset in
                        if let preset { preset.apply(to: &store.settings.overlay) }
                    })) {
                        Text("Apply a preset…").tag(OverlayPreset?.none)
                        ForEach(OverlayPreset.allCases) { Text($0.title).tag(Optional($0)) }
                    }
                    Button("Preview") { app.showSampleCaptions() }
                }
                Note("Changes apply to the overlay live. Use Preview to show sample captions.")
            }

            Section("Text") {
                Picker("Font", selection: $store.settings.overlay.fontFamily) {
                    Text("System (SF Pro)").tag("")
                    ForEach(families, id: \.self) { Text($0).tag($0) }
                }
                SliderRow(title: "Size", value: $store.settings.overlay.fontSize, range: 14...96, step: 1, format: Fmt.points)
                Picker("Weight", selection: $store.settings.overlay.fontWeight) {
                    ForEach(FontWeightChoice.allCases) { Text($0.title).tag($0) }
                }
                ColorRow(title: "Color", color: $store.settings.overlay.textColor)
                SliderRow(title: "Line spacing", value: $store.settings.overlay.lineSpacing, range: 0...24, step: 1, format: Fmt.points)
                Picker("Alignment", selection: $store.settings.overlay.alignment) {
                    ForEach(AlignmentChoice.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
            }

            Section("Outline & shadow") {
                SliderRow(title: "Outline width", value: $store.settings.overlay.strokeWidth, range: 0...6, step: 0.5,
                          format: { $0 == 0 ? "Off" : String(format: "%.1f pt", $0) })
                if store.settings.overlay.strokeWidth > 0 {
                    ColorRow(title: "Outline color", color: $store.settings.overlay.strokeColor)
                }
                Toggle("Drop shadow", isOn: $store.settings.overlay.shadowEnabled)
                if store.settings.overlay.shadowEnabled {
                    ColorRow(title: "Shadow color", color: $store.settings.overlay.shadowColor)
                    SliderRow(title: "Shadow blur", value: $store.settings.overlay.shadowRadius, range: 0...20, step: 1, format: Fmt.points)
                }
            }

            Section("Background") {
                Picker("Style", selection: $store.settings.overlay.backgroundStyle) {
                    ForEach(BackgroundStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.settings.overlay.backgroundStyle == .box {
                    ColorRow(title: "Color", color: $store.settings.overlay.backgroundColor)
                    Toggle("Blur what's behind the box", isOn: $store.settings.overlay.backgroundBlur)
                    Toggle("Box spans the full overlay width", isOn: $store.settings.overlay.fixedWidthBox)
                    SliderRow(title: "Corner radius", value: $store.settings.overlay.cornerRadius, range: 0...40, step: 1, format: Fmt.points)
                    SliderRow(title: "Horizontal padding", value: $store.settings.overlay.paddingH, range: 0...80, step: 1, format: Fmt.points)
                    SliderRow(title: "Vertical padding", value: $store.settings.overlay.paddingV, range: 0...60, step: 1, format: Fmt.points)
                    SliderRow(title: "Border", value: $store.settings.overlay.borderWidth, range: 0...6, step: 0.5,
                              format: { $0 == 0 ? "Off" : String(format: "%.1f pt", $0) })
                    if store.settings.overlay.borderWidth > 0 {
                        ColorRow(title: "Border color", color: $store.settings.overlay.borderColor)
                    }
                }
                SliderRow(title: "Overall opacity", value: $store.settings.overlay.opacity, range: 0.2...1, format: Fmt.percent)
            }

            Section("Original speech") {
                Toggle("Show what you said alongside the translation", isOn: $store.settings.overlay.showSource)
                if store.settings.overlay.showSource {
                    Picker("Position", selection: $store.settings.overlay.sourceAbove) {
                        Text("Above translation").tag(true)
                        Text("Below translation").tag(false)
                    }
                    .pickerStyle(.segmented)
                    SliderRow(title: "Relative size", value: $store.settings.overlay.sourceScale, range: 0.3...1, format: Fmt.percent)
                    ColorRow(title: "Color", color: $store.settings.overlay.sourceColor)
                    if store.settings.overlay.layout != .marquee {
                        Stepper("Lines: \(store.settings.overlay.sourceMaxLines)", value: $store.settings.overlay.sourceMaxLines, in: 1...4)
                    }
                }
            }

            Section("Live captions") {
                Toggle("Show provisional words (still settling) while you speak", isOn: $store.settings.overlay.showProvisional)
                if store.settings.overlay.showProvisional {
                    SliderRow(title: "Provisional opacity", value: $store.settings.overlay.provisionalOpacity, range: 0.2...1, format: Fmt.percent)
                    Toggle("Provisional words in italic", isOn: $store.settings.overlay.provisionalItalic)
                }
                Toggle("Fade in words as they become final", isOn: $store.settings.overlay.fadeInNewWords)
                Toggle("Highlight words changed by the second pass", isOn: $store.settings.overlay.highlightRevisions)
                if store.settings.overlay.highlightRevisions {
                    ColorRow(title: "Highlight color", color: $store.settings.overlay.revisionColor)
                }
                Toggle("Show a badge when the translation falls behind", isOn: $store.settings.overlay.showLagIndicator)
                Note("Effects follow the system's Reduce Motion setting.")
            }
        }
        .task {
            families = Platform.fontFamilies
        }
    }
}

struct LayoutSettings: View {
    @Bindable var store: SettingsStore
    let app: AppController

    private var readingLimit: Binding<Bool> {
        Binding { store.settings.overlay.readingSpeed > 0 } set: { store.settings.overlay.readingSpeed = $0 ? 17 : 0 }
    }

    private var autoClear: Binding<Bool> {
        Binding { store.settings.overlay.autoClearAfter > 0 } set: { store.settings.overlay.autoClearAfter = $0 ? 12 : 0 }
    }

    var body: some View {
        Form {
            #if os(macOS)
            Section {
                HStack {
                    Button(store.settings.overlay.clickThrough ? "Unlock to drag & resize" : "Lock in place") {
                        app.overlay.toggleLock()
                    }
                    Button("Preview") { app.showSampleCaptions() }
                    Spacer()
                    Button("Reset overlay", role: .destructive) { store.resetOverlay() }
                }
                Note("When unlocked, drag the overlay anywhere and use the ↔ handle to change its width. Lock it again so clicks pass through to the apps underneath.")
            }
            #else
            Section {
                Button("Preview") { app.showSampleCaptions() }
                Button("Reset captions to defaults", role: .destructive) { store.resetOverlay() }
            }

            Section("Position") {
                Picker("Captions sit at the", selection: $store.settings.overlay.anchor) {
                    Text("Top").tag(OverlayAnchor.top)
                    Text("Middle").tag(OverlayAnchor.center)
                    Text("Bottom").tag(OverlayAnchor.bottom)
                }
                .pickerStyle(.segmented)
            }
            #endif

            #if os(macOS)
            Section("Position") {
                Picker("Display", selection: $store.settings.overlay.screenMode) {
                    ForEach(ScreenMode.allCases) { Text($0.title).tag($0) }
                }
                if store.settings.overlay.screenMode == .specific {
                    Picker("Screen", selection: $store.settings.overlay.screenName) {
                        ForEach(NSScreen.screens.map(\.localizedName), id: \.self) { Text($0).tag($0) }
                    }
                }
                LabeledContent("Anchor") {
                    HStack(alignment: .center, spacing: 12) {
                        if store.settings.overlay.anchor == .custom {
                            Text("Custom (dragged)").foregroundStyle(.secondary)
                        }
                        AnchorPicker(anchor: $store.settings.overlay.anchor)
                    }
                }
                SliderRow(title: "Width", value: $store.settings.overlay.widthFraction, range: 0.2...1, format: Fmt.percent)
                SliderRow(title: "Horizontal margin", value: $store.settings.overlay.marginX, range: 0...400, step: 1, format: Fmt.points)
                SliderRow(title: "Vertical margin", value: $store.settings.overlay.marginY, range: 0...400, step: 1, format: Fmt.points)
            }
            #endif

            Section("Captions") {
                Picker("Layout", selection: $store.settings.overlay.layout) {
                    ForEach(CaptionLayout.allCases) { Text($0.title).tag($0) }
                }
                if store.settings.overlay.layout == .marquee {
                    SliderRow(title: "Scroll speed", value: $store.settings.overlay.marqueeSpeed, range: 4...30, step: 1,
                              format: { String(format: "%.0f characters/s", $0) },
                              help: "How fast the text moves once it has caught up with the speaker (Chinese and Japanese characters count as two). It speeds up while words are waiting to come on screen, so it keeps up with the speaker.")
                    Note("One line of text crosses the screen like a news ticker; the original speech gets its own line. With Reduce Motion on, captions roll instead.")
                } else {
                    Stepper("Translation lines: \(store.settings.overlay.maxLines)", value: $store.settings.overlay.maxLines, in: 1...8)
                }
                if store.settings.overlay.layout == .stacked {
                    SliderRow(title: "Older line opacity", value: $store.settings.overlay.olderLineOpacity, range: 0.2...1, format: Fmt.percent)
                }
                SliderRow(title: "Start a fresh caption after", value: $store.settings.overlay.paragraphBreak, range: 1...15,
                          format: Fmt.seconds, help: "After this much silence, the next words start a new caption instead of continuing the last one.")
                Toggle("Show listening indicator", isOn: $store.settings.overlay.showStatusIndicator)
                Toggle("Show privacy indicator (on this \(Platform.deviceName) / sends text elsewhere)", isOn: $store.settings.overlay.showPrivacyIndicator)
                    .disabled(!store.settings.overlay.showStatusIndicator)
            }

            Section("Readability") {
                Toggle("Limit reading speed", isOn: readingLimit)
                if store.settings.overlay.readingSpeed > 0 {
                    SliderRow(title: "Reading speed", value: $store.settings.overlay.readingSpeed, range: 10...30, step: 1,
                              format: { String(format: "%.0f characters/s", $0) },
                              help: "A line stays until it has been on screen long enough to read at this speed (subtitle guidelines suggest 15–20; Chinese and Japanese characters count as two). When speech comes faster, the caption briefly grows instead of scrolling a line away unread. New words are never delayed.")
                    Stepper("Extra lines while catching up: \(store.settings.overlay.readingExtraLines)",
                            value: $store.settings.overlay.readingExtraLines, in: 1...3)
                }
                Toggle("Clear captions after a silence", isOn: autoClear)
                if store.settings.overlay.autoClearAfter > 0 {
                    SliderRow(title: "Clear after", value: $store.settings.overlay.autoClearAfter, range: 3...60, step: 1,
                              format: Fmt.seconds,
                              help: "Captions are cleared after this much silence, but never before the last one has had time to be read.")
                }
            }

            #if os(macOS)
            Section("Window") {
                Picker("Stay on top of", selection: $store.settings.overlay.level) {
                    ForEach(OverlayLevel.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Click-through (locked)", isOn: $store.settings.overlay.clickThrough)
                Toggle("Show on all Spaces", isOn: $store.settings.overlay.allSpaces)
                Toggle("Hide from screen recording and screen sharing", isOn: $store.settings.overlay.hideFromScreenCapture)
                Toggle("Hide automatically when idle", isOn: $store.settings.overlay.autoHide)
                if store.settings.overlay.autoHide {
                    SliderRow(title: "Hide after", value: $store.settings.overlay.autoHideDelay, range: 2...60, step: 1, format: Fmt.seconds)
                }
            }
            #endif

            Section("Animation") {
                Picker("New lines (stacked layout)", selection: $store.settings.overlay.textAnimation) {
                    ForEach(TextAnimationStyle.allCases) { Text($0.title).tag($0) }
                }
                SliderRow(title: "Duration (also used to fade the overlay in and out)",
                          value: $store.settings.overlay.animationDuration, range: 0.05...1, format: Fmt.seconds)
                Note("Rolling captions update in place, the way live captions do.")
            }
        }
    }
}
