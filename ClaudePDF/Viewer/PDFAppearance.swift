import SwiftUI
import CoreImage
import PDFKit

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
    static let backdropBeforeInversion = NSColor(white: 0.95, alpha: 1)

    /// How long a switch takes to cross. A page of paper going near-black in one frame is a
    /// flashbulb in reverse; spread over a third of a second the same change reads as a dimmer
    /// being turned down. Long enough to be seen as a sweep, short enough that ⇧⌘D still feels
    /// like a switch rather than something you wait for.
    static let transitionDuration: CFTimeInterval = 0.35

    /// The system turning the window dark under a reader who didn't ask for it — *Match system*
    /// at sunset — gets longer than that.
    ///
    /// A pressed key wants its result promptly: you asked, and a slow answer reads as lag. A
    /// change you did not ask for is the opposite case, and the eye is looking at the page while
    /// it happens rather than at the toolbar. Still under a second, so it stays a transition
    /// rather than an effect.
    static let sunsetDuration: CFTimeInterval = 0.6

    /// Idempotent — safe to call on every `updateNSView`.
    static func apply(dark: Bool, to pdfView: PDFView, lightBackground: NSColor) {
        apply(progress: dark ? 1 : 0, to: pdfView, lightBackground: lightBackground)
    }

    /// A frame of the sweep: `progress` 0 is the page as authored, 1 is fully darkened.
    ///
    /// Zero installs *no* filter rather than the identity one, so a light window pays nothing
    /// for the feature — an identity chain is still four filters Core Animation composites on
    /// every frame.
    static func apply(progress: CGFloat, to pdfView: PDFView, lightBackground: NSColor) {
        pdfView.wantsLayer = true
        pdfView.layer?.filters = progress <= 0 ? [] : invertingFilters(progress: progress)
        pdfView.backgroundColor = backdrop(progress: progress, lightBackground: lightBackground)
    }

    /// Thumbnails ride the same filter. Their background stays clear, and a clear pixel has
    /// premultiplied alpha 0, so the sidebar keeps the window's own colour either way.
    static func apply(dark: Bool, to thumbnailView: PDFThumbnailView) {
        apply(progress: dark ? 1 : 0, to: thumbnailView)
    }

    static func apply(progress: CGFloat, to thumbnailView: PDFThumbnailView) {
        thumbnailView.wantsLayer = true
        thumbnailView.layer?.filters = progress <= 0 ? [] : invertingFilters(progress: progress)
    }

    /// The surround has to cross with the page rather than jump ahead of it: at `progress` 0 the
    /// filter is not installed, so handing it `backdropBeforeInversion` straight away would flash
    /// the margins near-white before anything else moved. Blending in the *pre-filter* space is
    /// what keeps the two in step, since this is the colour the filter is about to be handed.
    private static func backdrop(progress: CGFloat, lightBackground: NSColor) -> NSColor {
        guard progress > 0 else { return lightBackground }
        guard progress < 1 else { return backdropBeforeInversion }
        guard let light = lightBackground.usingColorSpace(.sRGB),
              let dark = backdropBeforeInversion.usingColorSpace(.sRGB) else {
            return backdropBeforeInversion
        }
        func mix(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * progress }
        return NSColor(
            srgbRed: mix(light.redComponent, dark.redComponent),
            green: mix(light.greenComponent, dark.greenComponent),
            blue: mix(light.blueComponent, dark.blueComponent),
            alpha: mix(light.alphaComponent, dark.alphaComponent)
        )
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
    ///
    /// `progress` scales the whole chain towards the identity, which is what makes a smooth
    /// light↔dark cross possible: at 0 the matrix is `out = x` and the hue rotation is 0°, so
    /// the page renders as authored. Both parts are linear in it, so nothing overshoots on the
    /// way. Stepping this per frame is also *why* the animation isn't a `CABasicAnimation` on
    /// the filter's key paths — the matrix rides in `CIVector`s, which Core Animation will not
    /// interpolate, and animating the one scalar it would take (the hue angle) on its own just
    /// swings the colours around an un-inverted page.
    static func invertingFilters(progress: CGFloat = 1) -> [CIFilter] {
        let amount = min(max(progress, 0), 1)
        guard let encode = CIFilter(name: "CILinearToSRGBToneCurve"),
              let invert = rangeMappedInvert(progress: amount),
              let decode = CIFilter(name: "CISRGBToneCurveToLinear"),
              let hue = CIFilter(name: "CIHueAdjust") else { return [] }
        hue.setValue(CGFloat.pi * amount, forKey: kCIInputAngleKey)
        return [encode, invert, decode, hue]
    }

    /// `out = ink − x·(ink − paper)`: `CIColorInvert` with the output squeezed into the readable
    /// band, as one matrix rather than an invert plus a rescale. It sits between the tone curves
    /// on purpose — the levels are sRGB levels, so the arithmetic belongs in the encoded space,
    /// not in Core Image's linear one.
    ///
    /// Part-way through a sweep it is that matrix mixed with the identity: `out = (1−t)·x +
    /// t·(ink − x·(ink − paper))`. Mixing the *coefficients* rather than running two chains and
    /// blending their images keeps this one matrix at every point of the transition.
    private static func rangeMappedInvert(progress: CGFloat = 1) -> CIFilter? {
        guard let filter = CIFilter(name: "CIColorMatrix") else { return nil }
        let ink = inkInFilterSpace * progress
        let span = (1 - progress) - progress * (inkInFilterSpace - paperInFilterSpace)
        filter.setValue(CIVector(x: span, y: 0, z: 0, w: 0), forKey: "inputRVector")
        filter.setValue(CIVector(x: 0, y: span, z: 0, w: 0), forKey: "inputGVector")
        filter.setValue(CIVector(x: 0, y: 0, z: span, w: 0), forKey: "inputBVector")
        filter.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        filter.setValue(CIVector(x: ink, y: ink, z: ink, w: 0), forKey: "inputBiasVector")
        return filter
    }
}

