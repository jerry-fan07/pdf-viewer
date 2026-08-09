import Foundation

/// Picks the page numbers an answer names in its own prose — "see page 12",
/// "(pp. 3–5)" — so they can be shown and jumped to alongside the provider's
/// API-native citations.
///
/// This exists because only one of the three providers has citations at all.
/// `AnthropicProvider` declares `supportsCitations: true` and its stream turns
/// `citations_delta` into `Citation` values; the Claude Code CLI and DeepSeek paths
/// declare `false` and are *asked in the prompt* to "reference page numbers inline"
/// instead (`ClaudeCodePrompt.ask`). Reading only `card.citations` therefore left the
/// panel's "pages cited by this conversation" strip structurally empty on two of the
/// three paths, and blind to prose mentions on the third.
///
/// Read back out of the answer text — once, in `QACard.finish()` — rather than
/// emitted as synthetic `Citation` events on purpose: nothing has to be parsed twice
/// in two providers' streams, nothing fabricated reaches `HistoryStore`, and every
/// transcript already saved to disk gains its pages the moment it is reopened.
///
/// The rules are conservative for the same reason `AnswerQuotes`' are — a page chip
/// that jumps somewhere the answer never mentioned is worse than no chip:
///   • **A marker word is required.** `page`, `pages`, `p.`, `pp.`, at a word
///     boundary, so "app. 4" and "chap. 4" are not page references.
///   • **The number must follow the marker.** "a 12-page proof" and "3 pages" name no
///     page; neither does a bare "page".
///   • **Code is opaque.** A `p. 12` inside backticks or a fenced block belongs to the
///     code, not the prose.
///   • **A list needs the plural.** "pages 3, 5 and 9" is a list; "page 3, 12 of the
///     subjects dropped out" is a sentence carrying on past a single page.
///   • **A spaced dash is a pause, not a range.** A typeset range is closed up
///     (`3–5`); "page 3 — 12 trials were excluded" is prose.
///   • **A long range is not expanded.** "the whole argument (pp. 1–45)" would
///     otherwise paint the entire histogram, so only its endpoints are taken.
enum PageReferences {
    /// Longest range spelt out page by page. A handful of pages is a citation; forty
    /// is a gesture at the document, and expanding it says "cited" about every page in
    /// between.
    static let maximumRangeSpan = 10

    /// A number longer than this is a year, a token count or an equation number that
    /// happens to sit after the word "page" — not a page in any document we can open.
    private static let maximumDigits = 5

    /// Every page the prose names, unique and ascending. Not filtered against the
    /// document: the caller knows the page count and drops what is out of range, so a
    /// model that invents "page 300" of a 40-page paper gets nothing rather than the
    /// last page.
    static func pages(in source: String) -> [Int] {
        var found = Set<Int>()
        let scalars = Array(source)
        var index = 0

        while index < scalars.count {
            if scalars[index] == "`" {
                index = endOfCode(in: scalars, startingAt: index)
                continue
            }
            guard let marker = marker(in: scalars, at: index) else {
                index += 1
                continue
            }
            let (pages, next) = numbers(
                in: scalars, startingAt: marker.end, allowsList: marker.isPlural
            )
            found.formUnion(pages)
            // Carry on from where the numbers stopped, never from before the marker:
            // "pages" must not be re-read as "page".
            index = max(next, marker.end)
        }

        return found.sorted()
    }

    // MARK: Scanning

    /// A `page` / `pages` / `p.` / `pp.` marker starting here: where it ends, and
    /// whether it was the plural. The preceding character must not be alphanumeric,
    /// which is what keeps "app. 4" and "chap. 4" out.
    private static func marker(
        in scalars: [Character], at index: Int
    ) -> (end: Int, isPlural: Bool)? {
        if index > 0, scalars[index - 1].isLetter || scalars[index - 1].isNumber { return nil }
        // Longest first: "pages" before "page", "pp." before "p.".
        for (word, isPlural) in [("pages", true), ("page", false), ("pp.", true), ("p.", false)] {
            let end = index + word.count
            guard end <= scalars.count else { continue }
            guard String(scalars[index..<end]).lowercased() == word else { continue }
            // A word marker has to end at a word boundary; "pagerank 3" is not a page.
            if word == "pages" || word == "page" {
                if end < scalars.count, scalars[end].isLetter || scalars[end].isNumber { continue }
            }
            return (end, isPlural)
        }
        return nil
    }

    /// The numbers after a marker: `12`, `3–5`, and — after a plural marker only —
    /// `7, 9 and 11`. Returns the pages and the index it stopped at.
    ///
    /// A list is refused after the singular because a comma after a single page is
    /// almost always the sentence carrying on: "See page 3, 12 of the subjects dropped
    /// out" names one page, not two. A writer naming several uses the plural.
    private static func numbers(
        in scalars: [Character], startingAt start: Int, allowsList: Bool
    ) -> ([Int], Int) {
        var pages: [Int] = []
        var index = skipSpaces(in: scalars, from: start)

        while let (first, afterFirst) = integer(in: scalars, at: index) {
            index = afterFirst
            var span = [first]

            if let (last, afterLast) = rangeEnd(in: scalars, at: index), last > first {
                index = afterLast
                span = last - first <= maximumRangeSpan ? Array(first...last) : [first, last]
            }
            pages += span

            guard allowsList else { break }
            // "7, 9 and 11" — only continue when another number actually follows, so
            // "pages 7 and the appendix" stops here.
            guard let afterList = listSeparator(in: scalars, at: skipSpaces(in: scalars, from: index)) else {
                break
            }
            let numberStart = skipSpaces(in: scalars, from: afterList)
            guard integer(in: scalars, at: numberStart) != nil else { break }
            index = numberStart
        }

        return (pages, index)
    }

