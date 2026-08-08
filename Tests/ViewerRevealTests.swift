import PDFKit
import XCTest
@testable import ClaudePDF

/// The wiring between a quoted answer and the page, exercised through a real `PDFView`:
/// the locator can be perfect and the feature still show nothing if the flash never
/// reaches `highlightedSelections`.
@MainActor
final class ViewerRevealTests: XCTestCase {

    private func makeViewer(pages: [[String]]) -> (PDFViewerController, PDFView) {
        let view = PDFView()
        view.document = PDFFixtures.makeTextDocument(pages: pages)
        let controller = PDFViewerController()
        controller.attach(view: view)
        return (controller, view)
    }

    func testRevealHighlightsTheQuotedPassage() {
        let (viewer, view) = makeViewer(pages: [
            ["Filler on the first page."],
            ["The breakpoint sits above everything volatile in the request."],
        ])

        XCTAssertTrue(viewer.reveal(quote: "The breakpoint sits above everything volatile"))

        let highlighted = view.highlightedSelections ?? []
        XCTAssertEqual(highlighted.count, 1)
        XCTAssertEqual(
            TextNormalizer.normalize(highlighted.first?.string ?? "").text,
            "the breakpoint sits above everything volatile"
        )
    }

    func testAMissChangesNothingOnScreen() {
        let (viewer, view) = makeViewer(pages: [["Filler that says nothing useful."]])

        XCTAssertFalse(viewer.reveal(quote: "a passage that is nowhere in this document"))
        XCTAssertNil(view.highlightedSelections)
    }

    /// The reader's own text selection is what the composer picks up at submit, so a
    /// flash must not become the anchor of their next question.
    func testRevealDoesNotTouchTheReadersSelection() {
        let (viewer, view) = makeViewer(pages: [["The breakpoint sits above everything volatile."]])

        XCTAssertTrue(viewer.reveal(quote: "The breakpoint sits above everything"))

        XCTAssertNil(view.currentSelection)
        XCTAssertNil(viewer.selectionInfo())
    }

    func testTheFlashClearsItselfAndLeavesNoHighlightBehind() async throws {
        let (viewer, view) = makeViewer(pages: [["The breakpoint sits above everything volatile."]])

        XCTAssertTrue(viewer.reveal(quote: "The breakpoint sits above everything"))
        XCTAssertNotNil(view.highlightedSelections, "the pulse should be visible immediately")

        try await Task.sleep(for: .seconds(2.5))   // the full pulse sequence is ~2.0s
        XCTAssertNil(view.highlightedSelections, "a finished flash restores the search state")
    }
}
