import Foundation

/// Column alignment from a table's delimiter row (`:---`, `:---:`, `---:`).
enum ColumnAlignment: Equatable {
    case leading, center, trailing
}

/// One line of a bulleted or numbered list. Nesting is carried as a depth rather than as
/// child blocks: models nest lists two levels at most, and a flat list with a depth renders
/// identically while keeping the parser — and its tests — readable.
struct ListItem: Equatable {
    let depth: Int
    /// `nil` for a bullet. Numbers are renumbered sequentially per run, as CommonMark
    /// specifies, so the `1. 1. 1.` that models sometimes emit still shows as 1, 2, 3.
    let ordinal: Int?
    let content: [AnswerSegment]
}

/// A block-level element of an assistant answer.
indirect enum MarkdownBlock: Equatable {
    case heading(level: Int, content: [AnswerSegment])
    case paragraph([AnswerSegment])
    case list([ListItem])
    case code(language: String?, body: String)
    case math(String)
    case quote([MarkdownBlock])
    /// `rows[0]` is the header. Every row is padded to `alignments.count`.
    case table(alignments: [ColumnAlignment], rows: [[[AnswerSegment]]])
    case rule
}

/// Splits an answer into block-level Markdown, one layer above `LaTeXSegmenter`.
///
/// The pass order is the whole design. `AttributedString(markdown:)` cannot do blocks at
/// all — it is used here only for the inline span inside a block — and `LaTeXSegmenter`
/// works on a single run of prose. So blocks are cut first, and only a block's own inline
/// text is handed down to the segmenter, which then hands prose to Markdown. Each layer
/// sees exactly what it understands.
///
/// Two things are carved out here rather than downstream, because both can span lines and
/// neither survives being cut at a blank line:
///   • fenced code — opaque, and the reason `` ```latex `` used to arrive as one collapsed
///     code span with the info string typeset as content.
///   • display math sitting on its own lines, including `\begin{aligned}` with blank lines
///     inside it.
///
/// Streaming rules, since the whole answer re-parses on every delta:
///   • An unclosed fence runs to the end of the answer (CommonMark's rule, and the stable
///     one — the block grows in place instead of flickering prose → code at the closer).
///   • An unclosed `$$` / `\[` / `\begin{env}` stays prose, matching the segmenter. A
///     half-arrived equation must never flash on screen and then re-flow.
enum MarkdownBlocks {

