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

struct Question: Equatable {
    var text: String
    var selectedText: String?
    var selectedTextPage: Int?      // 1-indexed
    var regionImagePNG: Data?
    var regionPage: Int?            // 1-indexed page the crop came from
    var regionFallbackText: String? // text inside the crop, for text-only providers
    var pageHint: Int?              // 1-indexed page the user is viewing
}

/// One finished exchange in the thread the reader is in.
///
/// The whole `Question` is kept rather than its text, so a provider re-renders a
/// past turn with exactly the function that rendered it when it was live. That is
/// what keeps the replayed conversation byte-identical from one question to the
/// next, which is what the prefix caching on both API paths rests on.
struct ConversationTurn: Equatable {
    let question: Question
    let answer: String
}

/// The thread a question is being asked inside. Empty for the first question
/// after a document is opened and after "New conversation" — which is the whole
/// point of the type: clearing it costs nothing on the document side, because the
/// document lives in the `DocumentAttachment` beside it.
///
/// Two ways to carry a thread, because the providers genuinely differ. The API
/// paths have no server-side conversation, so their history is `turns`, replayed
/// after the cached document on every request. Claude Code keeps the thread in a
/// CLI session and hands back the id of the fork each answer left behind, so it
/// replays nothing and resumes `handle` instead.
struct Conversation: Equatable {
    var turns: [ConversationTurn] = []
    /// Provider-side continuation, reported by `.threadHandle`. Cleared when the
    /// provider changes: a session id means nothing to a different provider.
    var handle: String?
    /// How many of `turns` are already inside `handle`. A cancelled answer is
    /// recorded as a turn but leaves no resumable fork behind, so the two can
    /// drift — and a handle-based provider has to replay the difference or that
    /// turn silently drops out of the conversation.
    var handledTurns = 0

    var isEmpty: Bool { turns.isEmpty && handle == nil }

    /// The tail `handle` does not already account for. All of it when there is no
    /// handle at all, which is how a mid-thread provider switch keeps its thread.
    var unhandledTurns: [ConversationTurn] {
        Self.replayable(handle == nil ? turns : Array(turns.dropFirst(handledTurns)))
    }

    /// Everything, for the providers that replay rather than resume.
    var replayableTurns: [ConversationTurn] { Self.replayable(turns) }

    /// An answer that never arrived is not a turn: replaying one would leave two
    /// user messages next to each other, which both API paths reject.
    private static func replayable(_ turns: [ConversationTurn]) -> [ConversationTurn] {
        turns.filter { !$0.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

enum ChatEvent {
    case textDelta(String)
    case citation(pageNumber: Int, citedText: String)   // 1-indexed
    case usage(inputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int, outputTokens: Int)
    /// Provider-side condition worth showing beside the answer — e.g. a
    /// subscription rate-limit warning. Not an error; the answer still arrives.
    case notice(String)
    /// Where the thread now lives on the provider's side, for providers that keep
    /// it there. Emitted only once an answer has actually landed, because a run
    /// that died leaves nothing worth resuming. Thread state, not card state — the
    /// engine takes it out of the stream rather than showing it.
    case threadHandle(String)
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

    /// One question, asked inside `conversation` and about `attachment`; streams
    /// deltas back. The two are deliberately separate arguments: the attachment is
    /// the document and survives everything, the conversation is the thread and is
    /// thrown away whenever the reader starts a new one.
    func ask(_ question: Question, in attachment: DocumentAttachment, conversation: Conversation)
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
