import Foundation
import CoreGraphics
import PDFKit

/// Every view→page→pixel conversion for region crops lives here, with no dependency on a
/// live `PDFView` in the pure functions, so it can be unit-tested across zoom and rotation.
/// PLAN.md §4B/§9 call this out as the fiddly spot, and it is: page space is y-up, its
/// origin is not necessarily zero, and rotation applies at *draw* time only.
///
/// The behavior below was measured against PDFKit (see docs/phase2-geometry.md), not assumed:
///
///   1. `page.bounds(for:)` is the **unrotated** box. Its origin may be non-zero and its
///      width/height are *never* swapped for rotation — true for both `/Rotate` declared in
///      the file and `page.rotation` set programmatically.
///   2. `pdfView.convert(_:to: page)` speaks that same unrotated, origin-included space.
///   3. `page.draw(with:to:)` renders **normalized and rotated**: it maps `bounds.origin` to
///      the context origin and applies rotation, so its extent is `bounds.size` at 0°/180°
///      and swapped at 90°/270°.
///
/// (1) and (3) disagree whenever rotation ≠ 0, which is exactly the bug class this enum exists
/// to contain: `renderRect(forUnrotated:…)` is the bridge between the two spaces.
enum CropGeometry {
    /// Drags shorter than this on both edges (in view points) are clicks, not crops.
    static let minimumDragEdge: CGFloat = 8

    /// Render crops at 2× for legible text in the model's vision input.
    static let defaultScale: CGFloat = 2

    /// Cap the long edge to keep image-token cost bounded (PLAN.md §4B).
    static let defaultMaxPixelEdge: CGFloat = 1600

    // MARK: Drag

    /// Normalize a drag into a positive-size rect, so dragging up/left works like down/right.
    static func dragRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        )
    }

    /// A drag is a crop only if it covers real area on both axes; otherwise it is a click.
    static func isUsableDrag(_ rect: CGRect) -> Bool {
        rect.width >= minimumDragEdge && rect.height >= minimumDragEdge
    }

    // MARK: Page space

    /// Intersect a page-space rect with the page box. Returns nil when the drag lands off the
    /// page entirely or the overlap is too thin to render.
    static func clamp(_ rect: CGRect, to boxBounds: CGRect) -> CGRect? {
        let clamped = rect.intersection(boxBounds)
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1 else { return nil }
        return clamped
    }

    /// Rotation in [0, 90, 180, 270], tolerating negative and >360 values from the file.
    static func normalizedRotation(_ rotation: Int) -> Int {
        let wrapped = ((rotation % 360) + 360) % 360
        // PDF only defines multiples of 90; snap anything else to the nearest.
        return ((wrapped + 45) / 90 % 4) * 90
    }

    /// Map a rect from unrotated page space (what `convert(_:to: page)` and `bounds(for:)`
    /// use) into the space `page.draw(with:to:)` actually renders in: origin-normalized and
    /// rotated. This is the one conversion PDFKit does not do for you.
    static func renderRect(forUnrotated rect: CGRect, boxBounds: CGRect, rotation: Int) -> CGRect {
        // Normalize away the box origin first — draw() puts bounds.origin at the context origin.
        let u = rect.offsetBy(dx: -boxBounds.minX, dy: -boxBounds.minY)
        let w = boxBounds.width
        let h = boxBounds.height

        switch normalizedRotation(rotation) {
        case 90:
            return CGRect(x: u.minY, y: w - u.maxX, width: u.height, height: u.width)
        case 180:
            return CGRect(x: w - u.maxX, y: h - u.maxY, width: u.width, height: u.height)
        case 270:
            return CGRect(x: h - u.maxY, y: u.minX, width: u.height, height: u.width)
        default:
            return u
        }
    }

    /// Size of the page as rendered by `draw` — swapped at 90°/270°.
    static func renderedPageSize(boxBounds: CGRect, rotation: Int) -> CGSize {
        let quarterTurn = normalizedRotation(rotation) % 180 != 0
        return quarterTurn
            ? CGSize(width: boxBounds.height, height: boxBounds.width)
            : boxBounds.size
    }

    // MARK: Rasterization

    /// The bitmap size and the scale that actually gets used after the long-edge cap.
    struct Raster: Equatable {
        let pixelSize: CGSize
        let scale: CGFloat
    }

    /// `scale`× the point size, reduced if that would exceed `maxPixelEdge` on the long edge.
    static func raster(
        for size: CGSize,
        scale: CGFloat = defaultScale,
        maxPixelEdge: CGFloat = defaultMaxPixelEdge
    ) -> Raster? {
        guard size.width > 0, size.height > 0, scale > 0, maxPixelEdge >= 1 else { return nil }
        let longEdge = max(size.width, size.height)
        let effective = min(scale, maxPixelEdge / longEdge)
        let pixels = CGSize(
            width: max(1, (size.width * effective).rounded()),
            height: max(1, (size.height * effective).rounded())
        )
        return Raster(pixelSize: pixels, scale: effective)
    }

    // MARK: Live-view bridge
    //
    // The only functions that touch a PDFView. Kept trivial: everything with arithmetic in it
    // lives above, where it is testable without a window.

    /// Rect in an overlay view's coordinates → the PDFView's coordinates.
    static func viewRect(_ rect: CGRect, from overlay: NSView, to pdfView: PDFView) -> CGRect {
        overlay.convert(rect, to: pdfView)
    }

    /// The page a drag belongs to, chosen by the rect's center. With `displaysPageBreaks =
    /// false` a drag can straddle two pages; anchoring to one page and clamping is the v1 policy.
    static func page(for viewRect: CGRect, in pdfView: PDFView) -> PDFPage? {
        pdfView.page(for: CGPoint(x: viewRect.midX, y: viewRect.midY), nearest: true)
    }

    /// Rect in PDFView coordinates → unrotated page space.
    static func pageRect(for viewRect: CGRect, in pdfView: PDFView, on page: PDFPage) -> CGRect {
        pdfView.convert(viewRect, to: page)
    }
}
