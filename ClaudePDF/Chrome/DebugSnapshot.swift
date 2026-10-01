#if DEBUG
import AppKit
import CoreImage
import PDFKit
import SwiftUI

/// Renders a document window to PNG without the window server, for looking at the
/// design from a script (and with the screen locked).
///
///     CLAUDEPDF_SNAPSHOT=/tmp/shot.png [CLAUDEPDF_ASK="…"] ClaudePDF.app/Contents/MacOS/ClaudePDF doc.pdf
///
/// With `CLAUDEPDF_ASK`, the question is asked first and the shot waits for the answer.
@MainActor
enum DebugSnapshot {
    /// Views that float over the pages, in window coordinates (top-left origin).
    static var overlayFrames: [String: CGRect] = [:]

    static func scheduleIfRequested(engine: ChatEngine, viewer: PDFViewerController, pins: PinnedNotes) {
        let env = ProcessInfo.processInfo.environment
        guard let path = env["CLAUDEPDF_SNAPSHOT"] else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2.5))
            if let page = env["CLAUDEPDF_PAGE"].flatMap(Int.init) {
                viewer.scroll(toPage: page)
                try? await Task.sleep(for: .seconds(0.5))
            }
            if let search = env["CLAUDEPDF_FIND"] {
                viewer.searchQuery = search
                try? await Task.sleep(for: .seconds(1))
            }
            if let text = env["CLAUDEPDF_ASK"] {
                var question = Question(text: text)
                question.pageHint = viewer.currentPageNumber
                if let quote = env["CLAUDEPDF_QUOTE"] {
                    question.selectedText = quote
                    question.selectedTextPage = viewer.currentPageNumber
                }
                engine.ask(question)
                for _ in 0..<200 where engine.isStreaming {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                try? await Task.sleep(for: .seconds(0.5))
            }
            if env["CLAUDEPDF_PIN"] != nil, let card = engine.threadCards.last, let note = pins.save(card: card) {
                pins.focusedID = note.id
                try? await Task.sleep(for: .seconds(0.5))
            }
            if let staged = env["CLAUDEPDF_STAGE"] {
                engine.pendingSelection = PendingSelection(text: staged, page: viewer.currentPageNumber)
            }
            try? await Task.sleep(for: .seconds(0.5))
            write(to: URL(fileURLWithPath: path))
            NSApp.terminate(nil)
        }
    }

    private static func write(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.frame.width > 600 }),
              let frameView = window.contentView?.superview else { return }
        frameView.layoutSubtreeIfNeeded()
        guard let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) else { return }
        frameView.cacheDisplay(in: frameView.bounds, to: rep)
        // PDFKit draws its pages as tiles `cacheDisplay` never sees: paint them in,
        // then put back what floats over them.
        let chrome = rep.cgImage
        if let pdfView = find(PDFView.self, in: frameView), let context = NSGraphicsContext(bitmapImageRep: rep) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = context
            drawPages(of: pdfView, into: frameView)
            if let chrome {
                let scale = CGFloat(chrome.width) / frameView.bounds.width
                for rect in overlayFrames.values {
                    let pixels = CGRect(x: rect.minX * scale, y: rect.minY * scale,
                                        width: rect.width * scale, height: rect.height * scale)
                    guard let piece = chrome.cropping(to: pixels) else { continue }
                    let target = CGRect(x: rect.minX, y: frameView.bounds.height - rect.maxY,
                                        width: rect.width, height: rect.height)
                    context.cgContext.resetClip()
                    NSGraphicsContext.saveGraphicsState()
                    NSBezierPath(roundedRect: target, xRadius: 9, yRadius: 9).addClip()
                    context.cgContext.draw(piece, in: target)
                    NSGraphicsContext.restoreGraphicsState()
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        }
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews { if let match = find(type, in: sub) { return match } }
        return nil
    }

    private static func drawPages(of pdfView: PDFView, into frameView: NSView) {
        let dark = !(pdfView.layer?.filters?.isEmpty ?? true)
        let clip = frameView.convert(pdfView.bounds, from: pdfView)
        NSBezierPath(rect: clip).setClip()
        if dark {
            // What the filter makes of the surround, which `cacheDisplay` drew unfiltered.
            NSColor(srgbRed: 0.10, green: 0.10, blue: 0.105, alpha: 1).setFill()
            clip.fill()
        }
        for page in pdfView.visiblePages {
            let box = pdfView.displayBox
            let rect = frameView.convert(pdfView.convert(page.bounds(for: box), from: page), from: pdfView)
            let image = page.thumbnail(of: CGSize(width: rect.width * 2, height: rect.height * 2), for: box)
            if !dark {
                NSGraphicsContext.saveGraphicsState()
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
                shadow.shadowBlurRadius = 4
                shadow.shadowOffset = NSSize(width: 0, height: -1)
                shadow.set()
                NSColor.white.setFill()
                rect.fill()
                NSGraphicsContext.restoreGraphicsState()
                image.draw(in: rect)
            } else {
                PageImageDarkening.darken(image)?.draw(in: rect)
            }
        }
    }
}

extension View {
    /// Marks a view that floats over the pages, so a snapshot can put it back on top.
    func snapshotOverlay(_ name: String) -> some View {
        background(GeometryReader { proxy in
            Color.clear.onAppear { DebugSnapshot.overlayFrames[name] = proxy.frame(in: .global) }
                .onChange(of: proxy.frame(in: .global)) { _, frame in DebugSnapshot.overlayFrames[name] = frame }
        })
    }
}
#else
import SwiftUI
extension View {
    func snapshotOverlay(_ name: String) -> some View { self }
}
#endif
