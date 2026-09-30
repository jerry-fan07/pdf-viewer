import AppKit
import SwiftUI

/// The workspace palette: neutral greys for every surface, one blue for "this is
/// selected / this is the action". Every value is a light/dark pair so the chrome
/// follows the window through ⇧⌘D.
enum ChromeInk {
    /// Top bar, rails, status bar.
    static let bar = dynamic(0xFFFFFF, 0x2A2A2C)
    /// Side panels.
    static let panel = dynamic(0xFAFAFA, 0x232325)
    /// Behind the pages.
    static let canvas = dynamic(0xE3E4E6, 0x161617)
    /// The same desk for PDFKit, which is handed the *light* one only: dark pages
    /// get their surround from the darkening filter, which inverts what it is given.
    static let canvasLightNS = rgb(0xE3E4E6)
    /// Raised surfaces over the canvas — the quick-tool palette.
    static let raised = dynamic(0xFFFFFF, 0x323235)

    static let divider = dynamic(0xE1E1E3, 0x3A3A3D)
    static let dividerStrong = dynamic(0xCFCFD2, 0x4A4A4E)

    static let text = dynamic(0x1D1D1F, 0xE8E8EA)
    static let secondary = dynamic(0x6B6B70, 0xA1A1A6)
    static let tertiary = dynamic(0x9B9BA0, 0x6E6E73)

    static let accent = dynamic(0x1473E6, 0x4B9CF5)
    static let accentSoft = dynamicAlpha(0x1473E6, 0.10, 0x4B9CF5, 0.18)
    static let hover = dynamicAlpha(0x000000, 0.055, 0xFFFFFF, 0.07)
    static let pressed = dynamicAlpha(0x000000, 0.10, 0xFFFFFF, 0.12)
    /// Text fields and the question well.
    static let well = dynamic(0xF2F2F4, 0x1C1C1E)

    static let barHeight: CGFloat = 40
    static let statusHeight: CGFloat = 24
    static let railWidth: CGFloat = 44

    private static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: nsDynamic(light, dark))
    }

    private static func dynamicAlpha(_ light: UInt32, _ lightAlpha: CGFloat,
                                     _ dark: UInt32, _ darkAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        })
    }

    private static func nsDynamic(_ light: UInt32, _ dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? rgb(dark) : rgb(light)
        }
    }

    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: alpha)
    }
}

// MARK: - Controls

/// A square icon button with a hover wash — the unit every bar is built from.
struct ChromeIconButton: View {
    let systemImage: String
    var help: String = ""
    var isOn = false
    var size: CGFloat = 26
    var iconSize: CGFloat = 13
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(isOn ? ChromeInk.accent : ChromeInk.secondary)
                .frame(width: size, height: size)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(isOn ? ChromeInk.accentSoft : hovering ? ChromeInk.hover : .clear)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// A text button in the bars: plain until hovered.
struct ChromeTextButtonStyle: ButtonStyle {
    var prominent = false

    func makeBody(configuration: Configuration) -> some View {
        StyledLabel(configuration: configuration, prominent: prominent)
    }

    private struct StyledLabel: View {
        let configuration: Configuration
        let prominent: Bool
        @State private var hovering = false

        var body: some View {
            configuration.label
                .font(.system(size: 11.5, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? Color.white : ChromeInk.text)
                .padding(.horizontal, 9)
                .frame(height: 26)
                .background(
                    RoundedRectangle(cornerRadius: 5).fill(
                        prominent
                            ? ChromeInk.accent.opacity(configuration.isPressed ? 0.8 : hovering ? 0.92 : 1)
                            : configuration.isPressed ? ChromeInk.pressed : hovering ? ChromeInk.hover : .clear
                    )
                )
                .contentShape(Rectangle())
                .onHover { hovering = $0 }
        }
    }
}

struct VDivider: View {
    var height: CGFloat = 18
    var body: some View {
        Rectangle().fill(ChromeInk.divider).frame(width: 1, height: height)
    }
}

struct HDivider: View {
    var body: some View {
        Rectangle().fill(ChromeInk.divider).frame(height: 1)
    }
}

/// The small-caps heading every side panel opens with.
struct PanelHeading<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(ChromeInk.secondary)
            Spacer(minLength: 4)
            accessory
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 34)
    }
}

extension PanelHeading where Accessory == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// Makes a stretch of custom title bar drag the window, as the real one would.
struct WindowDragArea: NSViewRepresentable {
    final class DragView: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                window?.performZoom(nil)
            } else {
                window?.performDrag(with: event)
            }
        }
    }

    func makeNSView(context: Context) -> DragView { DragView() }
    func updateNSView(_ nsView: DragView, context: Context) {}
}

/// Moves the traffic lights down to the middle of our taller top bar. AppKit puts
/// them back whenever it re-lays the title bar out, so this follows it.
struct TrafficLightAligner: NSViewRepresentable {
    final class Probe: NSView {
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else { return }
            let names: [Notification.Name] = [
                NSWindow.didResizeNotification, NSWindow.didBecomeKeyNotification,
                NSWindow.didResignKeyNotification, NSWindow.didExitFullScreenNotification,
                NSWindow.didEndLiveResizeNotification,
            ]
            observers = names.map { name in
                NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.align() }
                }
            }
            DispatchQueue.main.async { [weak self] in self?.align() }
        }

        override func layout() {
            super.layout()
            align()
        }

        private func align() {
            guard let window else { return }
            for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
                guard let button = window.standardWindowButton(kind), let bar = button.superview else { continue }
                // The title bar view is bottom-up; the centre we want is half our bar down from its top.
                let y = bar.bounds.height - ChromeInk.barHeight / 2 - button.frame.height / 2
                let x: CGFloat = 14 + CGFloat([.closeButton, .miniaturizeButton, .zoomButton].firstIndex(of: kind)!) * 20
                let origin = CGPoint(x: x, y: max(0, y))
                if button.frame.origin != origin { button.setFrameOrigin(origin) }
            }
        }

        deinit { observers.forEach(NotificationCenter.default.removeObserver) }
    }

    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ nsView: Probe, context: Context) {}
}
