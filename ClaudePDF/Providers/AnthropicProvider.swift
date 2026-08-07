import Foundation

/// Claude via the Anthropic API. The reference implementation of the caching model — PLAN.md §5.1.
///
/// attach: upload the PDF once via the Files API
///   POST https://api.anthropic.com/v1/files   (anthropic-beta: files-api-2025-04-14) → file_id
///
/// ask: fresh, independent conversation per question, built as:
///   system: FROZEN system prompt (byte-identical every time — never interpolate)
///   user content: [ document block {file_id, citations: enabled,
///                                   cache_control: {ephemeral, ttl: 1h}},   ← cache breakpoint
///                   …selection text / crop image / question AFTER the breakpoint ]
///   stream: true → SSE; text via content_block_delta.text_delta,
///   citations via citations_delta (page_location.start_page_number is 1-indexed).
///
/// Guards: check stop_reason == "refusal" before reading content; verify caching via
/// usage.cache_read_input_tokens (0 on question 2 ⇒ a prefix mutation bug).
struct AnthropicProvider: ChatProvider {
    let id = "anthropic"
    let displayName = "Claude (API)"
    let capabilities = ProviderCapabilities(
        supportsVision: true, supportsNativePDF: true, supportsCitations: true
    )

    var model = "claude-opus-5"

    func attach(document: PDFDocumentInfo) async throws -> DocumentAttachment {
        guard KeychainStore.get(.anthropicAPIKey) != nil else {
            throw ProviderError.notConfigured("Add an Anthropic API key in Settings")
        }
        // Phase 3: Files API upload → DocumentAttachment(handle: file_id)
        throw ProviderError.notImplemented("Anthropic provider lands in Phase 3 (see PLAN.md §5.1)")
    }

    func ask(_ question: Question, in attachment: DocumentAttachment)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ProviderError.notImplemented("Anthropic provider lands in Phase 3"))
        }
    }
}
