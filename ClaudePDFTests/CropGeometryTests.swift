import CoreGraphics
import XCTest

/// Pure-geometry tests: no PDFView, no window. The pixel-truth counterpart that proves these
/// formulas match what PDFKit actually draws lives in CropRendererTests.
final class CropGeometryTests: XCTestCase {

    // MARK: dragRect

    func testDragRectNormalizesEveryDirection() {
        let expected = CGRect(x: 10, y: 20, width: 30, height: 40)
        let corners = [
            (CGPoint(x: 10, y: 20), CGPoint(x: 40, y: 60)),   // down-right
            (CGPoint(x: 40, y: 60), CGPoint(x: 10, y: 20)),   // up-left
            (CGPoint(x: 40, y: 20), CGPoint(x: 10, y: 60)),   // down-left
            (CGPoint(x: 10, y: 60), CGPoint(x: 40, y: 20)),   // up-right
        ]
        for (start, end) in corners {
            XCTAssertEqual(CropGeometry.dragRect(from: start, to: end), expected,
                           "drag \(start)→\(end)")
        }
    }

    func testDragRectOfZeroLengthDragIsEmpty() {
        let point = CGPoint(x: 5, y: 5)
        XCTAssertEqual(CropGeometry.dragRect(from: point, to: point), CGRect(x: 5, y: 5, width: 0, height: 0))
    }

    func testUsableDragNeedsAreaOnBothAxes() {
        let edge = CropGeometry.minimumDragEdge
        XCTAssertTrue(CropGeometry.isUsableDrag(CGRect(x: 0, y: 0, width: edge, height: edge)))
        XCTAssertFalse(CropGeometry.isUsableDrag(CGRect(x: 0, y: 0, width: edge - 0.1, height: 100)),
                       "a thin horizontal smear is a click, not a crop")
        XCTAssertFalse(CropGeometry.isUsableDrag(CGRect(x: 0, y: 0, width: 100, height: edge - 0.1)))
        XCTAssertFalse(CropGeometry.isUsableDrag(.zero))
    }

    // MARK: clamp

