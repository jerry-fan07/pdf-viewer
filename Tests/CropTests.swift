import XCTest
import PDFKit
@testable import ClaudePDF

/// The overlay → `PendingCrop` wiring: the part of the crop path that owns a live `PDFView`.
///
/// The geometry and rasterization underneath it are covered far more thoroughly by
/// `CropGeometryTests` and `CropRendererTests` (rotation, non-zero box origins, pixel caps,
/// text capture, zoom independence), so this file deliberately does not retest them — it
/// checks only that this layer hands the right rect to that pipeline and maps the result back.
@MainActor
final class CropTests: XCTestCase {

    private func makeDocument(pageSize: NSSize = NSSize(width: 400, height: 300)) throws -> PDFDocument {
        let image = NSImage(size: pageSize, flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        let page = try XCTUnwrap(PDFPage(image: image))
        let document = PDFDocument()
        document.insert(page, at: 0)
        return document
    }

    // MARK: View ↔ page geometry

    /// The whole crop path rests on this: the crop is defined in page space, so if PDFView's
    /// conversion is invertible at any zoom, zoom needs no compensation anywhere else.
    func testViewToPageRoundTripAcrossZoomLevels() throws {
        let document = try makeDocument()
        let pdfView = PDFView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        pdfView.document = document
        pdfView.autoScales = false
        pdfView.layoutDocumentView()
        let page = try XCTUnwrap(document.page(at: 0))
        let pageRect = CGRect(x: 50, y: 60, width: 120, height: 80)

        for zoom in [0.5, 1.0, 2.0] {
            pdfView.scaleFactor = CGFloat(zoom)
            pdfView.layoutDocumentView()
            let viewRect = pdfView.convert(pageRect, from: page)
            let roundTrip = pdfView.convert(viewRect, to: page)
            XCTAssertEqual(roundTrip.origin.x, pageRect.origin.x, accuracy: 0.5, "zoom \(zoom)")
            XCTAssertEqual(roundTrip.origin.y, pageRect.origin.y, accuracy: 0.5, "zoom \(zoom)")
            XCTAssertEqual(roundTrip.width, pageRect.width, accuracy: 0.5, "zoom \(zoom)")
            XCTAssertEqual(roundTrip.height, pageRect.height, accuracy: 0.5, "zoom \(zoom)")
        }
    }

    // MARK: End-to-end makeCrop

    /// Overlay → page conversion, clamping, and PNG production, at two zoom levels.
    func testMakeCropProducesCropFromOverlayRect() throws {
        let document = try makeDocument()

        for zoom in [1.0, 2.0] {
            let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
            let pdfView = PDFView(frame: parent.bounds)
            pdfView.document = document
            pdfView.autoScales = false
            parent.addSubview(pdfView)
            let overlay = NSView(frame: parent.bounds)
            parent.addSubview(overlay)
            pdfView.layoutDocumentView()
            pdfView.scaleFactor = CGFloat(zoom)
            pdfView.layoutDocumentView()

            // Drag over the middle of the visible page.
            let dragRect = CGRect(x: 250, y: 250, width: 120, height: 90)
            let crop = try XCTUnwrap(
                CropExtractor.makeCrop(viewRect: dragRect, overlay: overlay, pdfView: pdfView),
                "zoom \(zoom)"
            )
            XCTAssertEqual(crop.pageNumber, 1, "zoom \(zoom)")
            let rep = try XCTUnwrap(NSBitmapImageRep(data: crop.png), "zoom \(zoom)")
            XCTAssertGreaterThan(rep.pixelsWide, 0)
            XCTAssertGreaterThan(rep.pixelsHigh, 0)
            // Image-only page → no text layer → no fallback text.
            XCTAssertNil(crop.fallbackText, "zoom \(zoom)")
        }
    }

    func testMakeCropRejectsRectsThatMissThePage() throws {
        let document = try makeDocument()
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        let pdfView = PDFView(frame: parent.bounds)
        pdfView.document = document
        parent.addSubview(pdfView)
        let overlay = NSView(frame: parent.bounds)
        parent.addSubview(overlay)
        pdfView.layoutDocumentView()

        // `page(for:nearest:)` always returns *some* page, so landing off the paper has to be
        // caught by the clamp rather than by page lookup.
        XCTAssertNil(CropExtractor.makeCrop(
            viewRect: CGRect(x: 5000, y: 5000, width: 100, height: 100),
            overlay: overlay, pdfView: pdfView
        ))
    }

    /// The minimum-drag gate lives in the overlay, not in `makeCrop`: it is a gesture
    /// question, and 8 *view* points means the same thing at every zoom, where the old
    /// page-space threshold quietly got stricter as you zoomed out.
    func testSubThresholdDragIsRejectedBeforeItReachesMakeCrop() {
        XCTAssertFalse(CropGeometry.isUsableDrag(CGRect(x: 0, y: 0, width: 4, height: 40)))
        XCTAssertFalse(CropGeometry.isUsableDrag(CGRect(x: 0, y: 0, width: 2, height: 2)))
        XCTAssertTrue(CropGeometry.isUsableDrag(CGRect(x: 0, y: 0, width: 20, height: 20)))
    }
}