/// Drives `PDFPageDarkening` from one state to the other over `transitionDuration` instead of
/// snapping between them.
///
/// One of these per filtered view, held by the representable's coordinator, because the sweep is
/// a property of *that* layer: the pages and the thumbnail strip each run their own so a window
/// with the sidebar open crosses as one picture.
///
/// A timer stepping `layer.filters` is doing by hand what Core Animation would do for an
/// animatable property — see `invertingFilters(progress:)` for why it can't. It runs in
/// `.common` modes so a sweep started just before a scroll doesn't freeze half-way.
@MainActor
final class PDFDarkeningAnimator {
    /// Called with 0…1 for each frame of the sweep, and with an exact 0 or 1 at either end so
    /// the resting state is never a rounding error away from "no filter at all".
    private let render: (CGFloat) -> Void

    /// `nil` until the first `set`, which is what tells "opened dark" from "switched to dark":
    /// a window opening under a dark system must show a dark page, not sweep into one.
    private var target: Bool?

    /// What the *previous* `set` said about the window following the system, which is half of
    /// what distinguishes a sunset from a keypress — see `duration(wasFollowingSystem:_:)`.
    /// Its initial value is never read: the first `set` is the un-animated one.
    private var followedSystem = false

    private var progress: CGFloat = 0
    private var timer: Timer?

    init(render: @escaping (CGFloat) -> Void) {
        self.render = render
    }

    /// Safe to call on every `updateNSView`: asking again for the state already in flight lets
    /// the sweep run on rather than restarting it from wherever it had got to.
    ///
    /// `followingSystem` is whether the window is on *Match system*. It is not what the pages
    /// should do — `dark` is — it is how they came to be asked, which is what sets the pace.
    func set(dark: Bool, followingSystem: Bool, animated: Bool) {
        defer { followedSystem = followingSystem }
        guard target != dark else { return }
        target = dark
        let destination: CGFloat = dark ? 1 : 0
        guard animated else { return finish(at: destination) }

        // From wherever the previous sweep reached, over a full duration: reversing ⇧⌘D
        // mid-cross should ease back, not snap because it had less ground to cover.
        let origin = progress
        let begun = CACurrentMediaTime()
        let duration = Self.duration(wasFollowingSystem: followedSystem, followingSystem)
        timer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated {
                self.step(from: origin, to: destination, begun: begun, over: duration)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Only a window that was on *Match system* and still is can have been turned dark by the
    /// system itself; every other way of getting here is somebody's keypress.
    ///
    /// Both halves are load-bearing. Without the first, choosing *Match system* in Settings from
    /// *Always light* at night would be paced as a sunset, when it is a decision just made. And
    /// ⇧⌘D always fails the second, since the toggle picks a side rather than following.
    nonisolated static func duration(
        wasFollowingSystem: Bool, _ isFollowingSystem: Bool
    ) -> CFTimeInterval {
        wasFollowingSystem && isFollowingSystem
            ? PDFPageDarkening.sunsetDuration
            : PDFPageDarkening.transitionDuration
    }

    /// Time-based rather than counting ticks, so a dropped frame shortens the sweep instead of
    /// stretching it.
    private func step(
        from origin: CGFloat, to destination: CGFloat, begun: CFTimeInterval, over duration: CFTimeInterval
    ) {
        let elapsed = CACurrentMediaTime() - begun
        let fraction = elapsed / duration
        guard fraction < 1 else { return finish(at: destination) }
        progress = origin + (destination - origin) * Self.eased(CGFloat(fraction))
        render(progress)
    }

    private func finish(at destination: CGFloat) {
        timer?.invalidate()
        timer = nil
        progress = destination
        render(destination)
    }

    /// Smoothstep. A linear ramp is visibly a ramp — it starts and stops at full speed, which is
    /// the part of a hard cut the eye was objecting to in the first place.
    nonisolated static func eased(_ fraction: CGFloat) -> CGFloat {
        let t = min(max(fraction, 0), 1)
        return t * t * (3 - 2 * t)
    }
}
