import XCTest
@testable import ClaudePDF

/// The last layer of the answer pipeline, and the one that has to undo the cutting the
/// three above it did. `LaTeXSegmenter` splits prose at every `$…$` and `AnswerQuotes`
/// splits it again at every quotation; a `**` that opens before one of those cuts and
/// closes after it is still one span, and every test here is a shape where parsing the
/// fragments separately would leave the delimiters on screen as text.
final class InlineRunsTests: XCTestCase {

    private func pieces(_ source: String) -> [InlinePiece] {
        InlineRuns.pieces(LaTeXSegmenter.segments(in: source))
    }

    /// Flattens the pieces back to plain text, so a test can assert on what is *shown*
    /// without restating how prose and math interleave.
    private func plain(_ pieces: [InlinePiece]) -> String {
        pieces.map { piece in
            switch piece {
            case .text(let attributed): return String(attributed.characters)
            case .inlineMath(let latex): return "<\(latex)>"
            case .displayMath(let latex): return "<<\(latex)>>"
            }
        }.joined()
    }

    /// The presentation intent covering the first occurrence of `needle`.
    private func intent(around needle: String, in pieces: [InlinePiece]) -> InlinePresentationIntent? {
        for case .text(let attributed) in pieces {
            guard let range = attributed.range(of: needle) else { continue }
            return attributed[range].runs.first?.inlinePresentationIntent
        }
        return nil
    }

    /// Every distinct passage linked back to the document, in order.
    private func links(_ pieces: [InlinePiece]) -> [String] {
        var out: [String] = []
        for case .text(let attributed) in pieces {
            for run in attributed.runs {
                guard let quote = run.link.flatMap(SourceLink.quote(from:)) else { continue }
                if out.last != quote { out.append(quote) }   // one span, several styled runs
            }
        }
        return out
    }

    // MARK: Emphasis across an equation — the bug that started this

    func testBoldSurvivesAnEquationInsideIt() {
        let out = pieces("**Any invertible $Q$ gives a rival factorization** (p. 3)")

        XCTAssertFalse(plain(out).contains("*"), "the asterisks were drawn as text: \(plain(out))")
        XCTAssertEqual(
            intent(around: "Any invertible", in: out), .stronglyEmphasized,
            "the half before the equation lost its bold"
        )
        XCTAssertEqual(
            intent(around: "gives a rival", in: out), .stronglyEmphasized,
            "the half after the equation lost its bold"
        )
        XCTAssertNil(intent(around: "(p. 3)", in: out), "the bold ran past its closer")
    }

    func testItalicSurvivesAnEquationInsideIt() {
        let out = pieces("A factorization *is* a choice of the $(r-1)$-simplex it encloses")

        XCTAssertFalse(plain(out).contains("*"))
        XCTAssertEqual(intent(around: "is", in: out), .emphasized)
    }

    func testLinkTextSurvivesAnEquationInsideIt() {
        let out = pieces("See [the bound on $B$ here](https://example.com/paper) for the proof.")

        XCTAssertFalse(plain(out).contains("]("), "the link syntax was drawn as text: \(plain(out))")
        XCTAssertFalse(plain(out).contains("https://"), "the URL was drawn as text")

        var found: [URL] = []
        for case .text(let attributed) in out {
            for run in attributed.runs {
                if let link = run.link, found.last != link { found.append(link) }
            }
        }
        XCTAssertEqual(found, [URL(string: "https://example.com/paper")!])
    }

    /// The list item from the screenshot, through the parser that actually produces it.
    func testTheNumberedListItemThatReportedThis() {
        let blocks = MarkdownBlocks.parse(
            "1. **Any invertible $Q$ gives a rival factorization** (p. 3): so uniqueness\n"
            + "2. **Those constraints are geometric** (p. 4): normalizing helps"
        )
        guard case .list(let items)? = blocks.first, items.count == 2 else {
            return XCTFail("expected a two-item list, got \(blocks)")
        }

        // The second item never broke — it has no math inside its bold — so it is the
        // control: both items must now come out the same way.
        for item in items {
            let out = InlineRuns.pieces(item.content)
            XCTAssertFalse(plain(out).contains("*"), "asterisks left in: \(plain(out))")
        }
        XCTAssertEqual(
            intent(around: "Any invertible", in: InlineRuns.pieces(items[0].content)),
            intent(around: "Those constraints", in: InlineRuns.pieces(items[1].content))
        )
    }

