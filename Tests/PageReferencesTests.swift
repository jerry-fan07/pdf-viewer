import XCTest
@testable import ClaudePDF

/// What counts as a page reference in an answer, and what a card therefore says it
/// cites. The expensive failure is the same one `AnswerQuotesTests` guards against
/// from the other side: a false positive is a bar in the histogram and a chip under
/// the answer that send the reader to a page nobody mentioned.
final class PageReferencesTests: XCTestCase {

    // MARK: Detection

    func testEveryMarkerSpelling() {
        XCTAssertEqual(PageReferences.pages(in: "See page 12 for the proof."), [12])
        XCTAssertEqual(PageReferences.pages(in: "See p. 12 for the proof."), [12])
        XCTAssertEqual(PageReferences.pages(in: "Defined on Page 4."), [4])
        XCTAssertEqual(PageReferences.pages(in: "(p.7)"), [7])
        XCTAssertEqual(PageReferences.pages(in: "Both pages 3 and 9 say so."), [3, 9])
        XCTAssertEqual(PageReferences.pages(in: "See pp. 3, 5, 8."), [3, 5, 8])
    }

    func testAscendingAndDeduplicated() {
        let answer = "It appears on page 9, again on page 2, and once more on page 9."
        XCTAssertEqual(PageReferences.pages(in: answer), [2, 9])
    }

    func testShortRangesExpand() {
        XCTAssertEqual(PageReferences.pages(in: "See pp. 3\u{2013}5."), [3, 4, 5])
        XCTAssertEqual(PageReferences.pages(in: "See pp. 3-5."), [3, 4, 5])
        XCTAssertEqual(PageReferences.pages(in: "See pages 3 to 5."), [3, 4, 5])
    }

    /// "The whole argument (pp. 1–45)" is a gesture at the document, not a citation of
    /// forty-five pages; expanded, it would ink every bar in the strip.
    func testLongRangeKeepsOnlyItsEndpoints() {
        XCTAssertEqual(PageReferences.pages(in: "The whole argument (pp. 1\u{2013}45)."), [1, 45])
        let span = PageReferences.maximumRangeSpan
        XCTAssertEqual(
            PageReferences.pages(in: "See pp. 1\u{2013}\(1 + span)."),
            Array(1...(1 + span))
        )
        XCTAssertEqual(
            PageReferences.pages(in: "See pp. 1\u{2013}\(2 + span)."),
            [1, 2 + span]
        )
    }

    func testMarkerAndNumberSurviveALineWrap() {
        XCTAssertEqual(PageReferences.pages(in: "as shown on page\n12 of the paper"), [12])
    }

    // MARK: Rejection

    /// The word-boundary rule. Both of these end in "p." and neither is a page.
    func testAbbreviationsEndingInPAreNotPages() {
        XCTAssertEqual(PageReferences.pages(in: "See app. 4 of the standard."), [])
        XCTAssertEqual(PageReferences.pages(in: "See chap. 4 of the standard."), [])
    }

    func testAMarkerWithoutANumberIsNotAReference() {
        XCTAssertEqual(PageReferences.pages(in: "It runs to 3 pages."), [])
        XCTAssertEqual(PageReferences.pages(in: "The page is blank."), [])
        XCTAssertEqual(PageReferences.pages(in: "A 12-page proof follows."), [])
        XCTAssertEqual(PageReferences.pages(in: "The PageRank 3 algorithm."), [])
    }

    func testNumberOnTheOtherSideOfAParagraphBreakIsNotThisMarkersNumber() {
        XCTAssertEqual(PageReferences.pages(in: "turn the page\n\n12 of them failed"), [])
    }

    /// The sentence carrying on past a single page. A writer naming several pages uses
    /// the plural, so a comma after the singular is prose.
    func testASingularMarkerTakesOneNumberOnly() {
        XCTAssertEqual(
            PageReferences.pages(in: "See page 3, 12 of the subjects dropped out."), [3]
        )
        XCTAssertEqual(PageReferences.pages(in: "On page 5, 30% of the trials failed."), [5])
        XCTAssertEqual(PageReferences.pages(in: "See p. 3 and 12 others agreed."), [3])
        // The plural still takes its list.
        XCTAssertEqual(PageReferences.pages(in: "See pages 3, 12."), [3, 12])
    }

