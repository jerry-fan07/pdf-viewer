import AppKit
import SwiftMath
import SwiftUI

/// Typesets a LaTeX run into an image so it can sit inline inside a SwiftUI `Text`.
///
/// Images rather than a live `NSViewRepresentable`: inline math has to flow *within* a
/// wrapped paragraph ("where \(x\) is the mean"), and the only way to do that in SwiftUI
/// is `Text(Image(…))` concatenation. The image is created with a drawing handler, so it
/// is resolution-independent — re-rasterised at the device scale instead of being a 1×
/// bitmap stretched on Retina.
@MainActor
enum MathRenderer {

    struct Rendered {
        let image: NSImage
        /// Points of the image that hang below the math baseline. Feeds `.baselineOffset`
        /// so an inline `\frac` or `x_1` sits on the prose baseline instead of floating.
        let descent: CGFloat
    }

    private struct Key: Hashable {
        let latex: String
        let fontSize: CGFloat
        let display: Bool
        let dark: Bool
    }

    private static var cache: [Key: Rendered] = [:]
    private static var failed: Set<Key> = []

    /// Nil when the run is not valid LaTeX — callers fall back to showing the source.
    static func render(latex: String, fontSize: CGFloat, display: Bool, colorScheme: ColorScheme) -> Rendered? {
        let key = Key(latex: latex, fontSize: fontSize, display: display, dark: colorScheme == .dark)
        if let hit = cache[key] { return hit }
        if failed.contains(key) { return nil }

        guard let rendered = build(key) else {
            failed.insert(key)
            return nil
        }
        // Streaming re-renders the answer on every delta, so a cache is required, not an
        // optimisation. Partial runs churn keys; a flat cap keeps that bounded.
        if cache.count > 512 { cache.removeAll() }
        cache[key] = rendered
        return rendered
    }

    private static func build(_ key: Key) -> Rendered? {
        let label = MTMathUILabel()
        label.fontSize = key.fontSize
        label.labelMode = key.display ? .display : .text
        label.textAlignment = .left
        label.contentInsets = MTEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        label.textColor = textColor(dark: key.dark)
        label.displayErrorInline = false
        label.latex = LaTeXNormalizer.normalize(key.latex)
        guard label.error == nil else { return nil }

        // `fittingSize`, not `intrinsicContentSize`: SwiftMath only overrides the latter on
        // iOS, so on macOS it returns NSView's (-1, -1) and every equation silently fails.
        var size = label.fittingSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0.5, size.height > 0.5 else { return nil }
        // The label floors its own layout box at half the font size and centres within it;
        // match that or short runs come out off-baseline.
        size.height = max(size.height, key.fontSize / 2)

        // The display list — and the baseline it is positioned on — only exists after layout.
        // With this exact frame the label puts the baseline at y = descent, which is what
        // the image below is drawn against.
        label.frame = CGRect(origin: .zero, size: size)
        label.needsLayout = true
        label.layoutSubtreeIfNeeded()
        guard let display = label.displayList else { return nil }
        let descent = display.descent

        // Capture the display list, not the label: the handler may run off the main thread.
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            display.draw(context)
            context.restoreGState()
            return true
        }
        return Rendered(image: image, descent: descent)
    }

    /// Resolved eagerly for the target appearance: the drawing handler runs later, outside
    /// any appearance context, so a dynamic `NSColor` would resolve to the wrong shade.
    private static func textColor(dark: Bool) -> NSColor {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        var resolved = NSColor.labelColor
        appearance?.performAsCurrentDrawingAppearance {
            resolved = NSColor.labelColor.usingColorSpace(.sRGB) ?? NSColor.labelColor
        }
        return resolved
    }
}

/// Bridges the TeX models actually emit to the subset SwiftMath parses.
///
/// SwiftMath fails an equation *whole*: one `\operatorname` it doesn't know and the entire
/// display block falls back to raw source. So the cost of a missing alias is not a slightly
/// wrong glyph, it's a wall of TeX in the middle of an answer. Every entry below is a
/// command that was checked to fail against SwiftMath 1.7.3 and to have a near-equivalent
/// that renders; see `MathRendererTests`.
enum LaTeXNormalizer {

