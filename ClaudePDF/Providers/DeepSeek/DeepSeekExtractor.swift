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
    /// Pages whose text came from OCR rather than from the PDF's own text layer.
    var ocrPages: Int = 0

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
    ///
    /// Pages with no text layer are recognised with Vision when `ocr` is on
    /// (PLAN.md §7) — that covers both a wholly scanned document and the
    /// image-only pages inside an otherwise-searchable one, which Phase 4 passed
    /// through as silent gaps. `progress` reports (pages recognised, pages to
    /// recognise) so a long scan doesn't look like a hang.
    static func extract(
        from url: URL,
        characterBudget: Int = characterBudget,
        ocr: Bool = AppSettings.ocrEnabled,
        cache: OCRCache = .shared,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) throws -> ExtractedDocument {
        guard let document = PDFDocument(url: url) else {
            throw DeepSeekError.unreadableDocument(url.lastPathComponent)
        }
        var pageTexts = (0..<document.pageCount).map { document.page(at: $0)?.string }

        var ocrPages = 0
        if ocr {
            ocrPages = try fillGapsWithOCR(
                &pageTexts, document: document, url: url, cache: cache, progress: progress
            )
        }

        do {
            var extracted = try assemble(pageTexts: pageTexts, characterBudget: characterBudget)
            extracted.ocrPages = ocrPages
            return extracted
        } catch DeepSeekError.noTextLayer(let pages) where ocr {
            // OCR ran and still found nothing: saying "no text layer" would
            // invite the reader to turn on a setting that is already on.
            throw DeepSeekError.ocrFoundNothing(pages: pages)
        }
    }

    /// Recognise every page that came back empty, in place. Returns how many
    /// pages OCR contributed.
    ///
    /// Results are cached on disk under the document key: the extracted body is
    /// the cached *prompt* prefix, so two attaches of the same file must produce
    /// byte-identical text, and re-running Vision over a long scan is minutes of
    /// work to arrive at the same answer.
    private static func fillGapsWithOCR(
        _ pageTexts: inout [String?],
        document: PDFDocument,
        url: URL,
        cache: OCRCache,
        progress: (@Sendable (Int, Int) -> Void)?
    ) throws -> Int {
        let gaps = pageTexts.indices.filter {
            (pageTexts[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "").isEmpty
        }
        guard !gaps.isEmpty else { return 0 }

        var cached = cache.load(for: url)
        var recognised = 0
        var done = 0
        var cacheChanged = false
        // Whatever was recognised before a cancellation is still worth keeping —
        // the next attempt resumes instead of starting the scan over.
        defer { if cacheChanged { cache.save(cached, for: url) } }

        for index in gaps {
            // A 600-page scan is minutes of work; a cancelled attach must be
            // able to stop it rather than run to completion in the background.
            try Task.checkCancellation()
            defer {
                done += 1
                progress?(done, gaps.count)
            }
            let key = String(index + 1)
            if let text = cached[key] {
                // An empty cached string is a remembered "nothing here", and is
                // worth honouring — re-OCRing a blank page every open is waste.
                if !text.isEmpty {
                    pageTexts[index] = text
                    recognised += 1
                }
                continue
            }
            guard let page = document.page(at: index) else { continue }
            let text = OCRExtractor.recognizeText(in: page)
            cached[key] = text ?? ""
            cacheChanged = true
            if let text {
                pageTexts[index] = text
                recognised += 1
            }
        }

        return recognised
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

        // A scanned PDF with OCR turned off has nothing to send. `extract` turns
        // this into a different message when OCR ran and still found nothing.
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
