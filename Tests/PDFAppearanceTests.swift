import XCTest
import SwiftUI
import CoreImage
import PDFKit
@testable import ClaudePDF

/// The filter itself is only observable on screen; what is worth pinning down is the
/// resolution table and the fact that darkening never reaches page content.
final class PDFAppearanceTests: XCTestCase {
    func testMatchSystemFollowsTheWindow() {
        XCTAssertTrue(AppearanceMode.matchSystem.darkPages(system: .dark))
        XCTAssertFalse(AppearanceMode.matchSystem.darkPages(system: .light))
    }

    func testExplicitModesOverruleTheSystem() {
        XCTAssertTrue(AppearanceMode.dark.darkPages(system: .light))
        XCTAssertFalse(AppearanceMode.light.darkPages(system: .dark))
    }

    func testRawValuesAreStableAcrossLaunches() {
        // These are persisted in UserDefaults: renaming a case silently resets the setting.
        XCTAssertEqual(AppearanceMode.allCases.map(\.rawValue), ["matchSystem", "light", "dark"])
        XCTAssertNil(AppearanceMode(rawValue: "system"))
        // The defaults key predates the mode going app-wide, and is deliberately not renamed.
        XCTAssertEqual(AppSettings.appearanceKey, "viewer.pdfAppearance")
    }

    // MARK: The chrome follows too

    /// `matchSystem` must not force a scheme. The window's scheme is what `darkPages(system:)`
    /// reads, so forcing it would make the answer its own input: a window dark at night would
    /// report itself dark forever and never follow the system back to light.
    func testMatchSystemDoesNotForceAScheme() {
        XCTAssertNil(AppearanceMode.matchSystem.preferredColorScheme)
    }

    func testExplicitModesCarryTheWholeWindow() {
        XCTAssertEqual(AppearanceMode.dark.preferredColorScheme, .dark)
        XCTAssertEqual(AppearanceMode.light.preferredColorScheme, .light)
    }

    /// Chrome and pages are one switch now: no mode may darken one without the other.
    func testChromeAndPagesNeverDisagree() {
        for mode in AppearanceMode.allCases {
            for system in [ColorScheme.light, .dark] {
                let chromeIsDark = mode.preferredColorScheme ?? system
                XCTAssertEqual(chromeIsDark == .dark, mode.darkPages(system: system),
                               "\(mode.rawValue) under \(system) splits the chrome from the pages")
            }
        }
    }

    // MARK: What the filter actually does

