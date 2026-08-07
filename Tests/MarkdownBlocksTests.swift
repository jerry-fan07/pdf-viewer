import XCTest
@testable import ClaudePDF

/// The block parser sits above `LaTeXSegmenter`, so it inherits that layer's hard rule:
/// nothing may appear mid-stream that isn't in the finished answer. Most of what follows is
/// either a shape models actually emit or a case where getting the layering wrong is silent.
final class MarkdownBlocksTests: XCTestCase {

    private func parse(_ input: String) -> [MarkdownBlock] {
        MarkdownBlocks.parse(input)
    }

    /// Flattens a block's inline runs back to plain text, so a test can assert on content
    /// without restating how prose and math interleave.
    private func plain(_ segments: [AnswerSegment]) -> String {
        segments.map { segment in
            switch segment {
            case .text(let text): return text
            case .inlineMath(let latex): return "<\(latex)>"
            case .displayMath(let latex): return "<<\(latex)>>"
            }
        }.joined()
    }

    // MARK: Fenced code — the bug that started this

    func testFencedCodeKeepsItsLinesAndDropsTheInfoString() {
        let input = """
        Here:

        ```swift
        let a = 1

        let b = 2
        ```

        Done.
        """
        guard case .code(let language, let body)? = parse(input).dropFirst().first else {
            return XCTFail("expected a code block")
        }
        XCTAssertEqual(language, "swift")
        // The whole reason this file exists: newlines survive, and "swift" is not content.
        XCTAssertEqual(body, "let a = 1\n\nlet b = 2")
    }

    func testTildeFenceAndUppercaseInfoString() {
        guard case .code(let language, let body)? = parse("~~~Python\nx = 1\n~~~").first else {
            return XCTFail("expected a code block")
        }
        XCTAssertEqual(language, "python")
        XCTAssertEqual(body, "x = 1")
    }

    /// CommonMark's rule, and the streaming-stable one: the block grows in place rather than
    /// flickering prose → code the moment the closing fence arrives.
    func testUnclosedFenceRunsToTheEnd() {
        guard case .code(let language, let body)? = parse("```js\nconst a = 1\nconst b = 2").first else {
            return XCTFail("expected a code block")
        }
        XCTAssertEqual(language, "js")
        XCTAssertEqual(body, "const a = 1\nconst b = 2")
    }

    /// ``` `a` and `b` ``` is prose about code, not a fence.
    func testBacktickInInfoStringIsNotAFence() {
        guard case .paragraph? = parse("``` `a` and `b` ```").first else {
            return XCTFail("expected a paragraph")
        }
    }

    // MARK: latex fences typeset

    func testClosedLatexFenceBecomesDisplayMath() {
        let input = """
        ```latex
        \\begin{equation} x = y \\end{equation}
        ```
        """
        XCTAssertEqual(parse(input), [.math("\\begin{equation} x = y \\end{equation}")])
    }

    /// Models put several equations in one fence, separated by blank lines and labelled
    /// with `%`. The normalizer strips comments, so the label is lifted out as prose
    /// instead of vanishing.
    func testLatexFenceSplitsOnBlankLinesAndKeepsCommentLabels() {
        let input = """
        ```latex
        % linear mixing model, Eq. (2)
        \\bm{x}_n = \\bm{A}\\bm{s}_n

        % standing assumptions
        \\bm{1}^T \\bm{s}_n = 1
        ```
        """
        let blocks = parse(input)
        XCTAssertEqual(blocks.count, 4)
        guard case .paragraph(let first)? = blocks.first else { return XCTFail("expected a label") }
        XCTAssertEqual(plain(first), "linear mixing model, Eq. (2)")
        XCTAssertEqual(blocks[1], .math("\\bm{x}_n = \\bm{A}\\bm{s}_n"))
        XCTAssertEqual(blocks[3], .math("\\bm{1}^T \\bm{s}_n = 1"))
    }

    /// Mid-stream the fence is still open, so it stays code — it must not flip to typeset
    /// and back when the closer lands.
    func testOpenLatexFenceStaysCode() {
        guard case .code? = parse("```latex\n\\begin{equation} x = y").first else {
            return XCTFail("an unclosed latex fence must stay code while it streams")
        }
    }