    /// The far end of a range starting at the number that ends here — `3–5`, `3-5`,
    /// `3 to 5` — or nil if this isn't one.
    ///
    /// A dash range must be written closed up, the way a typeset range is. A *spaced*
    /// dash is a prose pause: "See page 3 — 12 trials were excluded" would otherwise
    /// ink ten bars for a sentence that named one page.
    private static func rangeEnd(in scalars: [Character], at index: Int) -> (Int, Int)? {
        if let afterDash = dash(in: scalars, at: index) {
            return integer(in: scalars, at: afterDash)
        }
        let afterSpaces = skipSpaces(in: scalars, from: index)
        guard afterSpaces > index, let afterWord = word("to", in: scalars, at: afterSpaces) else {
            return nil
        }
        let numberStart = skipSpaces(in: scalars, from: afterWord)
        guard numberStart > afterWord else { return nil }
        return integer(in: scalars, at: numberStart)
    }

    private static func integer(in scalars: [Character], at index: Int) -> (Int, Int)? {
        var end = index
        while end < scalars.count, scalars[end].isASCII, scalars[end].isNumber { end += 1 }
        // The whole run is measured before it is cut: reading the first five digits of
        // a longer number would turn "page 123456" into page 12345.
        guard end > index, end - index <= maximumDigits else { return nil }
        guard let value = Int(String(scalars[index..<end])), value > 0 else { return nil }
        // "12th" and "12-page" are ordinals and compounds; "30%" is a proportion. None
        // of them is a page, however close to the word "page" they were written.
        if end < scalars.count, scalars[end].isLetter || scalars[end] == "%" { return nil }
        return (value, end)
    }

    /// Whitespace, but never across a blank line — a "page" ending one paragraph and a
    /// number opening the next are two different things.
    private static func skipSpaces(in scalars: [Character], from index: Int) -> Int {
        var cursor = index
        var newlines = 0
        while cursor < scalars.count, scalars[cursor].isWhitespace {
            if scalars[cursor].isNewline {
                newlines += 1
                if newlines > 1 { return index }
            }
            cursor += 1
        }
        return cursor
    }

    private static func dash(in scalars: [Character], at index: Int) -> Int? {
        guard index < scalars.count else { return nil }
        switch scalars[index] {
        case "-", "\u{2013}", "\u{2014}", "\u{2212}": return index + 1
        default: return nil
        }
    }

    private static func word(_ word: String, in scalars: [Character], at index: Int) -> Int? {
        let end = index + word.count
        guard end <= scalars.count,
              String(scalars[index..<end]).lowercased() == word else { return nil }
        return end
    }

    private static func listSeparator(in scalars: [Character], at index: Int) -> Int? {
        guard index < scalars.count else { return nil }
        if scalars[index] == "," || scalars[index] == "&" {
            // "pp. 3, and 5" — one separator may follow another.
            let next = skipSpaces(in: scalars, from: index + 1)
            return listSeparator(in: scalars, at: next) ?? index + 1
        }
        return word("and", in: scalars, at: index)
    }

    /// Index just past a code span or fenced block opening here. An unclosed one runs
    /// to the end, the same call `AnswerQuotes` makes: half-arrived code is still code.
    private static func endOfCode(in scalars: [Character], startingAt index: Int) -> Int {
        let fence = "```"
        let isFence = index + fence.count <= scalars.count
            && String(scalars[index..<(index + fence.count)]) == fence
        let marker = isFence ? fence : "`"
        var cursor = index + marker.count
        while cursor + marker.count <= scalars.count {
            if String(scalars[cursor..<(cursor + marker.count)]) == marker {
                return cursor + marker.count
            }
            cursor += 1
        }
        return scalars.count
    }
}

// MARK: - What one card points at

extension QACard {
    /// Every page this card sends the reader to: the provider's own citations, plus the
    /// pages the answer names in prose. Unique and ascending.
    ///
    /// `pageCount` is the document's, and pages outside it are dropped rather than
    /// clamped — "page 300" of a 40-page paper is a mistake, and page 40 is not a
    /// better answer than none. Passing 0 (the document hasn't finished loading)
    /// filters nothing.
    func citedPages(inDocumentOf pageCount: Int) -> [Int] {
        var pages = Set(citations.map(\.page))
        pages.formUnion(namedPages)
        guard pageCount > 0 else { return pages.sorted() }
        return pages.filter { (1...pageCount).contains($0) }.sorted()
    }

    /// Pages named in the prose that no citation already covers — the chips the source
    /// line adds after the citation chips, so the two never say "p. 12" twice.
    func prosePages(inDocumentOf pageCount: Int) -> [Int] {
        let cited = Set(citations.map(\.page))
        let pages = namedPages.filter { !cited.contains($0) }
        guard pageCount > 0 else { return pages }
        return pages.filter { (1...pageCount).contains($0) }
    }
}
