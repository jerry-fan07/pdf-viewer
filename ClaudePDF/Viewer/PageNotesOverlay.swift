import SwiftUI
import PDFKit
import Combine

/// What the window and the notes on the pages have to agree about.
@MainActor
final class PageNotesModel: ObservableObject {
    /// Whether the selected note's sheet is unfolded. The window's to set as well
    /// as the tabs': ⌘L, a crop and ⌥⌘I all open a note.
    @Published var isOpen = false
    /// How wide an open sheet is, in page points — the reader's, and kept.
    @Published var sheetWidth: CGFloat = PageNotesModel.storedSheetWidth
    /// As much sheet as the window shows of a fitted page, in page points. The
    /// viewer's to work out (`PDFContainerView`), and deliberately nothing to do
    /// with the zoom: a sheet that re-flowed as the page was zoomed would not be
    /// part of the page.
    @Published var wantedSheetHeight: CGFloat = 640

    static let defaultSheetWidth: CGFloat = 360
    static let minSheetWidth: CGFloat = 280
    static let maxSheetWidth: CGFloat = 720
    /// Tabs, then the sheet: the column every page keeps for its tabs.
    static let tabColumn = NoteTab.openWidth

    static var storedSheetWidth: CGFloat {
        let stored = UserDefaults.standard.double(forKey: AppSettings.noteSheetWidthKey)
        return clamp(stored > 0 ? CGFloat(stored) : defaultSheetWidth)
    }

    static func clamp(_ width: CGFloat) -> CGFloat {
        min(max(width, minSheetWidth), maxSheetWidth)
    }

    func keepSheetWidth() {
        UserDefaults.standard.set(Double(sheetWidth), forKey: AppSettings.noteSheetWidthKey)
    }

    /// The room every page keeps at its right edge.
    var noteRoom: CGFloat { Self.tabColumn + (isOpen ? sheetWidth : 0) }
}

/// The `PDFView`, and over it the notes stuck to its pages.
///
/// **The notes are part of the page, and drawn outside PDFKit.** Their room is a
/// page margin (`PDFViewerController.setNoteRoom`), so PDFKit scales it, scrolls
/// it and fits it with the page. What is drawn in that room is not inside the
/// `PDFView`, because the dark-pages filter is on the `PDFView`'s layer and would
/// invert a chat sheet along with the paper. It is in a sibling laid over it, and
/// each visible page's notes are put where PDFKit says that page is — re-asked,
/// synchronously, on every scroll, zoom and pinch, in the transaction PDFKit moves
/// the page in, so the two do not come apart even for a frame.
final class PDFContainerView: NSView {
    let pdfView: AskablePDFView
    private let overlay = PassthroughView()
    private let engine: ChatEngine
    private let viewer: PDFViewerController
    let model: PageNotesModel

    private var observers: [NSObjectProtocol] = []
    private var subscriptions: Set<AnyCancellable> = []
    private var hosts: [Int: ScaledHost] = [:]
    private var syncScheduled = false
    private var syncing = false
    /// The note the viewer last scrolled to — so opening one brings it into the
    /// window once, and scrolling away from it afterwards is allowed.
    private var revealed: UUID?