    // MARK: Display math as its own block

    func testStandaloneDisplayMathIsABlock() {
        XCTAssertEqual(
            parse("Before\n\n$$\nE = mc^2\n$$\n\nAfter").filter { if case .math = $0 { return true } else { return false } },
            [.math("\nE = mc^2\n")]
        )
    }

    func testEnvironmentSpanningBlankLinesSurvives() {
        let input = "\\begin{aligned}\na &= b \\\\\n\nc &= d\n\\end{aligned}"
        XCTAssertEqual(parse(input), [.math(input)])
    }

    func testUnclosedDisplayMathStaysProse() {
        guard case .paragraph(let segments)? = parse("$$\nE = mc^2").first else {
            return XCTFail("expected prose")
        }
        XCTAssertEqual(plain(segments), "$$ E = mc^2")
    }

    /// A paragraph that happens to contain an equation splits around it.
    func testInlineDisplayMathSplitsTheParagraph() {
        let blocks = parse("The result is \\[x^2\\] which follows.")
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[1], .math("x^2"))
    }

    // MARK: Headings, rules, quotes

    func testHeadings() {
        guard case .heading(let level, let content)? = parse("## The MVES criterion").first else {
            return XCTFail("expected a heading")
        }
        XCTAssertEqual(level, 2)
        XCTAssertEqual(plain(content), "The MVES criterion")
    }

    func testHeadingWithInlineMath() {
        guard case .heading(_, let content)? = parse("### Why $\\rho$ matters").first else {
            return XCTFail("expected a heading")
        }
        XCTAssertEqual(plain(content), "Why <\\rho> matters")
    }

    func testHashWithoutSpaceIsNotAHeading() {
        guard case .paragraph? = parse("#hashtag").first else { return XCTFail("expected a paragraph") }
    }

    func testThematicBreakBeatsBulletMarker() {
        XCTAssertEqual(parse("---"), [.rule])
        XCTAssertEqual(parse("* * *"), [.rule])
    }

    func testBlockquoteParsesItsContentsAsBlocks() {
        guard case .quote(let inner)? = parse("> ## Note\n> Text here").first else {
            return XCTFail("expected a quote")
        }
        XCTAssertEqual(inner.count, 2)
        guard case .heading(let level, _)? = inner.first else { return XCTFail("expected a heading") }
        XCTAssertEqual(level, 2)
    }

    // MARK: Lists

    func testBulletListWithNesting() {
        let input = """
        - first
          - nested
        - second
        """
        guard case .list(let items)? = parse(input).first else { return XCTFail("expected a list") }
        XCTAssertEqual(items.map(\.depth), [0, 1, 0])
        XCTAssertEqual(items.map { plain($0.content) }, ["first", "nested", "second"])
        XCTAssertTrue(items.allSatisfy { $0.ordinal == nil })
    }

    /// Four-space nesting has to read the same as two-space, so depth comes from an indent
    /// stack rather than dividing the column count.
    func testFourSpaceNestingIsOneLevel() {
        guard case .list(let items)? = parse("- a\n    - b\n- c").first else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(items.map(\.depth), [0, 1, 0])
    }

    /// Models emit `1. 1. 1.`; CommonMark renumbers, so this does too.
    func testOrderedListRenumbers() {
        guard case .list(let items)? = parse("1. one\n1. two\n1. three").first else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(items.map(\.ordinal), [1, 2, 3])
    }

    func testOrderedListHonoursItsStartingNumber() {
        guard case .list(let items)? = parse("3. three\n4. four").first else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(items.map(\.ordinal), [3, 4])
    }

    func testWrappedListItemJoinsTheItemAbove() {
        guard case .list(let items)? = parse("- a line that\n  continues here\n- next").first else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(items.map { plain($0.content) }, ["a line that continues here", "next"])
    }

    func testListItemKeepsInlineMath() {
        guard case .list(let items)? = parse("- the volume $\\operatorname{vol}(B)$ shrinks").first else {
            return XCTFail("expected a list")
        }
        XCTAssertEqual(plain(items[0].content), "the volume <\\operatorname{vol}(B)> shrinks")
    }

    // MARK: Tables

    func testTable() {
        let input = """
        | Symbol | Meaning |
        |:-------|--------:|
        | $N$ | endmembers |
        | $L$ | pixels |
        """
        guard case .table(let alignments, let rows)? = parse(input).first else {
            return XCTFail("expected a table")
        }
        XCTAssertEqual(alignments, [.leading, .trailing])
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[0].map(plain), ["Symbol", "Meaning"])
        XCTAssertEqual(rows[1].map(plain), ["<N>", "endmembers"])
    }

    /// The case this parser exists for: a pipe inside `$…$` is a conditional or a
    /// set-builder bar, not a column break.
    func testPipeInsideMathDoesNotOpenAColumn() {
        let input = """
        | Rule | Form |
        |---|---|
        | Bayes | $P(A|B) = P(B|A)P(A)/P(B)$ |
        | Set | $\\{x | x > 0\\}$ |
        """
        guard case .table(_, let rows)? = parse(input).first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1].count, 2)
        XCTAssertEqual(plain(rows[1][1]), "<P(A|B) = P(B|A)P(A)/P(B)>")
        XCTAssertEqual(rows[2].count, 2)
    }

    func testPipeInsideCodeSpanDoesNotOpenAColumn() {
        let input = "| Shell | Effect |\n|---|---|\n| `a | b` | pipes |"
        guard case .table(_, let rows)? = parse(input).first else { return XCTFail("expected a table") }
        XCTAssertEqual(rows[1].map(plain), ["`a | b`", "pipes"])
    }

    func testRowWithoutADelimiterIsNotATable() {
        guard case .paragraph? = parse("| just | prose |\nmore text").first else {
            return XCTFail("a pipe row alone is not a table")
        }
    }

    // MARK: Paragraphs

    func testSoftWrappedParagraphReflows() {
        guard case .paragraph(let segments)? = parse("one line\nand its continuation").first else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(plain(segments), "one line and its continuation")
    }

    func testTrailingSpacesMakeAHardBreak() {
        guard case .paragraph(let segments)? = parse("first  \nsecond").first else {
            return XCTFail("expected a paragraph")
        }
        XCTAssertEqual(plain(segments), "first\nsecond")
    }

    func testBlockStartsInterruptAParagraph() {
        // No blank line before the list — models omit it constantly.
        let blocks = parse("Consider:\n- one\n- two")
        XCTAssertEqual(blocks.count, 2)
        guard case .list(let items)? = blocks.last else { return XCTFail("expected a list") }
        XCTAssertEqual(items.count, 2)
    }

    // MARK: Streaming

    /// The block-level twin of `LaTeXSegmenterTests.testNoPrefixInventsMath`. Every prefix
    /// of an answer is rendered as it streams; none of them may typeset an equation that
    /// the finished answer does not contain.
    func testNoPrefixInventsMath() {
        let full = """
        # Result

        The criterion is $$\\min_b \\operatorname{vol}(B)$$ subject to \\(x \\in C\\).

        ```latex
        \\begin{equation} y = Ax \\end{equation}
        ```

        | a | b |
        |---|---|
        | $1$ | 2 |

        It costs $5.
        """
        for length in 0...full.count {
            for block in MarkdownBlocks.parse(String(full.prefix(length))) {
                guard case .math(let latex) = block else { continue }
                XCTAssertTrue(
                    full.contains(latex.trimmingCharacters(in: .whitespacesAndNewlines)),
                    "prefix of length \(length) invented “\(latex)”"
                )
            }
        }
    }

    /// Parsing runs on every streamed delta, so it has to stay cheap and, more importantly,
    /// always terminate — every branch must consume at least one line.
    func testParsingAlwaysTerminates() {
        for input in ["", "\n", "   ", "```", "$$", "\\begin{aligned}", ">", "-", "- ", "|",
                      "|---|", "#", "######", "~~~", "> - a\n> - b", "1.", "0. x"] {
            _ = MarkdownBlocks.parse(input)
        }
    }
}
