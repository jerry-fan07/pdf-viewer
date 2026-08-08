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