    init(pdfView: AskablePDFView, engine: ChatEngine, viewer: PDFViewerController, model: PageNotesModel) {
        self.pdfView = pdfView
        self.engine = engine
        self.viewer = viewer
        self.model = model
        super.init(frame: .zero)
        for view in [pdfView, overlay] as [NSView] {
            view.frame = bounds
            view.autoresizingMask = [.width, .height]
            addSubview(view)
        }
        // Anything that can move a tab, add one, or open a sheet. Will-change, so
        // the look is taken a turn later, when it has.
        engine.objectWillChange.merge(with: model.objectWillChange)
            .sink { [weak self] _ in self?.scheduleSync() }
            .store(in: &subscriptions)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    /// Once the `PDFView` has its document — and again when it is given another.
    func observe() {
        let center = NotificationCenter.default
        for observer in observers { center.removeObserver(observer) }
        let names: [Notification.Name] = [
            .PDFViewScaleChanged, .PDFViewVisiblePagesChanged, .PDFViewDisplayModeChanged,
            .PDFViewDisplayBoxChanged, .PDFViewDocumentChanged,
        ]
        observers = names.map { name in
            center.addObserver(forName: name, object: pdfView, queue: nil) { [weak self] _ in
                MainActor.assumeIsolated { self?.sync() }
            }
        }
        // A scroll and a pinch are both the clip view's bounds changing; PDFKit
        // posts no scale change for a pinch until it is over.
        if let clip = pdfView.documentView?.enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            clip.postsFrameChangedNotifications = true
            for name in [NSView.boundsDidChangeNotification, NSView.frameDidChangeNotification] {
                observers.append(center.addObserver(forName: name, object: clip, queue: nil) { [weak self] _ in
                    MainActor.assumeIsolated { self?.sync() }
                })
            }
        }
        for host in hosts.values { host.removeFromSuperview() }
        hosts.removeAll()
        scheduleSync()
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    override func layout() {
        super.layout()
        sync()
    }

    private func scheduleSync() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.syncScheduled = false
            self?.sync()
        }
    }

    // MARK: Putting the notes where the pages are

    private func sync() {
        // Re-laying the document out for a new margin posts the very notifications
        // that lead here; the look already under way will see what they announce.
        guard !syncing, let document = pdfView.document, bounds.width > 0 else { return }
        syncing = true
        defer { syncing = false }
        viewer.setNoteRoom(model.noteRoom)
        updateWantedSheetHeight()

        let open = model.isOpen ? engine.selectedThread : nil
        var seen = Set<Int>()
        for page in pdfView.visiblePages {
            let number = document.index(for: page) + 1
            seen.insert(number)
            let pageRect = overlay.convert(pdfView.convert(page.bounds(for: pdfView.displayBox), from: page), from: pdfView)
            let size = Self.shownSize(of: page, box: pdfView.displayBox)
            guard size.width > 0 else { continue }
            let host = hosts[number] ?? makeHost(page: number, size: size)
            // Only the page with the open note is as wide as a sheet; on the rest
            // the column is a tab wide, and what is beside it is plain backdrop
            // that a click or a drag goes straight through to PDFKit.
            let hasSheet = open?.anchor.page == number
            let content = CGSize(
                width: PageNotesModel.tabColumn + (hasSheet ? model.sheetWidth : 0),
                height: hasSheet ? max(size.height, sheetBottom(onPageOfHeight: size.height)) : size.height
            )
            host.place(origin: CGPoint(x: pageRect.maxX, y: pageRect.minY), contentSize: content,
                       scale: pageRect.width / size.width)
            // Over its neighbours: a sheet on a short page runs past its foot.
            if hasSheet, overlay.subviews.last !== host { overlay.addSubview(host) }
        }
        for (number, host) in hosts where !seen.contains(number) {
            host.removeFromSuperview()
            hosts[number] = nil
        }
        revealOpenNoteIfNew(open)
    }

    private func makeHost(page number: Int, size: CGSize) -> ScaledHost {
        let host = ScaledHost(rootView: AnyView(
            PageNotesView(page: number, pageHeight: size.height, engine: engine, viewer: viewer, model: model)
        ))
        overlay.addSubview(host)
        hosts[number] = host
        return host
    }

    /// The page as it is shown: a page turned on its side is as wide as it was tall.
    private static func shownSize(of page: PDFPage, box: PDFDisplayBox) -> CGSize {
        let bounds = page.bounds(for: box)
        return page.rotation % 180 == 0 ? bounds.size : CGSize(width: bounds.height, height: bounds.width)
    }

    private func sheetBottom(onPageOfHeight pageHeight: CGFloat) -> CGFloat {
        let frame = NoteTabLayout.sheetFrame(tabTop: 0, pageHeight: pageHeight, wanted: model.wantedSheetHeight)
        return max(pageHeight, frame.height)
    }

    /// What the window shows of a *fitted* page, top to bottom, in page points.
    private func updateWantedSheetHeight() {
        let fit = pdfView.scaleFactorForSizeToFit
        guard fit > 0, bounds.height > 0 else { return }
        let wanted = (bounds.height / fit).rounded()
        guard abs(wanted - model.wantedSheetHeight) > 1 else { return }
        // Not from inside a layout pass: this is published, and SwiftUI is mid-update.
        DispatchQueue.main.async { [model] in model.wantedSheetHeight = wanted }
    }

    // MARK: Bringing an opened note into the window

    private func revealOpenNoteIfNew(_ open: ConversationThread?) {
        guard let open else {
            revealed = nil
            return
        }
        guard revealed != open.id else { return }
        revealed = open.id
        // A turn later: the page has just been re-fitted around the sheet, and the
        // sheet's own view has not been laid out where its tab is yet.
        DispatchQueue.main.async { [weak self] in self?.reveal(open) }
    }

    private func reveal(_ note: ConversationThread) {
        guard let document = pdfView.document, let page = document.page(at: note.anchor.page - 1),
              let documentView = pdfView.documentView else { return }
        let size = Self.shownSize(of: page, box: pdfView.displayBox)
        let tabs = NoteTab.layout(engine.threads.filter { $0.anchor.page == note.anchor.page }, pageHeight: size.height)
        let tabTop = tabs.slots.first { $0.id == note.id }?.top ?? 0
        let sheet = NoteTabLayout.sheetFrame(tabTop: tabTop, pageHeight: size.height, wanted: model.wantedSheetHeight)

        let pageRect = documentView.convert(pdfView.convert(page.bounds(for: pdfView.displayBox), from: page), from: pdfView)
        let scale = pageRect.width / size.width
        // The document view may or may not be flipped; "down the page" is towards
        // smaller y when it is not.
        let top = documentView.isFlipped ? pageRect.minY + sheet.top * scale : pageRect.maxY - (sheet.top + sheet.height) * scale
        let target = CGRect(x: pageRect.maxX, y: top,
                            width: (PageNotesModel.tabColumn + model.sheetWidth) * scale, height: sheet.height * scale)
        documentView.scrollToVisible(target)
    }

    // MARK: Events over the notes

    /// A scroll or a pinch that starts over a tab is still a scroll or a pinch of
    /// the document. (Over the sheet's transcript it never gets here: that scrolls.)
    override func scrollWheel(with event: NSEvent) {
        pdfView.documentView?.enclosingScrollView?.scrollWheel(with: event)
    }

    override func magnify(with event: NSEvent) {
        pdfView.documentView?.enclosingScrollView?.magnify(with: event)
    }
}

