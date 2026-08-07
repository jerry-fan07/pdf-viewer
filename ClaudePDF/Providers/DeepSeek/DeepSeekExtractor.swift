import Foundation
import PDFKit

/// The extracted, page-annotated text that stands in for the PDF on text-only
/// providers (PLAN.md §5.2). This *is* the cached prefix, so it must be a pure
/// function of the document — never of the question or the page being read.
struct ExtractedDocument: Equatable {
    /// Page-annotated body: "[Page 1]\n…\n\n[Page 2]\n…".
    let text: String
    /// Pages in the source document.
    let pageCount: Int
    /// Pages actually represented in `text`. Lower than `pageCount` only when the
    /// document blew the character budget.
    let includedPages: Int

    var wasTruncated: Bool { includedPages < pageCount }
}

enum DeepSeekExtractor {

    /// Ceiling on the extracted body, in characters.
    ///
    /// V4 models carry a 1M-token context. At a conservative ~3.5 chars/token this
    /// is ~690K tokens, which leaves generous room for the preamble, the question
    /// and the answer. Truncation happens **at attach**, at page granularity, and
    /// never per question: PLAN.md §5.2 originally proposed a window around the
    /// reader's current page, but that would change the prefix on every scroll and
    /// destroy the cache the whole design rests on (superseded — see PLAN.md §5.2).
    static let characterBudget = 2_400_000

    /// Read a PDF off disk and extract it. Task-confined: the `PDFDocument` is
    /// created and consumed here, never shared across threads.
    static func extract(from url: URL, characterBudget: Int = characterBudget) throws -> ExtractedDocument {
        guard let document = PDFDocument(url: url) else {
            throw DeepSeekError.unreadableDocument(url.lastPathComponent)
        }
        let pageTexts = (0..<document.pageCount).map { document.page(at: $0)?.string }
        return try assemble(pageTexts: pageTexts, characterBudget: characterBudget)
    }

    /// Pure half: page strings in, annotated body out. Split from `extract` so the
    /// markers, the empty-page handling and the budget are testable without a PDF.
    static func assemble(pageTexts: [String?], characterBudget: Int = characterBudget) throws -> ExtractedDocument {
        var body = ""
        var includedPages = 0
        var sawText = false

        for (index, raw) in pageTexts.enumerated() {
            let pageNumber = index + 1
            let page = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            // An empty page carries nothing to include, but it *is* covered —
            // it must not make the document look truncated.
            guard !page.isEmpty else {
                includedPages = pageNumber
                continue
            }

            let block = (body.isEmpty ? "" : "\n\n") + "[Page \(pageNumber)]\n" + page
            guard body.count + block.count <= characterBudget else { break }

            body += block
            includedPages = pageNumber
            sawText = true
        }

        // Scanned PDFs have no text layer at all. OCR is Phase 6; until then this
        // is a readable dead end pointing at a provider that reads pages natively.
        guard sawText else { throw DeepSeekError.noTextLayer(pages: pageTexts.count) }

        return ExtractedDocument(text: body, pageCount: pageTexts.count, includedPages: includedPages)
    }
}

// MARK: - Session text store

/// Keeps extracted bodies in memory for the session so questions 2..N don't
/// re-parse the PDF. Purely an optimisation: on a miss the provider re-extracts
/// from `DocumentAttachment.sourceURL`, so evicting a document that still has a
/// window open costs a re-parse, never an error.
final class DeepSeekTextStore: @unchecked Sendable {
    static let shared = DeepSeekTextStore()

    /// Bodies run to megabytes, so this is deliberately shallow.
    private let capacity = 8

    private let lock = NSLock()
    private var texts: [String: ExtractedDocument] = [:]
    private var order: [String] = []   // least-recently stored first

    func lookup(_ key: String) -> ExtractedDocument? {
        lock.lock()
        defer { lock.unlock() }
        return texts[key]
    }

    func store(_ document: ExtractedDocument, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        if texts[key] == nil { order.append(key) }
        texts[key] = document
        while order.count > capacity {
            texts.removeValue(forKey: order.removeFirst())
        }
    }
}
