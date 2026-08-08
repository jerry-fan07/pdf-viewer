import AppKit
import CoreGraphics
import PDFKit
import XCTest
@testable import ClaudePDF

/// Pixel-truth tests. These are what actually prove the geometry: a marker of known colour at
/// known page coordinates must come out in the middle of the exported PNG. If PDFKit's draw
/// semantics ever change, these fail rather than silently producing off-by-a-page crops.
final class CropRendererTests: XCTestCase {

    /// Crop tightly around a marker, so the marker fills the output and the centre pixel is it.
    private func capture(
        page: PDFPage, marker: CGRect, origin: CGPoint = .zero
    ) -> RegionCapture? {
        CropRenderer.capture(
            page: page, pageIndex: 0,
            pageRect: PDFFixtures.inPageSpace(marker, origin: origin)
        )
    }

    // MARK: Rotation

    func testMarkersRenderCorrectlyAtEveryRotation() {
        for rotation in [0, 90, 180, 270] {
            let page = PDFFixtures.makePage(rotation: rotation)
            for (name, marker, expected) in [
                ("red", PDFFixtures.red, PNGInspector.RGB.red),
                ("blue", PDFFixtures.blue, PNGInspector.RGB.blue),
                ("black", PDFFixtures.black, PNGInspector.RGB.black),
            ] {
                guard let capture = capture(page: page, marker: marker) else {
                    XCTFail("no capture for \(name) at rotation \(rotation)")
                    continue
                }
                assertColor(PNGInspector.centerColor(capture.pngData), isNear: expected,
                            "\(name) marker at rotation \(rotation)")
            }
        }
    }

    /// A crop of the whole page must keep the markers in their displayed corners — this is the
    /// test that would catch a rotation mapping that is self-consistent but transposed.
    func testWholePageCropPlacesMarkersInTheRightCornersWhenRotated() {
        let page = PDFFixtures.makePage(rotation: 90)
        let whole = CGRect(origin: .zero, size: PDFFixtures.pageSize)
        guard let capture = capture(page: page, marker: whole) else {
            return XCTFail("no whole-page capture")
        }
        // At 90°, the unrotated bottom-left (red) is displayed at the top-left, the unrotated
        // top-left (blue) at the top-right, and the unrotated bottom-right (black) bottom-left.
        assertColor(PNGInspector.color(capture.pngData, atFractionX: 0.2, y: 0.9),
                    isNear: .red, "red should be top-left when rotated 90°")
        assertColor(PNGInspector.color(capture.pngData, atFractionX: 0.8, y: 0.9),
                    isNear: .blue, "blue should be top-right when rotated 90°")
        assertColor(PNGInspector.color(capture.pngData, atFractionX: 0.2, y: 0.1),
                    isNear: .black, "black should be bottom-left when rotated 90°")
        XCTAssertEqual(capture.pixelSize, CGSize(width: 200, height: 400),
                       "a quarter-turned page rasters with its edges swapped")
    }

    // MARK: Non-zero page origin

    func testMarkersRenderCorrectlyWhenTheMediaBoxOriginIsNotZero() {
        let origin = CGPoint(x: 137, y: 61)
        for rotation in [0, 90, 180, 270] {
            let page = PDFFixtures.makePage(origin: origin, rotation: rotation)
            XCTAssertEqual(page.bounds(for: .cropBox).origin, origin,
                           "fixture should actually carry a non-zero origin")
            guard let capture = capture(page: page, marker: PDFFixtures.red, origin: origin) else {
                XCTFail("no capture at rotation \(rotation)")
                continue
            }
            assertColor(PNGInspector.centerColor(capture.pngData), isNear: .red,
                        "red marker, origin \(origin), rotation \(rotation)")
        }
    }

    // MARK: Raster size

    func testCropIsRasteredAtTwoTimesScale() {
        let page = PDFFixtures.makePage()
        let capture = capture(page: page, marker: PDFFixtures.red)
        XCTAssertEqual(capture?.pixelSize, CGSize(width: 40, height: 40),
                       "a 20×20 pt crop is 40×40 px at 2×")
        XCTAssertEqual(PNGInspector.size(of: capture!.pngData), CGSize(width: 40, height: 40),
                       "the PNG itself must be pixel-sized, not point-sized")
    }

    func testLargeCropStaysUnderThePixelCap() {
        let page = PDFFixtures.makePage()
        let capture = CropRenderer.capture(
            page: page, pageIndex: 0,
            pageRect: CGRect(origin: .zero, size: PDFFixtures.pageSize),
            scale: 2, maxPixelEdge: 120
        )
        XCTAssertEqual(capture?.pixelSize, CGSize(width: 120, height: 60))
    }

    // MARK: Text fallback (for providers without vision — PLAN.md §4B)

    func testCropOverTextCapturesTheTextUnderneath() {
        let page = PDFFixtures.makePage()
        let capture = capture(page: page, marker: PDFFixtures.textRect)
        XCTAssertEqual(capture?.text, PDFFixtures.textString)
    }

    func testCropOverAFigureWithNoTextLayerHasNoTextFallback() {
        let page = PDFFixtures.makePage()
        // The red marker is pure vector fill; nothing to extract.
        XCTAssertNil(capture(page: page, marker: PDFFixtures.red)?.text)
    }

    // MARK: Failure modes

    func testCropOffThePageProducesNothing() {
        let page = PDFFixtures.makePage()
        XCTAssertNil(CropRenderer.capture(
            page: page, pageIndex: 0, pageRect: CGRect(x: 900, y: 900, width: 40, height: 40)
        ))
    }

