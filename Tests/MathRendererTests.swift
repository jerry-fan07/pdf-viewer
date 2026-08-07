import XCTest
@testable import ClaudePDF

/// Runs inside the app as its test host, so this also proves SwiftMath's font bundle
/// resolves from the built `.app` — the failure mode there is silent (every equation
/// falls back to raw source, nothing logs).
@MainActor
final class MathRendererTests: XCTestCase {

    private func render(_ latex: String, display: Bool = false) -> MathRenderer.Rendered? {
        MathRenderer.render(latex: latex, fontSize: 13, display: display, colorScheme: .light)
    }

    func testTypesetsCommonExpressions() throws {
        for latex in ["E = mc^2", "\\alpha_1 + \\beta^2", "\\frac{\\sqrt{\\pi}}{2}",
                      "\\int_0^\\infty e^{-x^2}\\,dx", "\\nabla^2 u", "\\sum_{n=1}^{N} \\frac{1}{n^2}"] {
            let rendered = try XCTUnwrap(render(latex), "failed to typeset \(latex)")
            XCTAssertGreaterThan(rendered.image.size.width, 0)
            XCTAssertGreaterThan(rendered.image.size.height, 0)
        }
    }

    func testDescentIsReportedForDeepGlyphs() throws {
        // A subscript hangs below the baseline; without a descent the inline image would
        // sit too high in the line.
        let deep = try XCTUnwrap(render("x_1"))
        XCTAssertGreaterThan(deep.descent, 0)
    }

    /// Unparseable TeX must report failure so `AnswerView` can fall back to showing the
    /// source. (SwiftMath is lenient about *malformed* but recognisable input — e.g. it
    /// will happily typeset `\frac{1}` with an empty denominator — so this only covers
    /// input it genuinely rejects.)
    func testUnparseableLatexFails() {
        XCTAssertNil(render("\\notacommand{x}"))
        XCTAssertNil(render("\\begin{aligned} x"))
        XCTAssertNil(render("{a"))
    }

    func testResultsAreCached() throws {
        let first = try XCTUnwrap(render("\\gamma^2 + \\delta"))
        let second = try XCTUnwrap(render("\\gamma^2 + \\delta"))
        XCTAssertTrue(first.image === second.image, "streaming re-renders every delta; caching is required")
    }

    // MARK: Normalizer

    func testEnvironmentsModelsEmitAreTypeset() throws {
        XCTAssertNotNil(render("\\begin{align} a &= b \\\\ c &= d \\end{align}", display: true))
        XCTAssertNotNil(render("\\begin{equation} x = y \\end{equation}", display: true))
        XCTAssertNotNil(render("\\begin{cases} 1 & x > 0 \\\\ 0 & x \\le 0 \\end{cases}", display: true))
    }

    func testDisplayOnlyCommandsAreDropped() throws {
        XCTAssertNotNil(render("x = y \\nonumber", display: true))
        XCTAssertNotNil(render("\\dfrac{1}{2}", display: true))
        XCTAssertEqual(LaTeXNormalizer.normalize("x = y \\label{eq:one}"), "x = y")
    }
}
