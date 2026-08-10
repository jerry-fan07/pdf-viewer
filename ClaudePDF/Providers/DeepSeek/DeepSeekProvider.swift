import Foundation

/// DeepSeek via its OpenAI-compatible API — PLAN.md §5.2.
///
///   attach: extract the PDF's text with PDFKit, page-annotated ("[Page 12]\n…"),
///           and keep it for the session. No upload, no server-side state.
///
///   ask:    POST /chat/completions with the frozen preamble + document as the
///           `system` message, then the reader's thread, then this question as the
///           last `user` message. DeepSeek's context caching is automatic on
///           repeated prefixes, so questions 2..N read the document at ~50× less
///           than the first — provided the prefix is byte-identical, which is the
///           whole discipline of the builder, and which a replayed thread has to
///           preserve rather than break.
///
/// Text-only: `supportsVision` is false until DeepSeek's public API documents
/// image input. Crops degrade to the region's extracted text (PLAN.md §4).
struct DeepSeekProvider: ChatProvider {
    let id = "deepseek"
    let displayName = "DeepSeek"
    let capabilities = ProviderCapabilities(
        supportsVision: false, supportsNativePDF: false, supportsCitations: false
    )

    let model: DeepSeekModel
    var thinking: DeepSeekThinking = .low

    var modelName: String? { model.displayName }
    var pricing: TokenPricing? { model.tokenPricing }

    // MARK: Transport

    private static let endpoint = URL(string: "https://api.deepseek.com/chat/completions")!

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // Inter-byte idle timeout, not a total budget: a cache miss on a large
        // document can sit silent for a while before the first token.
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    // MARK: Attach

    func attach(document: PDFDocumentInfo) async throws -> DocumentAttachment {
        try await attach(document: document, progress: { _ in })
    }

    func attach(document: PDFDocumentInfo, progress: @escaping @Sendable (String) -> Void)
        async throws -> DocumentAttachment
    {
        _ = try Self.apiKey()   // fail before doing the extraction work

        let key = Self.storeKey(for: document.fileURL)
        let extracted = try DeepSeekExtractor.extract(from: document.fileURL) { done, total in
            progress("Reading scanned page \(done) of \(total)…")
        }
        DeepSeekTextStore.shared.store(extracted, for: key)

        return DocumentAttachment(providerID: id, handle: key,
                                  title: document.fileURL.lastPathComponent,
                                  sourceURL: document.fileURL)
    }

    // MARK: Ask

    func ask(_ question: Question, in attachment: DocumentAttachment, conversation: Conversation)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await stream(question, in: attachment, conversation: conversation) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func stream(_ question: Question,
                        in attachment: DocumentAttachment,
                        conversation: Conversation,
                        yield: (ChatEvent) -> Void) async throws
    {
        let apiKey = try Self.apiKey()
        let document = try Self.document(for: attachment)

        // A crop this provider cannot see, with no text under it, is the one case
        // PLAN.md §4 asks us to call out beside the answer rather than swallow.
        if question.regionImagePNG != nil,
           (question.regionFallbackText?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) {
            yield(.notice("\(displayName) can't see images — switch to Claude for visual questions."))
        }
        if document.ocrPages > 0 {
            yield(.notice("\(document.ocrPages) page\(document.ocrPages == 1 ? "" : "s") had no "
                          + "text layer and were read by OCR — expect transcription errors."))
        }
        if document.wasTruncated {
            yield(.notice("Only pages 1–\(document.includedPages) of \(document.pageCount) fit "
                          + "in the context window; later pages were not sent."))
        }

        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try DeepSeekRequestBuilder.encoder().encode(
            DeepSeekRequestBuilder.body(
                question: question,
                document: document,
                title: attachment.title,
                model: model,
                thinking: thinking,
                canSeeImages: capabilities.supportsVision,
                conversation: conversation
            )
        )

        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeepSeekError.badResponse }

        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw DeepSeekError.api(status: http.statusCode, detail: Self.errorDetail(from: data))
        }

        var decoder = DeepSeekStreamDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
            guard trimmed.hasPrefix("data:") else { continue }
            for event in try decoder.consume(String(trimmed.dropFirst("data:".count))) { yield(event) }
        }

        // A connection that drops after a complete answer but before `[DONE]`
        // should still report usage and close the card.
        if !decoder.sawTerminator {
            for event in decoder.finalEvents() { yield(event) }
        }
    }

    // MARK: Helpers

    /// The extracted body for this attachment. The session store is an
    /// optimisation only — if it has been evicted, re-extract from the file.
    private static func document(for attachment: DocumentAttachment) throws -> ExtractedDocument {
        if let cached = DeepSeekTextStore.shared.lookup(attachment.handle) { return cached }
        guard let source = attachment.sourceURL else { throw ProviderError.attachmentMissing }
        let extracted = try DeepSeekExtractor.extract(from: source)
        DeepSeekTextStore.shared.store(extracted, for: attachment.handle)
        return extracted
    }

    /// Folds in size and modification date, so editing the file behind an open
    /// window re-extracts instead of answering from stale text. See `DocumentKey`.
    static func storeKey(for url: URL) -> String { DocumentKey.make(for: url) }

    private static func apiKey() throws -> String {
        guard let key = KeychainStore.get(.deepseekAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else {
            throw ProviderError.notConfigured("Add a DeepSeek API key in Settings")
        }
        return key
    }

    static func errorDetail(from data: Data) -> String {
        struct Wrapper: Decodable {
            struct Detail: Decodable { let type: String?; let message: String? }
            let error: Detail?
        }
        if let wrapper = try? JSONDecoder().decode(Wrapper.self, from: data),
           let detail = wrapper.error {
            let parts = [detail.type, detail.message].compactMap { $0 }
            if !parts.isEmpty { return parts.joined(separator: ": ") }
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.isEmpty ? "no response body" : String(raw.prefix(400))
    }
}
