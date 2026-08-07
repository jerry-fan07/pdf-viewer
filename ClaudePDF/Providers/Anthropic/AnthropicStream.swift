import Foundation

/// Turns the `data:` payloads of a `/v1/messages` SSE stream into `ChatEvent`s.
///
/// Deliberately permissive: anything it doesn't recognise is skipped. Opus 5 runs
/// adaptive thinking by default, so a live stream also carries `ping` events,
/// `thinking` / `signature_delta` blocks (empty text under the default
/// `display: "omitted"`), and — with server-side fallbacks enabled — `fallback`
/// content blocks. Only an explicit `error` event throws.
struct AnthropicStreamDecoder {
    private(set) var inputTokens = 0
    private(set) var cacheReadTokens = 0
    private(set) var cacheWriteTokens = 0
    private(set) var outputTokens = 0
    private(set) var stopReason: String?
    private(set) var refusalCategory: String?

    /// `true` when the model declined before producing content. The provider turns
    /// this into a readable error instead of an empty answer bubble (PLAN.md §5.1).
    var wasRefused: Bool { stopReason == "refusal" }

    mutating func consume(_ payload: Data) throws -> [ChatEvent] {
        guard let event = try? JSONDecoder().decode(Envelope.self, from: payload) else { return [] }

        switch event.type {
        case "message_start":
            absorb(event.message?.usage)
            return []

        case "content_block_delta":
            guard let delta = event.delta else { return [] }
            switch delta.type {
            case "text_delta":
                guard let text = delta.text, !text.isEmpty else { return [] }
                return [.textDelta(text)]
            case "citations_delta":
                guard let citation = delta.citation,
                      citation.type == "page_location",
                      let page = citation.startPageNumber
                else { return [] }
                return [.citation(pageNumber: page, citedText: citation.citedText ?? "")]
            default:
                return []   // thinking_delta, signature_delta, input_json_delta, …
            }

        case "message_delta":
            absorb(event.usage)
            if let delta = event.delta {
                stopReason = delta.stopReason ?? stopReason
                refusalCategory = delta.stopDetails?.category ?? refusalCategory
            }
            return []

        case "message_stop":
            return [
                .usage(inputTokens: inputTokens,
                       cacheReadTokens: cacheReadTokens,
                       cacheWriteTokens: cacheWriteTokens,
                       outputTokens: outputTokens),
                .done,
            ]

        case "error":
            throw AnthropicError.stream(
                type: event.error?.type ?? "error",
                message: event.error?.message ?? "The stream ended with an unknown error."
            )

        default:
            return []   // ping, content_block_start/stop, fallback blocks, …
        }
    }

    private mutating func absorb(_ usage: Usage?) {
        guard let usage else { return }
        // Usage arrives split across message_start and message_delta, and later
        // events may repeat cumulative totals — never let a count go backwards.
        inputTokens = max(inputTokens, usage.inputTokens ?? 0)
        cacheReadTokens = max(cacheReadTokens, usage.cacheReadInputTokens ?? 0)
        cacheWriteTokens = max(cacheWriteTokens, usage.cacheCreationInputTokens ?? 0)
        outputTokens = max(outputTokens, usage.outputTokens ?? 0)
    }

    // MARK: Wire shapes (every field optional — the stream is versioned server-side)

    private struct Envelope: Decodable {
        let type: String
        let message: MessageStart?
        let delta: Delta?
        let usage: Usage?
        let error: APIError?
    }

    private struct MessageStart: Decodable { let usage: Usage? }

    private struct Delta: Decodable {
        let type: String?
        let text: String?
        let citation: Citation?
        let stopReason: String?
        let stopDetails: StopDetails?

        enum CodingKeys: String, CodingKey {
            case type, text, citation
            case stopReason = "stop_reason"
            case stopDetails = "stop_details"
        }
    }

    private struct Citation: Decodable {
        let type: String?
        let citedText: String?
        let startPageNumber: Int?

        enum CodingKeys: String, CodingKey {
            case type
            case citedText = "cited_text"
            case startPageNumber = "start_page_number"
        }
    }

    private struct StopDetails: Decodable {
        let category: String?
        let explanation: String?
    }

    private struct Usage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreationInputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
        }
    }

    private struct APIError: Decodable {
        let type: String?
        let message: String?
    }
}

// MARK: - Errors

enum AnthropicError: LocalizedError {
    case api(status: Int, detail: String)
    case stream(type: String, message: String)
    case refused(category: String?)
    case documentTooLarge(pages: Int, cap: Int, model: String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .api(let status, let detail):
            switch status {
            case 401: return "Anthropic rejected the API key (401). Check it in Settings."
            case 429: return "Rate limited by Anthropic (429). Wait a moment and ask again."
            case 500...599: return "Anthropic had a server error (\(status)). Try again — \(detail)"
            default: return "Anthropic returned \(status): \(detail)"
            }
        case .stream(let type, let message):
            return "Stream error (\(type)): \(message)"
        case .refused(let category):
            let reason = category.map { " (\($0))" } ?? ""
            return "Claude declined to answer this question\(reason). Rephrasing usually helps."
        case .documentTooLarge(let pages, let cap, let model):
            return "This document is \(pages) pages; \(model) accepts \(cap) for native PDF reading. "
                + "Pick a larger-context model in Settings, or use a provider that reads extracted text."
        case .badResponse:
            return "Anthropic returned a response this app could not read."
        }
    }
}
