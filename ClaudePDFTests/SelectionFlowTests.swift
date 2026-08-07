import AppKit
import PDFKit
import XCTest

/// The Phase 2 exit criterion, tested at the level the app actually uses:
/// "both modes produce a correct `Question` from any zoom level."
///
/// Drives `PDFViewerController` — the same entry points the toolbar, ⌘L and the crop overlay
/// call — with a real PDFView in a window-less hierarchy, so no GUI automation is involved.
@MainActor
final class SelectionFlowTests: XCTestCase {

    private var document: PDFDocument!
    private var view: PDFView!
    private var overlay: CropOverlayView!
    private var controller: PDFViewerController!

    private func setUpViewer(scale: CGFloat = 1, rotation: Int = 0) {
        document = PDFFixtures.makeDocument(rotation: rotation)
        let container = NSView(frame: CGRect(x: 0, y: 0, width: 600, height: 500))
        view = PDFView(frame: CGRect(x: 40, y: 30, width: 500, height: 400))
        view.document = document
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = false
        view.autoScales = false
        view.scaleFactor = scale
        overlay = CropOverlayView(frame: view.frame)
        container.addSubview(view)
        container.addSubview(overlay)
        view.layoutSubtreeIfNeeded()

        controller = PDFViewerController()
        controller.attach(view: view)
    }

    /// The drag the user would make to box a given page rect, expressed in overlay coordinates.
    private func overlayRect(for pageRect: CGRect) -> CGRect {
        overlay.convert(view.convert(pageRect, from: document.page(at: 0)!), from: view)
    }

    private func question(from anchor: QuestionAnchor?) -> Question {
        var question = Question(text: "What is this?")
        question.pageHint = controller.currentPageNumber
        anchor?.apply(to: &question)
        return question
    }

    // MARK: Crop mode

    func testCropDragProducesAQuestionCarryingThePNGAtEveryZoom() {
        for rotation in [0, 90, 180, 270] {
            for scale in [CGFloat(0.5), 1.0, 2.0, 4.0] {
                setUpViewer(scale: scale, rotation: rotation)
                controller.toggleCropMode()
                XCTAssertTrue(controller.cropModeActive)

                controller.completeCrop(rect: overlayRect(for: PDFFixtures.red), from: overlay)

                XCTAssertNil(controller.anchorError,
                             "rotation \(rotation), scale \(scale): \(controller.anchorError ?? "")")
                XCTAssertFalse(controller.cropModeActive, "a completed crop leaves crop mode")

                let question = question(from: controller.takeAnchor())
                guard let png = question.regionImagePNG else {
                    XCTFail("no crop on the question (rotation \(rotation), scale \(scale))")
                    continue
                }
                assertColor(PNGInspector.centerColor(png), isNear: .red,
                            "rotation \(rotation), scaleFactor \(scale)")
                XCTAssertEqual(question.regionPage, 1)
                XCTAssertEqual(question.pageHint, 1)
                XCTAssertNil(question.selectedText, "a crop is not a text selection")
            }
        }
    }

    func testCropOverTextAlsoCarriesTheTextFallback() {
        setUpViewer()
        controller.completeCrop(rect: overlayRect(for: PDFFixtures.textRect), from: overlay)
        let question = question(from: controller.takeAnchor())
        XCTAssertNotNil(question.regionImagePNG)
        XCTAssertEqual(question.regionText, PDFFixtures.textString,
                       "text-only providers need something to read (PLAN.md §4B)")
    }

    func testCropOverAFigureHasNoTextFallback() {
        setUpViewer()
        controller.completeCrop(rect: overlayRect(for: PDFFixtures.red), from: overlay)
        XCTAssertNil(question(from: controller.takeAnchor()).regionText)
    }

    func testCropOffThePageReportsAnErrorInsteadOfStagingAnAnchor() {
        setUpViewer()
        controller.toggleCropMode()
        // Far outside the page, in a corner of the overlay that no page occupies.
        controller.completeCrop(rect: CGRect(x: 0, y: 0, width: 20, height: 20), from: overlay)
        XCTAssertNil(controller.anchor)
        XCTAssertNotNil(controller.anchorError, "the user should be told why nothing happened")
    }

