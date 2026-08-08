import SwiftUI
import CoreImage
import PDFKit

/// How PDF *pages* are rendered. Independent of the app chrome, which always follows the
/// system: a dark toolbar around a page of white paper is the normal reading case, and
/// plenty of people want it to stay that way at night.
enum PDFAppearanceMode: String, CaseIterable, Identifiable {
    case matchSystem
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .matchSystem: return "Match system"
        case .light:       return "Always light"
        case .dark:        return "Always dark"
        }
    }

    /// Whether pages should be darkened in a window running under `system`.
    func darkPages(system: ColorScheme) -> Bool {
        switch self {
        case .matchSystem: return system == .dark
        case .light:       return false
        case .dark:        return true
        }
    }
}

/// Darkens PDF pages by filtering the *view layer*, not by overriding `PDFPage.draw`.
///
/// The override is the obvious implementation and the wrong one here: `CropRenderer` draws
/// through the same `page.draw` path, so it would invert every region screenshot the app
/// sends to a provider. Page content must stay the way the document authored it; only what
/// reaches the screen changes.
///
/// The filter is a range-mapped invert followed by a 180° hue rotation — "smart invert". Plain
/// inversion flips lightness *and* hue, turning a blue figure orange; rotating the hue back
/// leaves black-on-white as white-on-black while a blue line stays blue.
enum PDFPageDarkening {
    /// The band the inverted page lands in, as the sRGB levels a screenshot reads back.
    ///
    /// A full-range invert is the mathematically obvious choice and reads badly: paper at pure
    /// black under 255-white text is a glare source, not a night mode. Paper sits just off
    /// black and ink stops short of white, so the page carries the same contrast the rest of a
    /// dark macOS window does. Everything else — greys, coloured text, figures — is carried
    /// along by the same map, which is what takes the intensity off saturated colours too.
    static let paperLevel: CGFloat = 15 / 255
    static let inkLevel: CGFloat = 200 / 255

    /// What the matrix is actually fed. Core Image's sRGB tone-curve pair is not quite an exact
    /// inverse, so handing it `paperLevel`/`inkLevel` straight renders 18/210 rather than
    /// 15/200 — measured off the running app, and reproduced by `PDFAppearanceTests`, which
    /// asserts the *rendered* levels rather than these. Retune against that test, not by eye.
    private static let paperInFilterSpace: CGFloat = 0.050
    private static let inkInFilterSpace: CGFloat = 0.735

    /// Fed to the filter, so this is the colour *before* inversion: 0.95 comes out a step above
    /// `paperLevel`, keeping page edges perceptible without framing the page in a lighter box.
    /// Hue rotation leaves greys alone, so the round trip is exact.
    ///
    /// Nothing darker than `paperLevel` is reachable — pure white input already maps there — so
    /// the surround has to sit at or above the page rather than below it.
    private static let backdropBeforeInversion = NSColor(white: 0.95, alpha: 1)

    /// Idempotent — safe to call on every `updateNSView`.
    static func apply(dark: Bool, to pdfView: PDFView, lightBackground: NSColor) {
        pdfView.wantsLayer = true
        pdfView.layer?.filters = dark ? invertingFilters() : []
        pdfView.backgroundColor = dark ? backdropBeforeInversion : lightBackground
    }

    /// Thumbnails ride the same filter. Their background stays clear, and a clear pixel has
    /// premultiplied alpha 0, so the sidebar keeps the window's own colour either way.
    static func apply(dark: Bool, to thumbnailView: PDFThumbnailView) {
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.filters = dark ? invertingFilters() : []
    }

    /// Search-match colour, chosen for what it looks like *after* the filter.
    ///
    /// The filter maps a colour to (inverted hue + 180°) at roughly (1 − luminance), so a
    /// bright `systemYellow` highlight comes out a muddy olive. Feeding it a dark olive
    /// instead gets the bright yellow back on screen.
    static func searchHighlightColor(dark: Bool) -> NSColor {
        dark ? NSColor(red: 0.28, green: 0.26, blue: 0, alpha: 1) : .systemYellow
    }

    /// Core Image works in *linear* light, where `1 − x` is not the inversion anyone means:
    /// measured on screen, a bare invert left a 0.9 grey panel at 0.57 — a glaring mid-grey
    /// where the eye expects near-black. The tone-curve pair moves the arithmetic into the
    /// space the PDF's colours were authored in and back.
    ///
    /// These are sRGB's actual piecewise curve, not a 2.2 power approximation of it. The two
    /// diverge most near black, which is exactly where `paperLevel` lives: approximating put
    /// paper at 4/255 instead of 15/255.
    ///
    /// Fresh instances per call: a `CIFilter` is stateful and must not be shared between layers.
    static func invertingFilters() -> [CIFilter] {
        guard let encode = CIFilter(name: "CILinearToSRGBToneCurve"),
              let invert = rangeMappedInvert(),
              let decode = CIFilter(name: "CISRGBToneCurveToLinear"),
              let hue = CIFilter(name: "CIHueAdjust") else { return [] }
        hue.setValue(CGFloat.pi, forKey: kCIInputAngleKey)
        return [encode, invert, decode, hue]
    }

    /// `out = ink − x·(ink − paper)`: `CIColorInvert` with the output squeezed into the readable
    /// band, as one matrix rather than an invert plus a rescale. It sits between the tone curves
    /// on purpose — the levels are sRGB levels, so the arithmetic belongs in the encoded space,
    /// not in Core Image's linear one.
    private static func rangeMappedInvert() -> CIFilter? {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return nil }
        let ink = inkInFilterSpace
        let span = -(ink - paperInFilterSpace)
        filter.setValue(CIVector(x: span, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: span, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: span, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter.setValue(CIVector(x: ink, y: ink, z: ink, w: 0), forKey: "inputBiasVector")
        return filter
    }
}
