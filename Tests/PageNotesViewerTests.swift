import PDFKit
import XCTest
@testable import ClaudePDF

/// The viewer's half of a note: where on a page a passage is, and the room a page
/// keeps beside itself for what is stuck to it.
@MainActor
final class PageNotesViewerTests: XCTestCase {
    /// The document is handed back with its page: a page does not keep its
    /// document alive, and one without a document has no box to measure against.
    private func letterDocument() throws -> PDFDocument {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 600, height: 800)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        context.beginPDFPage(nil)
        context.endPDFPage()
        context.closePDF()
        return try XCTUnwrap(PDFDocument(data: data as Data))
    }

    private func letterPage(rotation: Int = 0) throws -> PDFPage {
        let page = try XCTUnwrap(letterDocument().page(at: 0))
        page.rotation = rotation
        return page
    }

    /// Page space starts at the foot of the page; a note is measured from its head.
    func testAPassageIsMeasuredFromTheHeadOfThePage() throws {
        let page = try letterPage()
        let passage = CGRect(x: 50, y: 500, width: 300, height: 100)   // its top edge is 200 down
        let anchor = PDFViewerController.anchor(for: passage, on: page, pageNumber: 3, box: .mediaBox)
        XCTAssertEqual(anchor.page, 3)
        XCTAssertEqual(try XCTUnwrap(anchor.y), 0.25, accuracy: 0.0001)
    }

    /// A page shown on its side has a different edge uppermost, and "how far down"
    /// is how far down the page *as shown*.
    func testATurnedPageIsMeasuredTheWayItIsShown() throws {
        let passage = CGRect(x: 60, y: 500, width: 300, height: 100)
        let expected: [Int: Double] = [90: 0.1, 180: 0.625, 270: 0.4]
        for (rotation, y) in expected {
            let anchor = PDFViewerController.anchor(for: passage, on: try letterPage(rotation: rotation),
                                                    pageNumber: 1, box: .mediaBox)
            XCTAssertEqual(try XCTUnwrap(anchor.y), y, accuracy: 0.0001, "rotation \(rotation)")
        }
    }

    /// The notes' room is a page margin, so an auto-scaled page is fitted *with*
    /// it: opening a sheet makes the page smaller, and the room is beside the page
    /// rather than shared out either side of it.
    func testTheRoomForNotesIsFittedWithThePage() throws {
        let view = PDFView(frame: CGRect(x: 0, y: 0, width: 1000, height: 700))
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.pageBreakMargins = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        view.document = try letterDocument()
        let viewer = PDFViewerController()
        viewer.attach(view: view)

        viewer.setNoteRoom(30)
        let shut = view.scaleFactor
        viewer.setNoteRoom(430)
        let open = view.scaleFactor

        XCTAssertEqual(view.pageBreakMargins.right, 430)
        XCTAssertEqual(open / shut, (600.0 + 30) / (600 + 430), accuracy: 0.02,
                       "the page was not re-fitted around the sheet")
        let page = try XCTUnwrap(view.currentPage)
        XCTAssertEqual(view.convert(page.bounds(for: view.displayBox), from: page).minX, 0, accuracy: 1,
                       "the room went either side of the page instead of beside it")
    }
}
