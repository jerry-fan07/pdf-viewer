import AppKit
import SwiftUI

/// Renders an assistant answer: block-level Markdown with LaTeX typeset in place.
///
/// `MarkdownBlocks` decides *what* the blocks are; this file only draws them. The one
/// structural rule that leaks into the drawing is how the two kinds of math behave. Inline
/// math is concatenated into the same `Text` as the prose around it, so it wraps and reflows
/// with the sentence; display math is its own block, centred, and scaled down rather than
/// clipped when the equation is wider than the panel.
struct AnswerView: View {
    let answer: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(MarkdownBlocks.parse(answer).enumerated()), id: \.offset) { _, block in
                BlockView(block: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Blocks

private struct BlockView: View {
    let block: MarkdownBlock

    var body: some View {
        switch block {
        case .paragraph(let segments):
            InlineText(segments: segments)

        case .heading(let level, let content):
            let style = Self.headingStyle(level)
            InlineText(segments: content, fontSize: style.size)
                .font(style.font)
                .padding(.top, level <= 2 ? 4 : 0)

        case .math(let latex):
            DisplayMathView(latex: latex)

        case .code(let language, let body):
            CodeBlockView(language: language, code: body)

        case .list(let items):
            ListBlockView(items: items)

        case .quote(let blocks):
            QuoteBlockView(blocks: blocks)

        case .table(let alignments, let rows):
            TableBlockView(alignments: alignments, rows: rows)

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    /// Point size travels alongside the `Font` because inline math inside a heading is an
    /// image: it has to be rasterised at the heading's size, not the body's.
    static func headingStyle(_ level: Int) -> (font: Font, size: CGFloat) {
        switch level {
        case 1: return (.title2.weight(.bold), NSFont.preferredFont(forTextStyle: .title2).pointSize)
        case 2: return (.title3.weight(.semibold), NSFont.preferredFont(forTextStyle: .title3).pointSize)
        case 3: return (.headline, NSFont.preferredFont(forTextStyle: .headline).pointSize)
        // Body weight, not `.subheadline`: that is *smaller* than the prose around it, so an
        // h4 would read as a caption rather than as a heading.
        default: return (.body.weight(.semibold), NSFont.preferredFont(forTextStyle: .body).pointSize)
        }
    }
}

// MARK: - Inline runs

/// A run of prose with inline math typeset into it, as one concatenated `Text` so the whole
/// thing wraps as a single paragraph.
private struct InlineText: View {
    let segments: [AnswerSegment]
    var fontSize: CGFloat = NSFont.preferredFont(forTextStyle: .body).pointSize

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        // `InlineRuns` has already done the Markdown and the quote links, over the run as a
        // whole — a `**` that opens before an equation and closes after it is one span, and
        // it can only be seen as one by something looking at the whole run at once.
        InlineRuns.pieces(segments).reduce(Text(verbatim: "")) { result, piece in
            switch piece {
            case .text(let attributed):
                return result + Text(attributed)

            case .inlineMath(let latex):
                guard let math = MathRenderer.render(
                    latex: latex, fontSize: fontSize, display: false, colorScheme: colorScheme
                ) else {
                    return result + Text(verbatim: latex).font(.system(size: fontSize, design: .monospaced))
                }
                return result + Text(Image(nsImage: math.image)).baselineOffset(-math.descent)

            case .displayMath(let latex):
                // Reachable only where a block cannot be opened (a table cell, say); the
                // parser demotes those to inline math, so this is a belt-and-braces case.
                return result + Text(verbatim: latex)
            }
        }
        .textSelection(.enabled)
        // Deliberately *not* `.frame(maxWidth: .infinity)`. A run that claims the full width
        // itself cannot then be aligned by its container, which is how a right-aligned table
        // column ends up rendering flush left. The enclosing VStack already aligns leading.
    }
}

// MARK: - Display math

private struct DisplayMathView: View {
    let latex: String

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        if let math = MathRenderer.render(
            latex: latex,
            fontSize: NSFont.preferredFont(forTextStyle: .body).pointSize * 1.1,
            display: true,
            colorScheme: colorScheme
        ) {
            // Never larger than typeset, but allowed to shrink: the chat panel is narrow
            // and a wide equation should scale down rather than clip or force a scroller.
            Image(nsImage: math.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: math.image.size.width, maxHeight: math.image.size.height)
                .frame(maxWidth: .infinity, alignment: .center)
        } else {
            // Invalid or unsupported TeX: show the source rather than swallowing it.
            Text(verbatim: latex)
                .font(.body.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Code

private struct CodeBlockView: View {
    let language: String?
    let code: String

    @Environment(\.colorScheme) private var colorScheme
    @State private var copied = false

    private var fontSize: CGFloat { NSFont.preferredFont(forTextStyle: .body).pointSize * 0.92 }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Text(language.flatMap { $0.isEmpty ? nil : $0 } ?? "text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button(action: copy) {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help(copied ? "Copied" : "Copy code")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)

            Divider()

            // Code is the one thing in an answer that must not be re-wrapped — a wrapped
            // line changes what the code appears to say — so it scrolls instead.
            //
            // Both `fixedSize`es are load-bearing. A `ScrollView` has no ideal height, so
            // inside the transcript's own vertical scroll it is free to be squeezed: without
            // them a multi-line block collapses to one truncated line ("def f(x):…").
            ScrollView(.horizontal, showsIndicators: false) {
                Text(CodeHighlighter.highlight(code, language: language, colorScheme: colorScheme))
                    .font(.system(size: fontSize, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(8)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(code, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
        }
    }
}

// MARK: - Lists

private struct ListBlockView: View {
    let items: [ListItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(marker(item))
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(minWidth: 15, alignment: .trailing)
                    InlineText(segments: item.content)
                }
                .padding(.leading, CGFloat(item.depth) * 18)
            }
        }
    }

    private func marker(_ item: ListItem) -> String {
        if let ordinal = item.ordinal { return "\(ordinal)." }
        return item.depth % 2 == 0 ? "•" : "◦"
    }
}

// MARK: - Quotes

private struct QuoteBlockView: View {
    let blocks: [MarkdownBlock]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(.tertiary)
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 8) {
                // Erased on purpose: a quote holds blocks, and a `BlockView` that mentions
                // `QuoteBlockView` in its own body type would not be a finite Swift type.
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    AnyView(BlockView(block: block))
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Tables

private struct TableBlockView: View {
    let alignments: [ColumnAlignment]
    let rows: [[[AnswerSegment]]]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                        InlineText(segments: cell)
                            .font(index == 0 ? .body.weight(.semibold) : .body)
                            .multilineTextAlignment(textAlignment(column))
                            .frame(maxWidth: .infinity, alignment: alignment(column))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 5)
                    }
                }
                .background(index == 0 ? AnyShapeStyle(.quaternary.opacity(0.5)) : AnyShapeStyle(.clear))
                if index == 0 {
                    Divider().gridCellUnsizedAxes(.horizontal).gridCellColumns(alignments.count)
                }
            }
        }
        // Cells wrap rather than scroll: the chat panel is narrow enough that a scroller
        // would hide most of a table behind a gesture.
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private func alignment(_ column: Int) -> Alignment {
        switch alignments.indices.contains(column) ? alignments[column] : .leading {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }

    private func textAlignment(_ column: Int) -> TextAlignment {
        switch alignments.indices.contains(column) ? alignments[column] : .leading {
        case .leading: return .leading
        case .center: return .center
        case .trailing: return .trailing
        }
    }
}