    /// Environments SwiftMath understands, keyed by what a model is likely to write.
    private static let environmentAliases: [String: String] = [
        "align": "aligned", "align*": "aligned", "alignat": "aligned", "alignat*": "aligned",
        "gathered": "gather", "gather*": "gather", "multline": "gather", "multline*": "gather",
        "eqnarray*": "eqnarray", "split*": "split",
    ]

    /// Wrappers that carry no layout of their own — strip them and typeset the body.
    private static let transparentEnvironments = ["equation*", "equation", "displaymath", "math"]

    /// `\cmd` → `\other`, applied in order: the argument (if any) is already braced, so
    /// swapping the command name is enough. `\operatorname*` has to precede `\operatorname`
    /// or the starred form is left as `\mathrm*`.
    private static let commandAliases: [(from: String, to: String)] = [
        ("\\operatorname*", "\\mathrm"), ("\\operatorname", "\\mathrm"),
        ("\\boldsymbol", "\\bm"), ("\\pmb", "\\bm"),
        ("\\mathscr", "\\mathcal"),          // no script face here; calligraphic is the near miss
        ("\\dfrac", "\\frac"), ("\\tfrac", "\\frac"),
        ("\\lVert", "\\|"), ("\\rVert", "\\|"), ("\\lvert", "|"), ("\\rvert", "|"),
        ("\\argmin", "\\arg\\min"), ("\\argmax", "\\arg\\max"),
        ("\\dots", "\\ldots"), ("\\dotsc", "\\ldots"), ("\\dotsb", "\\cdots"),
        ("\\lparen", "("), ("\\rparen", ")"),
        // No `\thinspace` → `\,` alias: this pass runs *after* `droppedCommands`, so an
        // alias that produces an explicit space would re-manufacture the atom dropped there.
    ]

    /// Commands whose braced argument has to go with them — dropping only the name would
    /// leave the argument typeset as stray italic letters. `\stackrel{d}{=}` keeps its
    /// *second* argument, which is what makes it degrade to a plain `=` rather than vanish.
    private static let rewrittenWithArgument: [(from: String, to: String)] = [
        ("\\label", ""), ("\\tag*", ""), ("\\tag", ""), ("\\phantom", ""),
        // `\hspace` becomes nothing rather than `\;`: explicit spaces are the trap below.
        ("\\hspace*", ""), ("\\hspace", ""), ("\\vspace*", ""), ("\\vspace", ""),
        ("\\xrightarrow", "\\to"), ("\\xleftarrow", "\\leftarrow"),
        ("\\stackrel", ""), ("\\overset", ""), ("\\underset", ""),
    ]

    /// Commands that only matter in a real LaTeX document, or whose only job is sizing that
    /// SwiftMath does for itself. The name goes; any braced argument stays and is typeset.
    private static let droppedCommands = [
        "\\nonumber", "\\notag", "\\displaystyle", "\\textstyle", "\\scriptstyle",
        "\\limits", "\\nolimits", "\\!", "\\substack", "\\mathop",
        "\\bigl", "\\bigr", "\\Bigl", "\\Bigr", "\\biggl", "\\biggr", "\\Biggl", "\\Biggr",
        "\\bigg", "\\Bigg", "\\big", "\\Big",
        // Explicit spaces, dropped rather than passed through, because SwiftMath 1.7.3 traps
        // on them. Its `MTMathList.finalized` treats a space atom as the previous atom when
        // deciding whether a `-` is a sign or a subtraction, but the typesetter skips spaces
        // without advancing *its* previous atom. So `= \, -y` reaches the spacing table as
        // (relation, binary operator), which is an `.invalid` pair: an assertion failure in
        // Debug — SIGTRAP, taking the app or the test process with it — and silently zero
        // spacing in Release. Models emit `\quad -x` and `= \, -1` freely, so this is not a
        // rare shape. The lost space is cosmetic and SwiftMath re-derives most of it from the
        // glyph classes anyway; the trap is not. `docs/swiftmath-finalized-space-fix.diff` is
        // the upstream fix, which is what to vendor if the exact spacing is ever wanted.
        "\\,", "\\;", "\\>", "\\quad", "\\qquad",
        // These are spaces in real LaTeX but no command at all in SwiftMath, so leaving them
        // in fails the whole equation to raw source rather than costing a space. (Aliasing
        // `\thinspace` to `\,` — what used to happen — would re-manufacture the trap above.)
        "\\:", "\\thinspace", "\\enspace",
    ]

