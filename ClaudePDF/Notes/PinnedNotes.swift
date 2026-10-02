import AppKit
import PDFKit
import SwiftUI

/// An answer saved onto the page it is about: a marker on the page, and a card in
/// the assistant's Notes tab. A snapshot of the answer, not a reference to it, so
/// deleting the conversation leaves the note where it is.
struct PinnedNote: Codable, Identifiable, Equatable {
    var id = UUID()
    /// The answer it was saved from, so that answer can say it has been saved.
    var cardID: UUID?
    var threadID: UUID?
    /// 1-indexed.
    var page: Int
    /// The marker's height on the page as a share from the head; nil for "the top".
    var y: Double?
    var question: String
    var answer: String
    /// The passage the question was about, highlighted on the page with the note.
    var quote: String?
    var provider: String?
    var createdAt = Date()
}

/// One JSON file per document beside the history, keyed the same way. The PDF
/// itself is never written: the window only views it, and touching the file would
/// change the key everything else about the document is stored under.
struct PinnedNoteStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? {
            let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory())
            return base.appendingPathComponent("ClaudePDF/PageNotes", isDirectory: true)
        }()
    }

    func fileURL(for documentURL: URL) -> URL {
        directory.appendingPathComponent(DocumentKey.filename(for: documentURL) + ".json")
    }

    func load(for documentURL: URL) -> [PinnedNote] {
        guard let data = try? Data(contentsOf: fileURL(for: documentURL)) else { return [] }
        return (try? JSONDecoder().decode([PinnedNote].self, from: data)) ?? []
    }

    func save(_ notes: [PinnedNote], for documentURL: URL) {
        let url = fileURL(for: documentURL)
        if notes.isEmpty {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(notes).write(to: url, options: .atomic)
    }
}

/// The document's saved notes, and the annotations that put them on its pages.
@MainActor
final class PinnedNotes: ObservableObject {
    @Published private(set) var notes: [PinnedNote] = []
    /// The note last clicked on the page or in the list — the Notes tab shows it selected.
    @Published var focusedID: UUID?
    /// Bumped when a marker on the page is clicked, so the window can bring the Notes tab up.
    @Published private(set) var activation = 0
    /// Bumped whenever the annotations on the pages change.
    @Published private(set) var revision = 0

    private let store: PinnedNoteStore
    private var textIndex = PDFTextIndex()
    private var document: PDFDocument?
    private var documentURL: URL?

    init(store: PinnedNoteStore = PinnedNoteStore()) {
        self.store = store
    }

    func load(for url: URL?, document: PDFDocument) {
        self.document = document
        textIndex = PDFTextIndex()
        documentURL = url
        notes = url.map(store.load(for:)) ?? []
        for note in notes { place(note) }
    }

    func note(forCard id: UUID) -> PinnedNote? {
        notes.first { $0.cardID == id }
    }

    /// Pages that carry at least one note, ascending.
    var pages: [Int] { Array(Set(notes.map(\.page))).sorted() }

    // MARK: Saving

    @discardableResult
    func save(card: QACard) -> PinnedNote? {
        if let existing = note(forCard: card.id) { return existing }
        guard let document, !card.answer.isEmpty else { return nil }
        let question = card.question
        let page = min(max(question.selectedTextPage ?? question.regionPage ?? card.citations.first?.page
                           ?? question.pageHint ?? 1, 1), document.pageCount)
        let quote = question.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let note = PinnedNote(
            cardID: card.id, threadID: card.threadID, page: page,
            y: quote.flatMap { passageShare(of: $0, onPage: page) },
            question: question.text, answer: card.answer, quote: quote,
            provider: [card.providerName, card.modelName].compactMap { $0 }.filter { !$0.isEmpty }
                .joined(separator: " · ")
        )
        notes.append(note)
        place(note)
        persist()
        return note
    }

