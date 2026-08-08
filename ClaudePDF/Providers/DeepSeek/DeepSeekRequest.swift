import Foundation

/// Models offered by the DeepSeek provider (verified against api-docs.deepseek.com,
/// Aug 2026). Both carry a 1M-token context. The legacy `deepseek-chat` /
/// `deepseek-reasoner` aliases were retired on 2026-07-24 — do not ship them.
enum DeepSeekModel: String, CaseIterable, Identifiable, Sendable {
    case v4Flash = "deepseek-v4-flash"
    case v4Pro = "deepseek-v4-pro"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .v4Flash: return "DeepSeek V4 Flash"
        case .v4Pro: return "DeepSeek V4 Pro"
        }
    }

    /// Cache-hit / cache-miss input and output, USD per million tokens. Shown in
    /// Settings so the cost lever in PLAN.md §7 is visible where the choice is made.
    var pricing: (cacheHit: Double, cacheMiss: Double, output: Double) {
        switch self {
        case .v4Flash: return (0.0028, 0.14, 0.28)
        case .v4Pro: return (0.003625, 0.435, 0.87)
        }
    }

    /// The same rates in the shape the per-answer cost line wants. DeepSeek
    /// caches automatically and bills no write premium, so `cacheWrite` is zero —
    /// and the provider never reports cache-write tokens anyway.
    var tokenPricing: TokenPricing {
        TokenPricing(input: pricing.cacheMiss, cacheRead: pricing.cacheHit,
                     cacheWrite: 0, output: pricing.output)
    }
}

/// Thinking on the V4 models is **enabled by default at `high` effort**, which is
/// the wrong default for a reading UI — it buys depth the typical "what does this
/// table say" question does not need, and pays for it in latency and output tokens.
/// This is the latency lever for the DeepSeek path, mirroring `output_config.effort`
/// on the Anthropic path; it is a top-level request parameter, so changing it never
/// invalidates the cached document prefix.
enum DeepSeekThinking: String, CaseIterable, Identifiable, Sendable {
    case off
    case low
    case high
    case max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off: return "Off (fastest)"
        case .low: return "Low"
        case .high: return "High (API default)"
        case .max: return "Max (slowest)"
        }
    }

    var isEnabled: Bool { self != .off }

    /// `reasoning_effort` is only meaningful while thinking is enabled.
    var reasoningEffort: String? { isEnabled ? rawValue : nil }
}

// MARK: - Wire shapes

struct DeepSeekChatRequest: Encodable {
    let model: String
    let messages: [Message]
    let stream: Bool
    let streamOptions: StreamOptions
    let maxTokens: Int
    let thinking: Thinking
    let reasoningEffort: String?

    enum CodingKeys: String, CodingKey {
        case model, messages, stream, thinking
        case streamOptions = "stream_options"
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
    }

    struct Message: Encodable, Equatable {
        let role: String
        let content: String
    }

    /// Without this the stream carries no usage at all, and the "% cached"
    /// indicator — the cache-regression alarm of PLAN.md §9 — goes blind.
    struct StreamOptions: Encodable {
        let includeUsage = true
        enum CodingKeys: String, CodingKey { case includeUsage = "include_usage" }
    }

    struct Thinking: Encodable {
        let type: String   // "enabled" | "disabled"
    }
}

// MARK: - Builder

/// Builds `/chat/completions` bodies whose prefix is byte-identical across
/// questions. DeepSeek's context caching is automatic on repeated prefixes — there
/// is no cache parameter to set, so an identical prefix is the *only* thing
/// standing between question 2 and a 50× more expensive cache miss.
///
/// Layout: one `system` message carrying the frozen preamble **and** the extracted
/// document, then one `user` message carrying everything volatile. PLAN.md §5.2
/// specified the document as a separate user message; putting it in `system` is
/// the layout DeepSeek's own caching guide demonstrates and it avoids two
/// consecutive `user` turns (superseded — see PLAN.md §5.2).
enum DeepSeekRequestBuilder {
    /// Thinking tokens are billed as output, so this is a ceiling on cost as much
    /// as on length. The models accept up to 384K.
    static let maxTokens = 16_000

