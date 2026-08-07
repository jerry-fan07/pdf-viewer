import SwiftUI
import PDFKit

/// View model for the PDF pane: owns the live PDFView, current page, zoom, search,
/// and per-document scroll restore. Chat citations and selection capture go through here too.
@MainActor
final class PDFViewerController: ObservableObject {
    private(set) weak var pdfView: PDFView?

    @Published private(set) var viewReady = false
    @Published private(set) var currentPageNumber = 1   // 1-indexed
    @Published private(set) var pageCount = 0

    /// Region-crop mode: the overlay is mounted only while this is true (PLAN.md §4B).
    @Published var cropModeActive = false

    /// The selection or crop the next question will be asked about. Staged rather than read
    /// at submit time, because a crop stops existing the moment the drag ends.
    @Published private(set) var anchor: QuestionAnchor?

    /// Set when a crop lands somewhere unusable, so the UI can say why nothing happened.
    @Published var anchorError: String?

    @Published var searchQuery = "" {
        didSet { if searchQuery != oldValue { scheduleSearch() } }
    }
    @Published private(set) var matches: [PDFSelection] = []
    @Published private(set) var currentMatchIndex = 0   // 0-based

    /// Mirrors `selectionInfo() != nil`. Published rather than computed so the "Ask about
    /// Selection" control actually re-enables when the user highlights text — SwiftUI has no
    /// other way to learn that PDFKit's selection changed.
    @Published private(set) var hasTextSelection = false

    private var observers: [NSObjectProtocol] = []
    private var searchTask: Task<Void, Never>?
    private var restoreDefaultsKey: String?

    // MARK: Lifecycle

    /// Must be called before the PDFView attaches so restore has its key.
    func configureRestore(for url: URL?) {
        restoreDefaultsKey = url.map { "lastPage:\($0.path)" }
    }