    func testTogglingCropModeClearsAStaleError() {
        setUpViewer()
        controller.anchorError = "stale"
        controller.toggleCropMode()
        XCTAssertNil(controller.anchorError)
    }

    func testCancellingCropModeLeavesNoAnchor() {
        setUpViewer()
        controller.toggleCropMode()
        controller.cancelCrop()
        XCTAssertFalse(controller.cropModeActive)
        XCTAssertNil(controller.anchor)
    }

    // MARK: Text-selection mode

    private func selectFixtureText() {
        let page = document.page(at: 0)!
        view.setCurrentSelection(page.selection(for: PDFFixtures.textRect), animate: false)
    }

    func testCapturingATextSelectionProducesAQuestionWithTheSelectedText() {
        for scale in [CGFloat(0.5), 1.0, 2.0, 4.0] {
            setUpViewer(scale: scale)
            selectFixtureText()
            XCTAssertTrue(controller.captureTextSelection(), "at scaleFactor \(scale)")

            let question = question(from: controller.takeAnchor())
            XCTAssertEqual(question.selectedText, PDFFixtures.textString, "at scaleFactor \(scale)")
            XCTAssertEqual(question.selectedTextPage, 1)
            XCTAssertNil(question.regionImagePNG, "a text ask carries no image")
        }
    }

    /// Guards a reactivity bug rather than a logic one: `hasTextSelection` used to be computed,
    /// so nothing told SwiftUI to re-enable "Ask about Selection" when the user highlighted text
    /// and the control stayed grey. It has to be *published* off PDFKit's selection notification.
    func testHasTextSelectionIsPublishedWhenTheSelectionChanges() {
        setUpViewer()
        XCTAssertFalse(controller.hasTextSelection, "nothing selected yet")

        selectFixtureText()
        // The observer is delivered on the main queue; let it drain before asserting.
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)

        XCTAssertTrue(controller.hasTextSelection,
                      "the Ask about Selection control would stay disabled")
    }

    func testCapturingWithNothingSelectedReportsAnError() {
        setUpViewer()
        XCTAssertFalse(controller.captureTextSelection())
        XCTAssertNil(controller.anchor)
        XCTAssertNotNil(controller.anchorError)
    }

    // MARK: Anchor staging

    func testTakeAnchorFallsBackToALiveSelectionWhenNothingWasStaged() {
        setUpViewer()
        selectFixtureText()
        // The user never pressed ⌘L — just selected text and typed a question.
        XCTAssertNil(controller.anchor)
        XCTAssertEqual(question(from: controller.takeAnchor()).selectedText, PDFFixtures.textString)
    }

    func testAStagedAnchorIsConsumedExactlyOnce() {
        setUpViewer()
        controller.completeCrop(rect: overlayRect(for: PDFFixtures.red), from: overlay)
        XCTAssertNotNil(controller.takeAnchor())
        XCTAssertNil(controller.anchor, "the anchor is cleared once it is on a question")
        XCTAssertNil(controller.takeAnchor(), "a second question must not reuse the crop")
    }

    func testAStagedCropWinsOverAStaleTextSelection() {
        setUpViewer()
        selectFixtureText()
        controller.completeCrop(rect: overlayRect(for: PDFFixtures.red), from: overlay)
        let question = question(from: controller.takeAnchor())
        XCTAssertNotNil(question.regionImagePNG)
        XCTAssertNil(question.selectedText,
                     "the explicit crop is the anchor, not whatever text happened to be selected")
    }

    func testClearAnchorRemovesTheStagedCropAndError() {
        setUpViewer()
        controller.completeCrop(rect: overlayRect(for: PDFFixtures.red), from: overlay)
        controller.anchorError = "something"
        controller.clearAnchor()
        XCTAssertNil(controller.anchor)
        XCTAssertNil(controller.anchorError)
    }
}
