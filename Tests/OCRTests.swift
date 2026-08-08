import PDFKit
import XCTest
@testable import ClaudePDF

/// Phase 6: OCR closes the two gaps Phase 4 left open on the text-only path —
/// a wholly scanned document was a dead end, and the image-only pages inside an
/// otherwise-searchable one passed through as silent gaps.
///
/// These run Vision for real against generated bitmaps. The fixtures are clean,
/// large, black-on-white Helvetica: the point is that the pipeline is wired up
/// correctly, not that the recogniser copes with a bad scan.
final class OCRTests: XCTestCase {

    private var directory: URL!
    private var cache: OCRCache!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ocr-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        cache = OCRCache(directory: directory.appendingPathComponent("cache"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Write a generated document to disk so the extractor can open it by URL.
    private func writeScan(words: [String], name: String = "scan.pdf") throws -> URL {
        let url = directory.appendingPathComponent(name)
        let document = PDFFixtures.makeScannedDocument(words: words)
        XCTAssertTrue(document.write(to: url))
        return url
    }

    // MARK: The fixture itself

    /// If the fixture had a text layer these tests would pass without OCR ever
    /// running, so this assertion is load-bearing.
    func testScannedFixtureHasNoTextLayer() {
        let document = PDFFixtures.makeScannedDocument(words: ["INVOICE"])
        let text = document.page(at: 0)?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertTrue(text?.isEmpty ?? true, "the fixture must be image-only, or OCR is untested")
    }

    // MARK: Recognition

    func testRecognisesTextOnAScannedPage() throws {
        let document = PDFFixtures.makeScannedDocument(words: ["INVOICE"])
        let page = try XCTUnwrap(document.page(at: 0))
        let text = try XCTUnwrap(OCRExtractor.recognizeText(in: page))
        XCTAssertTrue(text.uppercased().contains("INVOICE"), "recognised \(text)")
    }

    func testRecognisesTextInAPNG() throws {
        let document = PDFFixtures.makeScannedDocument(words: ["SUMMARY"])
        let page = try XCTUnwrap(document.page(at: 0))
        let (png, _) = try XCTUnwrap(CropRenderer.renderPNG(
            page: page, clampedPageRect: page.bounds(for: .cropBox), scale: 2
        ))
        let text = try XCTUnwrap(OCRExtractor.recognizeText(inPNG: png))
        XCTAssertTrue(text.uppercased().contains("SUMMARY"), "recognised \(text)")
    }

    func testBlankPageRecognisesAsNothing() throws {
        let document = PDFFixtures.makeScannedDocument(words: [" "])
        let page = try XCTUnwrap(document.page(at: 0))
        XCTAssertNil(OCRExtractor.recognizeText(in: page))
    }

    // MARK: Extraction

    /// The Phase 4 dead end: a document with no text layer at all.
    func testWhollyScannedDocumentExtractsWithOCR() throws {
        let url = try writeScan(words: ["INVOICE", "TOTALS"])
        let extracted = try DeepSeekExtractor.extract(from: url, ocr: true, cache: cache)

        XCTAssertEqual(extracted.pageCount, 2)
        XCTAssertEqual(extracted.ocrPages, 2)
        XCTAssertTrue(extracted.text.contains("[Page 1]"))
        XCTAssertTrue(extracted.text.contains("[Page 2]"))
        XCTAssertTrue(extracted.text.uppercased().contains("INVOICE"))
        XCTAssertTrue(extracted.text.uppercased().contains("TOTALS"))
    }

    func testWithOCROffAScannedDocumentIsStillARefusal() throws {
        let url = try writeScan(words: ["INVOICE"])
        XCTAssertThrowsError(try DeepSeekExtractor.extract(from: url, ocr: false, cache: cache)) { error in
            guard case DeepSeekError.noTextLayer = error else {
                return XCTFail("expected noTextLayer, got \(error)")
            }
        }
    }

    /// With OCR on and nothing recognised, "no text layer" would invite the
    /// reader to turn on a setting that is already on.
    func testBlankScanReportsThatOCRFoundNothing() throws {
        let url = try writeScan(words: [" "])
        XCTAssertThrowsError(try DeepSeekExtractor.extract(from: url, ocr: true, cache: cache)) { error in
            guard case DeepSeekError.ocrFoundNothing = error else {
                return XCTFail("expected ocrFoundNothing, got \(error)")
            }
        }
    }

    func testProgressReportsEveryPageItRecognises() throws {
        let url = try writeScan(words: ["ALPHA", "BETA", "GAMMA"])
        let reports = ReportBox()
        _ = try DeepSeekExtractor.extract(from: url, ocr: true, cache: cache) { done, total in
            reports.append((done, total))
        }
        XCTAssertEqual(reports.values.map(\.0), [1, 2, 3])
        XCTAssertEqual(Set(reports.values.map(\.1)), [3])
    }

    // MARK: Caching

    /// The extracted body *is* the cached prompt prefix — two attaches of the
    /// same file must produce byte-identical text, or every question pays a
    /// fresh cache miss (PLAN.md §5.2).
    func testRepeatedExtractionIsByteIdentical() throws {
        let url = try writeScan(words: ["INVOICE"])
        let first = try DeepSeekExtractor.extract(from: url, ocr: true, cache: cache)
        let second = try DeepSeekExtractor.extract(from: url, ocr: true, cache: cache)
        XCTAssertEqual(first.text, second.text)
    }

    func testSecondExtractionReadsTheCacheInsteadOfRecognisingAgain() throws {
        let url = try writeScan(words: ["INVOICE"])
        _ = try DeepSeekExtractor.extract(from: url, ocr: true, cache: cache)

        let reports = ReportBox()
        _ = try DeepSeekExtractor.extract(from: url, ocr: true, cache: cache) { done, total in
            reports.append((done, total))
        }
        // Progress still ticks (the page is still a gap in the text layer), but
        // the recognised text now comes from disk.
        XCTAssertFalse(cache.load(for: url).isEmpty)
        XCTAssertEqual(reports.values.count, 1)
    }

    /// A page that recognised as nothing is remembered as nothing — re-running
    /// Vision over a blank page on every open is pure waste.
    func testEmptyRecognitionIsCachedToo() throws {
        let url = try writeScan(words: [" "])
        _ = try? DeepSeekExtractor.extract(from: url, ocr: true, cache: cache)
        XCTAssertEqual(cache.load(for: url), ["1": ""])
    }

    func testCacheIsKeyedPerDocument() throws {
        let first = try writeScan(words: ["INVOICE"], name: "a.pdf")
        let second = try writeScan(words: ["SUMMARY"], name: "b.pdf")
        XCTAssertNotEqual(cache.fileURL(for: first), cache.fileURL(for: second))
    }
}

/// Collects progress callbacks from the extractor's `@Sendable` closure.
private final class ReportBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [(Int, Int)] = []

    func append(_ value: (Int, Int)) {
        lock.lock(); defer { lock.unlock() }
        storage.append(value)
    }

    var values: [(Int, Int)] {
        lock.lock(); defer { lock.unlock() }
        return storage
    }
}
