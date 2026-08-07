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
enum LaTeXNormalizer {

    /// Environments SwiftMath understands, keyed by what a model is likely to write.
    private static let environmentAliases: [String: String] = [
        "align": "aligned", "align*": "aligned", "alignat": "aligned", "alignat*": "aligned",
        "gathered": "gather", "gather*": "gather", "multline": "gather", "multline*": "gather",
        "eqnarray*": "eqnarray", "split*": "split",
    ]

    /// Wrappers that carry no layout of their own — strip them and typeset the body.
    private static let transparentEnvironments = ["equation*", "equation", "displaymath", "math"]

    private static let commandAliases: [String: String] = [
        "\\dfrac": "\\frac", "\\tfrac": "\\frac", "\\thinspace": "\\,", "\\lparen": "(", "\\rparen": ")",
    ]

    /// Commands that only matter in a real LaTeX document and make the parser fail here.
    private static let droppedCommands = ["\\nonumber", "\\notag", "\\displaystyle", "\\limits", "\\!"]

    static func normalize(_ latex: String) -> String {
        var text = latex

        for environment in transparentEnvironments {
            text = text.replacingOccurrences(of: "\\begin{\(environment)}", with: "")
            text = text.replacingOccurrences(of: "\\end{\(environment)}", with: "")
        }
        for (from, to) in environmentAliases {
            text = text.replacingOccurrences(of: "\\begin{\(from)}", with: "\\begin{\(to)}")
            text = text.replacingOccurrences(of: "\\end{\(from)}", with: "\\end{\(to)}")
        }
        text = stripArguments(of: ["\\label", "\\tag", "\\tag*"], in: text)
        for command in droppedCommands {
            text = text.replacingOccurrences(of: command, with: "")
        }
        for (from, to) in commandAliases {
            text = text.replacingOccurrences(of: from, with: to)
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes `\label{…}`-style calls, brace argument included.
    private static func stripArguments(of commands: [String], in text: String) -> String {
        var result = text
        for command in commands {
            while let range = result.range(of: command + "{") {
                var depth = 1
                var index = range.upperBound
                while index < result.endIndex, depth > 0 {
                    if result[index] == "{" { depth += 1 }
                    if result[index] == "}" { depth -= 1 }
                    index = result.index(after: index)
                }
                result.removeSubrange(range.lowerBound..<index)
            }
        }
        return result
    }
}
