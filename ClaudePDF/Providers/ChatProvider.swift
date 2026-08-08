import Foundation

// The provider abstraction. Abstracted at the *ask* level, not HTTP —
// the Claude Code provider is a child process, not a network client. See PLAN.md §2.

struct ProviderCapabilities {
    let supportsVision: Bool        // can accept a cropped screenshot
    let supportsNativePDF: Bool     // can ingest the PDF file itself
    let supportsCitations: Bool     // returns page-anchored citations
}

struct PDFDocumentInfo {
    let fileURL: URL
    let pageCount: Int
}

/// Opaque per-document handle a provider returns from attach():
/// Anthropic → Files API file_id; Claude Code → primed session_id; DeepSeek → extracted-text key.
struct DocumentAttachment {
    let providerID: String
    let handle: String
    /// Human-readable document title, sent with the request so citations can name it.
    var title: String = ""
    /// The local file the handle was derived from — lets a provider invalidate a
    /// stale server-side handle.
    var sourceURL: URL? = nil
}

struct Question {
    var text: String
    var selectedText: String?
    var selectedTextPage: Int?      // 1-indexed
    var regionImagePNG: Data?
    var regionPage: Int?            // 1-indexed page the crop came from
    var regionFallbackText: String? // text inside the crop, for text-only providers
    var pageHint: Int?              // 1-indexed page the user is viewing
}

enum ChatEvent {
    case textDelta(String)
    case citation(pageNumber: Int, citedText: String)   // 1-indexed
    case usage(inputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, outputTokens: Int)
    /// Provider-side condition worth showing beside the answer — e.g. a
    /// subscription rate-limit warning. Not an error; the answer still arrives.
    case notice(String)
    case done
}

enum ProviderError: LocalizedError {
    case notConfigured(String)
    case notImplemented(String)
    case attachmentMissing

    var errorDescription: String? {
        switch self {
        case .notConfigured(let detail): return "Provider not configured: \(detail)"
        case .notImplemented(let detail): return "Not implemented yet: \(detail)"
        case .attachmentMissing: return "The document is not attached to this provider yet."
        }
    }
}

protocol ChatProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var capabilities: ProviderCapabilities { get }

    /// The model this provider was built with, for the per-answer badge. Nil
    /// where the app doesn't choose one — the subscription path answers on
    /// whatever model the CLI is configured for.
    var modelName: String? { get }

    /// Per-token prices, for the per-answer cost line. Nil where there is no
    /// per-token bill to show (the subscription path, the mock).
    var pricing: TokenPricing? { get }

    /// Called once per opened document (upload / extract / prime a session).
    func attach(document: PDFDocumentInfo) async throws -> DocumentAttachment

    /// Same, with a channel for a one-line status while a slow attach runs —
    /// OCR over a scanned document is minutes, and silence there reads as a hang.
    /// Providers whose attach is a single upload or prime inherit the default.
    func attach(document: PDFDocumentInfo, progress: @escaping @Sendable (String) -> Void)
        async throws -> DocumentAttachment

    /// One independent question; streams deltas back.
    func ask(_ question: Question, in attachment: DocumentAttachment)
        -> AsyncThrowingStream<ChatEvent, Error>
}

extension ChatProvider {
    var modelName: String? { nil }
    var pricing: TokenPricing? { nil }

    func attach(document: PDFDocumentInfo, progress: @escaping @Sendable (String) -> Void)
        async throws -> DocumentAttachment
    {
        try await attach(document: document)
    }
}