    static func normalize(_ latex: String) -> String {
        var text = stripComments(latex)

        for environment in transparentEnvironments {
            text = text.replacingOccurrences(of: "\\begin{\(environment)}", with: "")
            text = text.replacingOccurrences(of: "\\end{\(environment)}", with: "")
        }
        for (from, to) in environmentAliases {
            text = text.replacingOccurrences(of: "\\begin{\(from)}", with: "\\begin{\(to)}")
            text = text.replacingOccurrences(of: "\\end{\(from)}", with: "\\end{\(to)}")
        }
        for (from, to) in rewrittenWithArgument {
            text = rewrite(from, withArgumentTo: to, in: text)
        }
        for command in droppedCommands {
            text = replaceCommand(command, with: "", in: text)
        }
        for (from, to) in commandAliases {
            text = replaceCommand(from, with: to, in: text)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Drops `%` to end of line, TeX's comment. SwiftMath has no notion of comments — it
    /// does not error on one, it silently typesets the prose after the `%` as italic math,
    /// which is worse. `\%` is a literal percent sign and survives.
    private static func stripComments(_ text: String) -> String {
        var out = ""
        var index = text.startIndex
        while index < text.endIndex {
            let c = text[index]
            if c == "\\", text.index(after: index) < text.endIndex {
                out.append(c)
                index = text.index(after: index)
                out.append(text[index])
                index = text.index(after: index)
                continue
            }
            if c == "%" {
                while index < text.endIndex, text[index] != "\n" { index = text.index(after: index) }
                continue                         // the newline itself is kept: it separates align rows
            }
            out.append(c)
            index = text.index(after: index)
        }
        return out
    }

    /// Textual command replacement that respects TeX's own tokenizing rule: a command name
    /// made of letters ends at the first non-letter. Without this, dropping `\big` also
    /// mangles `\bigcup` into `cup`, and aliasing `\dots` eats the `\dotsb` prefix.
    private static func replaceCommand(_ command: String, with replacement: String, in text: String) -> String {
        let needsBoundary = command.last?.isLetter ?? false
        var result = ""
        var index = text.startIndex
        while let range = text.range(of: command, range: index..<text.endIndex) {
            if needsBoundary, range.upperBound < text.endIndex, text[range.upperBound].isLetter {
                result.append(contentsOf: text[index..<range.upperBound])
                index = range.upperBound
                continue
            }
            result.append(contentsOf: text[index..<range.lowerBound])
            result.append(replacement)
            index = range.upperBound
        }
        result.append(contentsOf: text[index...])
        return result
    }

    /// Removes `\cmd{…}` — one balanced brace group — and puts `replacement` in its place.
    private static func rewrite(_ command: String, withArgumentTo replacement: String, in text: String) -> String {
        var result = text
        while let range = result.range(of: command + "{") {
            var depth = 1
            var index = range.upperBound
            while index < result.endIndex, depth > 0 {
                if result[index] == "{" { depth += 1 }
                if result[index] == "}" { depth -= 1 }
                index = result.index(after: index)
            }
            result.replaceSubrange(range.lowerBound..<index, with: replacement)
        }
        return result
    }
}
