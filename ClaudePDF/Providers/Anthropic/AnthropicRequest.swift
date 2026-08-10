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

    /// Base input/output rates, USD per million tokens. Cache read (0.1×) and
    /// the 1-hour cache write (2×) are derived in `TokenPricing.anthropic`.
    /// Sonnet 5 carries an introductory $2/$10 through 2026-08-31; the standard
    /// rate is used here so the figure doesn't quietly become wrong in September.
    var pricing: TokenPricing {
        switch self {
        case .opus5: return .anthropic(input: 5, output: 25)
        case .sonnet5: return .anthropic(input: 3, output: 15)
        case .haiku45: return .anthropic(input: 1, output: 5)
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
    let messages: [Message]
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

    /// A turn. Assistant turns exist because a thread is replayed to an API that
    /// keeps no conversation of its own; they carry the answer as one text block.
    struct Message: Encodable {
        let role: String
        let content: [AnthropicContentBlock]

        static func user(_ content: [AnthropicContentBlock]) -> Message {
            Message(role: "user", content: content)
        }

        static func assistant(_ text: String) -> Message {
            Message(role: "assistant", content: [.text(text)])
        }
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

        When a specific passage carries your answer, quote it in double quotes, copied \
        from the document exactly — same words, same order, no tidying up — and keep it \
        under about 25 words. The viewer looks each quotation up on the page and \
        highlights it, so a paraphrase inside quotation marks points the reader at nothing.

        When the question carries a quoted selection or a cropped region, treat that \
        as its subject; the page the reader is on is context, not a constraint.

        Lead with the answer, then the supporting detail. Keep it short: no restating \
        the question, no narrating what you are about to do. Use Markdown sparingly — \
        short paragraphs, and lists only when they earn their place.

        Write mathematics as LaTeX so the viewer can typeset it: $…$ inline, $$…$$ for \
        a displayed equation. Prefer it to Unicode symbols and plain-text notation — \
        write $\\phi(H) \\neq 1$, not φ(H) ≠ 1.
        """

    /// Everything at and before the cache breakpoint. Depends only on the
    /// document, never on the question.
    static func cachedPrefix(for attachment: DocumentAttachment) -> [AnthropicContentBlock] {
        [.document(fileID: attachment.handle, title: attachment.title)]
    }

    /// Everything after the breakpoint. Varies per question and never invalidates
    /// the cache.
    static func volatileSuffix(for question: Question) -> [AnthropicContentBlock] {
        suffix(for: question, resendingCrop: true)
    }

    /// A past turn's user side. Identical to `volatileSuffix` but for the crop:
    /// the image is described rather than re-uploaded, so a ten-turn thread does
    /// not re-send ten screenshots with every question. It also keeps the three
    /// providers saying the same thing about a past crop — DeepSeek cannot see one
    /// at all, and Claude Code still has the real image in its resumed session.
    /// Re-cropping is the way back to the pixels if a follow-up needs them.
    static func replayedSuffix(for question: Question) -> [AnthropicContentBlock] {
        suffix(for: question, resendingCrop: false)
    }

    private static func suffix(for question: Question,
                               resendingCrop: Bool) -> [AnthropicContentBlock]
    {
        var blocks: [AnthropicContentBlock] = []

        if let selected = question.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty {
            let page = question.selectedTextPage.map { "page \($0)" } ?? "the document"
            blocks.append(.text("The reader selected this text on \(page):\n\"\"\"\n\(selected)\n\"\"\""))
        }

        if let png = question.regionImagePNG {
            let page = question.regionPage.map { "page \($0)" } ?? "the document"
            if resendingCrop {
                blocks.append(.text("The reader cropped this region from \(page):"))
                blocks.append(.imagePNG(base64: png.base64EncodedString()))
            } else {
                var note = "The reader cropped a region from \(page), shown to you at the time."
                if let fallback = question.regionFallbackText?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !fallback.isEmpty {
                    note += " Its text:\n\"\"\"\n\(fallback)\n\"\"\""
                }
                blocks.append(.text(note))
            }
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

    /// The turns, with the document opening the first of them.
    ///
    /// The thread is replayed *after* the cache breakpoint, every question, which
    /// is what keeps a continuous conversation compatible with a cached document:
    /// the serialized bytes up to and including the document block are the same on
    /// question 1 and question 20. The history itself is not cached — the known
    /// follow-up here is a second, rolling `cache_control` on the current turn, and
    /// it is deliberately not in this change because the first breakpoint's live
    /// cache-hit behaviour is still unverified (README, "Status").
    static func messages(question: Question,
                         attachment: DocumentAttachment,
                         conversation: Conversation) -> [AnthropicMessagesRequest.Message]
    {
        let turns = conversation.replayableTurns
        guard let first = turns.first else {
            return [.user(content(for: question, attachment: attachment))]
        }

        var messages: [AnthropicMessagesRequest.Message] = [
            .user(cachedPrefix(for: attachment) + replayedSuffix(for: first.question)),
            .assistant(first.answer),
        ]
        for turn in turns.dropFirst() {
            messages.append(.user(replayedSuffix(for: turn.question)))
            messages.append(.assistant(turn.answer))
        }
        messages.append(.user(volatileSuffix(for: question)))
        return messages
    }

    static func body(question: Question,
                     attachment: DocumentAttachment,
                     conversation: Conversation = Conversation(),
                     model: AnthropicModel) -> AnthropicMessagesRequest
    {
        AnthropicMessagesRequest(
            model: model.rawValue,
            maxTokens: maxTokens,
            stream: true,
            system: [.init(text: systemPrompt)],
            messages: messages(question: question, attachment: attachment,
                               conversation: conversation),
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
