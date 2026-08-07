import Foundation

/// Decodes the NDJSON emitted by
/// `claude -p … --output-format stream-json --include-partial-messages --verbose`.
///
/// Record types seen on the wire (captured from CLI 2.1.223):
///   system (subtype "init", carries session_id) · rate_limit_event ·
///   stream_event (wraps a **raw Anthropic SSE event** in `.event`) ·
///   assistant / user (complete messages, redundant with the deltas) · result.
///
/// Two things differ from the plain API stream and drive the design:
///  • The CLI runs an agent loop, so one question can contain several
///    message_start…message_stop cycles. `.done` therefore comes from the final
///    `result` record, never from `message_stop`.
///  • `result` is the authoritative usage and cost, so per-message usage is ignored.
struct ClaudeCodeStreamDecoder {
    private(set) var sessionID: String?
    private(set) var totalCostUSD: Double?

    mutating func consume(_ line: String) throws -> [ChatEvent] {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let record = try? JSONDecoder().decode(Record.self, from: Data(trimmed.utf8))
        else { return [] }

        if let id = record.sessionID, sessionID == nil { sessionID = id }

        switch record.type {
        case "stream_event":
            guard let event = record.event, event.type == "content_block_delta",
                  let delta = event.delta, delta.type == "text_delta",
                  let text = delta.text, !text.isEmpty
            else { return [] }   // thinking_delta, input_json_delta, tool blocks, …
            return [.textDelta(text)]

        case "rate_limit_event":
            guard let info = record.rateLimitInfo, let notice = info.notice else { return [] }
            return [.notice(notice)]

        case "result":
            totalCostUSD = record.totalCostUSD
            if record.isError == true {
                throw ClaudeCodeError.cliFailed(
                    status: 0,
                    stderr: record.result ?? record.subtype ?? "Claude Code reported an error."
                )
            }
            let usage = record.usage
            return [
                .usage(inputTokens: usage?.inputTokens ?? 0,
                       cacheReadTokens: usage?.cacheReadInputTokens ?? 0,
                       cacheWriteTokens: usage?.cacheCreationInputTokens ?? 0,
                       outputTokens: usage?.outputTokens ?? 0),
                .done,
            ]

        default:
            return []   // system, assistant, user, anything added in a later CLI
        }
    }

    // MARK: Wire shapes

    private struct Record: Decodable {
        let type: String
        let subtype: String?
        let sessionID: String?
        let event: Event?
        let rateLimitInfo: RateLimitInfo?
        let usage: Usage?
        let isError: Bool?
        let result: String?
        let totalCostUSD: Double?

        enum CodingKeys: String, CodingKey {
            case type, subtype, event, usage, result
            case sessionID = "session_id"
            case rateLimitInfo = "rate_limit_info"
            case isError = "is_error"
            case totalCostUSD = "total_cost_usd"
        }
    }

    private struct Event: Decodable {
        let type: String
        let delta: Delta?
    }

    private struct Delta: Decodable {
        let type: String?
        let text: String?
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

    struct RateLimitInfo: Decodable {
        let status: String?
        let rateLimitType: String?
        let utilization: Double?
        let resetsAt: Double?

        enum CodingKeys: String, CodingKey {
            case status, utilization, resetsAt
            case rateLimitType = "rateLimitType"
        }

        /// Only worth showing when the subscription limit is actually under
        /// pressure — PLAN.md §5.3 asks for these to be surfaced, not swallowed.
        var notice: String? {
            guard let status, status != "allowed" else { return nil }
            let window = (rateLimitType ?? "subscription").replacingOccurrences(of: "_", with: "-")
            var text = "Subscription limit"
            if let utilization {
                text += ": \(Int((utilization * 100).rounded()))% of your \(window) allowance used"
            } else {
                text += " \(status.replacingOccurrences(of: "_", with: " "))"
            }
            if let resetsAt {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .short
                text += " (resets \(formatter.string(from: Date(timeIntervalSince1970: resetsAt))))"
            }
            return text + "."
        }
    }
}
