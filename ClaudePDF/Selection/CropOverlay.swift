import SwiftUI
import PDFKit

// Phase 2 — region screenshot mode (PLAN.md §4B).
//
// Planned shape:
//   • A transparent overlay NSView on top of the PDFView captures a drag rectangle.
//   • Convert view coords → page coords via pdfView.convert(rect, to: page).
//     ⚠ PDF page space is bottom-left origin and zoom-dependent — keep ALL conversion
//     inside CropGeometry below and unit-test it across zoom levels.
//   • Render the crop by drawing the PDFPage into a CGContext clipped to the rect at
//     2× scale → PNG (cap ~1600 px long edge). Also capture page.selection(for: rect)?.string
//     as the text fallback for text-only providers.

enum CropGeometry {
    /// Convert a rect in PDFView coordinates to page space. Isolated here so it can be
    /// unit-tested against zoom/rotation cases (Phase 2).
    static func pageRect(for viewRect: CGRect, in pdfView: PDFView, on page: PDFPage) -> CGRect {
        pdfView.convert(viewRect, to: page)
    }
}
