import SwiftUI
import UniformTypeIdentifiers
import PDFKit

@main
struct ClaudePDFApp: App {
    var body: some Scene {
        DocumentGroup(viewing: PDFFileDocument.self) { configuration in
            DocumentWindow(document: configuration.document, fileURL: configuration.fileURL)
        }
        // The top bar is drawn by the window itself — dense, with the traffic
        // lights in its leading inset — so the system title bar goes.
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
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
    @StateObject private var canvas = CanvasState()
    @State private var pdf: PDFDocument?
    @State private var navigationPane: NavigationPane? = .pages
    @State private var lastNavigationPane: NavigationPane = .pages
    @State private var assistantOpen = true
    @State private var cropMode = false
    @FocusState private var searchFocused: Bool
    @Environment(\.openSettings) private var openSettings

    // Watched so a change in Settings reaches documents that are already open.
    @AppStorage(AppSettings.providerChoiceKey) private var providerChoice = ProviderChoice.automatic.rawValue
    @AppStorage(AppSettings.anthropicModelKey) private var anthropicModel = AnthropicModel.sonnet5.rawValue
    @AppStorage(AppSettings.claudeCodeModelKey) private var claudeCodeModel = ClaudeCodeModel.cliDefault.rawValue
    @AppStorage(AppSettings.claudeCodeEffortKey) private var claudeCodeEffort = ClaudeCodeEffort.cliDefault.rawValue
    @AppStorage(AppSettings.deepseekModelKey) private var deepseekModel = DeepSeekModel.v4Flash.rawValue
    @AppStorage(AppSettings.deepseekThinkingKey) private var deepseekThinking = DeepSeekThinking.low.rawValue

    @AppStorage(AppSettings.appearanceKey)
    private var appearance = AppearanceMode.matchSystem.rawValue
    @Environment(\.colorScheme) private var colorScheme

    /// Set by ⇧⌘D and the top bar's moon, and scoped to this window. `nil` means
    /// "still following Settings".
    @State private var appearanceOverride: AppearanceMode?

    private var appearanceMode: AppearanceMode {
        appearanceOverride ?? AppearanceMode(rawValue: appearance) ?? .matchSystem
    }

    private var darkPages: Bool {
        appearanceMode.darkPages(system: colorScheme)
    }

    private var followsSystem: Bool {
        appearanceMode == .matchSystem
    }

    private var title: String {
        fileURL?.lastPathComponent ?? "Untitled.pdf"
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(
                title: title,
                viewer: viewer,
                canvas: canvas,
                navigationOpen: navigationOpenBinding,
                assistantOpen: $assistantOpen,
                darkPages: darkModeBinding,
                searchFocused: $searchFocused,
                onSnapshot: { cropMode.toggle() }
            )
            HStack(spacing: 0) {
                NavigationRail(pane: $navigationPane, openSettings: { openSettings() })
                VRule()
                if let navigationPane, let pdf {
                    NavigationPanel(
                        pane: navigationPane,
                        document: pdf,
                        viewer: viewer,
                        engine: engine,
                        darkPages: darkPages,
                        onClose: { self.navigationPane = nil },
                        onOpenConversation: { assistantOpen = true }
                    )
                    .frame(width: 216)
                    VRule()
                }
                canvasArea
                    .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity)
                if assistantOpen {
                    VRule()
                    AssistantPanel(
                        engine: engine,
                        viewer: viewer,
                        onClose: { assistantOpen = false },
                        onSnapshot: { cropMode = true }
                    )
                    .frame(width: 340)
                }
            }
            StatusBar(viewer: viewer, canvas: canvas, engine: engine)
        }
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 980, minHeight: 560)
        .preferredColorScheme(appearanceMode.preferredColorScheme)
        .background(hiddenShortcuts)
        .background(TrafficLightAligner())
        .onAppear(perform: load)
        .onChange(of: navigationPane) { _, pane in
            if let pane { lastNavigationPane = pane }
        }
        .onChange(of: providerSettings) { _, _ in
            applyProviderSettings()
        }
    }

    private var canvasArea: some View {
        ZStack(alignment: .topLeading) {
            ChromeInk.canvas
            if let pdf {
                CanvasPDFRepresentable(
                    document: pdf,
                    controller: viewer,
                    canvas: canvas,
                    darkPages: darkPages,
                    followsSystem: followsSystem,
                    onAskAboutSelection: captureSelection
                )
                if cropMode {
                    CropOverlay(onCrop: handleCrop)
                }
            } else {
                ContentUnavailableView("Could not load PDF", systemImage: "doc.questionmark")
            }
            QuickToolPalette(canvas: canvas, cropMode: $cropMode, onAsk: captureSelection)
                .snapshotOverlay("palette")
                .padding(12)
            if cropMode {
                CropHint { cropMode = false }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
            }
        }
        .clipped()
    }

    private var navigationOpenBinding: Binding<Bool> {
        Binding(
            get: { navigationPane != nil },
            set: { navigationPane = $0 ? lastNavigationPane : nil }
        )
    }

    /// Steers this window and nothing else, and picks a side explicitly rather
    /// than going back to `matchSystem`.
    private var darkModeBinding: Binding<Bool> {
        Binding(
            get: { darkPages },
            set: { appearanceOverride = $0 ? .dark : .light }
        )
    }

    /// Invisible buttons that exist only to carry keyboard shortcuts.
    private var hiddenShortcuts: some View {
        HStack(spacing: 0) {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("") { captureSelection() }
                .keyboardShortcut("l", modifiers: .command)
            Button("") { cropMode.toggle() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
            Button("") { appearanceOverride = darkPages ? .light : .dark }
                .keyboardShortcut("d", modifiers: [.command, .shift])
            Button("") { assistantOpen.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("") { navigationOpenBinding.wrappedValue.toggle() }
                .keyboardShortcut("s", modifiers: [.command, .control])
            Button("") { viewer.zoomOut() }
                .keyboardShortcut("-", modifiers: .command)
            Button("") { canvas.fitWidth() }
                .keyboardShortcut("0", modifiers: .command)
            Button("") { viewer.zoomIn() }
                .keyboardShortcut("=", modifiers: .command)
            Button("") { viewer.previousMatch() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Button("") { viewer.nextMatch() }
                .keyboardShortcut("g", modifiers: .command)
            Button("") {
                engine.startNewThread(at: viewer.currentPageAnchor)
                assistantOpen = true
                engine.requestComposerFocus()
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("") { engine.selectAdjacentThread(offset: -1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
            Button("") { engine.selectAdjacentThread(offset: 1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
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

    /// "Ask About Selection" (context menu, palette or ⌘L): stage the selection
    /// in the assistant's composer.
    private func captureSelection() {
        guard let selection = viewer.selectionInfo() else { return }
        assistantOpen = true
        engine.pendingSelection = selection
        engine.requestComposerFocus()
    }

    private func handleCrop(rect: CGRect, overlay: NSView) {
        defer { cropMode = false }
        guard let pdfView = viewer.pdfView,
              let crop = CropExtractor.makeCrop(viewRect: rect, overlay: overlay, pdfView: pdfView)
        else { return }
        assistantOpen = true
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
        // Which provider answers is frozen in a window the reader has steered;
        // how it answers — thinking, effort, model — is not. `applySettings`
        // draws that line, because the engine is where it can be tested.
        engine.applySettings()
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
        #if DEBUG
        if let pane = ProcessInfo.processInfo.environment["CLAUDEPDF_PANE"] {
            navigationPane = NavigationPane(rawValue: pane)
        }
        DebugSnapshot.scheduleIfRequested(engine: engine, viewer: viewer)
        #endif
    }
}

private struct VRule: View {
    var body: some View {
        Rectangle().fill(ChromeInk.divider).frame(width: 1)
    }
}
