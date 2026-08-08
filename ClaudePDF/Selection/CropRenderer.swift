import Foundation
import CoreGraphics
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// A rendered region crop, ready to become a `Question` anchor.
struct RegionCapture: Equatable {
    let pngData: Data
    /// Text under the crop, for providers that cannot see images (PLAN.md §4B, §5.2).
    let text: String?
    let pageNumber: Int         // 1-indexed
    let pageRect: CGRect        // unrotated page space, clamped to the page
    let pixelSize: CGSize
}

/// Renders a page region to PNG. Deliberately CoreGraphics-only: going through `NSImage`
/// would reintroduce point-vs-pixel ambiguity and silently double the crop on a Retina display.
enum CropRenderer {
    /// Render `pageRect` (unrotated page space) and pick up the text underneath it.
    /// Returns nil when the rect misses the page or is too thin to raster.
    ///
    /// - Note: `page.draw` requires the owning `PDFDocument` to still be alive; PDFPage does
    ///   not retain it. Callers must hold the document (the app does, via `DocumentWindow`).
    static func capture(
        page: PDFPage,
        pageIndex: Int,
        pageRect: CGRect,
        box: PDFDisplayBox = .cropBox,
        scale: CGFloat = CropGeometry.defaultScale,
        maxPixelEdge: CGFloat = CropGeometry.defaultMaxPixelEdge
    ) -> RegionCapture? {
        let bounds = page.bounds(for: box)
        guard let clamped = CropGeometry.clamp(pageRect, to: bounds) else { return nil }
        guard let (png, pixelSize) = renderPNG(
            page: page, clampedPageRect: clamped, box: box, scale: scale, maxPixelEdge: maxPixelEdge
        ) else { return nil }

        let text = page.selection(for: clamped)?.string?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return RegionCapture(
            pngData: png,
            text: (text?.isEmpty ?? true) ? nil : text,
            pageNumber: pageIndex + 1,
            pageRect: clamped,
            pixelSize: pixelSize
        )
    }

    /// `clampedPageRect` must already be inside `page.bounds(for: box)`.
    static func renderPNG(
        page: PDFPage,
        clampedPageRect: CGRect,
        box: PDFDisplayBox = .cropBox,
        scale: CGFloat = CropGeometry.defaultScale,
        maxPixelEdge: CGFloat = CropGeometry.defaultMaxPixelEdge
    ) -> (Data, CGSize)? {
        guard let (image, pixelSize) = renderImage(
            page: page, clampedPageRect: clampedPageRect,
            box: box, scale: scale, maxPixelEdge: maxPixelEdge
        ) else { return nil }
        guard let data = encodePNG(image) else { return nil }
        return (data, pixelSize)
    }

    /// The raster half of `renderPNG`, kept separate so OCR can read pixels
    /// without a PNG round-trip (`OCRExtractor`).
    static func renderImage(
        page: PDFPage,
        clampedPageRect: CGRect,
        box: PDFDisplayBox = .cropBox,
        scale: CGFloat = CropGeometry.defaultScale,
        maxPixelEdge: CGFloat = CropGeometry.defaultMaxPixelEdge
    ) -> (CGImage, CGSize)? {
        let bounds = page.bounds(for: box)
        // The rect the *renderer* needs: origin-normalized and rotated. See CropGeometry.
        let target = CropGeometry.renderRect(
            forUnrotated: clampedPageRect, boxBounds: bounds, rotation: page.rotation
        )
        guard let raster = CropGeometry.raster(
            for: target.size, scale: scale, maxPixelEdge: maxPixelEdge
        ) else { return nil }

        let width = Int(raster.pixelSize.width)
        let height = Int(raster.pixelSize.height)
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }

        context.interpolationQuality = .high
        // PDFs are authored for paper: anything the page doesn't paint should read as white,
        // not black or transparent.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        context.saveGState()
        context.scaleBy(x: raster.scale, y: raster.scale)
        context.translateBy(x: -target.minX, y: -target.minY)
        page.draw(with: box, to: context)
        context.restoreGState()

        guard let image = context.makeImage() else { return nil }
        return (image, raster.pixelSize)
    }

    static func encodePNG(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
