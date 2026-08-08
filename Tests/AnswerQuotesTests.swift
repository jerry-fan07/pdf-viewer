import XCTest
@testable import ClaudePDF

/// What counts as a quotation in an answer. Over-eager detection is the expensive
/// failure here: every false positive is an underlined run that jumps the reader
/// somewhere arbitrary, or worse, tells them the document doesn't say something it does.
final class AnswerQuotesTests: XCTestCase {

    // MARK: Detection

    func testStraightAndCurlyQuotesAreBothFound() {
        XCTAssertEqual(
            AnswerQuotes.quotes(in: "The paper says \"attach the document once per reader\" up front."),
            ["attach the document once per reader"]
        )
        XCTAssertEqual(
            AnswerQuotes.quotes(in: "The paper says \u{201C}attach the document once\u{201D} up front."),
            ["attach the document once"]
        )
    }

    func testSeveralQuotesInOneAnswer() {
        let answer = "It calls this \"a stable prefix match\" and later \"the cache breakpoint sits above\"."
        XCTAssertEqual(
            AnswerQuotes.quotes(in: answer),
            ["a stable prefix match", "the cache breakpoint sits above"]
        )
    }

    /// The streaming rule, inherited from the math layer: an unclosed delimiter is
    /// never a delimiter. The whole answer re-parses on every delta, so a half-arrived
    /// quotation must stay prose rather than flash a link and then re-flow.
    func testUnclosedQuoteStaysProse() {
        let partial = "The paper says \"attach the document once per"
        XCTAssertEqual(AnswerQuotes.quotes(in: partial), [])
        XCTAssertEqual(AnswerQuotes.split(partial), [AnswerChunk(text: partial, quote: nil)])
    }

    func testApostrophesAreNeverQuoteMarks() {
        let answer = "The model's own summary of the author's argument isn't a quotation."
        XCTAssertEqual(AnswerQuotes.quotes(in: answer), [])
    }

    func testCurlyApostrophesDoNotOpenAQuote() {
        let answer = "The author\u{2019}s claim about the reader\u{2019}s attention span is unsupported."
        XCTAssertEqual(AnswerQuotes.quotes(in: answer), [])
    }

    func testAQuotedTermIsTooShortToLocate() {
        // "cache" appears on every page; highlighting one arbitrarily is worse than not linking.
        XCTAssertEqual(AnswerQuotes.quotes(in: "It calls this the \"cache\" model."), [])
    }

    func testAQuoteLongerThanAParagraphIsRejected() {
        let long = String(repeating: "word ", count: 120)
        XCTAssertEqual(AnswerQuotes.quotes(in: "It says \"\(long)\" somewhere."), [])
    }

    func testQuotesInsideCodeSpansAreOpaque() {
        let answer = "Pass `--output-format \"stream-json\" --verbose` to the CLI."
        XCTAssertEqual(AnswerQuotes.quotes(in: answer), [])
    }

    func testAQuoteAfterACodeSpanIsStillFound() {
        let answer = "Pass `--resume \"sid\"`, because it says \"the primed session is never mutated\"."
        XCTAssertEqual(AnswerQuotes.quotes(in: answer), ["the primed session is never mutated"])
    }

    func testAMarkOnTheOtherSideOfABlankLineIsNotACloser() {
        let answer = "It says \"this is unfinished\n\nand this paragraph quotes something else\" here."
        XCTAssertEqual(AnswerQuotes.quotes(in: answer), [])
    }

    func testARejectedOpenerDoesNotSwallowARealQuoteLater() {
        // The first mark is too short to pair usefully; the sentence still has a real quote.
        let answer = "The \"cache\" idea rests on \"a byte-identical prefix across questions\"."
        XCTAssertEqual(AnswerQuotes.quotes(in: answer), ["a byte-identical prefix across questions"])
    }

    // MARK: Splitting

    func testSplitReproducesTheInputExactly() {
        let samples = [
            "Plain prose with no quotation at all.",
            "It says \"the cache is a prefix match\" and then stops.",
            "\u{201C}an opening quotation carries the sentence\u{201D} — and prose follows.",
            "Two: \"the first quoted passage here\" then \"the second quoted passage here\".",
            "Unclosed \"quotation still streaming in",
            "`code \"span\"` and then \"a real quotation of some length\".",
            "",
        ]
        for sample in samples {
            let rebuilt = AnswerQuotes.split(sample).map(\.text).joined()
            XCTAssertEqual(rebuilt, sample, "split must be lossless for: \(sample)")
        }
    }

    func testSplitKeepsTheMarksOnTheQuotedChunk() {
        let chunks = AnswerQuotes.split("It says \"the cache is a prefix match\" plainly.")
        XCTAssertEqual(chunks, [
            AnswerChunk(text: "It says ", quote: nil),
            AnswerChunk(text: "\"the cache is a prefix match\"", quote: "the cache is a prefix match"),
            AnswerChunk(text: " plainly.", quote: nil),
        ])
    }

    // MARK: Chip labels

    func testChipLabelShortensAtAWordBoundary() {
        let label = AnswerQuotes.chipLabel(for: "the cache breakpoint sits above everything volatile")
        XCTAssertTrue(label.hasPrefix("\u{201C}the cache breakpoint sits"), label)
        XCTAssertTrue(label.hasSuffix("\u{2026}\u{201D}"), label)
        XCTAssertLessThanOrEqual(label.count, 36)
    }

    func testShortQuoteIsShownWhole() {
        XCTAssertEqual(
            AnswerQuotes.chipLabel(for: "a stable prefix match"),
            "\u{201C}a stable prefix match\u{201D}"
        )
    }

    func testChipLabelFlattensLineBreaks() {
        XCTAssertFalse(AnswerQuotes.chipLabel(for: "one line\nand another").contains("\n"))
    }

    // MARK: Link round-trip

    func testLinkCarriesTheQuoteThroughPercentEncoding() {
        let awkward = "100% of a+b & \"c\" — ünïcode, é, and a / slash?"
        let url = SourceLink.url(quote: awkward)
        XCTAssertNotNil(url)
        XCTAssertEqual(SourceLink.quote(from: url!), awkward)
    }

    func testForeignLinksArePassedThrough() {
        XCTAssertNil(SourceLink.quote(from: URL(string: "https://example.com?q=hello")!))
        XCTAssertNil(SourceLink.quote(from: URL(string: "mailto:someone@example.com")!))
    }
}
