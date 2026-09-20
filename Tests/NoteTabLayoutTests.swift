import XCTest
@testable import ClaudePDF

/// Where one page's tabs stand along its edge. Pure arithmetic, in page points —
/// which is the point: a tab's place is a fact about the page, and nothing about
/// the window, the zoom or the scroll position comes into it.
final class NoteTabLayoutTests: XCTestCase {
    private let pageHeight: CGFloat = 792
    /// Ten of chrome, and the title.
    private func tabHeight(_ titleLength: CGFloat) -> CGFloat { titleLength + 10 }

    private func note(_ y: Double?, title: CGFloat = 100, id: UUID = UUID()) -> NoteTabLayout.Note {
        .init(id: id, y: y, titleWidth: title)
    }

    private func place(_ notes: [NoteTabLayout.Note], pageHeight: CGFloat? = nil) -> NoteTabLayout.Result {
        NoteTabLayout.place(notes, pageHeight: pageHeight ?? self.pageHeight, tabHeight: tabHeight)
    }

    func testATabStandsLevelWithItsPassage() {
        let result = place([note(0.5)])
        XCTAssertEqual(result.slots.map(\.top), [396])
        XCTAssertEqual(result.addTop, 396 + 110 + NoteTabLayout.spacing)
    }

    func testAPageWithNoNotesStillHasItsPlusAtTheHeadOfTheEdge() {
        let result = place([])
        XCTAssertTrue(result.slots.isEmpty)
        XCTAssertEqual(result.addTop, NoteTabLayout.topInset)
    }

    func testNotesAboutNoPassageStackFromTheTopInTheOrderTheyWereStarted() {
        let (first, second) = (UUID(), UUID())
        let result = place([note(nil, id: first), note(nil, id: second)])
        XCTAssertEqual(result.slots.map(\.id), [first, second])
        XCTAssertEqual(result.slots.map(\.top), [14, 14 + 110 + NoteTabLayout.spacing])
    }

    func testTabsFollowTheirPassagesDownThePageWhateverOrderTheyWereAskedIn() {
        let (low, high) = (UUID(), UUID())
        let result = place([note(0.8, id: low), note(0.1, id: high)])
        XCTAssertEqual(result.slots.map(\.id), [high, low])
    }

    func testPassagesALineApartDoNotPutOneTabOnAnother() {
        let result = place([note(0.30), note(0.31), note(0.32)])
        for (above, below) in zip(result.slots, result.slots.dropFirst()) {
            XCTAssertGreaterThanOrEqual(below.top, above.top + above.height + NoteTabLayout.spacing)
        }
        XCTAssertEqual(result.slots.first?.top ?? 0, 0.30 * pageHeight, accuracy: 0.01,
                       "the first of them has no reason to move")
    }

    func testATabAtTheFootOfThePageIsTakenBackUpOntoIt() {
        let result = place([note(0.99)])
        let slot = result.slots[0]
        XCTAssertLessThanOrEqual(result.addTop + NoteTabLayout.addHeight, pageHeight - NoteTabLayout.topInset + 0.01)
        XCTAssertLessThan(slot.top, 0.99 * pageHeight)
    }

    func testACrowdedPageShortensItsTitlesInsteadOfRunningOffTheBottom() {
        let result = place((0..<12).map { _ in note(nil, title: 400) })
        let last = result.slots[result.slots.count - 1]
        XCTAssertLessThan(result.slots[0].titleLength, NoteTabLayout.maxTitleLength)
        XCTAssertLessThanOrEqual(last.top + last.height, pageHeight)
        XCTAssertLessThanOrEqual(result.addTop + NoteTabLayout.addHeight, pageHeight)
    }

    func testAShortTitleMakesAShortTab() {
        let result = place([note(nil, title: 40), note(nil, title: 400)])
        XCTAssertEqual(result.slots.map(\.titleLength), [40, NoteTabLayout.maxTitleLength])
    }

    // MARK: The sheet

    func testTheSheetOpensLevelWithItsTab() {
        let frame = NoteTabLayout.sheetFrame(tabTop: 120, pageHeight: pageHeight, wanted: 500)
        XCTAssertEqual(frame.top, 120)
        XCTAssertEqual(frame.height, 500)
    }

    func testASheetThatWouldRunOffTheFootOfThePageIsMovedUpIt() {
        let frame = NoteTabLayout.sheetFrame(tabTop: 600, pageHeight: pageHeight, wanted: 500)
        XCTAssertEqual(frame.top + frame.height, pageHeight)
    }

    func testTheSheetIsNeverTallerThanThePageUnlessThePageIsTooShortToReadIn() {
        XCTAssertEqual(NoteTabLayout.sheetFrame(tabTop: 0, pageHeight: pageHeight, wanted: 2000).height, pageHeight)
        let slide = NoteTabLayout.sheetFrame(tabTop: 90, pageHeight: 300, wanted: 2000)
        XCTAssertEqual(slide.top, 0)
        XCTAssertEqual(slide.height, NoteTabLayout.minSheetHeight)
    }

    // MARK: Anchors

    func testAnAnchorIsKeptOnThePage() {
        XCTAssertEqual(NoteAnchor(page: 0, y: 1.4), NoteAnchor(page: 1, y: 1))
        XCTAssertEqual(NoteAnchor(page: 3, y: -0.2).y, 0)
    }
}
