import PDFKit
import SwiftUI
import XCTest
@testable import ClaudePDF

/// Renders the real views offscreen so the feature can be looked at, not just asserted
/// about — how the missing chip row was caught, and why the chips wrap instead of
/// scrolling. Self-contained: it generates its own paper and skips entirely unless
/// somebody has made the output directory, so an ordinary test run costs nothing.
///
///     mkdir -p /tmp/claude-pdf-demo/shots
///     xcodebuild ... test -only-testing:ClaudePDFTests/UISnapshots
@MainActor
final class UISnapshots: XCTestCase {

    /// Self-gating: the directory only exists when somebody has just made it in order
    /// to collect snapshots, so an ordinary test run skips these.
    private var directory: URL? {
        let url = URL(fileURLWithPath: "/tmp/claude-pdf-demo/shots")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// A generated two-page paper on disk — the providers take a file URL, and
    /// `MockProvider` reads it back to quote a real passage from the page.
    private func makeDemoPDF() throws -> URL {
        let url = try XCTUnwrap(directory).appendingPathComponent("paper.pdf")
        XCTAssertTrue(PDFFixtures.makePaperDocument().write(to: url))
        return url
    }

    private func write(_ image: NSImage, _ name: String) throws {
        guard let directory else { return }
        let tiff = image.tiffRepresentation!
        let png = NSBitmapImageRep(data: tiff)!.representation(using: .png, properties: [:])!
        try png.write(to: directory.appendingPathComponent(name))
    }

    @MainActor
    private func render<V: View>(_ view: V, width: CGFloat, height: CGFloat) -> NSImage? {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.scale = 2
        return renderer.nsImage
    }

    // MARK: The chat panel, answered

    func testChatPanelWithAnAnsweredQuestion() async throws {
        try XCTSkipIf(directory == nil)
        let demoPDF = try makeDemoPDF()
        let document = PDFDocument(url: demoPDF)!
        let view = PDFView()
        view.document = document
        let viewer = PDFViewerController()
        viewer.attach(view: view)
        viewer.scroll(toPage: 2)

        let engine = ChatEngine(provider: MockProvider())
        engine.attach(PDFDocumentInfo(fileURL: demoPDF, pageCount: document.pageCount))

        var question = Question(text: "What does the paper say about verifying the cache?")
        question.pageHint = 2
        engine.ask(question)

        let deadline = Date().addingTimeInterval(30)
        while engine.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(engine.isStreaming, "the mock answer never finished")

        let answer = engine.cards.last?.answer ?? ""
        XCTAssertFalse(AnswerQuotes.quotes(in: answer).isEmpty, "no quotation to link")

        let panel = ChatPanelView(engine: engine, viewer: viewer)
        let image = try XCTUnwrap(render(panel, width: 420, height: 900))
        try write(image, "chat-panel.png")
    }

    // MARK: The flash, on the page

    /// A `PDFView` renders nothing offscreen, so the page and PDFKit's own highlight
    /// drawing for the located selection are composed straight into a bitmap instead.
    /// The selection is the same object `reveal` flashes.
    func testFlashedPassageOnThePage() throws {
        try XCTSkipIf(directory == nil)
        let demoPDF = try makeDemoPDF()
        let document = PDFDocument(url: demoPDF)!
        let match = try XCTUnwrap(SourceLocator.locate(
            "A fuzzy match that highlighted a merely similar sentence would invert the purpose",
            in: document, index: PDFTextIndex(), nearPage: 2
        ))
        XCTAssertEqual(match.pageNumber, 2)

        let page = document.page(at: match.pageNumber - 1)!
        let bounds = page.bounds(for: .mediaBox)
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))

        NSGraphicsContext.saveGraphicsState()
        let graphics = NSGraphicsContext(bitmapImageRep: rep)!
        NSGraphicsContext.current = graphics
        let context = graphics.cgContext
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale))
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        match.selection.color = .controlAccentColor.withAlphaComponent(0.55)
        match.selection.draw(for: page, with: .mediaBox, active: true)
        NSGraphicsContext.restoreGraphicsState()

        let image = NSImage(size: bounds.size)
        image.addRepresentation(rep)
        try write(image, "flash.png")
    }

    // MARK: The light→dark sweep, frame by frame

    /// The filter only exists on screen, so the only way to judge whether the crossing is smooth
    /// is to look at it. This lays the frames out side by side at even progress: an eased sweep
    /// should read as a dimmer being turned down, with no step between two frames larger than
    /// the ones around it.
    func testDarkModeSweepFilmstrip() throws {
        try XCTSkipIf(directory == nil)
        let document = PDFFixtures.makePaperDocument()
        let page = try XCTUnwrap(document.page(at: 0))
        let bounds = page.bounds(for: .mediaBox)

        let steps: [CGFloat] = [0, 0.25, 0.5, 0.75, 1]
        let strip = NSImage(size: CGSize(width: bounds.width * CGFloat(steps.count), height: bounds.height))
        strip.lockFocus()
        for (index, progress) in steps.enumerated() {
            let frame = try darkened(page: page, bounds: bounds, progress: progress)
            frame.draw(in: CGRect(x: bounds.width * CGFloat(index), y: 0,
                                  width: bounds.width, height: bounds.height))
        }
        strip.unlockFocus()
        try write(strip, "dark-mode-sweep.png")
    }

    /// The page composed onto its paper and run through the same chain the layer gets.
    private func darkened(page: PDFPage, bounds: CGRect, progress: CGFloat) throws -> NSImage {
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(bounds.width * scale), pixelsHigh: Int(bounds.height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        NSGraphicsContext.saveGraphicsState()
        let graphics = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep))
        NSGraphicsContext.current = graphics
        graphics.cgContext.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        graphics.cgContext.fill(CGRect(x: 0, y: 0, width: bounds.width * scale, height: bounds.height * scale))
        graphics.cgContext.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: graphics.cgContext)
        NSGraphicsContext.restoreGraphicsState()

        var image = CIImage(cgImage: try XCTUnwrap(rep.cgImage))
        for filter in PDFPageDarkening.invertingFilters(progress: progress) {
            filter.setValue(image, forKey: kCIInputImageKey)
            image = try XCTUnwrap(filter.outputImage)
        }
        // Same linear working space Core Animation composites the layer in.
        let context = CIContext(options: [
            .workingColorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.linearSRGB))
        ])
        let rendered = try XCTUnwrap(context.createCGImage(
            image, from: image.extent, format: .RGBA8,
            colorSpace: try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        ))
        return NSImage(cgImage: rendered, size: bounds.size)
    }

    // MARK: One answer card, close up

    func testAnswerCard() async throws {
        try XCTSkipIf(directory == nil)
        let demoPDF = try makeDemoPDF()
        let document = PDFDocument(url: demoPDF)!
        let view = PDFView()
        view.document = document
        let viewer = PDFViewerController()
        viewer.attach(view: view)

        let engine = ChatEngine(provider: MockProvider())
        engine.attach(PDFDocumentInfo(fileURL: demoPDF, pageCount: document.pageCount))
        var question = Question(text: "What does the paper say about verifying the cache?")
        question.pageHint = 2
        engine.ask(question)

        let deadline = Date().addingTimeInterval(30)
        while engine.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let card = try XCTUnwrap(engine.cards.last)
        XCTAssertFalse(AnswerQuotes.quotes(in: card.answer).isEmpty, "no quotation to link")

        let image = try XCTUnwrap(render(
            QACardView(card: card, viewer: viewer).padding(10).background(.background),
            width: 420, height: 760
        ))
        try write(image, "answer-card.png")
    }
}
