import AppKit
import SwiftUI

/// The chat panel's palette (design 5A): one greyscale ink ramp and three hairline
/// weights, no boxes, no accent colour. Every value is a dynamic `NSColor` so the
/// panel follows its window through ⇧⌘D rather than staying a sheet of white paper
/// in a dark window — the design is drawn light-only, so the dark side of each pair
/// is chosen here, not there.
enum PanelInk {
    /// Panel paper. Slightly off pure white/black, like the design's #FCFCFC.
    static let background = dynamic(0xFCFCFC, 0x1D1D1F)
    /// Full-strength ink: questions, the current answer's dot, cited-page bars.
    static let ink = dynamic(0x111112, 0xE8E8EA)
    /// Answer prose — a step down from the questions, which carry the structure.
    static let prose = dynamic(0x4A4A4E, 0xB6B6BC)
    /// Captions, citations, usage lines.
    static let faint = dynamic(0xA0A0A4, 0x7C7C83)
    /// Placeholder text and axis extremes.
    static let fainter = dynamic(0xB4B4B8, 0x6C6C72)
    /// The quietest mark that is still a mark: hollow dots, the current-page bar.
    static let dim = dynamic(0xC6C6C8, 0x5A5A60)
    /// The left rule on a quoted passage.
    static let quoteRule = dynamic(0xD8D8DA, 0x48484D)
    /// Between answers, and the timeline rail.
    static let hairline = dynamic(0xECECEC, 0x2B2B2E)
    /// Full-bleed rules fencing the transcript off from header and composer.
    static let hairlineEdge = dynamic(0xE9E9E9, 0x303033)
    /// Uncited-page bars and image borders — hairlines that must read as shapes.
    static let hairlineStrong = dynamic(0xE4E4E4, 0x38383C)

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
    }
}