/// Sees through itself: a click that is not on a note belongs to the page under it.
final class PassthroughView: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// SwiftUI content drawn at the page's scale. The outer view's frame is the scaled
/// size and its bounds the unscaled one, which is how AppKit is told to scale a
/// view — drawing, hit-testing and tracking all follow — and the content is laid
/// out once, in page points, however far the page is zoomed.
final class ScaledHost: NSView {
    private let host: NSHostingView<AnyView>

    init(rootView: AnyView) {
        host = NSHostingView(rootView: rootView)
        // The size is the page's to decide, not the content's.
        host.sizingOptions = []
        super.init(frame: .zero)
        addSubview(host)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { true }

    func place(origin: CGPoint, contentSize: CGSize, scale: CGFloat) {
        let scaled = CGRect(x: origin.x, y: origin.y, width: contentSize.width * scale, height: contentSize.height * scale)
        if !frame.isClose(to: scaled) { frame = scaled }
        let unscaled = CGRect(origin: .zero, size: contentSize)
        if !bounds.isClose(to: unscaled) { bounds = unscaled }
        if !host.frame.isClose(to: unscaled) { host.frame = unscaled }
    }
}

private extension CGRect {
    func isClose(to other: CGRect) -> Bool {
        abs(minX - other.minX) < 0.01 && abs(minY - other.minY) < 0.01
            && abs(width - other.width) < 0.01 && abs(height - other.height) < 0.01
    }
}
