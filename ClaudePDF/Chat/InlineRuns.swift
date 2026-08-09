import AppKit
import Foundation

/// One drawable piece of an inline run: prose whose Markdown has already been applied,
/// or a run of math for the renderer to typeset.
enum InlinePiece: Equatable {
    case text(AttributedString)
    case inlineMath(String)
    /// Display math that reached a context where no block can be opened. Drawn as source.
    case displayMath(String)
}

/// The last layer of the answer pipeline: turns a block's inline segments into the pieces
/// `AnswerView` draws, with Markdown applied and quoted passages linked.
///
/// It exists because of one rule the layers above cannot enforce: **Markdown must be parsed
/// over the whole inline run, once.** `LaTeXSegmenter` cuts prose at every `$…$`, and
/// `AnswerQuotes` cuts it again at every quoted passage — and an emphasis span does not care
/// where those cuts fall. Parsing each fragment on its own is what turned
///
///     **Any invertible $Q$ gives a rival factorization**
///
/// into three fragments — `**Any invertible `, the math, ` gives a rival factorization**` —
/// each holding one unpaired `**`, which `AttributedString(markdown:)` then renders as
/// literal asterisks. The same break hit `*italic*`, `[link text](url)` and any emphasis
/// spanning a quotation.
///
/// So the run is put back together first: each math segment becomes a single placeholder
/// character, the whole thing is parsed once, and the math is spliced back in afterwards.
/// U+FFFC (OBJECT REPLACEMENT CHARACTER) is the placeholder because it is exactly what it
/// says — a stand-in for a non-text object — and because Markdown has no meaning for it, so
/// it cannot open, close or disturb a span it sits inside.
///
/// Quotes are then found in the *parsed* text rather than the source, which is the only
/// order that works once Markdown is a single pass — and is better anyway: a passage the
/// model wrote as `"the **whole** point"` now hunts the page for `the whole point` instead
/// of for asterisks that are not on it.
enum InlineRuns {

    /// Stands in for a run of math while Markdown is parsed.
    static let mathPlaceholder: Character = "\u{FFFC}"

    static func pieces(_ segments: [AnswerSegment]) -> [InlinePiece] {
        var source = ""
        var math: [InlinePiece] = []

        for segment in segments {
            switch segment {
            case .text(let text):
                // A placeholder the model itself emitted would be spliced against the wrong
                // equation, so it never reaches the parse.
                source += text.contains(mathPlaceholder)
                    ? text.filter { $0 != mathPlaceholder }
                    : text
            case .inlineMath(let latex):
                source.append(mathPlaceholder)
                math.append(.inlineMath(latex))
            case .displayMath(let latex):
                source.append(mathPlaceholder)
                math.append(.displayMath(latex))
            }
        }
        guard !source.isEmpty else { return [] }

        var attributed = markdown(source)
        link(quotesIn: &attributed)
        return splice(math, into: attributed)
    }

    // MARK: - Markdown

    private static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }

    // MARK: - Quotes

    /// Turns each quoted passage into a link back to the page it came from. The link lives
    /// on the attributed run rather than on a separate view so the quote still wraps inside
    /// its sentence.
    private static func link(quotesIn attributed: inout AttributedString) {
        let plain = maskingCode(attributed)
        var offset = 0

        for chunk in AnswerQuotes.split(plain) {
            let length = chunk.text.count
            defer { offset += length }
            guard let quote = chunk.quote, let url = SourceLink.url(quote: needle(for: quote)) else {
                continue
            }
            let start = attributed.index(attributed.startIndex, offsetByCharacters: offset)
            let end = attributed.index(start, offsetByCharacters: length)
            attributed[start..<end].link = url
            // `.linkColor` rather than a fixed blue: it is the system's own link colour, so
            // it tracks light and dark appearance and the accessibility settings that change
            // it. No underline — the colour alone marks the quote as actionable.
            attributed[start..<end].foregroundColor = .linkColor
        }
    }

    /// The parsed text with code spans blanked out, one space per character.
    ///
    /// `AnswerQuotes` skipped code by its backticks, and the parse has eaten those — but a
    /// `"` inside code still belongs to the code. Blanking keeps every other character at
    /// the offset it really has, so a quote range found here maps straight onto the
    /// attributed string.
    private static func maskingCode(_ attributed: AttributedString) -> String {
        var plain = ""
        for run in attributed.runs {
            let text = attributed[run.range].characters
            if run.inlinePresentationIntent?.contains(.code) == true {
                plain += String(repeating: " ", count: text.count)
            } else {
                plain += String(text)
            }
        }
        return plain
    }

    /// What to hunt for in the document. Math inside a quotation has no characters on the
    /// page for the placeholder to match, so it becomes an elision — which `SourceLocator`
    /// already knows how to relax around, matching the longest run either side of it.
    private static func needle(for quote: String) -> String {
        guard quote.contains(mathPlaceholder) else { return quote }
        return quote
            .split(separator: mathPlaceholder, omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "...")
    }

    // MARK: - Splicing the math back in

    private static func splice(_ math: [InlinePiece], into attributed: AttributedString) -> [InlinePiece] {
        var pieces: [InlinePiece] = []
        var rest = attributed
        var next = 0

        while next < math.count, let found = rest.characters.firstIndex(of: mathPlaceholder) {
            let head = rest[rest.startIndex..<found]
            if !head.characters.isEmpty { pieces.append(.text(AttributedString(head))) }
            pieces.append(math[next])
            next += 1
            rest = AttributedString(rest[rest.index(afterCharacter: found)...])
        }

        if !rest.characters.isEmpty { pieces.append(.text(rest)) }
        // Only reachable if the parse dropped a placeholder; keep the math rather than the
        // silence that losing it would leave behind.
        pieces.append(contentsOf: math[next...])
        return pieces
    }
}
