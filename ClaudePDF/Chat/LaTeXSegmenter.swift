import Foundation

/// One piece of an assistant answer: Markdown prose, or a run of LaTeX.
enum AnswerSegment: Equatable {
    case text(String)
    case inlineMath(String)
    case displayMath(String)
}

/// Splits an answer into prose and math runs *before* anything reaches
/// `AttributedString(markdown:)`.
///
/// The ordering is the whole point. Markdown eats TeX: `\alpha` loses its backslash,
/// `x_1` and `a * b` turn into emphasis. Run Markdown first and the math is already
/// destroyed by the time any renderer sees it — so the math has to be carved out first.
///
/// Delimiters recognised (models emit all of them; Claude leans on `\(…\)` / `\[…\]`):
///   `$$…$$`, `\[…\]`, `\begin{align}…\end{align}` → display
///   `\(…\)`, `$…$`                                → inline
///
/// Deliberate rules:
///   • Unclosed delimiters stay prose. Mid-stream a lone `$$` must not flicker into a
///     half-parsed equation and back when the closer arrives a delta later.
///   • `$…$` requires non-space neighbours and a non-digit after the closer, so
///     "costs $5 and $6" stays money. A rejected opener is emitted as prose and the
///     scan resumes one character later, so "$5 per unit, so $x = 5n$" still finds
///     the real math further along.
///   • Backtick code spans pass through untouched — `$x$` inside code is code.
enum LaTeXSegmenter {

    static func segments(in source: String) -> [AnswerSegment] {
        let chars = Array(source)
        var out: [AnswerSegment] = []
        var prose = ""
        var i = 0

        func flushProse() {
            guard !prose.isEmpty else { return }
            out.append(.text(prose))
            prose = ""
        }

        while i < chars.count {
            let c = chars[i]

            // Code spans are opaque: whatever is between the backticks is literal.
            if c == "`" {
                var fenceLength = 0
                while i + fenceLength < chars.count && chars[i + fenceLength] == "`" { fenceLength += 1 }
                let fence = [Character](repeating: "`", count: fenceLength)
                if let close = find(fence, in: chars, from: i + fenceLength) {
                    prose.append(contentsOf: chars[i..<(close + fenceLength)])
                    i = close + fenceLength
                } else {
                    prose.append(contentsOf: fence)
                    i += fenceLength
                }
                continue
            }

            if c == "\\", i + 1 < chars.count {
                let next = chars[i + 1]

                if next == "[", let close = find(["\\", "]"], in: chars, from: i + 2) {
                    flushProse()
                    out.append(.displayMath(String(chars[(i + 2)..<close])))
                    i = close + 2
                    continue
                }
                if next == "(", let close = find(["\\", ")"], in: chars, from: i + 2) {
                    flushProse()
                    out.append(.inlineMath(String(chars[(i + 2)..<close])))
                    i = close + 2
                    continue
                }
                if next == "b", let environment = mathEnvironment(in: chars, at: i) {
                    flushProse()
                    out.append(.displayMath(String(chars[i..<environment.end])))
                    i = environment.end
                    continue
                }
                // An escape (`\$`, `\\`, `` \` ``) — copy both characters so the escape
                // survives into the Markdown pass and the `$` is not read as a delimiter.
                prose.append(c)
                prose.append(next)
                i += 2
                continue
            }

            if c == "$", i + 1 < chars.count, chars[i + 1] == "$" {
                if let close = find(["$", "$"], in: chars, from: i + 2), close > i + 2 {
                    flushProse()
                    out.append(.displayMath(String(chars[(i + 2)..<close])))
                    i = close + 2
                    continue
                }
                prose.append("$")
                prose.append("$")
                i += 2
                continue
            }

            if c == "$", let close = inlineDollarClose(chars, openAt: i) {
                flushProse()
                out.append(.inlineMath(String(chars[(i + 1)..<close])))
                i = close + 1
                continue
            }

            prose.append(c)
            i += 1
        }

        flushProse()
        return out
    }

    // MARK: - Helpers

    private static func find(_ needle: [Character], in chars: [Character], from start: Int) -> Int? {
        guard !needle.isEmpty, chars.count >= needle.count else { return nil }
        var i = max(0, start)
        while i <= chars.count - needle.count {
            var k = 0
            while k < needle.count && chars[i + k] == needle[k] { k += 1 }
            if k == needle.count { return i }
            i += 1
        }
        return nil
    }

    /// Index of a valid closing `$` for an opener at `open`, or nil if this `$` is money.
    private static func inlineDollarClose(_ chars: [Character], openAt open: Int) -> Int? {
        guard open + 1 < chars.count else { return nil }
        let first = chars[open + 1]
        guard !first.isWhitespace, first != "$" else { return nil }

        var j = open + 1
        var pendingNewline = false
        while j < chars.count {
            let c = chars[j]
            if c == "\\" {
                j += 2                          // skip the escaped character, incl. `\$`
                continue
            }
            if c == "\n" {
                if pendingNewline { return nil } // a blank line ends any inline run
                pendingNewline = true
                j += 1
                continue
            }
            if !c.isWhitespace { pendingNewline = false }
            if c == "$" {
                let previous = chars[j - 1]
                let following = j + 1 < chars.count ? chars[j + 1] : nil
                guard j > open + 1, !previous.isWhitespace, !(following?.isNumber ?? false) else {
                    return nil                   // not a closer ⇒ treat the opener as money
                }
                return j
            }
            j += 1
        }
        return nil
    }

    /// Environments a model may emit bare, with no surrounding `$$`.
    private static let mathEnvironments: Set<String> = [
        "equation", "equation*", "displaymath", "align", "align*", "aligned",
        "alignat", "alignat*", "gather", "gather*", "gathered", "multline", "multline*",
        "split", "eqnarray", "eqnarray*", "cases", "array", "displaylines", "eqalign",
        "matrix", "pmatrix", "bmatrix", "Bmatrix", "vmatrix", "Vmatrix", "smallmatrix",
    ]

    /// Matches `\begin{env}` at `start` against a closing `\end{env}`.
    /// Returns the index one past the `\end{env}`.
    private static func mathEnvironment(in chars: [Character], at start: Int) -> (name: String, end: Int)? {
        let begin = Array("\\begin{")
        guard start + begin.count < chars.count else { return nil }
        for (offset, expected) in begin.enumerated() {
            guard chars[start + offset] == expected else { return nil }
        }

        var j = start + begin.count
        var name = ""
        while j < chars.count, chars[j] != "}", chars[j] != "\n" {
            name.append(chars[j])
            j += 1
        }
        guard j < chars.count, chars[j] == "}", mathEnvironments.contains(name) else { return nil }

        guard let close = find(Array("\\end{\(name)}"), in: chars, from: j + 1) else { return nil }
        return (name, close + "\\end{\(name)}".count)
    }
}
