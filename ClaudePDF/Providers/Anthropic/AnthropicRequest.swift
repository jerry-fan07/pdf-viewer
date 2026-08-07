import Foundation

/// Models offered by the Anthropic provider — PLAN.md §5.1.
/// Opus 5 is the default; Sonnet 5 is cheaper; Haiku 4.5 is cheapest but its
/// 200K context caps native PDFs at 100 pages instead of 600 (PLAN.md §7).
enum AnthropicModel: String, CaseIterable, Identifiable, Sendable {
    case opus5 = "claude-opus-5"
    case sonnet5 = "claude-sonnet-5"
    case haiku45 = "claude-haiku-4-5"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .opus5: return "Claude Opus 5"
        case .sonnet5: return "Claude Sonnet 5"
        case .haiku45: return "Claude Haiku 4.5"
        }
    }

    /// Native-PDF page cap for this model.
    var pageCap: Int {
        switch self {
        case .haiku45: return 100
        case .opus5, .sonnet5: return 600
        }
    }
}

// MARK: - Content blocks

/// One content block in the user turn.
///
/// `.document` is the cache breakpoint: it carries `cache_control` with the
/// 1-hour TTL, so it and everything before it are read from cache on questions
/// 2..N. Every other case must sit *after* it (PLAN.md §5.1).
enum AnthropicContentBlock: Encodable, Equatable {
    case document(fileID: String, title: String)
    case text(String)
    case imagePNG(base64: String)

    private enum CodingKeys: String, CodingKey {
        case type, source, title, citations, text
        case cacheControl = "cache_control"
    }

    private struct FileSource: Encodable {
        let type = "file"
        let fileID: String
        enum CodingKeys: String, CodingKey {
            case type
            case fileID = "file_id"
        }
    }

    private struct Base64Source: Encodable {
        let type = "base64"
        let mediaType: String
        let data: String
        enum CodingKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }

    private struct Citations: Encodable { let enabled: Bool }
    private struct CacheControl: Encodable { let type: String; let ttl: String }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .document(let fileID, let title):
            try container.encode("document", forKey: .type)
            try container.encode(FileSource(fileID: fileID), forKey: .source)
            try container.encode(title, forKey: .title)
            try container.encode(Citations(enabled: true), forKey: .citations)
            try container.encode(CacheControl(type: "ephemeral", ttl: "1h"), forKey: .cacheControl)
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imagePNG(let base64):
            try container.encode("image", forKey: .type)
            try container.encode(Base64Source(mediaType: "image/png", data: base64), forKey: .source)
        }
    }
}

// MARK: - Request body

struct AnthropicMessagesRequest: Encodable {
    let model: String
    let maxTokens: Int
    let stream: Bool
    let system: [SystemTextBlock]
    let messages: [UserMessage]
    let outputConfig: OutputConfig
    /// Server-side refusal fallback: if Opus 5's safety classifiers decline a
    /// question, the API re-serves it on Anthropic's recommended fallback model
    /// instead of handing us an empty answer. Remove this line together with the
    /// `server-side-fallback-…` beta header to disable.
    let fallbacks: String

    enum CodingKeys: String, CodingKey {
        case model, stream, system, messages, fallbacks
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
    }

    struct SystemTextBlock: Encodable {
        let type = "text"
        let text: String
    }

    struct UserMessage: Encodable {
        let role = "user"
        let content: [AnthropicContentBlock]
    }

    struct OutputConfig: Encodable { let effort: String }
}

// MARK: - Builder

/// Builds `/v1/messages` bodies whose cached prefix is byte-identical across
/// questions. Kept pure and free of I/O so the caching discipline is unit-testable
/// (PLAN.md §9: "unit-test that request prefixes are byte-identical").
enum AnthropicRequestBuilder {
    /// We stream, so the SDK/HTTP timeout ceiling doesn't apply. Opus 5 runs
    /// adaptive thinking by default and thinking counts against `max_tokens`,
    /// so PLAN.md's 4096 would truncate answers mid-sentence.
    static let maxTokens = 16_000

    /// Latency lever for a reading UI. `output_config` is a top-level request
    /// parameter, so changing it never invalidates the cached document prefix.
    static let effort = "medium"

    /// FROZEN. Never interpolate anything into this string — one changed byte
    /// moves the whole prefix and every question re-pays the document cache write.
    static let systemPrompt = """
        You are a reading assistant embedded in a PDF viewer. The user is reading \
        the attached document and asks questions about it.

        Answer from the document. If the document does not contain the answer, say \
        so plainly instead of guessing. Cite the passages you rely on so the reader \
        can jump straight to them.

        When the question carries a quoted selection or a cropped region, treat that \
        as its subject; the page the reader is on is context, not a constraint.

        Lead with the answer, then the supporting detail. Keep it short: no restating \
        the question, no narrating what you are about to do. Use Markdown sparingly — \
        short paragraphs, and lists only when they earn their place.
        """

    /// Everything at and before the cache breakpoint. Depends only on the
    /// document, never on the question.
    static func cachedPrefix(for attachment: DocumentAttachment) -> [AnthropicContentBlock] {
        [.document(fileID: attachment.handle, title: attachment.title)]
    }

    /// Everything after the breakpoint. Varies per question and never invalidates
    /// the cache.
    static func volatileSuffix(for question: Question) -> [AnthropicContentBlock] {
        var blocks: [AnthropicContentBlock] = []

        if let selected = question.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty {
            let page = question.selectedTextPage.map { "page \($0)" } ?? "the document"
            blocks.append(.text("The reader selected this text on \(page):\n\"\"\"\n\(selected)\n\"\"\""))
        }

        if let png = question.regionImagePNG {
            let page = question.regionPage.map { "page \($0)" } ?? "the document"
            blocks.append(.text("The reader cropped this region from \(page):"))
            blocks.append(.imagePNG(base64: png.base64EncodedString()))
        }

        var closing = ""
        if let page = question.pageHint {
            closing += "The reader is currently on page \(page).\n\n"
        }
        closing += question.text
        blocks.append(.text(closing))

        return blocks
    }

    static func content(for question: Question, attachment: DocumentAttachment) -> [AnthropicContentBlock] {
        cachedPrefix(for: attachment) + volatileSuffix(for: question)
    }

    static func body(question: Question,
                     attachment: DocumentAttachment,
                     model: AnthropicModel) -> AnthropicMessagesRequest
    {
        AnthropicMessagesRequest(
            model: model.rawValue,
            maxTokens: maxTokens,
            stream: true,
            system: [.init(text: systemPrompt)],
            messages: [.init(content: content(for: question, attachment: attachment))],
            outputConfig: .init(effort: effort),
            fallbacks: "default"
        )
    }

    /// Sorted keys keep the serialized prefix stable regardless of Foundation's
    /// dictionary ordering — the cache is a byte-level prefix match.
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}
