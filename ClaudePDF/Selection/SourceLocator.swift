import Foundation
import PDFKit

/// Where a quoted passage was found in the document.
struct SourceMatch {
    let selection: PDFSelection
    let pageNumber: Int      // 1-indexed
    /// True when only part of the quote could be matched (the tail was dropped to
    /// find it). The reader still lands on the right passage; the flash is shorter.
    let isPartial: Bool
}

/// Finds a passage an answer quoted back at us inside the PDF, so the viewer can
/// scroll to it and flash it — the difference between "trust me" and "look".
///
/// `PDFDocument.findString` is not enough on its own: it matches the *extracted*
/// characters exactly, and a model's quote almost never is those characters. The
/// page has a line break where the quote has a space, a hyphen where the quote has
/// a whole word, `“smart quotes”` where the quote has `"straight"` ones, an `ﬁ`
/// ligature where the quote has `fi`. So each page is normalised into a canonical
/// form, the quote is normalised the same way, and the match is mapped back to the
/// page's own UTF-16 offsets through an index built alongside the normalisation.
/// `PDFPage.selection(for:)` turns that range into something PDFKit can highlight.
///
/// Deliberate limits, so the failure modes are predictable:
///   • **Dehyphenation is lossy.** `inter-\nnational` normalises to `international`,
///     and so does a genuine compound broken across a line — `well-\nknown` becomes
///     `wellknown`, which a quote saying "well-known" will not match. Rather than
///     guess, the shortening fallback below absorbs the miss.
///   • **A quote spanning a page break is not stitched.** Matching is per page; the
///     shortening fallback finds the part that lives on the first page, which is the
///     right thing to scroll to anyway.
///   • **A quote that was paraphrased is not found**, by design. A fuzzy match that
///     highlighted an approximately-similar sentence would be worse than nothing:
///     the whole point of the feature is that the highlight is evidence.
enum SourceLocator {
    /// Below this, a "quote" is a word or two — it would match all over the document
    /// and highlight something arbitrary.
    static let minimumMatchLength = 12

    /// Ceiling on how far the shortening fallback may cut. A quote whittled down to
    /// its first few words is still the right passage; whittled below this it is a
    /// coin flip.
    static let minimumFallbackWords = 4

    static func locate(
        _ quote: String,
        in document: PDFDocument,
        index: PDFTextIndex,
        nearPage: Int? = nil
    ) -> SourceMatch? {
        let needle = TextNormalizer.normalize(quote).text
        guard needle.count >= minimumMatchLength else { return nil }

        let pages = pageOrder(pageCount: document.pageCount, hint: nearPage)
        for (offset, variant) in variants(of: needle).enumerated() {
            for pageNumber in pages {
                guard let page = document.page(at: pageNumber - 1),
                      let range = index.range(of: variant, onPage: pageNumber, page: page),
                      let selection = page.selection(for: range) else { continue }
                return SourceMatch(
                    selection: selection, pageNumber: pageNumber, isPartial: offset > 0
                )
            }
        }
        return nil
    }

    /// The page the reader was told to look at first, then its neighbours (a passage
    /// cited as "p. 12" often starts at the foot of 11), then everything else in order.
    static func pageOrder(pageCount: Int, hint: Int?) -> [Int] {
        let all = Array(1...max(pageCount, 1))
        guard let hint, pageCount > 0 else { return pageCount > 0 ? all : [] }
        let near = [hint, hint + 1, hint - 1, hint + 2, hint - 2].filter { $0 >= 1 && $0 <= pageCount }
        return near + all.filter { !near.contains($0) }
    }

    /// Progressively less demanding forms of the same quote. The full quote is tried
    /// against every page before any shortened form is tried against any page, so a
    /// complete match anywhere always beats a partial match on the hinted page.
    ///
    /// Two things get relaxed, in order: an elision (`"the first bit … the last bit"`
    /// matches nothing verbatim, but its longest segment does), then the tail — models
    /// tack a word onto the end of a quote far more often than onto the front.
    static func variants(of needle: String) -> [String] {
        var out = [needle]

        // Both spellings of an elision arrive here as "..." — the normaliser expands
        // "…" so a page and a quote that spell it differently still line up.
        let segments = needle
            .components(separatedBy: "...")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count >= minimumMatchLength }
        if segments.count > 1 {
            out += segments.sorted { $0.count > $1.count }
        }

        var words = (segments.max(by: { $0.count < $1.count }) ?? needle)
            .split(separator: " ")
            .map(String.init)
        while words.count > minimumFallbackWords {
            words.removeLast()
            let shortened = words.joined(separator: " ")
            guard shortened.count >= minimumMatchLength else { break }
            out.append(shortened)
        }

        return out
    }
}

// MARK: - Per-document normalised text

/// Lazily normalised page text, one entry per page, so clicking quote after quote in
/// a long answer does not re-normalise the document each time.
///
/// Per page rather than per document on purpose: a 600-page PDF should pay nothing at
/// open, and a reader only ever touches a handful of its pages.
final class PDFTextIndex {
    private var pages: [Int: TextNormalizer.Normalized] = [:]

    init() {}

    /// UTF-16 range on the page's own string, or nil if the normalised needle isn't there.
    func range(of needle: String, onPage pageNumber: Int, page: PDFPage) -> NSRange? {
        let normalized = self[pageNumber, page]
        guard let found = normalized.text.range(of: needle) else { return nil }
        let start = normalized.text.distance(from: normalized.text.startIndex, to: found.lowerBound)
        let end = normalized.text.distance(from: normalized.text.startIndex, to: found.upperBound)
        return normalized.sourceRange(from: start, to: end)
    }