    /// A spaced dash is a pause. Expanded as a range it would ink ten bars for a
    /// sentence that named one page.
    func testASpacedDashIsNotARange() {
        XCTAssertEqual(
            PageReferences.pages(in: "See page 3 \u{2014} 12 trials were excluded."), [3]
        )
        XCTAssertEqual(PageReferences.pages(in: "See pp. 3 - 5 of the appendix."), [3])
    }

    func testOrdinalsAndOversizedNumbersAreNotPages() {
        XCTAssertEqual(PageReferences.pages(in: "the page 12th of the run"), [])
        XCTAssertEqual(PageReferences.pages(in: "page 1234567"), [])
    }

    /// Code is opaque here for the same reason it is to `AnswerQuotes`: a `p. 3` inside
    /// backticks is part of the code, and a fenced block is not prose at all.
    func testCodeIsOpaque() {
        // Each snippet would parse as a reference on its own — that is the point.
        XCTAssertEqual(PageReferences.pages(in: "Call `render(pages 3)` first."), [])
        XCTAssertEqual(
            PageReferences.pages(in: "Like this:\n```swift\nrender(pages 3, 4)\n```\nand see page 8."),
            [8]
        )
    }

    // MARK: What a card reports

    /// The bug this exists for: the Claude Code and DeepSeek paths declare
    /// `supportsCitations: false` and are asked in the prompt to name pages inline, so
    /// a card with no citations at all still has pages to show.
    func testCardWithNoCitationsStillReportsThePagesItsProseNames() {
        let card = finishedCard(answer: "The bound is stated on page 4 and proved on p. 9.")
        XCTAssertEqual(card.citedPages(inDocumentOf: 20), [4, 9])
        XCTAssertEqual(card.prosePages(inDocumentOf: 20), [4, 9])
    }

    func testCitationsAndProseMergeWithoutDuplicating() {
        var card = finishedCard(answer: "Stated on page 4, proved on page 9.")
        card.citations = [Citation(page: 4, citedText: "the bound")]
        XCTAssertEqual(card.citedPages(inDocumentOf: 20), [4, 9])
        // p. 4 already has a citation chip; the source line must not print it twice.
        XCTAssertEqual(card.prosePages(inDocumentOf: 20), [9])
    }

    /// Dropped, not clamped: page 40 is not a better answer than none.
    func testPagesOutsideTheDocumentAreDropped() {
        let card = finishedCard(answer: "See page 4 and page 300.")
        XCTAssertEqual(card.citedPages(inDocumentOf: 40), [4])
        // Nothing is filtered before the document has finished loading.
        XCTAssertEqual(card.citedPages(inDocumentOf: 0), [4, 300])
    }

    /// Mid-stream, "page 1" is a prefix of "page 12", and a chip would point at the
    /// wrong page for as long as the next token takes to arrive — so a half-arrived
    /// answer names no pages until `finish()`.
    func testAStreamingAnswerNamesNoPagesUntilItFinishes() {
        var card = QACard(question: Question(text: "why?"))
        card.answer = "The bound is stated on page 1"
        card.citations = [Citation(page: 2, citedText: "cited live")]
        XCTAssertTrue(card.isStreaming)
        XCTAssertEqual(card.prosePages(inDocumentOf: 20), [])
        // Citations still stream live on the path that has them.
        XCTAssertEqual(card.citedPages(inDocumentOf: 20), [2])

        card.answer += "2 and proved on page 9."
        card.finish()
        XCTAssertEqual(card.prosePages(inDocumentOf: 20), [9, 12])
    }

    /// A restored card is parsed on the way in, which is what gives a transcript
    /// written before any of this existed its pages back.
    func testARestoredCardNamesItsPages() {
        let stored = StoredCard(
            id: UUID(), askedAt: Date(), questionText: "why?",
            selectedText: nil, selectedTextPage: nil,
            regionPage: nil, regionThumbnailPNG: nil,
            answer: "Stated on page 4, proved on p. 9.",
            citations: [], notices: [],
            providerName: "Claude (subscription)", modelName: nil,
            inputTokens: nil, cacheReadTokens: nil, cacheWriteTokens: nil,
            outputTokens: nil, costUSD: nil, error: nil
        )
        XCTAssertEqual(QACard(stored: stored).citedPages(inDocumentOf: 20), [4, 9])
    }

    private func finishedCard(answer: String) -> QACard {
        var card = QACard(question: Question(text: "why?"))
        card.answer = answer
        card.finish()
        return card
    }
}
