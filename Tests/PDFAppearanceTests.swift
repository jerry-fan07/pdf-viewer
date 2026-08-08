import XCTest
import SwiftUI
import CoreImage
import PDFKit
@testable import ClaudePDF

/// The filter itself is only observable on screen; what is worth pinning down is the
/// resolution table and the fact that darkening never reaches page content.
final class PDFAppearanceTests: XCTestCase {
    func testMatchSystemFollowsTheWindow() {
        XCTAssertTrue(PDFAppearanceMode.matchSystem.darkPages(system: .dark))
        XCTAssertFalse(PDFAppearanceMode.matchSystem.darkPages(system: .light))
    }

    func testExplicitModesOverruleTheSystem() {
        XCTAssertTrue(PDFAppearanceMode.dark.darkPages(system: .light))
        XCTAssertFalse(PDFAppearanceMode.light.darkPages(system: .dark))
    }

    func testRawValuesAreStableAcrossLaunches() {
        // These are persisted in UserDefaults: renaming a case silently resets the setting.
        XCTAssertEqual(PDFAppearanceMode.allCases.map(\.rawValue), ["matchSystem", "light", "dark"])
        XCTAssertNil(PDFAppearanceMode(rawValue: "system"))
    }

    // MARK: What the filter actually does

    /// Runs a colour through the same `CIFilter` chain the layer gets, and reports the level a
    /// screenshot would read. Validated against the running app: with the levels handed to the
    /// matrix un-compensated, this returned 18/210 for paper/ink and a screenshot of the real
    /// window measured 18/210 too, so it is a faithful stand-in for the on-screen result.
    private func filtered(_ color: NSColor) throws -> NSColor {
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var image = CIImage(color: CIColor(
            red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent,
            colorSpace: space
        ) ?? .white).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        for filter in PDFPageDarkening.invertingFilters() {
            filter.setValue(image, forKey: kCIInputImageKey)
            image = try XCTUnwrap(filter.outputImage)
        }
        let context = CIContext(options: [
            .workingColorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.linearSRGB))
        ])
        let rendered = try XCTUnwrap(
            context.createCGImage(image, from: image.extent, format: .RGBA8, colorSpace: space)
        )
        return try XCTUnwrap(
            NSBitmapImageRep(cgImage: rendered).colorAt(x: 4, y: 4)?.usingColorSpace(.sRGB)
        )
    }

    private func level(_ color: NSColor) throws -> CGFloat {
        try filtered(color).brightnessComponent * 255
    }

    /// The spec the filter is tuned to. The matrix is fed compensated values, so this — not the
    /// constants in `rangeMappedInvert` — is what says whether the tuning is right.
    func testPaperAndInkLandOnTheIntendedLevels() throws {
        XCTAssertEqual(try level(.white), PDFPageDarkening.paperLevel * 255, accuracy: 2,
                       "paper should read 15, not pure black")
        XCTAssertEqual(try level(.black), PDFPageDarkening.inkLevel * 255, accuracy: 3,
                       "body text should stop short of 255 white")
    }

    func testMidtonesStayInsideTheBand() throws {
        // A bare linear-space invert left this 0.9 grey at 145 — a glaring mid-grey.
        let panel = try level(NSColor(white: 0.9, alpha: 1))
        XCTAssertGreaterThan(panel, PDFPageDarkening.paperLevel * 255)
        XCTAssertLessThan(panel, 60)
        // Nothing the page can contain may out-shine the ink ceiling.
        for input in [CGFloat(0), 0.25, 0.5, 0.75, 1] {
            XCTAssertLessThanOrEqual(
                try level(NSColor(white: input, alpha: 1)), PDFPageDarkening.inkLevel * 255 + 3,
                "grey \(input) broke the ceiling"
            )
        }
    }

    func testColoursKeepTheirHueAndStayUnderTheCeiling() throws {
        let blue = NSColor(srgbRed: 0.1, green: 0.37, blue: 0.82, alpha: 1)
        let out = try filtered(blue)
        XCTAssertEqual(out.hueComponent, blue.hueComponent, accuracy: 0.06, "a blue figure stays blue")
        XCTAssertLessThanOrEqual(out.brightnessComponent * 255, PDFPageDarkening.inkLevel * 255 + 3,
                                 "a saturated figure is toned down, not lit up")
    }

    /// The reason the search colour is not just `systemYellow`: the filter lands that at a muddy
    /// 109/98/0 olive. This is the assertion that fails if the chain is ever retuned.
    func testSearchHighlightLandsBrightYellowOnScreen() throws {
        let yellow = try XCTUnwrap(NSColor.systemYellow.usingColorSpace(.sRGB))
        let onScreen = try filtered(PDFPageDarkening.searchHighlightColor(dark: true))
        XCTAssertGreaterThan(onScreen.brightnessComponent, 0.6)
        XCTAssertEqual(onScreen.hueComponent, yellow.hueComponent, accuracy: 0.06)

        let naive = try filtered(PDFPageDarkening.searchHighlightColor(dark: false))
        XCTAssertLessThan(naive.brightnessComponent + 0.15, onScreen.brightnessComponent,
                          "the compensation must be worth having")
    }

    /// The reason this is a layer filter and not a `PDFPage.draw` override: crops must not invert.
    /// A `draw` override would be live here, because `CropRenderer` draws through the same path.
    @MainActor
    func testDarkeningDoesNotReachCropOutput() throws {
        let document = PDFFixtures.makeDocument()
        let page = try XCTUnwrap(document.page(at: 0))

        let view = PDFView()
        view.document = document
        PDFPageDarkening.apply(dark: true, to: view, lightBackground: .white)
        XCTAssertEqual(view.layer?.filters?.count, 4, "dark pages should install the invert chain")

        let whole = CGRect(origin: .zero, size: PDFFixtures.pageSize)
        let capture = try XCTUnwrap(
            CropRenderer.capture(page: page, pageIndex: 0, pageRect: whole)
        )
        // Same expectations as CropRendererTests: the page comes out as authored.
        assertColor(PNGInspector.color(capture.pngData, atFractionX: 0.1, y: 0.2),
                    isNear: .red, "red marker must not invert")
        assertColor(PNGInspector.color(capture.pngData, atFractionX: 0.5, y: 0.9),
                    isNear: .white, "paper must stay white in an exported crop")
    }

    @MainActor
    func testTurningDarkPagesOffRestoresTheView() {
        let view = PDFView()
        view.document = PDFFixtures.makeDocument()
        let original = view.backgroundColor
        PDFPageDarkening.apply(dark: true, to: view, lightBackground: original)
        PDFPageDarkening.apply(dark: false, to: view, lightBackground: original)
        XCTAssertEqual(view.layer?.filters?.isEmpty, true)
        XCTAssertEqual(view.backgroundColor, original)
    }
}
