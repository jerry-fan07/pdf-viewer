import PDFKit
import XCTest
@testable import ClaudePDF

/// The half of answer-to-source highlighting that can be wrong silently: a quote the
/// model copied out of the document has to come back as a range on the right page,
/// through every way PDF extraction differs from what a model writes.
final class SourceLocatorTests: XCTestCase {

    private func locate(
        _ quote: String, in document: PDFDocument, nearPage: Int? = nil
    ) -> SourceMatch? {
        SourceLocator.locate(quote, in: document, index: PDFTextIndex(), nearPage: nearPage)
    }

    /// Normalised text of what a match actually selected, for asserting the range
    /// landed on the passage rather than merely on the page.
    private func selected(_ match: SourceMatch?) -> String {
        TextNormalizer.normalize(match?.selection.string ?? "").text
    }

    // MARK: The basic contract

    func testFindsAQuoteAndReportsItsPage() {
        let document = PDFFixtures.makeTextDocument(pages: [
            ["Nothing of interest lives on this page at all."],
            ["The cache is a prefix match, so a stable prefix", "is the whole design."],
        ])

        let match = locate("The cache is a prefix match", in: document)

        XCTAssertEqual(match?.pageNumber, 2)
        XCTAssertFalse(match?.isPartial ?? true)
        XCTAssertEqual(selected(match), "the cache is a prefix match")
    }

    func testMatchIsCaseInsensitive() {
        let document = PDFFixtures.makeTextDocument(pages: [["Prompt caching is a prefix match."]])
        XCTAssertEqual(locate("PROMPT CACHING IS A PREFIX", in: document)?.pageNumber, 1)
    }

    func testQuoteSpanningALineBreakStillMatches() {
        // The single most common miss: the model quotes a sentence the page wrapped.
        let document = PDFFixtures.makeTextDocument(pages: [
            ["Every question is an independent conversation", "that shares the document as a cache."],
        ])

        let match = locate("independent conversation that shares the document", in: document)

        XCTAssertEqual(match?.pageNumber, 1)
        XCTAssertEqual(selected(match), "independent conversation that shares the document")
    }

    func testHyphenationAcrossALineBreakIsRejoined() {
        let document = PDFFixtures.makeTextDocument(pages: [
            ["The protocol is deliberately inter-", "national in scope."],
        ])
        XCTAssertEqual(locate("deliberately international in scope", in: document)?.pageNumber, 1)
    }

    func testHyphenInsideALineIsKept() {
        let document = PDFFixtures.makeTextDocument(pages: [["A well-known result about caching."]])
        XCTAssertNotNil(locate("a well-known result about caching", in: document))
    }

    func testSmartPunctuationMatchesStraightPunctuation() {
        let document = PDFFixtures.makeTextDocument(pages: [
            ["The reader's own copy said \"attach once\" and nothing more."],
        ])
        // What a model writes back: curly apostrophe, curly quotes, an em dash.
        XCTAssertNotNil(locate("the reader\u{2019}s own copy said \u{201C}attach once\u{201D}", in: document))
    }

    // MARK: Which page wins

    func testPageHintWinsWhenTheSameSentenceAppearsTwice() {
        let sentence = "The document is attached once per reader."
        let document = PDFFixtures.makeTextDocument(pages: [[sentence], ["Filler."], [sentence]])

        XCTAssertEqual(locate(sentence, in: document, nearPage: 3)?.pageNumber, 3)
        XCTAssertEqual(locate(sentence, in: document, nearPage: 1)?.pageNumber, 1)
        // No hint: first occurrence, deterministically.
        XCTAssertEqual(locate(sentence, in: document)?.pageNumber, 1)
    }

    func testHintedPageIsSearchedButTheRestOfTheDocumentStillIs() {
        let document = PDFFixtures.makeTextDocument(pages: [
            ["Filler on the first page."],
            ["Filler on the second page."],
            ["The passage the answer actually quoted lives here."],
        ])
        XCTAssertEqual(locate("the passage the answer actually quoted", in: document, nearPage: 1)?.pageNumber, 3)
    }

    func testCompleteMatchAnywhereBeatsAPartialMatchOnTheHintedPage() {
        let document = PDFFixtures.makeTextDocument(pages: [
            ["Caching is a prefix match on something else entirely."],
            ["Caching is a prefix match and the breakpoint sits after it."],
        ])

        let match = locate(
            "Caching is a prefix match and the breakpoint", in: document, nearPage: 1
        )

        XCTAssertEqual(match?.pageNumber, 2, "the shortened form must not win on page 1 first")
        XCTAssertFalse(match?.isPartial ?? true)
    }

    // MARK: Relaxing the quote

    func testTrailingWordsThatArentOnThePageAreDropped() {
        let document = PDFFixtures.makeTextDocument(pages: [
            ["The breakpoint sits above everything volatile."],
        ])

        // A model tacking its own words onto the end of a quotation.
        let match = locate(
            "The breakpoint sits above everything volatile in the request", in: document
        )

        XCTAssertEqual(match?.pageNumber, 1)
        XCTAssertTrue(match?.isPartial ?? false)
        XCTAssertEqual(selected(match), "the breakpoint sits above everything volatile")
    }

