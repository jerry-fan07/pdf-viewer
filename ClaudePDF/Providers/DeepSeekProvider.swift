import Foundation

/// DeepSeek via its OpenAI-compatible API — PLAN.md §5.2.
///
/// attach: extract full text with PDFKit, page-annotated ("[Page 12]\n…"), store as the
///         stable prefix. Scanned PDFs (no text layer) need the OCR phase — until then,
///         surface "use Claude for this document".
///
/// ask: POST https://api.deepseek.com/chat/completions (stream: true), messages =
///   [ system (frozen), user: <full annotated text>, user: <question> ] — identical prefix
///   every question; DeepSeek's context caching is automatic on repeated prefixes.
///
/// Models: deepseek-v4-flash (default) / deepseek-v4-pro. Do NOT ship the deprecated
/// `deepseek-chat` alias. Text-only: supportsVision is false by policy until their API
/// documents image input (flip the flag, no code-path change).
struct DeepSeekProvider: ChatProvider {
    let id = "deepseek"
    let displayName = "DeepSeek"
    let capabilities = ProviderCapabilities(
        supportsVision: false, supportsNativePDF: false, supportsCitations: false
    )

    var model = "deepseek-v4-flash"

    func attach(document: PDFDocumentInfo) async throws -> DocumentAttachment {
        guard KeychainStore.get(.deepseekAPIKey) != nil else {
            throw ProviderError.notConfigured("Add a DeepSeek API key in Settings")
        }
        // Phase 4: PDFKit text extraction with page markers → cache key as handle
        throw ProviderError.notImplemented("DeepSeek provider lands in Phase 4 (see PLAN.md §5.2)")
    }

    func ask(_ question: Question, in attachment: DocumentAttachment)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ProviderError.notImplemented("DeepSeek provider lands in Phase 4"))
        }
    }
}
