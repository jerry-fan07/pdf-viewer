import PDFKit
import XCTest
@testable import ClaudePDF

@MainActor
final class PinnedNotesTests: XCTestCase {
    private var directory: URL!
    private var documentURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PinnedNotesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        documentURL = directory.appendingPathComponent("paper.pdf")
        XCTAssertTrue(PDFFixtures.makePaperDocument().write(to: documentURL))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeNotes() -> (PinnedNotes, PDFDocument) {
        let document = PDFDocument(url: documentURL)!
        let notes = PinnedNotes(store: PinnedNoteStore(directory: directory.appendingPathComponent("Notes")))
        notes.load(for: documentURL, document: document)
        return (notes, document)
    }

    private func card(quote: String? = nil, page: Int = 2, answer: String = "Because the highlight is the evidence.") -> QACard {
        var question = Question(text: "Why refuse approximate matches?")
        question.selectedText = quote
        question.selectedTextPage = quote == nil ? nil : page
        question.pageHint = page
        var card = QACard(question: question, providerName: "Mock")
        card.answer = answer
        card.finish()
        return card
    }

    private func markers(on page: PDFPage?) -> [PinnedNoteAnnotation] {
        page?.annotations.compactMap { $0 as? PinnedNoteAnnotation } ?? []
    }

    func testSavingPutsAMarkerOnThePageTheQuestionWasAbout() throws {
        let (notes, document) = makeNotes()
        let saved = try XCTUnwrap(notes.save(card: card(quote: "We deliberately refuse approximate matches.")))
        XCTAssertEqual(saved.page, 2)
        XCTAssertEqual(markers(on: document.page(at: 1)).map(\.noteID), [saved.id])
        XCTAssertTrue(markers(on: document.page(at: 0)).isEmpty)
    }

    func testTheMarkerIsLevelWithThePassage() throws {
        let (notes, document) = makeNotes()
        let quote = "We deliberately refuse approximate matches."
        let saved = try XCTUnwrap(notes.save(card: card(quote: quote)))
        let page = try XCTUnwrap(document.page(at: 1))
        let passage = try XCTUnwrap(document.findString(quote, withOptions: []).first { $0.pages.contains(page) })
        let marker = try XCTUnwrap(markers(on: page).first)
        XCTAssertNotNil(saved.y)
        XCTAssertEqual(marker.bounds.maxY, passage.bounds(for: page).maxY, accuracy: 12)
        // And the passage itself is highlighted with the note.
        let highlights = page.annotations.filter {
            $0.type == "Highlight" && $0.userName == PinnedNoteAnnotation.tag(saved.id)
        }
        XCTAssertFalse(highlights.isEmpty)
    }

    /// A selection a reader actually makes runs over the wrap — and comes back with
    /// the line break in it.
    func testAWrappedPassageIsHighlightedLineByLine() throws {
        let (notes, document) = makeNotes()
        let quote = "We locate each quotation on the page and highlight it, which converts\nan assertion into evidence the reader can see for themselves."
        let saved = try XCTUnwrap(notes.save(card: card(quote: quote)))
        let page = try XCTUnwrap(document.page(at: 1))
        let lines = Set(page.annotations
            .filter { $0.type == "Highlight" && $0.userName == PinnedNoteAnnotation.tag(saved.id) }
            .map { Int($0.bounds.minY.rounded()) })
        XCTAssertGreaterThanOrEqual(lines.count, 2)
    }

    func testSavingTheSameAnswerTwiceKeepsOneNote() {
        let (notes, document) = makeNotes()
        let answer = card()
        notes.save(card: answer)
        notes.save(card: answer)
        XCTAssertEqual(notes.notes.count, 1)
        XCTAssertEqual(markers(on: document.page(at: 1)).count, 1)
        XCTAssertNotNil(notes.note(forCard: answer.id))
    }

    func testMarkersOnOnePageDoNotOverlap() throws {
        let (notes, document) = makeNotes()
        notes.save(card: card())
        notes.save(card: card())
        let tops = markers(on: document.page(at: 1)).map(\.bounds.maxY).sorted()
        XCTAssertEqual(tops.count, 2)
        XCTAssertGreaterThanOrEqual(tops[1] - tops[0], PinnedNoteAnnotation.size.height)
    }

    func testNotesComeBackWithTheDocument() throws {
        let (first, _) = makeNotes()
        let saved = try XCTUnwrap(first.save(card: card(quote: "We deliberately refuse approximate matches.")))

        let (reopened, document) = makeNotes()
        XCTAssertEqual(reopened.notes, [saved])
        XCTAssertEqual(markers(on: document.page(at: 1)).map(\.noteID), [saved.id])
    }

    func testDeletingTakesTheNoteOffThePage() throws {
        let (notes, document) = makeNotes()
        let saved = try XCTUnwrap(notes.save(card: card(quote: "We deliberately refuse approximate matches.")))
        notes.delete(saved.id)
        XCTAssertTrue(notes.notes.isEmpty)
        let page = try XCTUnwrap(document.page(at: 1))
        XCTAssertTrue(page.annotations.filter { $0.userName == PinnedNoteAnnotation.tag(saved.id) }.isEmpty)
        // And it stays deleted.
        XCTAssertTrue(makeNotes().0.notes.isEmpty)
    }

    func testAnUnfinishedAnswerCannotBeSaved() {
        let (notes, _) = makeNotes()
        XCTAssertNil(notes.save(card: card(answer: "")))
    }

    func testTheOriginalFileIsNeverWritten() throws {
        let before = try FileManager.default.attributesOfItem(atPath: documentURL.path)
        let (notes, _) = makeNotes()
        notes.save(card: card(quote: "We deliberately refuse approximate matches."))
        let after = try FileManager.default.attributesOfItem(atPath: documentURL.path)
        XCTAssertEqual(before[.modificationDate] as? Date, after[.modificationDate] as? Date)
        XCTAssertEqual(before[.size] as? Int, after[.size] as? Int)
    }
}
