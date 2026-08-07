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
    @StateObject private var engine = ChatEngine(provider: MockProvider())
    @State private var pdf: PDFDocument?
    @State private var chatVisible = true
    @State private var thumbnailsVisible = false
    @State private var pageField = "1"
    @FocusState private var searchFocused: Bool

    var body: some View {
        HSplitView {
            if thumbnailsVisible {
                PDFThumbnailSidebar(controller: viewer)
                    .frame(width: 150)
            }

            Group {
                if let pdf {
                    ZStack(alignment: .top) {
                        PDFKitView(document: pdf, controller: viewer)
                        if viewer.cropModeActive {
                            CropOverlay(
                                onCrop: { rect, overlay in
                                    viewer.completeCrop(rect: rect, from: overlay)
                                    chatVisible = true
                                },
                                onCancel: viewer.cancelCrop
                            )
                            // Explicit fill: a bare NSView has no intrinsic size, and the
                            // overlay must cover exactly the same area as the PDFView.
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            cropHint
                        }
                    }
                } else {
                    ContentUnavailableView("Could not load PDF", systemImage: "doc.questionmark")
                }
            }
            .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)

            if chatVisible {
                ChatPanelView(engine: engine, viewer: viewer)
                    .frame(minWidth: 300, idealWidth: 360, maxWidth: 480)
            }
        }
        .toolbar { toolbarContent }
        .background(hiddenShortcuts)
        .onAppear(perform: load)
        .onChange(of: viewer.currentPageNumber) { _, page in
            pageField = String(page)
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
            .help("Show or hide page thumbnails")
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

            Button {
                if viewer.captureTextSelection() { chatVisible = true }
            } label: {
                Label("Ask about Selection", systemImage: "text.viewfinder")
            }
            .disabled(!viewer.hasTextSelection)
            .help("Ask about the highlighted text (⌘L)")

            Button {
                viewer.toggleCropMode()
            } label: {
                Label("Screenshot Region", systemImage: "rectangle.dashed")
            }
            .background(cropModeTint)
            .help("Drag a rectangle to ask about a figure, table, or equation (⌘⇧A)")

            Button {
                chatVisible.toggle()
            } label: {
                Label("Ask", systemImage: "bubble.left.and.text.bubble.right")
            }
            .help("Show or hide the chat panel")
        }
    }

    /// Toolbar buttons have no built-in "on" state; a tint behind the icon carries it.
    @ViewBuilder
    private var cropModeTint: some View {
        if viewer.cropModeActive {
            RoundedRectangle(cornerRadius: 5).fill(.tint.opacity(0.3))
        }
    }

    private var cropHint: some View {
        Text("Drag to select a region — Esc to cancel")
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            .padding(.top, 12)
            .allowsHitTesting(false)
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
        ZStack {
            Button("") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
            Button("") {
                if viewer.captureTextSelection() { chatVisible = true }
            }
            .keyboardShortcut("l", modifiers: .command)
            Button("") { viewer.toggleCropMode() }
                .keyboardShortcut("a", modifiers: [.command, .shift])
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
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