    func delete(_ id: UUID) {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return }
        let removed = notes.remove(at: index)
        removeAnnotations(for: id, page: removed.page)
        if focusedID == id { focusedID = nil }
        persist()
    }

    /// A marker on the page was clicked.
    func activate(_ id: UUID) {
        focusedID = id
        activation += 1
    }

    private func persist() {
        guard let documentURL else { return }
        store.save(notes, for: documentURL)
    }

    // MARK: On the page

    /// The marker's top edge as a share of the page, level with the passage.
    private func passageShare(of quote: String, onPage number: Int) -> Double? {
        guard let document, let page = document.page(at: number - 1) else { return nil }
        guard let match = passage(quote, on: page) else { return nil }
        return PDFViewerController.anchor(for: match.bounds(for: page), on: page,
                                          pageNumber: number, box: .cropBox).y
    }

    private func passage(_ quote: String, on page: PDFPage) -> PDFSelection? {
        guard let document else { return nil }
        // The answer-to-source locator first: it survives hyphenation and ligatures.
        let number = document.index(for: page) + 1
        if let match = SourceLocator.locate(quote, in: document, index: textIndex, nearPage: number),
           match.pageNumber == number {
            return match.selection
        }
        // A selection's text comes back with its line breaks; the first line is
        // enough to find it, and is less likely to be broken by hyphenation.
        let probe = quote.split(whereSeparator: \.isNewline).first.map(String.init) ?? quote
        let needle = String(probe.prefix(80)).trimmingCharacters(in: .whitespaces)
        guard needle.count >= 3 else { return nil }
        return document.findString(needle, withOptions: [.caseInsensitive])
            .first { $0.pages.contains(page) }
            .map { first in
                // Widen to the whole quote where it fits on the page.
                let whole = document.findString(String(quote.prefix(400)), withOptions: [.caseInsensitive])
                    .first { $0.pages.contains(page) }
                return whole ?? first
            }
    }

    private func place(_ note: PinnedNote) {
        guard let document, let page = document.page(at: note.page - 1) else { return }
        removeAnnotations(for: note.id, page: note.page)
        let bounds = page.bounds(for: .cropBox)
        let size = PinnedNoteAnnotation.size
        var top = bounds.maxY - CGFloat(note.y ?? 0) * bounds.height - 6
        // Markers that would land on top of one another stack down the margin.
        let others = page.annotations.compactMap { $0 as? PinnedNoteAnnotation }
        while others.contains(where: { abs($0.bounds.maxY - top) < size.height + 2 }) {
            top -= size.height + 4
        }
        top = min(max(top, bounds.minY + size.height + 4), bounds.maxY - 6)
        let rect = CGRect(x: bounds.maxX - size.width - 10, y: top - size.height,
                          width: size.width, height: size.height)
        page.addAnnotation(PinnedNoteAnnotation(note: note, bounds: rect))
        revision += 1

        if let quote = note.quote, let match = passage(quote, on: page) {
            for line in match.selectionsByLine() where line.pages.contains(page) {
                let mark = PDFAnnotation(bounds: line.bounds(for: page), forType: .highlight, withProperties: nil)
                mark.color = PinnedNoteAnnotation.highlight
                mark.userName = PinnedNoteAnnotation.tag(note.id)
                page.addAnnotation(mark)
            }
        }
    }

    /// A note's annotations are all on its own page, which is fixed.
    private func removeAnnotations(for id: UUID, page number: Int) {
        guard let page = document?.page(at: number - 1) else { return }
        let tag = PinnedNoteAnnotation.tag(id)
        for annotation in page.annotations where annotation.userName == tag {
            page.removeAnnotation(annotation)
            revision += 1
        }
    }

    // MARK: Export

    /// A copy of the PDF with the notes in it as ordinary sticky notes — the
    /// original is left as it is.
    func exportCopy() {
        guard let document else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        let stem = documentURL?.deletingPathExtension().lastPathComponent ?? "Document"
        panel.nameFieldStringValue = "\(stem) (with notes).pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        document.write(to: url)
    }
}

/// The marker a saved note leaves on its page. A standard text (sticky-note)
/// annotation underneath, so an exported copy opens as one anywhere; drawn here
/// as the assistant's own badge.
final class PinnedNoteAnnotation: PDFAnnotation {
    static let size = CGSize(width: 22, height: 22)
    /// Static, not dynamic: these are drawn under the dark-pages filter, which
    /// inverts whatever they are given.
    static let fill = NSColor(srgbRed: 0.08, green: 0.45, blue: 0.90, alpha: 1)
    static let highlight = NSColor(srgbRed: 0.45, green: 0.68, blue: 1, alpha: 0.28)

    let noteID: UUID

    static func tag(_ id: UUID) -> String { "claudepdf.note.\(id.uuidString)" }

    init(note: PinnedNote, bounds: CGRect) {
        noteID = note.id
        super.init(bounds: bounds, forType: .text, withProperties: nil)
        userName = Self.tag(note.id)
        contents = "Q: \(note.question)\n\n\(note.answer)"
        color = Self.fill
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        context.saveGState()
        // A speech bubble: rounded body, tail at the lower left.
        let body = CGRect(x: rect.minX, y: rect.minY + 3, width: rect.width, height: rect.height - 3)
        let path = CGMutablePath()
        path.addRoundedRect(in: body, cornerWidth: 5, cornerHeight: 5)
        path.move(to: CGPoint(x: body.minX + 4, y: body.minY + 1))
        path.addLine(to: CGPoint(x: body.minX + 3, y: rect.minY - 1))
        path.addLine(to: CGPoint(x: body.minX + 10, y: body.minY + 1))
        path.closeSubpath()
        context.setShadow(offset: CGSize(width: 0, height: -0.5), blur: 1.5,
                          color: NSColor.black.withAlphaComponent(0.35).cgColor)
        context.addPath(path)
        context.setFillColor(Self.fill.cgColor)
        context.fillPath()
        context.restoreGState()

        // The assistant's sparkle, in white.
        let config = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
            .applying(.init(paletteColors: [.white]))
        if let glyph = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(config) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let glyphRect = CGRect(x: body.midX - glyph.size.width / 2, y: body.midY - glyph.size.height / 2,
                                   width: glyph.size.width, height: glyph.size.height)
            glyph.draw(in: glyphRect)
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}