    func attach(view: PDFView) {
        pdfView = view
        pageCount = view.document?.pageCount ?? 0
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = [
            NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.pageDidChange() }
            },
            NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged, object: view, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.selectionDidChange() }
            },
        ]
        restoreScrollPosition()
        pageDidChange()
        selectionDidChange()
        viewReady = true
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    private func pageDidChange() {
        guard let view = pdfView, let document = view.document, let page = view.currentPage else { return }
        currentPageNumber = document.index(for: page) + 1
        if let key = restoreDefaultsKey {
            UserDefaults.standard.set(currentPageNumber, forKey: key)
        }
    }

    private func restoreScrollPosition() {
        guard let key = restoreDefaultsKey,
              let view = pdfView, let document = view.document else { return }
        let saved = UserDefaults.standard.integer(forKey: key)
        guard saved > 1, saved <= document.pageCount, let page = document.page(at: saved - 1) else { return }
        view.go(to: page)
    }

    // MARK: Navigation & zoom

    /// Scroll to a 1-indexed page (citation chips and the page field call this).
    func scroll(toPage pageNumber: Int) {
        guard let view = pdfView,
              let document = view.document,
              pageNumber >= 1, pageNumber <= document.pageCount,
              let page = document.page(at: pageNumber - 1) else { return }
        let top = NSPoint(x: 0, y: page.bounds(for: .mediaBox).height)
        view.go(to: PDFDestination(page: page, at: top))
    }

    func zoomIn() { pdfView?.zoomIn(nil) }
    func zoomOut() { pdfView?.zoomOut(nil) }

    func zoomToFit() {
        guard let view = pdfView else { return }
        view.scaleFactor = view.scaleFactorForSizeToFit
        view.autoScales = true
    }

    // MARK: Selection & crop (for chat)

    /// Current text selection plus its 1-indexed page, if any.
    func selectionInfo() -> (text: String, page: Int?)? {
        guard let view = pdfView,
              let selection = view.currentSelection,
              let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var page: Int?
        if let first = selection.pages.first, let document = view.document {
            page = document.index(for: first) + 1
        }
        return (text, page)
    }

    private func selectionDidChange() {
        hasTextSelection = selectionInfo() != nil
    }

    /// ⌘L / "Ask about Selection": stage the live text selection as the question's anchor.
    @discardableResult
    func captureTextSelection() -> Bool {
        guard let info = selectionInfo() else {
            anchorError = "Select some text in the document first."
            return false
        }
        anchorError = nil
        anchor = .text(info.text, page: info.page)
        return true
    }

    func toggleCropMode() {
        cropModeActive.toggle()
        if cropModeActive { anchorError = nil }
    }

    func cancelCrop() {
        cropModeActive = false
    }

    func clearAnchor() {
        anchor = nil
        anchorError = nil
    }

    /// Finish a crop drag: overlay coords → PDFView coords → page space → PNG.
    /// All arithmetic lives in CropGeometry/CropRenderer; this just sequences it.
    func completeCrop(rect overlayRect: CGRect, from overlay: NSView) {
        cropModeActive = false
        guard let view = pdfView, let document = view.document else { return }

        let viewRect = CropGeometry.viewRect(overlayRect, from: overlay, to: view)
        guard let page = CropGeometry.page(for: viewRect, in: view) else {
            anchorError = "That drag didn't land on a page."
            return
        }
        let pageRect = CropGeometry.pageRect(for: viewRect, in: view, on: page)
        guard let capture = CropRenderer.capture(
            page: page, pageIndex: document.index(for: page), pageRect: pageRect
        ) else {
            anchorError = "That region is off the page or too small to capture."
            return
        }
        anchorError = nil
        anchor = .region(capture)
    }

    /// Consume the staged anchor, falling back to a live text selection if the user never
    /// pressed ⌘L but does have text selected.
    func takeAnchor() -> QuestionAnchor? {
        if let anchor {
            self.anchor = nil
            return anchor
        }
        guard let info = selectionInfo() else { return nil }
        return .text(info.text, page: info.page)
    }

    // MARK: Search

    private func scheduleSearch() {
        searchTask?.cancel()
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard query.count >= 2 else {
            clearMatches()
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.performSearch(query)
        }
    }

    // Synchronous findString is fine for Phase 1; switch to beginFindString (async,
    // notification-based) if very large documents make typing hitch.
    private func performSearch(_ query: String) {
        guard let view = pdfView, let document = view.document else { return }
        let found = Array(document.findString(query, withOptions: [.caseInsensitive]).prefix(500))
        for selection in found { selection.color = .systemYellow }
        matches = found
        currentMatchIndex = 0
        view.highlightedSelections = found.isEmpty ? nil : found
        if let first = found.first { show(match: first) }
    }

    func nextMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex + 1) % matches.count
        show(match: matches[currentMatchIndex])
    }

    func previousMatch() {
        guard !matches.isEmpty else { return }
        currentMatchIndex = (currentMatchIndex - 1 + matches.count) % matches.count
        show(match: matches[currentMatchIndex])
    }

    private func show(match: PDFSelection) {
        guard let view = pdfView else { return }
        view.go(to: match)
        view.setCurrentSelection(match, animate: true)
    }

    private func clearMatches() {
        matches = []
        currentMatchIndex = 0
        pdfView?.highlightedSelections = nil
    }
}

// MARK: - Representables

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let controller: PDFViewerController

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = false
        view.document = document
        // Defer: attach() publishes state, which must not happen during view construction.
        DispatchQueue.main.async { controller.attach(view: view) }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document !== document {
            nsView.document = document
            DispatchQueue.main.async { controller.attach(view: nsView) }
        }
    }
}

/// Page-thumbnail sidebar bound to the main PDFView (PDFKit keeps them in sync).
struct PDFThumbnailSidebar: NSViewRepresentable {
    @ObservedObject var controller: PDFViewerController

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.thumbnailSize = CGSize(width: 96, height: 128)
        view.backgroundColor = .clear
        return view
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        // controller.viewReady flips after the PDFView attaches, re-running this update.
        if nsView.pdfView !== controller.pdfView {
            nsView.pdfView = controller.pdfView
        }
    }
}
