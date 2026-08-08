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

    @Published var searchQuery = "" {
        didSet { if searchQuery != oldValue { scheduleSearch() } }
    }
    @Published private(set) var matches: [PDFSelection] = []
    @Published private(set) var currentMatchIndex = 0   // 0-based

    private var pageObserver: NSObjectProtocol?
    private var searchTask: Task<Void, Never>?
    private var restoreDefaultsKey: String?

    /// Deliberately not `@Published`: the view layer drives this, and publishing from
    /// `updateNSView` would mutate state during a SwiftUI update pass.
    private var darkPages = false

    // MARK: Lifecycle

    /// Must be called before the PDFView attaches so restore has its key.
    func configureRestore(for url: URL?) {
        restoreDefaultsKey = url.map { "lastPage:\($0.path)" }
    }

    func attach(view: PDFView) {
        pdfView = view
        pageCount = view.document?.pageCount ?? 0
        if let observer = pageObserver { NotificationCenter.default.removeObserver(observer) }
        pageObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged, object: view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.pageDidChange() }
        }
        restoreScrollPosition()
        pageDidChange()
        viewReady = true
    }

    deinit {
        if let observer = pageObserver { NotificationCenter.default.removeObserver(observer) }
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

    // MARK: Appearance

    /// Existing matches keep their old colour otherwise — the highlight is baked into the
    /// selection, not re-derived at draw time.
    func setDarkPages(_ dark: Bool) {
        guard dark != darkPages else { return }
        darkPages = dark
        guard !matches.isEmpty else { return }
        let color = PDFPageDarkening.searchHighlightColor(dark: dark)
        for selection in matches { selection.color = color }
        pdfView?.highlightedSelections = matches
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

    // MARK: Selection (for chat)

    /// Current text selection plus its 1-indexed page, if any.
    func selectionInfo() -> PendingSelection? {
        guard let view = pdfView,
              let selection = view.currentSelection,
              let text = selection.string,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        var page: Int?
        if let first = selection.pages.first, let document = view.document {
            page = document.index(for: first) + 1
        }
        return PendingSelection(text: text, page: page)
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
        let color = PDFPageDarkening.searchHighlightColor(dark: darkPages)
        for selection in found { selection.color = color }
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

/// PDFView subclass that adds "Ask About Selection" to the text-selection context menu.
final class AskablePDFView: PDFView {
    var onAskAboutSelection: (() -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        if currentSelection?.string?.isEmpty == false {
            let item = NSMenuItem(
                title: "Ask About Selection",
                action: #selector(askAboutSelection(_:)),
                keyEquivalent: ""
            )
            item.target = self
            menu.insertItem(item, at: 0)
            menu.insertItem(.separator(), at: 1)
        }
        return menu
    }

    @objc private func askAboutSelection(_ sender: Any?) {
        onAskAboutSelection?()
    }
}

struct PDFKitView: NSViewRepresentable {
    let document: PDFDocument
    let controller: PDFViewerController
    var darkPages = false
    var onAskAboutSelection: (() -> Void)? = nil

    /// Holds the light-mode background so turning dark pages back off restores PDFKit's own
    /// colour — by then `backgroundColor` is the pre-inversion grey, not the original.
    final class Coordinator {
        var lightBackground: NSColor?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> PDFView {
        let view = AskablePDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = false
        view.document = document
        view.onAskAboutSelection = onAskAboutSelection
        context.coordinator.lightBackground = view.backgroundColor
        PDFPageDarkening.apply(dark: darkPages, to: view, lightBackground: view.backgroundColor)
        controller.setDarkPages(darkPages)
        // Defer: attach() publishes state, which must not happen during view construction.
        DispatchQueue.main.async { controller.attach(view: view) }
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        (nsView as? AskablePDFView)?.onAskAboutSelection = onAskAboutSelection
        PDFPageDarkening.apply(
            dark: darkPages,
            to: nsView,
            lightBackground: context.coordinator.lightBackground ?? nsView.backgroundColor
        )
        controller.setDarkPages(darkPages)
        if nsView.document !== document {
            nsView.document = document
            DispatchQueue.main.async { controller.attach(view: nsView) }
        }
    }
}

/// Page-thumbnail sidebar bound to the main PDFView (PDFKit keeps them in sync).
struct PDFThumbnailSidebar: NSViewRepresentable {
    @ObservedObject var controller: PDFViewerController
    var darkPages = false

    func makeNSView(context: Context) -> PDFThumbnailView {
        let view = PDFThumbnailView()
        view.thumbnailSize = CGSize(width: 96, height: 128)
        view.backgroundColor = .clear
        PDFPageDarkening.apply(dark: darkPages, to: view)
        return view
    }

    func updateNSView(_ nsView: PDFThumbnailView, context: Context) {
        PDFPageDarkening.apply(dark: darkPages, to: nsView)
        // controller.viewReady flips after the PDFView attaches, re-running this update.
        if nsView.pdfView !== controller.pdfView {
            nsView.pdfView = controller.pdfView
        }
    }
}
