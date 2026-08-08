import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Per-document Q&A history, persisted as one JSON file per document
/// (PLAN.md §6).
///
/// **History is display-only.** It is never re-sent to a provider: the context
/// model is "every question is an independent conversation over a cached
/// document" (PLAN.md §5), and quietly feeding old answers back would break both
/// the independence and the byte-identical prefix the caching rests on. What it
/// restores is the transcript the reader was looking at.
///
/// Each card records the provider and model that answered it, because a restored
/// transcript can predate a provider switch — the panel header only ever names
/// the *current* one.
struct StoredHistory: Codable, Sendable, Equatable {
    /// Bumped when the shape changes; a file from a future version is ignored
    /// rather than half-decoded.
    static let currentVersion = 1

    var version = currentVersion
    /// Human-readable provenance, so a stray file in the history folder can be
    /// traced back to its document. The file *name* is the hashed document key.
    var documentPath: String
    var cards: [StoredCard]
}

struct StoredCard: Codable, Sendable, Equatable {
    var id: UUID
    var askedAt: Date
    var questionText: String
    var selectedText: String?
    var selectedTextPage: Int?
    var regionPage: Int?
    /// A downscaled copy of the crop — display-only, so the full-resolution PNG
    /// that went to the model is not worth carrying in every history file.
    var regionThumbnailPNG: Data?
    var answer: String
    var citations: [StoredCitation]
    var notices: [String]
    var providerName: String
    var modelName: String?
    var inputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var outputTokens: Int?
    /// Computed while the card was live, from the rates in force then — a model
    /// change afterwards must not silently reprice an old answer.
    var costUSD: Double?
    var error: String?
}

struct StoredCitation: Codable, Sendable, Equatable {
    var page: Int
    var citedText: String
}

/// Reads and writes `StoredHistory` files. Task-confined and off the main actor:
/// every call touches the disk.
struct HistoryStore: Sendable {
    static let shared = HistoryStore()

    /// Cards kept per document. Old cards are dropped from the *front*, so the
    /// most recent questions are the ones that survive.
    static let cardLimit = 200

    /// Long edge, in pixels, of a persisted crop thumbnail. The card renders it
    /// at 80pt, so this is already generous at 2× — see `regionThumbnailPNG`.
    static let thumbnailMaxEdge = 400

    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory()
    }

    static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("ClaudePDF/History", isDirectory: true)
    }

    func fileURL(for documentURL: URL) -> URL {
        directory.appendingPathComponent(DocumentKey.filename(for: documentURL) + ".json")
    }

    /// Returns an empty history rather than throwing: a reader who opens a
    /// document should get the document, not an error about their transcript.
    func load(for documentURL: URL) -> StoredHistory? {
        guard let data = try? Data(contentsOf: fileURL(for: documentURL)),
              let history = try? JSONDecoder.history.decode(StoredHistory.self, from: data),
              history.version <= StoredHistory.currentVersion
        else { return nil }
        return history
    }

    func save(_ history: StoredHistory, for documentURL: URL) {
        var history = history
        if history.cards.count > Self.cardLimit {
            history.cards.removeFirst(history.cards.count - Self.cardLimit)
        }
        guard let data = try? JSONEncoder.history.encode(history) else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? data.write(to: fileURL(for: documentURL), options: .atomic)
    }

    func clear(for documentURL: URL) {
        try? FileManager.default.removeItem(at: fileURL(for: documentURL))
    }

    // MARK: Crop thumbnails

    /// Downscale a crop for storage. Returns nil — rather than the original —
    /// if the image can't be re-encoded, so a history file never grows a
    /// megabyte-scale PNG by accident.
    static func thumbnail(png: Data, maxEdge: Int = thumbnailMaxEdge) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}

private extension JSONEncoder {
    static var history: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

private extension JSONDecoder {
    static var history: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
