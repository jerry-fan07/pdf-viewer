import SwiftUI
import PDFKit

// Region screenshot mode (PLAN.md §4B): a transparent overlay captures a drag rectangle,
// which is converted to page space and rendered to a PNG with the region's text alongside it
// as a fallback for text-only providers.
//
// The geometry and rasterization live in CropGeometry / CropRenderer, against measured PDFKit
// behavior (docs/phase2-geometry.md) rather than against the documentation. This file is only
// the AppKit surface: mouse handling, and the hand-off into that pipeline.

/// Everything a question needs from a completed crop.
/// (Defined here, used as ChatEngine's pending-crop state.)
struct PendingCrop: Equatable {
    let png: Data
    let pageNumber: Int          // 1-indexed
    let fallbackText: String?    // text inside the region, for text-only providers
}

@MainActor
enum CropExtractor {

    /// Convert an overlay-space drag rect into a rendered crop.
    /// The overlay must be installed over the PDFView (same window) so AppKit can convert between them.
    static func makeCrop(viewRect: CGRect, overlay: NSView, pdfView: PDFView) -> PendingCrop? {
        // Each hop goes through CropGeometry rather than being spelled out here, so the path
        // the app runs is the one CropGeometryTests/CropRendererTests actually cover.
        let rectInPDFView = CropGeometry.viewRect(viewRect, from: overlay, to: pdfView)
        guard let page = CropGeometry.page(for: rectInPDFView, in: pdfView),
              let document = pdfView.document else { return nil }

        // Yields unrotated page space including the box origin; `CropRenderer` owns the
        // correction from there. The box has to be the one the *view* is laid out in, or the
        // two disagree on any document whose crop box differs from its media box.
        let pageRect = CropGeometry.pageRect(for: rectInPDFView, in: pdfView, on: page)
        guard let capture = CropRenderer.capture(
            page: page,
            pageIndex: document.index(for: page),
            pageRect: pageRect,
            box: pdfView.displayBox
        ) else { return nil }

        return PendingCrop(
            png: capture.pngData,
            pageNumber: capture.pageNumber,
            fallbackText: capture.text
        )
    }
}

// MARK: - Overlay view

/// Transparent drag-to-select overlay shown while crop mode is active.
final class CropOverlayNSView: NSView {
    var onCrop: ((CGRect, NSView) -> Void)?

    private var startPoint: NSPoint?
    private var currentRect: NSRect?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        startPoint = convert(event.locationInWindow, from: nil)
        currentRect = nil
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = startPoint else { return }
        currentRect = CropGeometry.dragRect(from: start, to: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startPoint = nil
            currentRect = nil
            needsDisplay = true
        }
        guard let rect = currentRect, CropGeometry.isUsableDrag(rect) else { return }
        onCrop?(rect, self)
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.withAlphaComponent(0.12).setFill()
        bounds.fill()
        if let rect = currentRect {
            // Punch a clear hole where the selection is, then outline it.
            NSColor.clear.setFill()
            rect.fill(using: .copy)
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 2
            outline.stroke()
        }
    }
}

struct CropOverlay: NSViewRepresentable {
    let onCrop: (CGRect, NSView) -> Void

    func makeNSView(context: Context) -> CropOverlayNSView {
        let view = CropOverlayNSView()
        view.onCrop = onCrop
        return view
    }

    func updateNSView(_ nsView: CropOverlayNSView, context: Context) {
        nsView.onCrop = onCrop
    }
}
