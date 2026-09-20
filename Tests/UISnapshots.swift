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

    /// Through a real `NSHostingView` in an offscreen window, not `ImageRenderer`:
    /// the renderer skips `ScrollView` content and draws AppKit-backed controls
    /// (menus, text fields) as placeholder blanks, which blinded these shots to
    /// the entire transcript. An appearance can be forced per shot — dynamic
    /// colours resolve against the window they are drawn in.
    @MainActor
    private func render<V: View>(
        _ view: V, width: CGFloat, height: CGFloat,
        appearance: NSAppearance.Name = .aqua
    ) -> NSImage? {
        let host = NSHostingView(rootView: view.frame(width: width, height: height))
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        let window = NSWindow(
            contentRect: host.frame, styleMask: .borderless, backing: .buffered, defer: false
        )
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let scale: CGFloat = 2
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = CGSize(width: width, height: height)
        host.cacheDisplay(in: host.bounds, to: rep)

        let image = NSImage(size: host.bounds.size)
        image.addRepresentation(rep)
        return image
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

        // Two questions, so the shot shows the thread, not just an answer: the
        // timeline rail needs a line between dots and the transcript a hairline
        // between sections before either can be looked at.
        for text in ["What does the paper say about verifying the cache?",
                     "What should I be sceptical about?"] {
            var question = Question(text: text)
            question.pageHint = 2
            engine.ask(question)

            let deadline = Date().addingTimeInterval(30)
            while engine.isStreaming && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertFalse(engine.isStreaming, "the mock answer never finished")
        }

        let answer = engine.cards.last?.answer ?? ""
        XCTAssertFalse(AnswerQuotes.quotes(in: answer).isEmpty, "no quotation to link")

        // A third answer in the shape the Claude Code and DeepSeek paths have: no
        // citations at all, pages named in the prose because the prompt asks for them.
        // Without it the shot only ever showed the one path that has citations, which
        // is how the strip came to be empty in the app for the other two.
        //
        // Asked in the *same* conversation, after a change of voice: a second
        // conversation would be a second tab, and this shot is of one panel.
        engine.switchProvider(to: ProsePageProvider(), isWindowOverride: true)
        var third = Question(text: "Where is the cache breakpoint discussed?")
        third.pageHint = 1
        engine.ask(third)
        let deadline = Date().addingTimeInterval(30)
        while engine.isStreaming && Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let cliCard = try XCTUnwrap(engine.cards.last)
        XCTAssertTrue(cliCard.citations.isEmpty, "this path is supposed to have none")
        XCTAssertEqual(cliCard.citedPages(inDocumentOf: document.pageCount), [1, 2])

        // The sheet as the page shows it: beside its tab, with the page's other
        // notes shut above and below — so there have to be other notes, on this
        // page and on the other one, each level with what it was asked about.
        let open = engine.threadID
        let places = [NoteAnchor(page: 2, y: 0.55), NoteAnchor(page: 1, y: 0.2), NoteAnchor(page: 2)]
        for (text, place) in zip(["Summarise the method in two sentences",
                                  "Who is cited for the cache design?",
                                  "Is the evaluation convincing?"], places) {
            engine.startNewThread(at: place)
            engine.switchProvider(to: MockProvider())
            var question = Question(text: text)
            question.pageHint = place.page
            engine.ask(question)
            let deadline = Date().addingTimeInterval(30)
            while engine.isStreaming && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        engine.selectThread(open)

        let notes = PageNotesModel()
        notes.sheetWidth = PageNotesModel.defaultSheetWidth
        notes.isOpen = true
        let panel = PageNotesView(page: 2, pageHeight: 1500, engine: engine, viewer: viewer, model: notes)
            .background(Color(nsColor: PDFPageDarkening.lightBackdrop))
        notes.wantedSheetHeight = 1500
        let panelWidth = PageNotesModel.tabColumn + notes.sheetWidth
        let image = try XCTUnwrap(render(panel, width: panelWidth, height: 1500))
        try write(image, "chat-panel.png")

        // The same again with the dark side of the palette resolved — the design
        // is drawn light-only, so this is the shot that judges the pairs
        // `PanelInk` chose.
        let dark = try XCTUnwrap(render(panel, width: panelWidth, height: 1500, appearance: .darkAqua))
        try write(dark, "chat-panel-dark.png")

        // The real viewer, notes and all. (A `PDFView` draws its paper offscreen
        // and not what is printed on it, which is all these shots need: where the
        // page is, and that what is stuck to it is still stuck to it.) Fitted with
        // a note open; zoomed out, where page, tabs and sheet shrink as one thing
        // in the middle of the backdrop; the same folded away; and zoomed in and
        // panned right, where the sheet is reached by scrolling to it like any
        // other part of the page.
        let pdfView = AskablePDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = PDFPageDarkening.lightBackdrop
        // Letter paper rather than the fixture's 400×300 cards: how much of a
        // window a note takes is the thing being looked at.
        pdfView.document = try XCTUnwrap(PDFDocument(data: Self.blankLetterPages(3)))
        let live = PDFViewerController()
        let container = PDFContainerView(pdfView: pdfView, engine: engine, viewer: live, model: notes)
        container.frame = CGRect(x: 0, y: 0, width: 1100, height: 760)
        let window = NSWindow(contentRect: container.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = container
        live.attach(view: pdfView)
        container.observe()
        live.scroll(toPage: 2)

        func settle() async throws { try await Task.sleep(for: .milliseconds(250)) }
        try await settle()
        XCTAssertEqual(pdfView.pageBreakMargins.right, PageNotesModel.tabColumn + notes.sheetWidth, accuracy: 0.5,
                       "an open note is room the page makes beside itself")
        try write(snapshot(container), "notes-fitted-open.png")

        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit * 0.55
        try await settle()
        try write(snapshot(container), "notes-zoomed-out-open.png")

        notes.isOpen = false
        try await settle()
        XCTAssertEqual(pdfView.pageBreakMargins.right, PageNotesModel.tabColumn, accuracy: 0.5)
        try write(snapshot(container), "notes-zoomed-out-folded.png")

        pdfView.autoScales = true
        try await settle()
        try write(snapshot(container), "notes-fitted-folded.png")

        notes.isOpen = true
        try await settle()
        pdfView.scaleFactor = pdfView.scaleFactorForSizeToFit * 1.7
        try await settle()
        if let scroll = pdfView.documentView?.enclosingScrollView, let documentView = pdfView.documentView {
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: documentView.frame.width - clip.bounds.width, y: clip.bounds.minY))
            scroll.reflectScrolledClipView(clip)
        }
        try await settle()
        try write(snapshot(container), "notes-zoomed-in-panned.png")
    }

    private static func blankLetterPages(_ count: Int) -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(consumer: CGDataConsumer(data: data)!, mediaBox: &box, nil)!
        for _ in 0..<count {
            context.beginPDFPage(nil)
            context.setFillColor(.white)
            context.fill(box)
            context.endPDFPage()
        }
        context.closePDF()
        return data as Data
    }

    private func snapshot(_ view: NSView) throws -> NSImage {
        view.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let image = NSImage(size: view.bounds.size)
        image.addRepresentation(rep)
        return image
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

/// A provider with `supportsCitations: false` that names its pages in prose, the way
/// `ClaudeCodePrompt.ask` asks the CLI to. Everything the panel can show about where
/// this answer came from has to be read back out of the answer text.
private struct ProsePageProvider: ChatProvider {
    let id = "prose-pages"
    let displayName = "Claude (subscription)"
    let capabilities = ProviderCapabilities(
        supportsVision: true, supportsNativePDF: true, supportsCitations: false
    )

    func attach(document: PDFDocumentInfo) async throws -> DocumentAttachment {
        DocumentAttachment(providerID: id, handle: document.fileURL.lastPathComponent,
                           sourceURL: document.fileURL)
    }

    func ask(_ question: Question, in attachment: DocumentAttachment, conversation: Conversation)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(
                "The breakpoint is introduced on page 1 and the measurement that "
                + "justifies it is on p. 2."
            ))
            continuation.yield(.usage(inputTokens: 900, cacheReadTokens: 1400,
                                      cacheWriteTokens: 0, outputTokens: 40))
            continuation.yield(.done)
            continuation.finish()
        }
    }
}