    /// Runs a colour through the same `CIFilter` chain the layer gets, and reports the level a
    /// screenshot would read. Validated against the running app: with the levels handed to the
    /// matrix un-compensated, this returned 18/210 for paper/ink and a screenshot of the real
    /// window measured 18/210 too, so it is a faithful stand-in for the on-screen result.
    private func filtered(_ color: NSColor, progress: CGFloat = 1) throws -> NSColor {
        let srgb = try XCTUnwrap(color.usingColorSpace(.sRGB))
        let space = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        var image = CIImage(color: CIColor(
            red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent,
            colorSpace: space
        ) ?? .white).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        for filter in PDFPageDarkening.invertingFilters(progress: progress) {
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

    private func level(_ color: NSColor, progress: CGFloat = 1) throws -> CGFloat {
        try filtered(color, progress: progress).brightnessComponent * 255
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

    // MARK: The way across

    /// The whole basis of the sweep: the same chain at 0 has to be a no-op, or the first frame
    /// of a switch is itself a jump. Tolerance is one level — the tone-curve pair does not quite
    /// cancel to the bit, which is the same rounding `paperInFilterSpace` compensates for.
    func testProgressZeroLeavesThePageAsAuthored() throws {
        XCTAssertEqual(try level(.white, progress: 0), 255, accuracy: 1)
        XCTAssertEqual(try level(.black, progress: 0), 0, accuracy: 1)
        let blue = NSColor(srgbRed: 0.1, green: 0.37, blue: 0.82, alpha: 1)
        XCTAssertEqual(try filtered(blue, progress: 0).hueComponent, blue.hueComponent, accuracy: 0.02)
    }

    /// No overshoot and no doubling back: paper only ever gets darker on the way in, ink only
    /// ever gets lighter, and both stop exactly where the un-animated filter used to put them.
    func testTheSweepMovesOneWayFromAuthoredToDark() throws {
        let paper = try (0...10).map { try level(.white, progress: CGFloat($0) / 10) }
        XCTAssertEqual(paper.last!, PDFPageDarkening.paperLevel * 255, accuracy: 2)
        for (before, after) in zip(paper, paper.dropFirst()) {
            XCTAssertLessThan(after, before + 1, "paper brightened at some point in the sweep")
        }
        for (step, mid) in paper.dropFirst().dropLast().enumerated() {
            XCTAssertGreaterThan(mid, PDFPageDarkening.paperLevel * 255,
                                 "step \(step + 1) is already past the far end")
        }

        let ink = try (0...10).map { try level(.black, progress: CGFloat($0) / 10) }
        XCTAssertEqual(ink.last!, PDFPageDarkening.inkLevel * 255, accuracy: 3)
        for (before, after) in zip(ink, ink.dropFirst()) {
            XCTAssertGreaterThan(after, before - 1, "ink darkened at some point in the sweep")
        }
    }

    /// The margins are filtered along with the page, so the colour handed to the filter has to
    /// start at PDFKit's own and arrive at the pre-inversion grey. Feeding it the endpoint from
    /// frame one flashes the surround before anything else has moved.
    @MainActor
    func testTheBackdropCrossesWithThePages() {
        let view = PDFView()
        view.document = PDFFixtures.makeDocument()
        let light = NSColor(srgbRed: 0.4, green: 0.4, blue: 0.4, alpha: 1)

        PDFPageDarkening.apply(progress: 0, to: view, lightBackground: light)
        XCTAssertEqual(view.backgroundColor, light)

        PDFPageDarkening.apply(progress: 0.5, to: view, lightBackground: light)
        let half = view.backgroundColor.usingColorSpace(.sRGB)?.redComponent ?? 0
        XCTAssertGreaterThan(half, 0.4)
        XCTAssertLessThan(half, 0.95)

        PDFPageDarkening.apply(progress: 1, to: view, lightBackground: light)
        XCTAssertEqual(view.backgroundColor, PDFPageDarkening.backdropBeforeInversion)
    }

    func testEasingStartsAndStopsAtRest() {
        XCTAssertEqual(PDFDarkeningAnimator.eased(0), 0)
        XCTAssertEqual(PDFDarkeningAnimator.eased(1), 1)
        XCTAssertEqual(PDFDarkeningAnimator.eased(0.5), 0.5, accuracy: 0.0001)
        // The point of the curve: it leaves and arrives slower than the middle travels.
        XCTAssertLessThan(PDFDarkeningAnimator.eased(0.1), 0.1)
        XCTAssertGreaterThan(PDFDarkeningAnimator.eased(0.9), 0.9)
    }

    // MARK: The animator

    /// Opening a document under a dark system must not fade the paper down from white. Only a
    /// switch made while the window is on screen is worth animating.
    @MainActor
    func testTheFirstApplyLandsWithoutASweep() {
        var frames: [CGFloat] = []
        let animator = PDFDarkeningAnimator { frames.append($0) }
        animator.set(dark: true, followingSystem: true, animated: false)
        XCTAssertEqual(frames, [1])
    }

    /// `updateNSView` runs for every unrelated change in the window — a keystroke in the chat
    /// panel must not re-render the filter, and must not restart a sweep already under way.
    @MainActor
    func testAskingAgainForTheCurrentStateDoesNothing() {
        var frames: [CGFloat] = []
        let animator = PDFDarkeningAnimator { frames.append($0) }
        animator.set(dark: false, followingSystem: false, animated: false)
        animator.set(dark: false, followingSystem: false, animated: true)
        animator.set(dark: false, followingSystem: false, animated: true)
        XCTAssertEqual(frames, [0])
    }

    @MainActor
    func testASwitchArrivesThroughIntermediateFrames() {
        let landed = expectation(description: "the sweep reaches full dark")
        var frames: [CGFloat] = []
        let animator = PDFDarkeningAnimator { progress in
            frames.append(progress)
            if progress >= 1 { landed.fulfill() }
        }
        animator.set(dark: false, followingSystem: false, animated: false)
        animator.set(dark: true, followingSystem: false, animated: true)
        wait(for: [landed], timeout: 5)

        XCTAssertEqual(frames.first, 0)
        XCTAssertEqual(frames.last, 1, "the sweep must settle on the exact endpoint")
        // At least one frame between the ends. Deliberately not a frame *count*: a loaded
        // machine can drop ticks, and "it went through the middle" is the actual claim —
        // exactly [0, 1] is the failure this is here to catch.
        XCTAssertGreaterThan(frames.count, 2, "the switch jumped instead of sweeping")
        for (before, after) in zip(frames, frames.dropFirst()) {
            XCTAssertGreaterThanOrEqual(after, before, "the sweep went backwards")
        }
    }

    // MARK: Sunset takes longer than a keypress

    /// The whole resolution table for pace, since the interesting cases are the ones that look
    /// like a sunset and aren't.
    func testOnlyAWindowFollowingTheSystemThroughoutGetsTheSunsetPace() {
        let sunset = PDFPageDarkening.sunsetDuration
        let pressed = PDFPageDarkening.transitionDuration
        XCTAssertGreaterThan(sunset, pressed, "a change nobody asked for should not be the brisk one")

        // Match system, still Match system: nothing in the app changed, so the system did.
        XCTAssertEqual(PDFDarkeningAnimator.duration(wasFollowingSystem: true, true), sunset)
        // ⇧⌘D and the toolbar moon pick a side, so the window stops following.
        XCTAssertEqual(PDFDarkeningAnimator.duration(wasFollowingSystem: true, false), pressed)
        // Settings, Always light → Match system at night: a decision just made, not a sunset.
        XCTAssertEqual(PDFDarkeningAnimator.duration(wasFollowingSystem: false, true), pressed)
        // Always light → Always dark in Settings.
        XCTAssertEqual(PDFDarkeningAnimator.duration(wasFollowingSystem: false, false), pressed)
    }

    /// Only the lower bound is asserted, and only on the slow case. A sweep cannot *finish*
    /// before its duration has elapsed, so this holds however loaded the machine is; an upper
    /// bound would be a bet on the timer being served on time, which is what makes that kind of
    /// assertion flaky.
    @MainActor
    func testASunsetActuallyTakesTheLongerPathOnTheClock() {
        let landed = expectation(description: "the sunset reaches full dark")
        let begun = CACurrentMediaTime()
        var elapsed: CFTimeInterval = 0
        let animator = PDFDarkeningAnimator { progress in
            if progress >= 1 {
                elapsed = CACurrentMediaTime() - begun
                landed.fulfill()
            }
        }
        animator.set(dark: false, followingSystem: true, animated: false)
        animator.set(dark: true, followingSystem: true, animated: true)
        wait(for: [landed], timeout: 5)

        XCTAssertGreaterThanOrEqual(elapsed, PDFPageDarkening.sunsetDuration,
                                    "the sunset finished before its own duration was up")
        XCTAssertGreaterThan(elapsed, PDFPageDarkening.transitionDuration,
                             "the sunset ran at the pressed-key pace")
    }
}