    func testClampKeepsRectsInsideThePage() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        let inside = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertEqual(CropGeometry.clamp(inside, to: bounds), inside)
    }

    func testClampTrimsOverhangIncludingNonZeroOrigin() {
        let bounds = CGRect(x: 100, y: 50, width: 200, height: 100)
        let overhanging = CGRect(x: 250, y: 100, width: 200, height: 200)
        XCTAssertEqual(CropGeometry.clamp(overhanging, to: bounds),
                       CGRect(x: 250, y: 100, width: 50, height: 50))
    }

    func testClampRejectsOffPageAndSliverRects() {
        let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)
        XCTAssertNil(CropGeometry.clamp(CGRect(x: 500, y: 500, width: 20, height: 20), to: bounds),
                     "a drag entirely off the page yields no crop")
        XCTAssertNil(CropGeometry.clamp(CGRect(x: 199.5, y: 10, width: 40, height: 20), to: bounds),
                     "a sub-pixel sliver cannot be rastered")
    }

    // MARK: rotation normalization

    func testNormalizedRotationWrapsAndSnaps() {
        XCTAssertEqual(CropGeometry.normalizedRotation(0), 0)
        XCTAssertEqual(CropGeometry.normalizedRotation(90), 90)
        XCTAssertEqual(CropGeometry.normalizedRotation(360), 0)
        XCTAssertEqual(CropGeometry.normalizedRotation(450), 90)
        XCTAssertEqual(CropGeometry.normalizedRotation(-90), 270)
        XCTAssertEqual(CropGeometry.normalizedRotation(-450), 270)
        XCTAssertEqual(CropGeometry.normalizedRotation(89), 90, "snap off-spec rotations")
        XCTAssertEqual(CropGeometry.normalizedRotation(44), 0)
    }

    // MARK: renderRect — the unrotated → drawn-space bridge

    private let bounds = CGRect(x: 0, y: 0, width: 200, height: 100)

    func testRenderRectIsIdentityAtZeroRotationAndZeroOrigin() {
        let rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        XCTAssertEqual(CropGeometry.renderRect(forUnrotated: rect, boxBounds: bounds, rotation: 0), rect)
    }

    func testRenderRectRemovesTheBoxOrigin() {
        // page.draw maps bounds.origin to the context origin, so a non-zero-origin page must
        // have that origin subtracted or the crop lands in the wrong place entirely.
        let shifted = CGRect(x: 100, y: 50, width: 200, height: 100)
        let rect = CGRect(x: 110, y: 60, width: 20, height: 20)
        XCTAssertEqual(
            CropGeometry.renderRect(forUnrotated: rect, boxBounds: shifted, rotation: 0),
            CGRect(x: 10, y: 10, width: 20, height: 20)
        )
    }

    /// Expectations below are the *measured* positions of the fixture markers in PDFKit's
    /// rendered output at each rotation (see docs/phase2-geometry.md).
    func testRenderRectRotates90() {
        let map = CropGeometry.renderRect(forUnrotated:boxBounds:rotation:)
        XCTAssertEqual(map(CGRect(x: 10, y: 10, width: 20, height: 20), bounds, 90),
                       CGRect(x: 10, y: 170, width: 20, height: 20), "red, bottom-left → top-left")
        XCTAssertEqual(map(CGRect(x: 10, y: 70, width: 20, height: 20), bounds, 90),
                       CGRect(x: 70, y: 170, width: 20, height: 20), "blue, top-left → top-right")
        XCTAssertEqual(map(CGRect(x: 170, y: 10, width: 20, height: 20), bounds, 90),
                       CGRect(x: 10, y: 10, width: 20, height: 20), "black, bottom-right → bottom-left")
    }

    func testRenderRectRotates180() {
        let map = CropGeometry.renderRect(forUnrotated:boxBounds:rotation:)
        XCTAssertEqual(map(CGRect(x: 10, y: 10, width: 20, height: 20), bounds, 180),
                       CGRect(x: 170, y: 70, width: 20, height: 20))
        XCTAssertEqual(map(CGRect(x: 170, y: 10, width: 20, height: 20), bounds, 180),
                       CGRect(x: 10, y: 70, width: 20, height: 20))
    }

    func testRenderRectRotates270() {
        let map = CropGeometry.renderRect(forUnrotated:boxBounds:rotation:)
        XCTAssertEqual(map(CGRect(x: 10, y: 10, width: 20, height: 20), bounds, 270),
                       CGRect(x: 70, y: 10, width: 20, height: 20))
        XCTAssertEqual(map(CGRect(x: 10, y: 70, width: 20, height: 20), bounds, 270),
                       CGRect(x: 10, y: 10, width: 20, height: 20))
    }

    func testRenderRectSwapsEdgesOnQuarterTurns() {
        let wide = CGRect(x: 0, y: 0, width: 40, height: 10)
        XCTAssertEqual(CropGeometry.renderRect(forUnrotated: wide, boxBounds: bounds, rotation: 90).size,
                       CGSize(width: 10, height: 40))
        XCTAssertEqual(CropGeometry.renderRect(forUnrotated: wide, boxBounds: bounds, rotation: 180).size,
                       CGSize(width: 40, height: 10))
    }

    func testRenderedPageSizeSwapsOnQuarterTurns() {
        XCTAssertEqual(CropGeometry.renderedPageSize(boxBounds: bounds, rotation: 0),
                       CGSize(width: 200, height: 100))
        XCTAssertEqual(CropGeometry.renderedPageSize(boxBounds: bounds, rotation: 90),
                       CGSize(width: 100, height: 200))
        XCTAssertEqual(CropGeometry.renderedPageSize(boxBounds: bounds, rotation: 180),
                       CGSize(width: 200, height: 100))
        XCTAssertEqual(CropGeometry.renderedPageSize(boxBounds: bounds, rotation: 270),
                       CGSize(width: 100, height: 200))
    }

    /// Rotating four times must return the original rect — catches sign errors that individual
    /// cases could share.
    func testFourQuarterTurnsAreIdentity() {
        var rect = CGRect(x: 13, y: 27, width: 31, height: 19)
        var box = bounds
        for _ in 0..<4 {
            rect = CropGeometry.renderRect(forUnrotated: rect, boxBounds: box, rotation: 90)
            box = CGRect(origin: .zero, size: CropGeometry.renderedPageSize(boxBounds: box, rotation: 90))
        }
        XCTAssertEqual(rect, CGRect(x: 13, y: 27, width: 31, height: 19))
    }

    // MARK: raster

    func testRasterUsesTwoTimesScaleBelowTheCap() {
        let raster = CropGeometry.raster(for: CGSize(width: 100, height: 50))
        XCTAssertEqual(raster?.scale, 2)
        XCTAssertEqual(raster?.pixelSize, CGSize(width: 200, height: 100))
    }

    func testRasterCapsTheLongEdge() {
        // 1000 pt at 2× would be 2000 px; the cap pulls the scale down to 1.6.
        let raster = CropGeometry.raster(for: CGSize(width: 1000, height: 500))
        XCTAssertEqual(raster?.scale ?? 0, 1.6, accuracy: 0.0001)
        XCTAssertEqual(raster?.pixelSize, CGSize(width: 1600, height: 800))
        XCTAssertLessThanOrEqual(max(raster!.pixelSize.width, raster!.pixelSize.height),
                                 CropGeometry.defaultMaxPixelEdge)
    }

    func testRasterCapsOnWhicheverEdgeIsLonger() {
        let tall = CropGeometry.raster(for: CGSize(width: 500, height: 1000))
        XCTAssertEqual(tall?.pixelSize, CGSize(width: 800, height: 1600))
    }

    func testRasterNeverProducesAZeroSizedBitmap() {
        XCTAssertNil(CropGeometry.raster(for: CGSize(width: 0, height: 50)))
        XCTAssertNil(CropGeometry.raster(for: CGSize(width: 50, height: -1)))
        // A very thin but non-empty crop still has to round up to at least one pixel.
        let sliver = CropGeometry.raster(for: CGSize(width: 1000, height: 0.1))
        XCTAssertEqual(sliver?.pixelSize.height, 1)
    }
}