    func testElidedQuoteMatchesItsLongestSegment() {
        let document = PDFFixtures.makeTextDocument(pages: [
            ["The system prompt is frozen, and one changed byte moves the whole prefix."],
        ])

        let match = locate("The system prompt is frozen … moves the whole prefix", in: document)

        XCTAssertEqual(match?.pageNumber, 1)
        XCTAssertTrue(match?.isPartial ?? false)
    }

    func testTypedOutEllipsisWorksTheSameWay() {
        let document = PDFFixtures.makeTextDocument(pages: [
            ["The system prompt is frozen, and one changed byte moves the whole prefix."],
        ])
        XCTAssertEqual(
            locate("The system prompt is frozen ... moves the whole prefix", in: document)?.pageNumber,
            1
        )
    }

    // MARK: Refusing to guess

    func testAParaphraseIsNotFound() {
        let document = PDFFixtures.makeTextDocument(pages: [
            ["Every question is an independent conversation over a cached document."],
        ])
        XCTAssertNil(
            locate("each query runs as its own separate exchange", in: document),
            "a fuzzy match here would highlight evidence the document does not contain"
        )
    }

    func testTooShortAQuoteIsRefused() {
        let document = PDFFixtures.makeTextDocument(pages: [["The cache is a prefix match."]])
        XCTAssertNil(locate("cache", in: document))
        XCTAssertNil(locate("the cache", in: document))
    }

    func testEmptyDocumentAndEmptyQuoteAreHandled() {
        let document = PDFFixtures.makeTextDocument(pages: [["Some text on a page."]])
        XCTAssertNil(locate("", in: document))
        XCTAssertNil(locate("   \n  ", in: document))
    }

    func testOutOfRangePageHintDoesNotCrashOrBlockTheSearch() {
        let document = PDFFixtures.makeTextDocument(pages: [["The passage lives on page one."]])
        XCTAssertEqual(locate("the passage lives on page one", in: document, nearPage: 99)?.pageNumber, 1)
        XCTAssertEqual(locate("the passage lives on page one", in: document, nearPage: 0)?.pageNumber, 1)
    }

    // MARK: The index

    func testIndexIsReusedAcrossLookups() {
        let document = PDFFixtures.makeTextDocument(pages: [
            ["First sentence about caching prefixes."],
            ["Second sentence about streaming deltas."],
        ])
        let index = PDFTextIndex()

        let first = SourceLocator.locate("first sentence about caching", in: document, index: index)
        let second = SourceLocator.locate("second sentence about streaming", in: document, index: index)

        XCTAssertEqual(first?.pageNumber, 1)
        XCTAssertEqual(second?.pageNumber, 2)
    }

    func testPageOrderPutsTheHintAndItsNeighboursFirstAndCoversEveryPage() {
        let order = SourceLocator.pageOrder(pageCount: 8, hint: 5)

        XCTAssertEqual(Array(order.prefix(5)), [5, 6, 4, 7, 3])
        XCTAssertEqual(order.sorted(), Array(1...8), "every page has to be reachable")
        XCTAssertEqual(order.count, 8, "and none of them twice")
    }
}

// MARK: - Normalisation

final class TextNormalizerTests: XCTestCase {

    private func normalized(_ source: String) -> String {
        TextNormalizer.normalize(source).text
    }

    func testWhitespaceRunsCollapseAndEdgesAreTrimmed() {
        XCTAssertEqual(normalized("  the   cache \n\n is\ta prefix  "), "the cache is a prefix")
    }

    func testLigaturesAndSmartPunctuationFoldOntoOneSpelling() {
        XCTAssertEqual(normalized("the \u{FB01}rst \u{201C}pre\u{FB02}ight\u{201D} check"),
                       "the first \"preflight\" check")
        XCTAssertEqual(normalized("caching \u{2014} a pre\u{FB03}x \u{2013} match"),
                       "caching - a preffix - match")
    }

    func testSoftHyphensVanishAndLineHyphensRejoin() {
        XCTAssertEqual(normalized("inter\u{00AD}national"), "international")
        XCTAssertEqual(normalized("inter-\nnational"), "international")
        XCTAssertEqual(normalized("well-known"), "well-known")
        XCTAssertEqual(normalized("dash - alone"), "dash - alone")
    }

    /// The map is the load-bearing part: a hit in normalised space has to come back
    /// as a range on the *original* string, past characters that changed length.
    func testSourceRangeMapsBackThroughFoldedCharacters() {
        let source = "The \u{FB01}rst\nrule: \u{201C}cache the pre\u{FB01}x\u{201D}"
        let result = TextNormalizer.normalize(source)

        let needle = "cache the prefix"
        let start = result.text.distance(from: result.text.startIndex,
                                         to: result.text.range(of: needle)!.lowerBound)
        let range = result.sourceRange(from: start, to: start + needle.count)

        let substring = (source as NSString).substring(with: range!)
        XCTAssertEqual(substring, "cache the pre\u{FB01}x")
    }

    func testSourceRangeRejectsNonsense() {
        let result = TextNormalizer.normalize("short text")
        XCTAssertNil(result.sourceRange(from: 0, to: 0))
        XCTAssertNil(result.sourceRange(from: 3, to: 2))
        XCTAssertNil(result.sourceRange(from: 0, to: 999))
    }

    func testEmptySourceIsSafe() {
        XCTAssertEqual(normalized(""), "")
        XCTAssertEqual(normalized("   \n  "), "")
        XCTAssertNil(TextNormalizer.normalize("").sourceRange(from: 0, to: 1))
    }
}
