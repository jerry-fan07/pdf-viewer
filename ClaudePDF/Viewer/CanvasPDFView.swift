import SwiftUI
import PDFKit

/// What a click on the page does.
enum CanvasTool: String, CaseIterable, Identifiable {
    case select, hand, highlight, comment, draw

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .select: "cursorarrow"
        case .hand: "hand.raised"
        case .highlight: "highlighter"
        case .comment: "text.bubble"
        case .draw: "pencil.and.scribble"
        }
    }

    var title: String {
        switch self {
        case .select: "Select"
        case .hand: "Hand"
        case .highlight: "Highlight"
        case .comment: "Comment"
        case .draw: "Draw"
        }
    }
}

enum CanvasLayout: String, CaseIterable, Identifiable {
    case single, continuous, twoUp

    var id: String { rawValue }

    var symbol: String {
        switch self {
        case .single: "doc"
        case .continuous: "doc.text"
        case .twoUp: "book"
        }
    }

    var title: String {
        switch self {
        case .single: "Single Page"
        case .continuous: "Continuous Scroll"
        case .twoUp: "Two-Page Spread"
        }
    }

    var displayMode: PDFDisplayMode {
        switch self {
        case .single: .singlePage
        case .continuous: .singlePageContinuous
        case .twoUp: .twoUpContinuous
        }
    }
}

/// The canvas's own bits of state the chrome shows — zoom and layout — kept out of
/// `PDFViewerController` so the viewer stays about the document.
@MainActor
final class CanvasState: ObservableObject {
    @Published private(set) var zoom: CGFloat = 1
    @Published var tool: CanvasTool = .select {
        didSet { view?.tool = tool }
    }
    @Published var layout: CanvasLayout = .continuous {
        didSet {
            view?.displayMode = layout.displayMode
            view?.displaysAsBook = false
        }
    }

    private weak var view: CanvasPDFView?
    private var observer: NSObjectProtocol?

    func attach(_ view: CanvasPDFView) {
        self.view = view
        view.tool = tool
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = NotificationCenter.default.addObserver(
            forName: .PDFViewScaleChanged, object: view, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.zoom = view.scaleFactor }
        }
        zoom = view.scaleFactor
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    static let presets: [CGFloat] = [0.5, 0.75, 1, 1.25, 1.5, 2, 3, 4]

    func setZoom(_ scale: CGFloat) {
        guard let view else { return }
        view.autoScales = false
        view.scaleFactor = min(max(scale, view.minScaleFactor), view.maxScaleFactor)
    }

    func fitWidth() {
        view?.autoScales = true
    }

    /// The whole of the current page in the window, top to bottom.
    func fitPage() {
        guard let view, let page = view.currentPage else { return }
        let bounds = page.bounds(for: view.displayBox)
        let visible = view.bounds.insetBy(dx: 24, dy: 24)
        guard bounds.width > 0, bounds.height > 0 else { return }
        setZoom(min(visible.width / bounds.width, visible.height / bounds.height))
    }

    /// "8.50 × 11.00 in" for the page being read.
    var pageSizeLabel: String? {
        guard let view, let page = view.currentPage else { return nil }
        let bounds = page.bounds(for: view.displayBox)
        let rotated = page.rotation % 180 != 0
        let width = (rotated ? bounds.height : bounds.width) / 72
        let height = (rotated ? bounds.width : bounds.height) / 72
        return String(format: "%.2f × %.2f in", width, height)
    }
}

/// The PDFView with tools: a hand that pans, a highlighter that marks what it
/// selects, and a comment tool that pins a note where it is clicked.
final class CanvasPDFView: AskablePDFView {
    var tool: CanvasTool = .select {
        didSet { window?.invalidateCursorRects(for: self) }
    }
    private var lastDrag: NSPoint?

    override func mouseDown(with event: NSEvent) {
        switch tool {
        case .hand:
            lastDrag = event.locationInWindow
            NSCursor.closedHand.push()
        case .comment:
            addComment(at: convert(event.locationInWindow, from: nil))
        default:
            super.mouseDown(with: event)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard tool == .hand, let last = lastDrag,
              let scroll = documentView?.enclosingScrollView else {
            super.mouseDragged(with: event)
            return
        }
        let now = event.locationInWindow
        let clip = scroll.contentView
        var origin = clip.bounds.origin
        origin.x -= now.x - last.x
        origin.y += (clip.isFlipped ? 1 : -1) * (now.y - last.y)
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
        lastDrag = now
    }

    override func mouseUp(with event: NSEvent) {
        switch tool {
        case .hand:
            lastDrag = nil
            NSCursor.pop()
        case .highlight:
            super.mouseUp(with: event)
            highlightSelection()
        default:
            super.mouseUp(with: event)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        switch tool {
        case .hand: addCursorRect(bounds, cursor: .openHand)
        case .comment, .draw: addCursorRect(bounds, cursor: .crosshair)
        default: break
        }
    }

    private func highlightSelection() {
        guard let selection = currentSelection, selection.string?.isEmpty == false else { return }
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let mark = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                mark.color = NSColor.systemYellow.withAlphaComponent(0.45)
                page.addAnnotation(mark)
            }
        }
        clearSelection()
    }

    private func addComment(at point: NSPoint) {
        guard let page = page(for: point, nearest: true) else { return }
        let onPage = convert(point, to: page)
        let note = PDFAnnotation(bounds: CGRect(x: onPage.x - 10, y: onPage.y - 10, width: 20, height: 20),
                                 forType: .text, withProperties: nil)
        note.color = NSColor(srgbRed: 1, green: 0.8, blue: 0.2, alpha: 1)
        note.contents = "Comment"
        page.addAnnotation(note)
    }
}

/// The document canvas: pages on a grey desk, with gaps and shadows between them.
struct CanvasPDFRepresentable: NSViewRepresentable {
    let document: PDFDocument
    let controller: PDFViewerController
    let canvas: CanvasState
    var darkPages = false
    var followsSystem = false
    var onAskAboutSelection: (() -> Void)? = nil

    final class Coordinator {
        var darkening: PDFDarkeningAnimator?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> CanvasPDFView {
        let view = CanvasPDFView()
        view.autoScales = true
        view.displayMode = canvas.layout.displayMode
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        view.pageShadowsEnabled = !darkPages
        view.document = document
        view.onAskAboutSelection = onAskAboutSelection
        context.coordinator.darkening = PDFDarkeningAnimator { [weak view] progress in
            guard let view else { return }
            PDFPageDarkening.apply(progress: progress, to: view, lightBackground: ChromeInk.canvasLightNS)
        }
        context.coordinator.darkening?.set(dark: darkPages, followingSystem: followsSystem, animated: false)
        controller.setDarkPages(darkPages)
        DispatchQueue.main.async {
            controller.attach(view: view)
            canvas.attach(view)
        }
        return view
    }

    func updateNSView(_ view: CanvasPDFView, context: Context) {
        view.onAskAboutSelection = onAskAboutSelection
        // A page shadow inverts into a glow, so dark pages go without.
        view.pageShadowsEnabled = !darkPages
        context.coordinator.darkening?.set(dark: darkPages, followingSystem: followsSystem, animated: true)
        controller.setDarkPages(darkPages)
        if view.document !== document {
            view.document = document
            DispatchQueue.main.async {
                controller.attach(view: view)
                canvas.attach(view)
            }
        }
    }
}
