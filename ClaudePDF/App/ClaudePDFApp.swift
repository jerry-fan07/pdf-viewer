import SwiftUI
import UniformTypeIdentifiers
import PDFKit

@main
struct ClaudePDFApp: App {
    var body: some Scene {
        DocumentGroup(viewing: PDFFileDocument.self) { configuration in
            DocumentWindow(document: configuration.document, fileURL: configuration.fileURL)
        }
        Settings {
            SettingsView()
        }
    }
}

/// Read-only wrapper so DocumentGroup gives us Open/Recents/Finder integration.
struct PDFFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.pdf] }

    let data: Data

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = data
    }

    // Viewer only — never called in practice, but FileDocument requires it.
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct DocumentWindow: View {
    let document: PDFFileDocument
    let fileURL: URL?

    @StateObject private var viewer = PDFViewerController()
    @StateObject private var engine = ChatEngine(provider: ProviderFactory.make())
    @State private var pdf: PDFDocument?
    @State private var chatVisible = true
    @State private var thumbnailsVisible = false
    @State private var cropMode = false
    @State private var pageField = "1"
    @FocusState private var searchFocused: Bool

    // Watched so a change in Settings reaches documents that are already open.
    @AppStorage(AppSettings.providerChoiceKey) private var providerChoice = ProviderChoice.automatic.rawValue
    @AppStorage(AppSettings.anthropicModelKey) private var anthropicModel = AnthropicModel.opus5.rawValue
    @AppStorage(AppSettings.claudeCodeModelKey) private var claudeCodeModel = ClaudeCodeModel.cliDefault.rawValue
    @AppStorage(AppSettings.claudeCodeEffortKey) private var claudeCodeEffort = ClaudeCodeEffort.cliDefault.rawValue
    @AppStorage(AppSettings.deepseekModelKey) private var deepseekModel = DeepSeekModel.v4Flash.rawValue
    @AppStorage(AppSettings.deepseekThinkingKey) private var deepseekThinking = DeepSeekThinking.low.rawValue

    // Same story for the appearance — Settings is the default every window starts from —
    // except that it is resolved against the window's own colour scheme rather than pushed
    // at the engine, and a window can be steered away from it by hand.
    @AppStorage(AppSettings.appearanceKey)
    private var appearance = AppearanceMode.matchSystem.rawValue
    @Environment(\.colorScheme) private var colorScheme

    /// Set by ⇧⌘D and the toolbar's moon, and scoped to this window: darkening the document
    /// you are reading at night must not reach across to the one on the other display.
    /// `nil` means "still following Settings", which is why this is an optional rather than
    /// a copy of the stored mode — a copy could not tell the two apart.
    @State private var appearanceOverride: AppearanceMode?

    private var appearanceMode: AppearanceMode {
        appearanceOverride ?? AppearanceMode(rawValue: appearance) ?? .matchSystem
    }

    private var darkPages: Bool {
        appearanceMode.darkPages(system: colorScheme)
    }

    /// Handed down alongside `darkPages` so the sweep can tell a sunset from a keypress: on
    /// *Match system* the pages can change without anybody touching the app, and that is the
    /// case that gets the longer crossing.
    private var followsSystem: Bool {
        appearanceMode == .matchSystem
    }

    var body: some View {
        HSplitView {
            if thumbnailsVisible {
                PDFThumbnailSidebar(controller: viewer, darkPages: darkPages, followsSystem: followsSystem)
                    .frame(width: 150)
            }

            Group {
                if let pdf {
                    ZStack {
                        PDFKitView(
                            document: pdf,
                            controller: viewer,
                            darkPages: darkPages,
                            followsSystem: followsSystem,
                            onAskAboutSelection: captureSelection
                        )
                        if cropMode {
                            CropOverlay(onCrop: handleCrop)
                        }
                    }
                } else {
                    ContentUnavailableView("Could not load PDF", systemImage: "doc.questionmark")
                }
            }
            .frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)

            if chatVisible {
                ChatPanelView(engine: engine, viewer: viewer)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 900)
            }
        }
        // The whole window, not just the pages: toolbar, sidebar and chat panel go dark
        // together. Applied here rather than to `NSApp.appearance` precisely because it is
        // per-window. `matchSystem` resolves to nil on purpose — see `AppearanceMode`.
        .preferredColorScheme(appearanceMode.preferredColorScheme)
        .toolbar { toolbarContent }
        .background(hiddenShortcuts)
        .onAppear(perform: load)
        .onChange(of: viewer.currentPageNumber) { _, page in
            pageField = String(page)
        }
        .onChange(of: providerSettings) { _, _ in
            applyProviderSettings()
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                thumbnailsVisible.toggle()
            } label: {
                Label("Thumbnails", systemImage: "sidebar.left")
            }
            .keyboardShortcut("s", modifiers: [.command, .control])
            .help("Show or hide page thumbnails (⌃⌘S)")
        }

        ToolbarItemGroup {
            ControlGroup {
                Button {
                    viewer.zoomOut()
                } label: {
                    Label("Zoom Out", systemImage: "minus.magnifyingglass")
                }
                .keyboardShortcut("-", modifiers: .command)

                Button {
                    viewer.zoomToFit()
                } label: {
                    Label("Zoom to Fit", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
                }
                .keyboardShortcut("0", modifiers: .command)

                Button {
                    viewer.zoomIn()
                } label: {
                    Label("Zoom In", systemImage: "plus.magnifyingglass")
                }
                .keyboardShortcut("=", modifiers: .command)
            }

            pageIndicator
            searchField

            Toggle(isOn: $cropMode) {
                Label("Select Region", systemImage: "crop")
            }
            .toggleStyle(.button)
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .help("Drag to screenshot a region and ask about it (⇧⌘A)")

            // One moon in both states: the button style already fills in when it is on, and a
            // sun that appears only while the app is light is a second, redundant signal.
            Toggle(isOn: darkModeBinding) {
                Label("Dark Mode", systemImage: "moon.fill")
            }
            .toggleStyle(.button)
            .keyboardShortcut("d", modifiers: [.command, .shift])
            .help("Darken this window (⇧⌘D) — Settings sets the default for other windows")

            Button {
                chatVisible.toggle()
                if chatVisible { engine.requestComposerFocus() }
            } label: {
                Label("Ask", systemImage: "bubble.left.and.text.bubble.right")
            }
            .keyboardShortcut("i", modifiers: [.command, .option])
            .help("Show or hide the chat panel (⌥⌘I)")
        }
    }

    /// Toggling steers this window and nothing else, and it picks a side explicitly rather
    /// than going back to `matchSystem`: once you have overruled the system for this document,
    /// following it again would flip the window out from under you at sunset. Same rule the
    /// provider picker follows — Settings is the default, not a remote control.
    private var darkModeBinding: Binding<Bool> {
        Binding(
            get: { darkPages },
            set: { appearanceOverride = $0 ? .dark : .light }
        )
    }

    private var pageIndicator: some View {
        HStack(spacing: 3) {
            TextField("", text: $pageField)
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.center)
                .frame(width: 46)
                .onSubmit {
                    if let page = Int(pageField) {
                        viewer.scroll(toPage: page)
                    } else {
                        pageField = String(viewer.currentPageNumber)
                    }
                }
            Text("of \(viewer.pageCount)")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .help("Current page — type a number to jump")
    }

    private var searchField: some View {
        HStack(spacing: 4) {
            TextField("Find", text: $viewer.searchQuery, prompt: Text("Find"))
                .textFieldStyle(.roundedBorder)
                .frame(width: 150)
                .focused($searchFocused)
                .onSubmit { viewer.nextMatch() }
                .onExitCommand {
                    viewer.searchQuery = ""
                    searchFocused = false
                }
            if !viewer.matches.isEmpty {
                Text("\(viewer.currentMatchIndex + 1)/\(viewer.matches.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                Button {
                    viewer.previousMatch()
                } label: {
                    Image(systemName: "chevron.up")
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .help("Previous match (⇧⌘G)")
                Button {
                    viewer.nextMatch()
                } label: {
                    Image(systemName: "chevron.down")
                }
                .keyboardShortcut("g", modifiers: .command)
                .help("Next match (⌘G)")
            } else if viewer.searchQuery.trimmingCharacters(in: .whitespaces).count >= 2 {
                Text("0 results")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    /// Invisible buttons that exist only to carry keyboard shortcuts.
    private var hiddenShortcuts: some View {
        HStack(spacing: 0) {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { captureSelection() }
                .keyboardShortcut("l", modifiers: .command)
            if cropMode {
                Button("") { cropMode = false }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    // MARK: Ask flows

    /// "Ask About Selection" (context menu or ⌘L): stage the selection and focus the composer.
    private func captureSelection() {
        guard let selection = viewer.selectionInfo() else { return }
        engine.pendingSelection = selection
        chatVisible = true
        engine.requestComposerFocus()
    }

    private func handleCrop(rect: CGRect, overlay: NSView) {
        defer { cropMode = false }
        guard let pdfView = viewer.pdfView,
              let crop = CropExtractor.makeCrop(viewRect: rect, overlay: overlay, pdfView: pdfView)
        else { return }

        chatVisible = true
        // The capability-based degradation of PLAN.md §4 lives in the engine, which
        // has to re-run it whenever the provider changes under a staged crop.
        engine.stage(crop: crop, focusComposer: true)
    }

    // MARK: Settings, applied live

    /// Everything in Settings that changes which provider — or which model —
    /// answers. Collapsed into one value because `onChange` wants one.
    private var providerSettings: String {
        [providerChoice, anthropicModel, claudeCodeModel, claudeCodeEffort,
         deepseekModel, deepseekThinking]
            .joined(separator: "|")
    }

    private func applyProviderSettings() {
        // A window whose provider was picked by hand keeps it: the Settings picker
        // is the default for newly opened documents, not a remote control for
        // windows the reader has already steered.
        guard !engine.providerIsWindowOverride else { return }
        engine.switchProvider(to: ProviderFactory.make())
    }

    // MARK: Loading

    private func load() {
        guard pdf == nil else { return }
        viewer.configureRestore(for: fileURL)   // before the PDFView attaches
        let doc = PDFDocument(data: document.data)
        pdf = doc
        if let doc, let url = fileURL {
            engine.attach(PDFDocumentInfo(fileURL: url, pageCount: doc.pageCount))
        }
    }
}
