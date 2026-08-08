import Foundation

/// Turns the `data:` payloads of DeepSeek's OpenAI-compatible SSE stream into
/// `ChatEvent`s.
///
/// Three things differ from the Anthropic stream and drive the design:
///  • The terminator is the literal `data: [DONE]`, which is not JSON. It is the
///    only reliable end-of-stream marker, so `.usage` + `.done` are emitted there
///    rather than from any decoded record.
///  • The usage chunk arrives immediately before `[DONE]` (and only because the
///    request sets `stream_options.include_usage`) with **`choices: []`** — never
///    index into `choices` unguarded.
///  • V4 runs thinking by default, so deltas carry `reasoning_content` alongside
///    `content`; reasoning is skipped, exactly like Anthropic's `thinking_delta`.
struct DeepSeekStreamDecoder {
    private(set) var cacheHitTokens = 0
    private(set) var cacheMissTokens = 0
    private(set) var outputTokens = 0
    private(set) var finishReason: String?
    private(set) var sawTerminator = false

    /// Feed one `data:` payload (the prefix already stripped).
    mutating func consume(_ payload: String) throws -> [ChatEvent] {
        let trimmed = payload.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        if trimmed == "[DONE]" {
            sawTerminator = true
            return finalEvents()
        }

        guard let chunk = try? JSONDecoder().decode(Chunk.self, from: Data(trimmed.utf8)) else {
            return []   // keep-alive comments, partial frames, anything added later
        }

        if let error = chunk.error {
            throw DeepSeekError.stream(message: error.message ?? "The stream ended with an unknown error.")
        }

        absorb(chunk.usage)

        guard let choice = chunk.choices?.first else { return [] }   // the usage chunk lands here
        finishReason = choice.finishReason ?? finishReason

        // reasoning_content is deliberately dropped: it is thinking, not the answer.
        guard let text = choice.delta?.content, !text.isEmpty else { return [] }
        return [.textDelta(text)]
    }

    /// `.usage` + `.done`, plus anything worth flagging beside the answer.
    /// Exposed so a stream that ends without `[DONE]` (a truncated connection that
    /// still returned a complete answer) can still be closed out cleanly.
    mutating func finalEvents() -> [ChatEvent] {
        var events: [ChatEvent] = []

        // DeepSeek reports hits and misses, not Anthropic's read/write split, and
        // a miss is written to the cache at no extra charge — so there is no
        // cache-write figure to report. Mapping miss → inputTokens (rather than
        // the `prompt_tokens` total, which already counts the hits) is what makes
        // QACard.cachedFraction compute hits / (hits + misses).
        events.append(.usage(inputTokens: cacheMissTokens,
                             cacheReadTokens: cacheHitTokens,
                             cacheWriteTokens: 0,
                             outputTokens: outputTokens))

        if finishReason == "length" {
            events.append(.notice("The answer hit the output limit and was cut short."))
        }
        if finishReason == "content_filter" {
            events.append(.notice("DeepSeek filtered part of this answer."))
        }

        events.append(.done)
        return events
    }

    private mutating func absorb(_ usage: Usage?) {
        guard let usage else { return }
        // Never let a count go backwards: a mid-stream chunk may repeat totals.
        cacheHitTokens = max(cacheHitTokens, usage.promptCacheHitTokens ?? 0)
        cacheMissTokens = max(cacheMissTokens, usage.promptCacheMissTokens ?? 0)
        outputTokens = max(outputTokens, usage.completionTokens ?? 0)
    }

    // MARK: Wire shapes (every field optional — the stream is versioned server-side)

    private struct Chunk: Decodable {
        let choices: [Choice]?
        let usage: Usage?
        let error: APIError?
    }

    private struct Choice: Decodable {
        let delta: Delta?
        let finishReason: String?

        enum CodingKeys: String, CodingKey {
            case delta
            case finishReason = "finish_reason"
        }
    }

    private struct Delta: Decodable {
        let content: String?
        let reasoningContent: String?

        enum CodingKeys: String, CodingKey {
            case content
            case reasoningContent = "reasoning_content"
        }
    }

    private struct Usage: Decodable {
        let promptTokens: Int?
        let completionTokens: Int?
        let promptCacheHitTokens: Int?
        let promptCacheMissTokens: Int?

        enum CodingKeys: String, CodingKey {
            case promptTokens = "prompt_tokens"
            case completionTokens = "completion_tokens"
            case promptCacheHitTokens = "prompt_cache_hit_tokens"
            case promptCacheMissTokens = "prompt_cache_miss_tokens"
        }
    }

    private struct APIError: Decodable {
        let type: String?
        let message: String?
    }
}

// MARK: - Errors

enum DeepSeekError: LocalizedError {
    case api(status: Int, detail: String)
    case stream(message: String)
    case noTextLayer(pages: Int)
    case ocrFoundNothing(pages: Int)
    case unreadableDocument(String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .api(let status, let detail):
            switch status {
            case 401: return "DeepSeek rejected the API key (401). Check it in Settings."
            case 402: return "DeepSeek reports an insufficient balance (402). Top up your account to keep asking."
            case 429: return "Rate limited by DeepSeek (429). Wait a moment and ask again."
            case 500...599: return "DeepSeek had a server error (\(status)). Try again — \(detail)"
            default: return "DeepSeek returned \(status): \(detail)"
            }
        case .stream(let message):
            return "Stream error: \(message)"
        case .noTextLayer(let pages):
            return "This \(pages)-page PDF has no text layer, and DeepSeek reads only text. "
                + "Turn on \"Read scanned pages\" in Settings, or use Claude for this "
                + "document — it reads the pages themselves."
        case .ocrFoundNothing(let pages):
            return "No text could be recognised on any of this \(pages)-page PDF, and "
                + "DeepSeek reads only text. Use Claude for this document — it reads the "
                + "pages themselves."
        case .unreadableDocument(let name):
            return "Could not read \(name) as a PDF."
        case .badResponse:
            return "DeepSeek returned a response this app could not read."
        }
    }
}
