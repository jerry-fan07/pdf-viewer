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

    /// Each of these is a command SwiftMath rejects outright. Because it fails an equation
    /// *whole*, a single missing alias turns a display block into a wall of raw TeX — which
    /// is exactly how `\operatorname` was found.
    func testCommandsSwiftMathRejectsAreAliased() {
        for latex in ["\\operatorname{vol}(x)", "\\operatorname*{argmin}_x f",
                      "\\boldsymbol{x} = \\boldsymbol{A}\\boldsymbol{s}", "\\pmb{x}",
                      "\\lVert x \\rVert_2", "\\lvert x \\rvert", "\\mathscr{S}",
                      "\\argmin_x f(x)", "\\argmax_x f(x)", "a \\dots b", "a \\dotsc b",
                      "\\sum_{\\substack{i<j}} a", "\\mathop{\\mathrm{vol}}(x)",
                      "\\bigl( \\frac{x}{y} \\bigr)", "\\Biggl( x \\Biggr)",
                      "a \\stackrel{\\Delta}{=} b", "a \\overset{d}{=} b",
                      "a \\xrightarrow{f} b", "a \\hspace{1em} b", "a \\phantom{xx} b"] {
            XCTAssertNotNil(render(latex, display: true), "failed to typeset \(latex)")
        }
    }

    /// The alias pass has to respect TeX's own rule that a command name ends at the first
    /// non-letter. A plain textual swap of `\big` would turn `\bigcup` into a stray `cup`.
    func testAliasesDoNotEatLongerCommandNames() throws {
        XCTAssertEqual(LaTeXNormalizer.normalize("\\bigcup_i A_i \\bigl( x \\bigr)"), "\\bigcup_i A_i ( x )")
        XCTAssertNotNil(render("\\bigcup_{i} A_i", display: true))
        XCTAssertNotNil(render("\\bigoplus_i V_i", display: true))
    }

    /// SwiftMath has no notion of `%`: it does not error on a comment, it typesets the prose
    /// after it as italic math, which is worse than failing.
    func testCommentsAreStripped() {
        XCTAssertEqual(LaTeXNormalizer.normalize("% linear mixing model\na = b"), "a = b")
        XCTAssertEqual(LaTeXNormalizer.normalize("50\\% of x"), "50\\% of x")
        XCTAssertNotNil(render("\\begin{aligned} a &= b \\\\ % note\n c &= d \\end{aligned}", display: true))
    }

    /// The equation from the bug report: an MVES criterion, which needs `\operatorname`,
    /// `\bm`, `\label` stripping and the `equation`/`aligned` environments all at once.
    func testMVESCriterionTypesets() throws {
        let latex = """
        \\begin{equation}
        \\begin{aligned}
        \\min_{\\bm{b}_1,\\ldots,\\bm{b}_N \\in \\mathbb{R}^M} \\quad
            & \\operatorname{vol}(\\operatorname{conv}\\{\\bm{b}_1,\\ldots,\\bm{b}_N\\}) \\\\
        \\text{s.t.} \\quad
            & \\bm{x}_n \\in \\operatorname{conv}\\{\\bm{b}_1,\\ldots,\\bm{b}_N\\},
              \\quad n = 1,\\ldots,L,
        \\end{aligned}
        \\label{eq:mves}
        \\end{equation}
        """
        XCTAssertNotNil(render(latex, display: true))
    }
}
