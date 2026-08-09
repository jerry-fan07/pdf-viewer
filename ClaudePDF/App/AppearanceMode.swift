import SwiftUI

/// How a window renders: chrome *and* pages, together.
///
/// The two used to be separate — the window followed the system while only the pages were
/// darkened — but a dark toolbar around a bright page and a bright toolbar around a dark one
/// are both halfway states nobody asked for. One switch now moves the whole window, so ⇧⌘D
/// reads as "night" rather than "invert the paper".
///
/// Per *window*, not per app: this is what the reader chose for the document in front of
/// them, and `DocumentWindow` applies it with `preferredColorScheme` rather than by setting
/// `NSApp.appearance`, which would drag every other open document along with it. Settings
/// holds the mode a window opens with.
///
/// The cost of collapsing them is that *Always light* is now light everywhere, including at
/// night on a dark system. That is the escape hatch for documents the page filter mangles
/// (photographs come out as negatives), so it stays available — it just takes the window
/// with it.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case matchSystem
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .matchSystem: return "Match system"
        case .light:       return "Always light"
        case .dark:        return "Always dark"
        }
    }

    /// What the window's colour scheme is forced to — `nil` for "don't force it".
    ///
    /// `matchSystem` *must* be nil rather than a resolved `.light`/`.dark`. The window's scheme
    /// is where `darkPages(system:)` reads its `system` from, so forcing it would feed the
    /// answer back into the question: a window darkened once at night would report itself dark
    /// forever and never come back at sunrise. Nil leaves that loop open. In the other two
    /// cases the answer doesn't depend on the input at all, so there is nothing to latch.
    var preferredColorScheme: ColorScheme? {
        switch self {
        case .matchSystem: return nil
        case .light:       return .light
        case .dark:        return .dark
        }
    }

    /// Whether pages should be darkened in a window running under `system`.
    func darkPages(system: ColorScheme) -> Bool {
        switch self {
        case .matchSystem: return system == .dark
        case .light:       return false
        case .dark:        return true
        }
    }
}
