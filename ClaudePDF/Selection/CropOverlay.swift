import SwiftUI
import AppKit

/// Transparent drag-to-crop layer placed over the PDFView while crop mode is on (PLAN.md §4B).
/// It only reports a rect in its own coordinates — every conversion afterwards is CropGeometry's job.
final class CropOverlayView: NSView {
    /// Rect in this view's coordinate space, plus the view itself so the caller can convert.
    var onCrop: ((CGRect, NSView) -> Void)?
    var onCancel: (() -> Void)?

    private var anchor: CGPoint?
    private var selection: CGRect = .zero

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    // MARK: Drag

    override func mouseDown(with event: NSEvent) {
        anchor = convert(event.locationInWindow, from: nil)
        selection = .zero
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        selection = CropGeometry.dragRect(from: anchor, to: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let anchor else { return }
        let rect = CropGeometry.dragRect(from: anchor, to: convert(event.locationInWindow, from: nil))
        self.anchor = nil
        selection = .zero
        needsDisplay = true
        // A click (rather than a drag) means "never mind" — leave crop mode.
        if CropGeometry.isUsableDrag(rect) {
            onCrop?(rect, self)
        } else {
            onCancel?()
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {          // Esc
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dim = NSColor.black.withAlphaComponent(0.3)
        dim.setFill()

        if selection.isEmpty {
            bounds.fill()
            return
        }
        // Dim everything except the selection. Four rects rather than a punch-out, so this
        // does not depend on the view being layer-backed and non-opaque.
        let s = selection.intersection(bounds)
        NSRect(x: bounds.minX, y: s.maxY, width: bounds.width, height: bounds.maxY - s.maxY).fill()
        NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: s.minY - bounds.minY).fill()
        NSRect(x: bounds.minX, y: s.minY, width: s.minX - bounds.minX, height: s.height).fill()
        NSRect(x: s.maxX, y: s.minY, width: bounds.maxX - s.maxX, height: s.height).fill()

        NSColor.controlAccentColor.setStroke()
        let outline = NSBezierPath(rect: s.insetBy(dx: 0.5, dy: 0.5))
        outline.lineWidth = 1
        outline.stroke()
    }
}

struct CropOverlay: NSViewRepresentable {
    let onCrop: (CGRect, NSView) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> CropOverlayView {
        let view = CropOverlayView()
        view.onCrop = onCrop
        view.onCancel = onCancel
        // Take key focus so Esc reaches the overlay rather than the chat field.
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }

    func updateNSView(_ nsView: CropOverlayView, context: Context) {
        nsView.onCrop = onCrop
        nsView.onCancel = onCancel
    }
}
