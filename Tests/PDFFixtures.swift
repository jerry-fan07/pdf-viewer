import CoreGraphics
import CoreText
import Foundation
import ImageIO
import PDFKit
import XCTest
@testable import ClaudePDF

/// A generated single-page PDF with markers at known page coordinates, so crop output can be
/// asserted by pixel colour rather than by eyeballing. All coordinates below are *box-relative*
/// (i.e. relative to `mediaBox.origin`), which is how `PDFPage.bounds(for:)` reports them minus
/// the origin — see CropGeometry's notes.
///
///   size: 200 × 100 pt
///   red   square at (10, 10, 20, 20)    — bottom-left
///   blue  square at (10, 70, 20, 20)    — top-left
///   black square at (170, 10, 20, 20)   — bottom-right
///   text  "HELLO" with baseline at (60, 45)
enum PDFFixtures {
    static let pageSize = CGSize(width: 200, height: 100)
    static let red = CGRect(x: 10, y: 10, width: 20, height: 20)
    static let blue = CGRect(x: 10, y: 70, width: 20, height: 20)
    static let black = CGRect(x: 170, y: 10, width: 20, height: 20)
    static let textRect = CGRect(x: 55, y: 40, width: 85, height: 30)
    static let textString = "HELLO"

    /// Retains generated documents: `PDFPage` does *not* retain its `PDFDocument`, and drawing
    /// a page whose document has deallocated silently produces nothing.
    private static var retained: [PDFDocument] = []

    static func makeDocument(origin: CGPoint = .zero, rotation: Int = 0) -> PDFDocument {
        let box = CGRect(origin: origin, size: pageSize)
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var mediaBox = box
        let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!

        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(box)
        fill(context, red, in: box, color: CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        fill(context, blue, in: box, color: CGColor(red: 0, green: 0, blue: 1, alpha: 1))
        fill(context, black, in: box, color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))

        let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
        let attributed = NSAttributedString(string: textString, attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: box.minX + 60, y: box.minY + 45)
        CTLineDraw(line, context)

        context.endPDFPage()
        context.closePDF()

        let document = PDFDocument(data: data as Data)!
        document.page(at: 0)!.rotation = rotation
        retained.append(document)
        return document
    }

    static func makePage(origin: CGPoint = .zero, rotation: Int = 0) -> PDFPage {
        makeDocument(origin: origin, rotation: rotation).page(at: 0)!
    }

    /// Marker rect translated into absolute (unrotated) page space for a given box origin —
    /// the space `PDFView.convert(_:to: page)` speaks.
    static func inPageSpace(_ marker: CGRect, origin: CGPoint) -> CGRect {
        marker.offsetBy(dx: origin.x, dy: origin.y)
    }

    private static func fill(_ context: CGContext, _ rect: CGRect, in box: CGRect, color: CGColor) {
        context.setFillColor(color)
        context.fill(rect.offsetBy(dx: box.minX, dy: box.minY))
    }
}

// MARK: - Pixel inspection

enum PNGInspector {
    struct RGB: Equatable, CustomStringConvertible {
        let r: Int, g: Int, b: Int
        var description: String { "(\(r),\(g),\(b))" }
    }

    static func size(of png: Data) -> CGSize? {
        guard let image = decode(png) else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    static func decode(_ png: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Colour at a fractional position, measured from the **bottom-left** so tests read in the
    /// same y-up orientation as page space. (0,0) is bottom-left, (1,1) is top-right.
    static func color(_ png: Data, atFractionX fx: CGFloat, y fy: CGFloat) -> RGB? {
        guard let image = decode(png) else { return nil }
        let width = image.width, height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &buffer, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let x = min(width - 1, max(0, Int(fx * CGFloat(width))))
        let rowFromTop = min(height - 1, max(0, Int((1 - fy) * CGFloat(height))))
        let i = (rowFromTop * width + x) * 4
        return RGB(r: Int(buffer[i]), g: Int(buffer[i + 1]), b: Int(buffer[i + 2]))
    }

    /// Colour at the centre of the image.
    static func centerColor(_ png: Data) -> RGB? {
        color(png, atFractionX: 0.5, y: 0.5)
    }
}

extension XCTestCase {
    /// Assert a sampled pixel is the expected marker colour.
    ///
    /// Matching is nearest-palette-entry rather than per-channel tolerance: converting the
    /// fixture's DeviceRGB fills into the output colour space shifts them measurably (pure blue
    /// arrives as ≈(4,51,255), pure red as ≈(255,38,0)). The palette entries are 255 apart in at
    /// least one channel, so "which marker is this?" stays unambiguous while the exact values
    /// are allowed to drift.
    func assertColor(
        _ actual: PNGInspector.RGB?,
        isNear expected: PNGInspector.RGB,
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("no pixel sampled. \(message)", file: file, line: line)
        }
        let palette = PNGInspector.RGB.markerPalette
        guard palette.contains(expected) else {
            return XCTFail("\(expected) is not a marker colour", file: file, line: line)
        }
        let nearest = palette.min { actual.distance(to: $0) < actual.distance(to: $1) }
        XCTAssertEqual(
            nearest, expected,
            "sampled \(actual), which reads as \(nearest.map(\.name) ?? "?") "
                + "rather than \(expected.name). \(message)",
            file: file, line: line
        )
    }
}

extension PNGInspector.RGB {
    static let red = Self(r: 255, g: 0, b: 0)
    static let blue = Self(r: 0, g: 0, b: 255)
    static let black = Self(r: 0, g: 0, b: 0)
    static let white = Self(r: 255, g: 255, b: 255)

    static let markerPalette: [Self] = [.red, .blue, .black, .white]

    var name: String {
        switch self {
        case .red: return "red"
        case .blue: return "blue"
        case .black: return "black"
        case .white: return "white"
        default: return description
        }
    }

    func distance(to other: Self) -> Int {
        let dr = r - other.r, dg = g - other.g, db = b - other.b
        return dr * dr + dg * dg + db * db
    }
}
