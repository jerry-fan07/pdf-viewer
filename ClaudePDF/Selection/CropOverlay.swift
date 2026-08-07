import SwiftUI
import PDFKit

// Region screenshot mode (PLAN.md §4B): a transparent overlay captures a drag rectangle,
// CropExtractor converts it to page space, renders a PNG at 2× (capped at 1600 px long edge),
// and extracts the region's text as a fallback for text-only providers.
//
// All coordinate conversion is isolated in CropExtractor / render() and unit-tested in
// Tests/CropTests.swift. Known limitation (documented, untested): rotated pages.

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
        let rectInPDFView = pdfView.convert(viewRect, from: overlay)
        let midpoint = CGPoint(x: rectInPDFView.midX, y: rectInPDFView.midY)
        guard let page = pdfView.page(for: midpoint, nearest: true),
              let document = pdfView.document else { return nil }

        // Page space; clamp to the page so off-page drags don't produce garbage.
        let pageRect = pdfView.convert(rectInPDFView, to: page)
            .intersection(page.bounds(for: .mediaBox))
        guard pageRect.width > 4, pageRect.height > 4 else { return nil }

        guard let png = render(page: page, rect: pageRect) else { return nil }
        let fallbackText = page.selection(for: pageRect)?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return PendingCrop(
            png: png,
            pageNumber: document.index(for: page) + 1,
            fallbackText: (fallbackText?.isEmpty ?? true) ? nil : fallbackText
        )
    }

    /// Render a page-space rect to PNG. 2× scale for legibility, capped so image-token
    /// cost stays bounded (PLAN.md §4B). Rotated pages are not yet handled.
    static func render(page: PDFPage, rect: CGRect, scale: CGFloat = 2.0, maxLongEdge: CGFloat = 1600) -> Data? {
        var effectiveScale = scale
        let longEdge = max(rect.width, rect.height) * scale
        if longEdge > maxLongEdge {
            effectiveScale = maxLongEdge / max(rect.width, rect.height)
        }
        let pixelWidth = Int((rect.width * effectiveScale).rounded())
        let pixelHeight = Int((rect.height * effectiveScale).rounded())
        guard pixelWidth > 0, pixelHeight > 0,
              let context = CGContext(
                data: nil, width: pixelWidth, height: pixelHeight,
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else { return nil }

        context.setFillColor(NSColor.white.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
        context.scaleBy(x: effectiveScale, y: effectiveScale)
        context.translateBy(x: -rect.minX, y: -rect.minY)
        page.draw(with: .mediaBox, to: context)

        guard let image = context.makeImage() else { return nil }
        return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
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
        let point = convert(event.locationInWindow, from: nil)
        currentRect = NSRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)
        )
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            startPoint = nil
            currentRect = nil
            needsDisplay = true
        }
        guard let rect = currentRect, rect.width > 8, rect.height > 8 else { return }
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
