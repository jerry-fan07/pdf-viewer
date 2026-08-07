import XCTest
import PDFKit
@testable import ClaudePDF

@MainActor
final class CropTests: XCTestCase {

    // MARK: Helpers

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

    // MARK: Rendering

    func testRenderPixelDimensionsAt2x() throws {
        let document = try makeDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let png = try XCTUnwrap(
            CropExtractor.render(page: page, rect: CGRect(x: 10, y: 10, width: 100, height: 50))
        )
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, 200)
        XCTAssertEqual(rep.pixelsHigh, 100)
    }

    func testRenderCapsLongEdge() throws {
        let document = try makeDocument(pageSize: NSSize(width: 2000, height: 1200))
        let page = try XCTUnwrap(document.page(at: 0))
        let png = try XCTUnwrap(
            CropExtractor.render(page: page, rect: CGRect(x: 0, y: 0, width: 1800, height: 900))
        )
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        XCTAssertEqual(rep.pixelsWide, 1600)
        XCTAssertEqual(rep.pixelsHigh, 800)
    }

    func testRenderRejectsDegenerateRect() throws {
        let document = try makeDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertNil(CropExtractor.render(page: page, rect: .zero))
    }

    // MARK: View ↔ page geometry

    /// The crop pipeline assumes PDFView's rect conversion is invertible at any zoom.
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

    func testMakeCropRejectsTinyOrOffPageRects() throws {
        let document = try makeDocument()
        let parent = NSView(frame: NSRect(x: 0, y: 0, width: 600, height: 600))
        let pdfView = PDFView(frame: parent.bounds)
        pdfView.document = document
        parent.addSubview(pdfView)
        let overlay = NSView(frame: parent.bounds)
        parent.addSubview(overlay)
        pdfView.layoutDocumentView()

        XCTAssertNil(CropExtractor.makeCrop(
            viewRect: CGRect(x: 300, y: 300, width: 2, height: 2),
            overlay: overlay, pdfView: pdfView
        ))
    }
}
