import AppKit
import SwiftUI

/// Renders an assistant answer: Markdown prose with LaTeX typeset in place.
///
/// Structure mirrors how the two kinds of math behave. Inline math is concatenated into
/// the same `Text` as the prose around it, so it wraps and reflows with the sentence.
/// Display math is its own block, centred, and scrolls horizontally if the equation is
/// wider than the panel rather than being clipped.
struct AnswerView: View {
    let answer: String

    @Environment(\.colorScheme) private var colorScheme

    private var fontSize: CGFloat { NSFont.preferredFont(forTextStyle: .body).pointSize }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks) { block in
                switch block.kind {
                case .prose(let segments):
                    paragraph(segments)
                        .textSelection(.enabled)
                case .display(let latex):
                    displayMath(latex)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Blocks

    private struct Block: Identifiable {
        enum Kind {
            case prose([AnswerSegment])
            case display(String)
        }
        let id: Int
        let kind: Kind
    }

    /// Display math breaks the answer into blocks; everything else accumulates into the
    /// current paragraph. The newlines that surrounded a `$$…$$` are trimmed so the
    /// equation does not leave a gap above and below it.
    private var blocks: [Block] {
        var out: [Block] = []
        var current: [AnswerSegment] = []

        func flushProse() {
            // Drop the blank line that only existed to separate prose from the equation
            // below it — the VStack already provides that gap.
            if case .text(let text)? = current.last {
                let trimmed = text.reversed().drop(while: { $0 == "\n" || $0 == " " }).reversed()
                if trimmed.isEmpty {
                    current.removeLast()
                } else {
                    current[current.count - 1] = .text(String(trimmed))
                }
            }
            guard !current.isEmpty else { return }
            out.append(Block(id: out.count, kind: .prose(current)))
            current = []
        }

        for segment in LaTeXSegmenter.segments(in: answer) {
            switch segment {
            case .displayMath(let latex):
                flushProse()
                out.append(Block(id: out.count, kind: .display(latex)))
            case .text(let text):
                // Leading newlines after an equation would otherwise open the paragraph
                // with blank space.
                if current.isEmpty, let last = out.last, case .display = last.kind {
                    let trimmed = text.drop(while: { $0 == "\n" || $0 == " " })
                    if trimmed.isEmpty { continue }
                    current.append(.text(String(trimmed)))
                } else {
                    current.append(segment)
                }
            case .inlineMath:
                current.append(segment)
            }
        }
        flushProse()
        return out
    }

    // MARK: - Rendering

    private func paragraph(_ segments: [AnswerSegment]) -> Text {
        segments.reduce(Text(verbatim: "")) { result, segment in
            switch segment {
            case .text(let text):
                return result + Text(markdown(text))
            case .inlineMath(let latex):
                guard let math = MathRenderer.render(
                    latex: latex, fontSize: fontSize, display: false, colorScheme: colorScheme
                ) else {
                    return result + Text(verbatim: latex).font(.body.monospaced())
                }
                return result + Text(Image(nsImage: math.image)).baselineOffset(-math.descent)
            case .displayMath(let latex):
                return result + Text(verbatim: latex)
            }
        }
    }

    @ViewBuilder
    private func displayMath(_ latex: String) -> some View {
        if let math = MathRenderer.render(
            latex: latex, fontSize: fontSize * 1.1, display: true, colorScheme: colorScheme
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
        }
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
