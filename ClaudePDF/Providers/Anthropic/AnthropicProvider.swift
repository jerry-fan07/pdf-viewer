import Foundation

/// Claude via the Anthropic API — the reference implementation of the caching
/// model in PLAN.md §5.1.
///
/// attach: upload the PDF once via the Files API → `file_id` (cached on disk, so
/// reopening a document doesn't re-send its bytes).
///
/// ask: a fresh, independent conversation per question —
///   system: FROZEN prompt (byte-identical every time)
///   user:   [document block {file_id, citations, cache_control 1h}]  ← breakpoint
///           …selection / crop / question, all *after* the breakpoint
/// streamed as SSE: `text_delta` → text, `citations_delta` → page-anchored chips.
///
/// Guards: `stop_reason == "refusal"` surfaces as a readable error rather than an
/// empty bubble; `usage.cache_read_input_tokens` is reported per answer so a
/// cache-busting regression is visible in the UI.
struct AnthropicProvider: ChatProvider {
    let id = "anthropic"
    let displayName = "Claude (API)"
    let capabilities = ProviderCapabilities(
        supportsVision: true, supportsNativePDF: true, supportsCitations: true
    )

    let model: AnthropicModel

    // MARK: Transport

    private static let apiBase = URL(string: "https://api.anthropic.com/v1")!
    private static let apiVersion = "2023-06-01"

    /// `files-api-…` covers both the upload and the `file_id` reference;
    /// `server-side-fallback-…` pairs with `"fallbacks": "default"` in the body.
    private static let betaHeader = "files-api-2025-04-14,server-side-fallback-2026-07-01"

    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        // The first question on a large PDF pays the cache write, which can sit
        // silent for a long time before the first byte arrives. This is an
        // inter-byte idle timeout, not a total budget.
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config)
    }()

    // MARK: Attach

    func attach(document: PDFDocumentInfo) async throws -> DocumentAttachment {
        let apiKey = try Self.apiKey()

        guard document.pageCount <= model.pageCap else {
            throw AnthropicError.documentTooLarge(
                pages: document.pageCount, cap: model.pageCap, model: model.displayName
            )
        }

        let title = document.fileURL.lastPathComponent
        if let cached = AnthropicFileCache.lookup(document.fileURL) {
            return DocumentAttachment(providerID: id, handle: cached,
                                      title: title, sourceURL: document.fileURL)
        }

        let fileID = try await upload(document.fileURL, apiKey: apiKey)
        AnthropicFileCache.store(fileID, for: document.fileURL)
        return DocumentAttachment(providerID: id, handle: fileID,
                                  title: title, sourceURL: document.fileURL)
    }

    private func upload(_ url: URL, apiKey: String) async throws -> String {
        let fileData = try Data(contentsOf: url)
        let boundary = "claudepdf-\(UUID().uuidString)"

        var request = Self.baseRequest(path: "files", apiKey: apiKey)
        request.setValue("multipart/form-data; boundary=\(boundary)",
                         forHTTPHeaderField: "Content-Type")

        let body = AnthropicMultipart.body(
            fileData: fileData,
            filename: url.lastPathComponent,
            mimeType: "application/pdf",
            boundary: boundary
        )

        let (data, response) = try await Self.session.upload(for: request, from: body)
        try Self.validate(response, body: data)

        struct FileMetadata: Decodable { let id: String }
        guard let metadata = try? JSONDecoder().decode(FileMetadata.self, from: data) else {
            throw AnthropicError.badResponse
        }
        return metadata.id
    }

    // MARK: Ask

    func ask(_ question: Question, in attachment: DocumentAttachment)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await stream(question, in: attachment) { continuation.yield($0) }
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
                        yield: (ChatEvent) -> Void) async throws
    {
        let apiKey = try Self.apiKey()

        var request = Self.baseRequest(path: "messages", apiKey: apiKey)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try AnthropicRequestBuilder.encoder().encode(
            AnthropicRequestBuilder.body(question: question, attachment: attachment, model: model)
        )

        let (bytes, response) = try await Self.session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw AnthropicError.badResponse }

        guard http.statusCode == 200 else {
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            // A stale file_id (deleted server-side) shouldn't wedge the document
            // forever — drop the cache entry so the next open re-uploads.
            if http.statusCode == 404, let source = attachment.sourceURL {
                AnthropicFileCache.invalidate(source)
            }
            throw AnthropicError.api(status: http.statusCode, detail: Self.errorDetail(from: data))
        }

        var decoder = AnthropicStreamDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            // Tolerate CRLF even though the API sends bare LF.
            let trimmed = line.hasSuffix("\r") ? String(line.dropLast()) : line
            guard trimmed.hasPrefix("data:") else { continue }
            let payload = trimmed.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
            guard !payload.isEmpty else { continue }
            for event in try decoder.consume(Data(payload.utf8)) { yield(event) }
        }

        if decoder.wasRefused {
            throw AnthropicError.refused(category: decoder.refusalCategory)
        }
    }

    // MARK: Helpers

    private static func apiKey() throws -> String {
        guard let key = KeychainStore.get(.anthropicAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !key.isEmpty
        else {
            throw ProviderError.notConfigured("Add an Anthropic API key in Settings")
        }
        return key
    }

    private static func baseRequest(path: String, apiKey: String) -> URLRequest {
        var request = URLRequest(url: apiBase.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.setValue(betaHeader, forHTTPHeaderField: "anthropic-beta")
        return request
    }

    private static func validate(_ response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw AnthropicError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw AnthropicError.api(status: http.statusCode, detail: errorDetail(from: body))
        }
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
