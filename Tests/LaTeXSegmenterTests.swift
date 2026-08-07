import XCTest
@testable import ClaudePDF

/// The segmenter is the part of LaTeX rendering that can be wrong *silently* — money
/// eaten as math, or a half-streamed `$$` flickering into an equation. Everything below
/// is a case that showed up while building it.
final class LaTeXSegmenterTests: XCTestCase {

    private func segments(_ input: String) -> [AnswerSegment] {
        LaTeXSegmenter.segments(in: input)
    }

    // MARK: Delimiter forms

    func testInlineParenDelimiters() {
        XCTAssertEqual(segments("Given \\(E = mc^2\\) here."),
                       [.text("Given "), .inlineMath("E = mc^2"), .text(" here.")])
    }

    func testInlineDollarDelimiters() {
        XCTAssertEqual(segments("Sum $\\sum_{i}^{n} i$ end"),
                       [.text("Sum "), .inlineMath("\\sum_{i}^{n} i"), .text(" end")])
    }

    func testDisplayDollarDelimiters() {
        XCTAssertEqual(segments("A\n\n$$E=mc^2$$\n\nB"),
                       [.text("A\n\n"), .displayMath("E=mc^2"), .text("\n\nB")])
    }

    func testDisplayBracketDelimiters() {
        XCTAssertEqual(segments("See \\[x^2\\] above"),
                       [.text("See "), .displayMath("x^2"), .text(" above")])
    }

    func testBareEnvironmentIsDisplayMath() {
        let input = "\\begin{aligned} a &= b \\\\ c &= d \\end{aligned}"
        XCTAssertEqual(segments(input), [.displayMath(input)])
    }

    func testUnknownEnvironmentIsNotMath() {
        let input = "\\begin{itemize} \\item one \\end{itemize}"
        XCTAssertEqual(segments(input), [.text(input)])
    }

    // MARK: Things that only look like math

    func testCurrencyPairStaysProse() {
        XCTAssertEqual(segments("The price is $5 and $6 today."),
                       [.text("The price is $5 and $6 today.")])
    }

    /// A rejected opener must not consume the real math that follows it.
    func testCurrencyBeforeRealMath() {
        XCTAssertEqual(segments("It costs $5 per unit, so $x = 5n$ total."),
                       [.text("It costs $5 per unit, so "), .inlineMath("x = 5n"), .text(" total.")])
    }

    func testSpacedDollarsAreNotMath() {
        XCTAssertEqual(segments("a $ b $ c"), [.text("a $ b $ c")])
    }

    func testEscapedDollarStaysProse() {
        XCTAssertEqual(segments("Escaped \\$100 stays."), [.text("Escaped \\$100 stays.")])
    }

    func testCodeSpanIsOpaque() {
        XCTAssertEqual(segments("Use `$x$` literally."), [.text("Use `$x$` literally.")])
    }

    func testInlineMathCannotCrossABlankLine() {
        XCTAssertEqual(segments("$a\n\nb$"), [.text("$a\n\nb$")])
    }

    // MARK: Streaming

    func testUnclosedDelimitersStayProse() {
        XCTAssertEqual(segments("Half open $$x + y"), [.text("Half open $$x + y")])
        XCTAssertEqual(segments("Half open \\(x + y"), [.text("Half open \\(x + y")])
        XCTAssertEqual(segments("Half open \\begin{aligned} a &= b"),
                       [.text("Half open \\begin{aligned} a &= b")])
    }

    /// Answers arrive a few characters at a time. No prefix may produce a math run that
    /// isn't in the finished answer — that is what makes equations flicker mid-stream.
    func testNoPrefixInventsMath() {
        let full = "Text $$\\frac{1}{2}$$ and \\(x^2\\) end, costing $5."
        for length in 0...full.count {
            for segment in segments(String(full.prefix(length))) {
                switch segment {
                case .inlineMath(let math), .displayMath(let math):
                    XCTAssertTrue(full.contains(math), "prefix of length \(length) invented “\(math)”")
                case .text:
                    break
                }
            }
        }
    }
}
