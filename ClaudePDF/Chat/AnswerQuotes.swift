import Foundation

/// One run of an answer's prose: either ordinary text or a passage the model quoted
/// from the document, which the viewer can go and find.
struct AnswerChunk: Equatable {
    let text: String
    /// The quoted passage without its quotation marks, or nil for ordinary prose.
    let quote: String?
}

/// Picks the quoted passages out of an answer so each can be turned into a link back
/// to the page it came from.
///
/// Two callers, and they hand it different things on purpose:
///   • `InlineRuns`, drawing a paragraph, passes the *parsed* text of one inline run —
///     Markdown already applied, code spans blanked out — so what a link goes hunting
///     for on the page is the words as they read, not the asterisks around them. That
///     is also the only order that works: Markdown is one pass over the whole run, so
///     a quotation cannot be cut out of the source before it.
///   • `ChatPanelView`, listing an answer's jump-to-source chips, passes the raw answer,
///     because it only needs to know *whether* the answer quotes anything and roughly
///     what. A chip for a quotation carrying markup therefore still hunts the markup;
///     the inline link beside it is the one that finds the passage.
///
/// Either way the layers above have taken away what would confuse it: `MarkdownBlocks`
/// has taken fenced code, `LaTeXSegmenter` the math. A `"` that arrives here is a
/// quotation mark rather than a string literal or a TeX unit.
///
/// The rules are conservative on purpose — a link that highlights the wrong thing is
/// worse than prose that isn't linked:
///   • **Only paired `“…”` and `"…"`.** Never `'…'`: "the model's answer" would open a
///     quote that the next apostrophe in the paragraph closes.
///   • **An unclosed quote stays prose.** The whole answer re-parses on every streamed
///     delta, so a `"` whose closer hasn't arrived yet would otherwise flash a link
///     around a half-arrived sentence — the same rule `LaTeXSegmenter` applies to `$`.
///   • **Length bounds both ways.** Under `minimumLength` it's a quoted *term*, which
///     would match all over the document; over `maximumLength` the two marks are
///     probably not a pair at all.
///   • **Code spans are opaque.** A `"` inside backticks belongs to the code.
enum AnswerQuotes {
    /// Roughly three or four words — the point where a match is the passage rather
    /// than a coincidence.
    static let minimumLength = 16
    /// Models quote a sentence or two; a "quote" longer than this is two stray marks
    /// with a paragraph between them.
    static let maximumLength = 400

    /// Splits prose into alternating plain and quoted chunks. Concatenating every
    /// `text` reproduces the input exactly, so the renderer can rebuild the paragraph
    /// without losing a character.
    static func split(_ source: String) -> [AnswerChunk] {
        var chunks: [AnswerChunk] = []
        var plain = ""
        var index = source.startIndex

        func flushPlain() {
            guard !plain.isEmpty else { return }
            chunks.append(AnswerChunk(text: plain, quote: nil))
            plain = ""
        }

        while index < source.endIndex {
            let character = source[index]

            if character == "`" {
                // Skip the whole code span, closer included; if it never closes, the
                // rest of the answer is code as far as we're concerned.
                let after = source.index(after: index)
                let end = source[after...].firstIndex(of: "`").map(source.index(after:))
                    ?? source.endIndex
                plain += source[index..<end]
                index = end
                continue
            }

            if let closer = closingMark(for: character),
               let range = quoteRange(in: source, openingAt: index, closer: closer) {
                flushPlain()
                let inner = String(source[source.index(after: range.lowerBound)..<range.upperBound])
                chunks.append(AnswerChunk(
                    text: String(source[range.lowerBound...range.upperBound]), quote: inner
                ))
                index = source.index(after: range.upperBound)
                continue
            }

            plain.append(character)
            index = source.index(after: index)
        }

        flushPlain()
        return chunks
    }

    /// Any quoted passage in the answer, in order — used to decide whether a card has
    /// anything to verify at all.
    static func quotes(in source: String) -> [String] {
        split(source).compactMap(\.quote)
    }

    /// Shortened form for a jump-to-source chip: enough words to recognise the passage.
    static func chipLabel(for quote: String) -> String {
        let flattened = quote
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flattened.count > 32 else { return "“\(flattened)”" }
        let cut = flattened.prefix(32)
        let words = cut.split(separator: " ")
        let trimmed = words.count > 1 ? words.dropLast().joined(separator: " ") : String(cut)
        return "“\(trimmed)…”"
    }

    private static func closingMark(for character: Character) -> Character? {
        switch character {
        case "\u{201C}": return "\u{201D}"   // “ … ”
        case "\"": return "\""
        default: return nil
        }
    }

    /// Range from the opening mark to its closer, or nil if this opener doesn't start
    /// a usable quote — in which case the caller treats it as prose and carries on
    /// scanning *after* it, so a rejected opener can't swallow a real quote later in
    /// the sentence.
    private static func quoteRange(
        in source: String, openingAt opener: String.Index, closer: Character
    ) -> ClosedRange<String.Index>? {
        var index = source.index(after: opener)
        while index < source.endIndex {
            let character = source[index]
            // A blank line ends a paragraph; a quote mark on the other side of one
            // is a different quote, not this one's closer.
            if character == "\n",
               let next = source.index(index, offsetBy: 1, limitedBy: source.endIndex),
               next < source.endIndex, source[next] == "\n" {
                return nil
            }
            if character == closer {
                let length = source.distance(from: source.index(after: opener), to: index)
                guard length >= minimumLength, length <= maximumLength else { return nil }
                return opener...index
            }
            index = source.index(after: index)
        }
        return nil   // unclosed: still streaming, or not a quote at all
    }
}

/// The custom URL a quoted run carries so clicking it reaches the viewer.
///
/// SwiftUI has no click handler for part of a `Text`; a `.link` attribute is the only
/// way to make one run of a wrapped paragraph actionable without breaking the
/// paragraph into a stack of views. The card intercepts the scheme with an
/// `OpenURLAction` and passes real `https://` links in an answer straight through.
enum SourceLink {
    static let scheme = "claudepdf-source"

    static func url(quote: String) -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "quote"
        components.queryItems = [URLQueryItem(name: "q", value: quote)]
        return components.url
    }

    /// The quote inside one of our URLs, or nil if this is somebody else's link.
    static func quote(from url: URL) -> String? {
        guard url.scheme == scheme else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "q" })?.value
    }
}