    static func parse(_ source: String) -> [MarkdownBlock] {
        let lines = source.components(separatedBy: "\n")
        var out: [MarkdownBlock] = []
        var i = 0

        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { i += 1; continue }

            if let fence = codeFence(lines, from: i) {
                let typeset = fence.closed && typesetFenceLanguages.contains(fence.language ?? "")
                    ? mathBlocks(fromFence: fence.body)
                    : []
                out.append(contentsOf: typeset.isEmpty
                    ? [.code(language: fence.language, body: fence.body)]
                    : typeset)
                i = fence.next
                continue
            }
            if let math = displayMath(lines, from: i) {
                out.append(.math(math.latex))
                i = math.next
                continue
            }
            if isThematicBreak(line) {
                out.append(.rule)
                i += 1
                continue
            }
            if let head = heading(line) {
                out.append(.heading(level: head.level, content: inlineOnly(head.text)))
                i += 1
                continue
            }
            if isQuote(line) {
                let quoted = quote(lines, from: i)
                out.append(.quote(quoted.blocks))
                i = quoted.next
                continue
            }
            if let parsed = table(lines, from: i) {
                out.append(.table(alignments: parsed.alignments, rows: parsed.rows))
                i = parsed.next
                continue
            }
            if listMarker(line) != nil {
                let parsed = list(lines, from: i)
                out.append(.list(parsed.items))
                i = parsed.next
                continue
            }

            let parsed = paragraph(lines, from: i)
            out.append(contentsOf: parsed.blocks)
            i = parsed.next
        }
        return out
    }

    // MARK: - Inline

    private static func inline(_ text: String) -> [AnswerSegment] {
        LaTeXSegmenter.segments(in: text)
    }

    /// Inline segments for contexts that cannot hold a block — a heading, a list item, a
    /// table cell. A `\[…\]` written there is demoted to inline math so it still typesets
    /// instead of being dropped into the middle of a sentence at display size.
    private static func inlineOnly(_ text: String) -> [AnswerSegment] {
        inline(text).map { segment in
            if case .displayMath(let latex) = segment { return .inlineMath(latex) }
            return segment
        }
    }

    // MARK: - Paragraphs

    /// A paragraph runs to the next blank line or the start of another block. Display math
    /// found *within* it (`text \[x\] text`) splits the paragraph, since an equation is a
    /// block wherever it appears.
    private static func paragraph(_ lines: [String], from start: Int) -> (blocks: [MarkdownBlock], next: Int) {
        var text = ""
        var i = start

        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { break }
            if i > start && startsNewBlock(lines, at: i) { break }

            if i > start {
                // CommonMark: a soft line break is a space; two trailing spaces or a
                // trailing backslash make it hard. Models rarely hard-wrap prose, but when
                // they do, reflowing beats a ragged right edge in a narrow chat panel.
                text += isHardBreak(lines[i - 1]) ? "\n" : " "
            }
            text += line.trimmingCharacters(in: .whitespaces)
            i += 1
        }

        var blocks: [MarkdownBlock] = []
        var run: [AnswerSegment] = []
        func flush() {
            while case .text(let last)? = run.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
                run.removeLast()
            }
            if !run.isEmpty { blocks.append(.paragraph(run)) }
            run = []
        }
        for segment in inline(text) {
            if case .displayMath(let latex) = segment {
                flush()
                blocks.append(.math(latex))
            } else {
                run.append(segment)
            }
        }
        flush()
        return (blocks, i)
    }

    private static func isHardBreak(_ line: String) -> Bool {
        line.hasSuffix("  ") || (line.hasSuffix("\\") && !line.hasSuffix("\\\\"))
    }

    // MARK: - Fenced code

    private struct Fence {
        let language: String?
        let body: String
        let closed: Bool
        let next: Int
    }

    /// The one fence language that is *not* drawn as code.
    ///
    /// A deliberate divergence from the web UI, which shows a ```latex fence as source. That
    /// is right for a general chat client and wrong for a reader pointed at papers, where
    /// the fence is nearly always the answer's actual equation rather than TeX being
    /// discussed as text. Only *closed* fences convert, so a half-streamed one stays code
    /// instead of flipping to typeset and back.
    private static let typesetFenceLanguages: Set<String> = ["latex", "tex", "math"]

    /// Splits a typeset fence on blank lines — models put several equations in one fence —
    /// and lifts each equation's leading `%` label out as prose. `LaTeXNormalizer` strips
    /// comments before typesetting, so without this the label would simply disappear.
    private static func mathBlocks(fromFence body: String) -> [MarkdownBlock] {
        var out: [MarkdownBlock] = []
        for chunk in body.components(separatedBy: "\n\n") {
            var label: [String] = []
            var math: [String] = []
            for line in chunk.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                if math.isEmpty, trimmed.hasPrefix("%") {
                    label.append(String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces))
                } else {
                    math.append(line)
                }
            }
            if !label.isEmpty { out.append(.paragraph(inlineOnly(label.joined(separator: " ")))) }
            if !math.isEmpty { out.append(.math(math.joined(separator: "\n"))) }
        }
        return out
    }

    private static func codeFence(_ lines: [String], from start: Int) -> Fence? {
        let line = lines[start]
        let indent = indentWidth(line)
        guard indent <= 3 else { return nil }

        let rest = line.dropFirst(indent)
        guard let marker = rest.first, marker == "`" || marker == "~" else { return nil }
        let openLength = rest.prefix(while: { $0 == marker }).count
        guard openLength >= 3 else { return nil }

        let info = rest.dropFirst(openLength).trimmingCharacters(in: .whitespaces)
        // A backtick in the info string means this was never a fence (CommonMark) — most
        // often it is prose about code, like ``` `a` and `b` ```.
        guard !(marker == "`" && info.contains("`")) else { return nil }
        let language = info.split(separator: " ").first.map { $0.lowercased() }

        var body: [String] = []
        var i = start + 1
        while i < lines.count {
            let candidate = lines[i]
            let closing = candidate.dropFirst(indentWidth(candidate))
                .drop(while: { $0 == marker })
                .trimmingCharacters(in: .whitespaces)
            let markerRun = candidate.dropFirst(indentWidth(candidate)).prefix(while: { $0 == marker }).count
            if indentWidth(candidate) <= 3, markerRun >= openLength, closing.isEmpty {
                return Fence(
                    language: language, body: body.joined(separator: "\n"), closed: true, next: i + 1
                )
            }
            body.append(candidate)
            i += 1
        }
        return Fence(
            language: language, body: body.joined(separator: "\n"), closed: false, next: lines.count
        )
    }

    // MARK: - Display math

    private struct BlockMath {
        let latex: String
        let next: Int
    }

    private static func displayMath(_ lines: [String], from start: Int) -> BlockMath? {
        guard indentWidth(lines[start]) <= 3 else { return nil }
        let head = String(lines[start].drop(while: { $0 == " " }))

        if head.hasPrefix("$$") { return delimited(lines, from: start, open: "$$", close: "$$") }
        if head.hasPrefix("\\[") { return delimited(lines, from: start, open: "\\[", close: "\\]") }
        if head.hasPrefix("\\begin{") { return environment(lines, from: start, head: head) }
        return nil
    }

    /// Consumes lines until the closer. Anything trailing the closer means this was a
    /// sentence that happened to start with math, not a display block — the inline pass
    /// handles that case, so bail and let the paragraph branch take it.
    private static func delimited(_ lines: [String], from start: Int, open: String, close: String) -> BlockMath? {
        var joined = String(lines[start].drop(while: { $0 == " " }))
        var i = start
        while true {
            let afterOpen = joined.index(joined.startIndex, offsetBy: open.count)
            if let closer = joined.range(of: close, range: afterOpen..<joined.endIndex) {
                guard joined[closer.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return BlockMath(latex: String(joined[afterOpen..<closer.lowerBound]), next: i + 1)
            }
            i += 1
            guard i < lines.count else { return nil }   // unclosed ⇒ prose, as in the segmenter
            joined += "\n" + lines[i]
        }
    }

    /// `\begin{env}…\end{env}` keeps its delimiters: `LaTeXNormalizer` needs the environment
    /// name to map it onto something SwiftMath draws.
    private static func environment(_ lines: [String], from start: Int, head: String) -> BlockMath? {
        let afterBegin = head.dropFirst("\\begin{".count)
        guard let brace = afterBegin.firstIndex(of: "}") else { return nil }
        let name = String(afterBegin[..<brace])
        guard LaTeXSegmenter.mathEnvironments.contains(name) else { return nil }

        let close = "\\end{\(name)}"
        var joined = head
        var i = start
        while true {
            if let closer = joined.range(of: close) {
                guard joined[closer.upperBound...].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
                return BlockMath(latex: joined, next: i + 1)
            }
            i += 1
            guard i < lines.count else { return nil }
            joined += "\n" + lines[i]
        }
    }

    // MARK: - Headings, rules, quotes

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let indent = indentWidth(line)
        guard indent <= 3 else { return nil }
        let rest = line.dropFirst(indent)
        let level = rest.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(level) else { return nil }

        let after = rest.dropFirst(level)
        guard after.isEmpty || after.first == " " else { return nil }

        var text = after.trimmingCharacters(in: .whitespaces)
        // A closing run of hashes ("## Title ##") is decoration, but only when a space
        // precedes it — otherwise "# C#" would lose its name.
        if text.hasSuffix("#") {
            let stripped = String(text.reversed().drop(while: { $0 == "#" }).reversed())
            if stripped.hasSuffix(" ") { text = stripped.trimmingCharacters(in: .whitespaces) }
        }
        return (level, text)
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        guard indentWidth(line) <= 3 else { return false }
        let stripped = line.filter { $0 != " " && $0 != "\t" }
        guard stripped.count >= 3, let first = stripped.first, "-*_".contains(first) else { return false }
        return stripped.allSatisfy { $0 == first }
    }

    private static func isQuote(_ line: String) -> Bool {
        indentWidth(line) <= 3 && line.dropFirst(indentWidth(line)).first == ">"
    }

    private static func quote(_ lines: [String], from start: Int) -> (blocks: [MarkdownBlock], next: Int) {
        var inner: [String] = []
        var i = start
        while i < lines.count {
            let line = lines[i]
            if isQuote(line) {
                var rest = line.dropFirst(indentWidth(line)).dropFirst()      // the ">"
                if rest.first == " " { rest = rest.dropFirst() }
                inner.append(String(rest))
            } else if isBlank(line) || startsNewBlock(lines, at: i) {
                break
            } else {
                inner.append(line)                                            // lazy continuation
            }
            i += 1
        }
        return (parse(inner.joined(separator: "\n")), i)
    }

    // MARK: - Lists

    private struct Marker {
        let indent: Int
        let ordinal: Int?
        let contentStart: Int
    }

    private static func listMarker(_ line: String) -> Marker? {
        let chars = Array(line)
        var i = 0
        while i < chars.count, chars[i] == " " { i += 1 }
        // Past this much indent the line is a continuation, not a new item.
        guard i <= 8, i < chars.count else { return nil }

        if chars[i] == "-" || chars[i] == "*" || chars[i] == "+" {
            guard i + 1 < chars.count, chars[i + 1] == " " else { return nil }
            return Marker(indent: i, ordinal: nil, contentStart: i + 2)
        }

        let indent = i
        var digits = ""
        while i < chars.count, chars[i].isNumber { digits.append(chars[i]); i += 1 }
        guard !digits.isEmpty, digits.count <= 9,
              i < chars.count, chars[i] == "." || chars[i] == ")",
              i + 1 < chars.count, chars[i + 1] == " " else { return nil }
        return Marker(indent: indent, ordinal: Int(digits), contentStart: i + 2)
    }

    private static func list(_ lines: [String], from start: Int) -> (items: [ListItem], next: Int) {
        struct Raw {
            let depth: Int
            let ordinal: Int?
            var text: String
        }
        var raws: [Raw] = []
        var indents: [Int] = []          // indent width per depth, so 2- and 4-space nesting both work
        var sawBlank = false
        var i = start

        while i < lines.count {
            let line = lines[i]
            if isBlank(line) { sawBlank = true; i += 1; continue }

            if !isThematicBreak(line), let marker = listMarker(line) {
                while let deepest = indents.last, marker.indent < deepest { indents.removeLast() }
                if indents.isEmpty {
                    indents = [marker.indent]
                } else if marker.indent > indents[indents.count - 1] {
                    indents.append(marker.indent)
                }
                let text = String(Array(line)[marker.contentStart...]).trimmingCharacters(in: .whitespaces)
                raws.append(Raw(depth: indents.count - 1, ordinal: marker.ordinal, text: text))
                sawBlank = false
                i += 1
                continue
            }

            // Not an item. A blank line already ended the list; otherwise this wraps the
            // item above it, unless it opens a block of its own.
            guard !sawBlank, !raws.isEmpty, !startsNewBlock(lines, at: i) else { break }
            raws[raws.count - 1].text += " " + line.trimmingCharacters(in: .whitespaces)
            i += 1
        }

        var counters: [Int] = []
        var previousDepth = -1
        var items: [ListItem] = []
        for raw in raws {
            while counters.count <= raw.depth { counters.append(0) }
            // Descending into a nested run restarts its numbering at whatever the model wrote.
            if raw.depth > previousDepth { counters[raw.depth] = (raw.ordinal ?? 1) - 1 }
            counters[raw.depth] += 1
            items.append(ListItem(
                depth: raw.depth,
                ordinal: raw.ordinal == nil ? nil : counters[raw.depth],
                content: inlineOnly(raw.text)
            ))
            previousDepth = raw.depth
        }
        return (items, i)
    }

    // MARK: - Tables

    private static func table(
        _ lines: [String], from start: Int
    ) -> (alignments: [ColumnAlignment], rows: [[[AnswerSegment]]], next: Int)? {
        guard start + 1 < lines.count, lines[start].contains("|") else { return nil }
        let header = splitRow(lines[start])
        guard !header.isEmpty,
              let alignments = delimiterRow(lines[start + 1]),
              alignments.count == header.count else { return nil }

        var rows: [[[AnswerSegment]]] = [header.map(inlineOnly)]
        var i = start + 2
        while i < lines.count, !isBlank(lines[i]), lines[i].contains("|") {
            var cells = splitRow(lines[i])
            while cells.count < alignments.count { cells.append("") }
            rows.append(cells.prefix(alignments.count).map(inlineOnly))
            i += 1
        }
        return (alignments, rows, i)
    }

    /// Splits a row on `|`, skipping any pipe that is inside math or a code span. Papers put
    /// conditionals and set-builders in cells — `$P(A|B)$`, `$\{x | x > 0\}$` — and a naive
    /// split shreds them into extra columns.
    ///
    /// `\|` is left escaped: in a math cell it is the norm delimiter, and in prose the
    /// Markdown pass unescapes it.
    private static func splitRow(_ line: String) -> [String] {
        let chars = Array(line.trimmingCharacters(in: .whitespaces))
        var cells: [String] = []
        var current = ""
        var inDollarMath = false
        var inParenMath = false
        var inCodeSpan = false
        var i = 0

        while i < chars.count {
            let c = chars[i]
            if c == "\\", i + 1 < chars.count {
                if chars[i + 1] == "(" { inParenMath = true }
                if chars[i + 1] == ")" { inParenMath = false }
                current.append(c)
                current.append(chars[i + 1])
                i += 2
                continue
            }
            if c == "`" { inCodeSpan.toggle() }
            if c == "$", !inCodeSpan { inDollarMath.toggle() }
            if c == "|", !inDollarMath, !inParenMath, !inCodeSpan {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                i += 1
                continue
            }
            current.append(c)
            i += 1
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))

        // The leading and trailing pipes of `| a | b |` each produce an empty edge cell.
        if cells.first?.isEmpty == true { cells.removeFirst() }
        if cells.last?.isEmpty == true { cells.removeLast() }
        return cells
    }

    private static func delimiterRow(_ line: String) -> [ColumnAlignment]? {
        let cells = splitRow(line)
        guard !cells.isEmpty else { return nil }

        var alignments: [ColumnAlignment] = []
        for cell in cells {
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            switch (cell.hasPrefix(":"), cell.hasSuffix(":")) {
            case (true, true): alignments.append(.center)
            case (false, true): alignments.append(.trailing)
            default: alignments.append(.leading)
            }
        }
        return alignments
    }

    // MARK: - Shared

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private static func indentWidth(_ line: String) -> Int {
        line.prefix(while: { $0 == " " }).count
    }

    /// Whether line `i` interrupts whatever block is being accumulated.
    ///
    /// A fence inside a list item is deliberately *not* handled: it ends the list and
    /// renders at top level. Supporting it properly means recursive container parsing, and
    /// that is where this file would double in size for a case models rarely produce.
    private static func startsNewBlock(_ lines: [String], at i: Int) -> Bool {
        let line = lines[i]
        return codeFence(lines, from: i) != nil
            || displayMath(lines, from: i) != nil
            || isThematicBreak(line)
            || heading(line) != nil
            || isQuote(line)
            || listMarker(line) != nil
            || table(lines, from: i) != nil
    }
}