    // MARK: Emphasis across a quotation

    func testBoldSpanningAQuotationStaysOneSpan() {
        let out = pieces("**the paper says \"every data point lies inside\" outright**")

        XCTAssertFalse(plain(out).contains("*"), "the asterisks were drawn as text: \(plain(out))")
        XCTAssertEqual(intent(around: "the paper says", in: out), .stronglyEmphasized)
        XCTAssertEqual(
            intent(around: "every data point", in: out)?.contains(.stronglyEmphasized), true,
            "the quotation itself dropped out of the bold"
        )
        XCTAssertEqual(intent(around: "outright", in: out), .stronglyEmphasized)
        XCTAssertEqual(links(out), ["every data point lies inside"])
    }

    // MARK: What the link goes looking for

    /// Before, the opening and closing quotation marks landed either side of the equation,
    /// in different segments, so `AnswerQuotes` never saw a pair and the passage was never
    /// a link at all.
    func testQuotationContainingMathIsLinkedWithAnElision() {
        let out = pieces("He writes \"every data point lies inside the $(r-1)$-simplex\" here.")

        // The equation has no characters on the page for a placeholder to match, so it is
        // spelt as an elision — which `SourceLocator` already relaxes around, hunting each
        // side on its own rather than failing on the whole.
        let needle = "every data point lies inside the...-simplex"
        XCTAssertEqual(links(out), [needle])
        let variants = SourceLocator.variants(of: needle)
        XCTAssertTrue(
            variants.contains { !$0.contains("...") && $0.count >= SourceLocator.minimumMatchLength },
            "no form long enough to hunt survived the elision: \(variants)"
        )
    }

    func testQuotationDropsItsMarkdownFromWhatItHunts() {
        let out = pieces("He said \"the **whole** point of the thing\" once.")

        // Searching the page for asterisks it does not contain found nothing, every time.
        XCTAssertEqual(links(out), ["the whole point of the thing"])
    }

    func testQuotationInsideACodeSpanIsNotLinked() {
        let out = pieces("Write `label = \"a string of some length\"` in the header.")

        XCTAssertEqual(links(out), [], "a quotation mark inside code belongs to the code")
        XCTAssertEqual(intent(around: "label = ", in: out)?.contains(.code), true)
    }

    func testOrdinaryQuotationIsStillLinked() {
        let out = pieces("The paper says \"volume ratios are preserved\" on page 5.")

        XCTAssertEqual(links(out), ["volume ratios are preserved"])
    }

    // MARK: Splicing

    func testMathIsSplicedBackWhereItStood() {
        let out = pieces("Just prose about $x = 5n$ and more.")

        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[1], .inlineMath("x = 5n"))
        XCTAssertEqual(plain(out), "Just prose about <x = 5n> and more.")
    }

    /// A placeholder the *model* emitted must not be mistaken for one of ours, or every
    /// equation after it is spliced one position too early.
    func testAStrayObjectReplacementCharacterIsDropped() {
        let out = pieces("a \u{FFFC} b $x$ c")

        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[1], .inlineMath("x"))
        XCTAssertEqual(plain(out), "a  b <x> c")
    }

    func testDisplayMathReachingAnInlineContextKeepsItsSource() {
        let out = InlineRuns.pieces([.text("before "), .displayMath("x^2"), .text(" after")])

        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[1], .displayMath("x^2"))
        XCTAssertEqual(plain(out), "before <<x^2>> after")
    }

    func testEmptyRunDrawsNothing() {
        XCTAssertEqual(InlineRuns.pieces([]), [])
        XCTAssertEqual(InlineRuns.pieces([.text("")]), [])
    }
}