    func testCropPartlyOffThePageIsTrimmedRatherThanRejected() {
        let page = PDFFixtures.makePage()
        let capture = CropRenderer.capture(
            page: page, pageIndex: 0, pageRect: CGRect(x: 180, y: -50, width: 100, height: 100)
        )
        XCTAssertEqual(capture?.pageRect, CGRect(x: 180, y: 0, width: 20, height: 50))
    }

    func testCaptureReportsAOneIndexedPageNumber() {
        let page = PDFFixtures.makePage()
        XCTAssertEqual(capture(page: page, marker: PDFFixtures.red)?.pageNumber, 1)
    }
}

/// The Phase 2 exit criterion: "both modes produce a correct `Question` from any zoom level."
/// Drives the real production path — overlay rect → PDFView coords → page space → PNG — against
/// a live PDFView at several zoom factors and rotations.
final class CropLiveViewTests: XCTestCase {

    private func makeView(document: PDFDocument, scale: CGFloat) -> PDFView {
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 500, height: 400))
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = false
        view.autoScales = false
        view.scaleFactor = scale
        view.layoutSubtreeIfNeeded()
        return view
    }

    func testRedMarkerRoundTripsThroughTheFullPathAtEveryZoom() {
        for rotation in [0, 90, 180, 270] {
            let document = PDFFixtures.makeDocument(rotation: rotation)
            for scale in [CGFloat(0.5), 1.0, 2.0, 4.0] {
                let view = makeView(document: document, scale: scale)
                let page = document.page(at: 0)!

                // Where the red marker sits on screen at this zoom — i.e. what the user would
                // drag a rectangle around.
                let viewRect = view.convert(PDFFixtures.red, from: page)

                guard let hitPage = CropGeometry.page(for: viewRect, in: view) else {
                    XCTFail("no page under the drag (rotation \(rotation), scale \(scale))")
                    continue
                }
                let pageRect = CropGeometry.pageRect(for: viewRect, in: view, on: hitPage)
                guard let capture = CropRenderer.capture(
                    page: hitPage, pageIndex: document.index(for: hitPage), pageRect: pageRect
                ) else {
                    XCTFail("no capture (rotation \(rotation), scale \(scale))")
                    continue
                }
                assertColor(PNGInspector.centerColor(capture.pngData), isNear: .red,
                            "rotation \(rotation), scaleFactor \(scale)")
                XCTAssertEqual(capture.pageNumber, 1)
            }
        }
    }

    func testCropPixelSizeIsIndependentOfZoom() {
        let document = PDFFixtures.makeDocument()
        let page = document.page(at: 0)!
        var sizes: [CGSize] = []
        for scale in [CGFloat(0.5), 1.0, 2.0, 4.0] {
            let view = makeView(document: document, scale: scale)
            let viewRect = view.convert(PDFFixtures.red, from: page)
            let pageRect = CropGeometry.pageRect(for: viewRect, in: view, on: page)
            let capture = CropRenderer.capture(page: page, pageIndex: 0, pageRect: pageRect)
            sizes.append(capture?.pixelSize ?? .zero)
        }
        // The same physical region always yields the same crop, whatever the viewer is zoomed to.
        XCTAssertEqual(Set(sizes.map(\.width)).count, 1, "widths varied: \(sizes)")
        XCTAssertEqual(sizes.first, CGSize(width: 40, height: 40))
    }

    func testTextSelectionUnderACropSurvivesZoom() {
        let document = PDFFixtures.makeDocument()
        let page = document.page(at: 0)!
        for scale in [CGFloat(0.5), 1.0, 3.0] {
            let view = makeView(document: document, scale: scale)
            let viewRect = view.convert(PDFFixtures.textRect, from: page)
            let pageRect = CropGeometry.pageRect(for: viewRect, in: view, on: page)
            let capture = CropRenderer.capture(page: page, pageIndex: 0, pageRect: pageRect)
            XCTAssertEqual(capture?.text, PDFFixtures.textString, "at scaleFactor \(scale)")
        }
    }

    /// The overlay is a sibling view laid over the PDFView; its rect has to survive the hop
    /// into PDFView coordinates even when the two views do not share an origin.
    func testOverlayRectConvertsIntoPDFViewCoordinates() {
        let document = PDFFixtures.makeDocument()
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        let view = makeView(document: document, scale: 1)
        view.frame = CGRect(x: 40, y: 30, width: 500, height: 400)
        let overlay = CropOverlayNSView(frame: view.frame)
        container.addSubview(view)
        container.addSubview(overlay)

        let page = document.page(at: 0)!
        let expected = view.convert(PDFFixtures.red, from: page)
        // The same rect expressed in the overlay's own coordinates (identical frames here, so
        // the values coincide — the point is that the conversion is applied at all).
        let overlayRect = overlay.convert(expected, from: view)
        let converted = CropGeometry.viewRect(overlayRect, from: overlay, to: view)

        XCTAssertEqual(converted.origin.x, expected.origin.x, accuracy: 0.001)
        XCTAssertEqual(converted.origin.y, expected.origin.y, accuracy: 0.001)

        let pageRect = CropGeometry.pageRect(for: converted, in: view, on: page)
        let capture = CropRenderer.capture(page: page, pageIndex: 0, pageRect: pageRect)
        assertColor(PNGInspector.centerColor(capture?.pngData ?? Data()), isNear: .red,
                    "overlay → PDFView → page round trip")
    }
}