    subscript(pageNumber: Int, page: PDFPage) -> TextNormalizer.Normalized {
        if let cached = pages[pageNumber] { return cached }
        let built = TextNormalizer.normalize(page.string ?? "")
        pages[pageNumber] = built
        return built
    }
}

// MARK: - Normalisation

/// Folds PDF-extracted text and a model's quote onto the same canonical form, keeping
/// a map back to where every canonical character came from.
enum TextNormalizer {
    /// Canonical text plus, for each of its characters, the UTF-16 span of the source
    /// character that produced it. One source character can produce several canonical
    /// ones (`ﬁ` → `fi`) or none (a soft hyphen), which is exactly why this is a map
    /// and not an offset.
    struct Normalized {
        let text: String
        private let starts: [Int]
        private let ends: [Int]

        init(text: String, starts: [Int], ends: [Int]) {
            self.text = text
            self.starts = starts
            self.ends = ends
        }

        /// Canonical character offsets → a range on the source string.
        func sourceRange(from start: Int, to end: Int) -> NSRange? {
            guard start >= 0, end > start, end <= starts.count else { return nil }
            let location = starts[start]
            let upper = ends[end - 1]
            guard upper > location else { return nil }
            return NSRange(location: location, length: upper - location)
        }
    }

    static func normalize(_ source: String) -> Normalized {
        var text = String()
        var starts: [Int] = []
        var ends: [Int] = []
        text.reserveCapacity(source.count)

        var offset = 0                 // UTF-16 offset of the character being read
        var pendingHyphen: (start: Int, end: Int)? = nil   // a hyphen that may be a line break
        var lastWasSpace = true        // leading whitespace is dropped, not turned into a space

        for character in source {
            let length = character.utf16.count
            let start = offset
            offset += length

            if character.isWhitespace || character.isNewline {
                // A hyphen immediately before a line break is a hyphenation artefact:
                // "inter-\nnational" is one word on the page.
                if pendingHyphen != nil, character.isNewline {
                    pendingHyphen = nil
                    lastWasSpace = false
                    continue
                }
                flush(&pendingHyphen, into: &text, &starts, &ends)
                if !lastWasSpace {
                    append(" ", from: start, to: offset, into: &text, &starts, &ends)
                    lastWasSpace = true
                }
                continue
            }

            flush(&pendingHyphen, into: &text, &starts, &ends)

            if character == "\u{00AD}" { continue }        // soft hyphen: never real text
            if isHyphen(character) {
                // Held back one character: only a *line-breaking* hyphen disappears.
                pendingHyphen = (start, offset)
                lastWasSpace = false
                continue
            }

            let folded = fold(character)
            if folded.isEmpty { continue }
            append(folded, from: start, to: offset, into: &text, &starts, &ends)
            lastWasSpace = false
        }
        flush(&pendingHyphen, into: &text, &starts, &ends)

        // A trailing space would make a needle ending in one fail against a page that
        // ends without it, and buys nothing.
        while text.last == " " {
            text.removeLast()
            starts.removeLast()
            ends.removeLast()
        }

        return Normalized(text: text, starts: starts, ends: ends)
    }

    /// Canonical form of one character: case-folded, with the punctuation a PDF and a
    /// chat model spell differently mapped onto one spelling, and ligatures expanded.
    private static func fold(_ character: Character) -> String {
        switch character {
        case "\u{201C}", "\u{201D}", "\u{201E}", "\u{00AB}", "\u{00BB}": return "\""
        case "\u{2018}", "\u{2019}", "\u{201A}", "\u{2032}": return "'"
        case "\u{2013}", "\u{2014}", "\u{2212}": return "-"
        case "\u{2026}": return "..."     // one spelling of an elision, so quotes and pages agree
        case "\u{00A0}", "\u{2007}", "\u{202F}": return " "
        case "\u{FB00}": return "ff"
        case "\u{FB01}": return "fi"
        case "\u{FB02}": return "fl"
        case "\u{FB03}": return "ffi"
        case "\u{FB04}": return "ffl"
        default:
            let lowered = character.lowercased()
            // Diacritic folding keeps "café" in an answer matching "cafe" on a page
            // that lost its accents in extraction — but only when it doesn't change
            // the character count, so the source map stays one-to-one.
            let folded = lowered.folding(options: [.diacriticInsensitive], locale: nil)
            return folded.count == lowered.count ? folded : lowered
        }
    }

    private static func isHyphen(_ character: Character) -> Bool {
        character == "-" || character == "\u{2010}" || character == "\u{2011}"
    }

    private static func flush(
        _ pending: inout (start: Int, end: Int)?,
        into text: inout String, _ starts: inout [Int], _ ends: inout [Int]
    ) {
        guard let hyphen = pending else { return }
        pending = nil
        append("-", from: hyphen.start, to: hyphen.end, into: &text, &starts, &ends)
    }

    private static func append(
        _ fragment: String, from start: Int, to end: Int,
        into text: inout String, _ starts: inout [Int], _ ends: inout [Int]
    ) {
        for character in fragment {
            text.append(character)
            starts.append(start)
            ends.append(end)
        }
    }
}