    /// FROZEN. Never interpolate anything into this string — it opens the cached
    /// prefix, so one changed byte re-prices every question in every document.
    static let systemPreamble = """
        You are a reading assistant embedded in a PDF viewer. The user is reading \
        the document below and asks questions about it.

        The document is given as extracted text, one "[Page N]" marker per page. \
        Those markers are the reader's page numbers: cite them inline (for example \
        "p. 12") so the reader can jump straight to the passage.

        Answer from the document. If the document does not contain the answer, say \
        so plainly instead of guessing.

        When a specific passage carries your answer, quote it in double quotes, copied \
        from the document exactly — same words, same order, no tidying up — and keep it \
        under about 25 words. The viewer looks each quotation up on the page and \
        highlights it, so a paraphrase inside quotation marks points the reader at nothing.

        When the question carries a quoted selection, treat that as its subject; the \
        page the reader is on is context, not a constraint.

        Lead with the answer, then the supporting detail. Keep it short: no restating \
        the question, no narrating what you are about to do. Use Markdown sparingly — \
        short paragraphs, and lists only when they earn their place.

        Write mathematics as LaTeX so the viewer can typeset it: $…$ inline, $$…$$ for \
        a displayed equation. Prefer it to Unicode symbols and plain-text notation — \
        write $\\phi(H) \\neq 1$, not φ(H) ≠ 1.
        """

    /// The cached prefix: frozen preamble + the document, and nothing else.
    /// Depends only on the document, never on the question.
    static func systemMessage(document: ExtractedDocument, title: String) -> String {
        var message = systemPreamble + "\n\n"
        message += "Document: \(title)\n"
        if document.wasTruncated {
            // Stable per document, so it lives inside the cached prefix rather
            // than being re-sent with every question.
            message += "Only pages 1–\(document.includedPages) of \(document.pageCount) fit; "
            message += "later pages are not available to you. Say so if the answer would be there.\n"
        }
        message += "\n" + document.text
        return message
    }

    /// Everything volatile, in one user turn after the prefix.
    static func userMessage(for question: Question, canSeeImages: Bool) -> String {
        var parts: [String] = []

        if let selected = question.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty {
            let page = question.selectedTextPage.map { "page \($0)" } ?? "the document"
            parts.append("The reader selected this text on \(page):\n\"\"\"\n\(selected)\n\"\"\"")
        }

        if question.regionImagePNG != nil && !canSeeImages {
            let page = question.regionPage.map { "page \($0)" } ?? "the document"
            if let fallback = question.regionFallbackText?
                .trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
                parts.append("The reader cropped a region of \(page). "
                    + "You cannot see images; this is the text inside it:\n\"\"\"\n\(fallback)\n\"\"\"")
            } else {
                // The provider also raises this as a UI notice — telling the model
                // keeps it from answering as though it had seen the figure.
                parts.append("The reader cropped a region of \(page) that contains no "
                    + "selectable text. You cannot see images, so answer from the page text "
                    + "around it and say what you could not see.")
            }
        }

        if let page = question.pageHint {
            parts.append("The reader is currently on page \(page).")
        }

        parts.append("Question: \(question.text)")
        return parts.joined(separator: "\n\n")
    }

    static func messages(question: Question,
                         document: ExtractedDocument,
                         title: String,
                         canSeeImages: Bool) -> [DeepSeekChatRequest.Message]
    {
        [
            .init(role: "system", content: systemMessage(document: document, title: title)),
            .init(role: "user", content: userMessage(for: question, canSeeImages: canSeeImages)),
        ]
    }

    static func body(question: Question,
                     document: ExtractedDocument,
                     title: String,
                     model: DeepSeekModel,
                     thinking: DeepSeekThinking,
                     canSeeImages: Bool) -> DeepSeekChatRequest
    {
        DeepSeekChatRequest(
            model: model.rawValue,
            messages: messages(question: question, document: document,
                               title: title, canSeeImages: canSeeImages),
            stream: true,
            streamOptions: .init(),
            maxTokens: maxTokens,
            thinking: .init(type: thinking.isEnabled ? "enabled" : "disabled"),
            reasoningEffort: thinking.reasoningEffort
        )
    }

    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
