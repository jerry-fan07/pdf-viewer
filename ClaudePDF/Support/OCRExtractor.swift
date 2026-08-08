import CoreGraphics
import Foundation
import ImageIO
import PDFKit
import Vision

/// Text recognition for pages that have no text layer — scanned PDFs, and the
/// image-only pages inside otherwise-searchable ones (PLAN.md §7).
///
/// This exists for the text-only path: Claude reads a scanned page natively, so
/// only DeepSeek needs the pixels turned into characters. The output feeds the
/// **cached prefix**, so it has to be a pure function of the document — same
/// bytes in, same string out. That is why results are cached on disk under the
/// document key rather than recomputed: two attaches of the same file must agree,
/// and a 400-page scan is minutes of work to redo.
enum OCRExtractor {

    /// Render scale for OCR. Vision reads a 612×792pt page far better at 2×
    /// (1224×1584 px) than at 1×, and past ~3× the accuracy gain stops paying
    /// for the memory.
    static let renderScale: CGFloat = 2

    /// Ceiling on the rendered page, in pixels per edge. A poster-sized page
    /// would otherwise raster to hundreds of megabytes.
    static let maxPixelEdge: CGFloat = 4000

    // MARK: Recognition

    /// Recognize text in a rendered image. Returns nil when Vision finds nothing —
    /// a genuinely blank page and a failed request are the same thing to the caller.
    static func recognizeText(in image: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let lines = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        let text = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Recognize text in a PNG — the crop path, where the region a text-only
    /// provider can't see has no text layer under it either.
    static func recognizeText(inPNG png: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
        else { return nil }
        return recognizeText(in: image)
    }

    /// Render a whole page and recognize it.
    ///
    /// - Note: `page.draw` needs the owning `PDFDocument` alive; PDFPage does not
    ///   retain it. Callers must hold the document.
    static func recognizeText(in page: PDFPage, box: PDFDisplayBox = .cropBox) -> String? {
        let bounds = page.bounds(for: box)
        guard let (image, _) = CropRenderer.renderImage(
            page: page, clampedPageRect: bounds, box: box,
            scale: renderScale, maxPixelEdge: maxPixelEdge
        ) else { return nil }
        return recognizeText(in: image)
    }
}

// MARK: - Disk cache

/// Recognized page text, keyed by document. OCR is the single most expensive
/// thing the app does, and the extracted body must be identical across attaches
/// or the cached prefix moves — so results are written once and replayed.
struct OCRCache: Sendable {
    static let shared = OCRCache()

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ClaudePDF/OCR", isDirectory: true)
    }

    func fileURL(for documentURL: URL) -> URL {
        directory.appendingPathComponent(DocumentKey.filename(for: documentURL) + ".json")
    }

    /// Page number (1-indexed, as a string so it survives JSON) → recognized text.
    func load(for documentURL: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: fileURL(for: documentURL)),
              let map = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return map
    }

    func save(_ pages: [String: String], for documentURL: URL) {
        guard let data = try? JSONEncoder().encode(pages) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: documentURL), options: .atomic)
    }
}
