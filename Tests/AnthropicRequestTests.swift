import XCTest
@testable import ClaudePDF

/// The caching model in PLAN.md §5.1 lives or dies on one property: the system
/// prompt and the document block are byte-identical on every question, and
/// everything volatile sits after the `cache_control` breakpoint.
final class AnthropicRequestTests: XCTestCase {

    private let attachment = DocumentAttachment(
        providerID: "anthropic",
        handle: "file_011CabcXYZ",
        title: "paper.pdf",
        sourceURL: URL(fileURLWithPath: "/tmp/paper.pdf")
    )

    private func plainQuestion() -> Question {
        Question(text: "What is the central claim?")
    }

    private func loadedQuestion() -> Question {
        var question = Question(text: "Explain this table.")
        question.selectedText = "Table 3 reports the ablation results."
        question.selectedTextPage = 12
        question.regionImagePNG = Data([0x89, 0x50, 0x4E, 0x47])
        question.regionPage = 12
        question.regionFallbackText = "Table 3"
        question.pageHint = 12
        return question
    }

    // MARK: The cache breakpoint

    func testCachedPrefixIsByteIdenticalAcrossDifferentQuestions() throws {
        let encoder = AnthropicRequestBuilder.encoder()
        let bare = AnthropicRequestBuilder.content(for: plainQuestion(), attachment: attachment)
        let loaded = AnthropicRequestBuilder.content(for: loadedQuestion(), attachment: attachment)

        // Everything at and before the breakpoint: identical bytes.
        XCTAssertEqual(try encoder.encode([bare[0]]), try encoder.encode([loaded[0]]))
        XCTAssertEqual(bare[0], loaded[0])

        // …and the questions really are different, so the test isn't vacuous.
        XCTAssertNotEqual(try encoder.encode(bare), try encoder.encode(loaded))
    }

    func testCachedPrefixIsExactlyTheDocumentBlock() throws {
        let prefix = AnthropicRequestBuilder.cachedPrefix(for: attachment)
        XCTAssertEqual(prefix.count, 1)
        XCTAssertEqual(prefix.first, .document(fileID: attachment.handle, title: attachment.title))

        let content = AnthropicRequestBuilder.content(for: loadedQuestion(), attachment: attachment)
        XCTAssertEqual(content.first, prefix.first, "the document block must come first")
    }

    func testDocumentBlockCarriesCitationsAndTheOneHourBreakpoint() throws {
        let encoder = AnthropicRequestBuilder.encoder()
        let block = AnthropicRequestBuilder.cachedPrefix(for: attachment)[0]
        let json = try XCTUnwrap(String(data: try encoder.encode([block]), encoding: .utf8))

        XCTAssertTrue(json.contains("\"type\":\"document\""), json)
        XCTAssertTrue(json.contains("\"file_id\":\"file_011CabcXYZ\""), json)
        XCTAssertTrue(json.contains("\"citations\":{\"enabled\":true}"), json)
        XCTAssertTrue(json.contains("\"ephemeral\""), json)
        XCTAssertTrue(json.contains("\"ttl\":\"1h\""), json)
        XCTAssertFalse(json.contains("base64"), "the PDF bytes must never ride in the request")
    }

    // MARK: The volatile suffix

    func testVolatileContentSitsAfterTheBreakpoint() throws {
        let content = AnthropicRequestBuilder.content(for: loadedQuestion(), attachment: attachment)

        guard case .document = content[0] else { return XCTFail("document block is not first") }
        for block in content.dropFirst() {
            if case .document = block { XCTFail("only one document block, and it must be first") }
        }

        // Selection, then crop, then the question — question always last.
        guard case .text(let selection) = content[1] else { return XCTFail("expected selection text") }
        XCTAssertTrue(selection.contains("page 12"))
        XCTAssertTrue(selection.contains("Table 3 reports the ablation results."))

        guard case .imagePNG(let base64) = content[3] else { return XCTFail("expected crop image") }
        XCTAssertEqual(base64, Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString())

        guard case .text(let closing) = content.last else { return XCTFail("expected trailing question") }
        XCTAssertTrue(closing.hasSuffix("Explain this table."))
        XCTAssertTrue(closing.contains("page 12"), "page hint rides with the question")
    }

    func testBareQuestionCarriesOnlyDocumentAndQuestion() throws {
        let content = AnthropicRequestBuilder.content(for: plainQuestion(), attachment: attachment)
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[1], .text("What is the central claim?"))
    }

    // MARK: The frozen system prompt

    func testSystemPromptIsTheFrozenConstantOnEveryRequest() throws {
        let first = AnthropicRequestBuilder.body(
            question: plainQuestion(), attachment: attachment, model: .opus5
        )
        let second = AnthropicRequestBuilder.body(
            question: loadedQuestion(),
            attachment: DocumentAttachment(providerID: "anthropic", handle: "file_other", title: "other.pdf"),
            model: .haiku45
        )
        XCTAssertEqual(first.system.count, 1)
        XCTAssertEqual(first.system[0].text, AnthropicRequestBuilder.systemPrompt)
        XCTAssertEqual(first.system[0].text, second.system[0].text)
    }

    /// The typesetter is only half the feature. Left alone, models answer a maths paper in
    /// Unicode (φ, ≈, √) and `LaTeXSegmenter` correctly finds nothing to typeset, so the
    /// prompt has to ask for TeX or none of the rendering ever runs.
    func testSystemPromptAsksForLaTeX() {
        let prompt = AnthropicRequestBuilder.systemPrompt
        XCTAssertTrue(prompt.contains("$$"), "no display delimiter requested")
        XCTAssertTrue(prompt.contains("LaTeX"))
        XCTAssertTrue(prompt.contains("\\phi"), "the worked example is what makes it stick")
    }

    // MARK: Conversations

    private func conversation(_ exchanges: [(String, String)]) -> Conversation {
        Conversation(turns: exchanges.map {
            ConversationTurn(question: Question(text: $0.0), answer: $0.1)
        })
    }

    /// The property the whole thread has to be compatible with: however long the
    /// conversation gets, the serialized bytes up to and including the document
    /// block are the ones the cache was written with.
    func testTheDocumentBlockIsUntouchedByAConversationOfAnyLength() throws {
        let encoder = AnthropicRequestBuilder.encoder()
        let reference = try encoder.encode(AnthropicRequestBuilder.cachedPrefix(for: attachment)[0])

        for length in 0...4 {
            let thread = conversation((0..<length).map { ("q\($0)", "a\($0)") })
            let messages = AnthropicRequestBuilder.messages(
                question: loadedQuestion(), attachment: attachment, conversation: thread
            )
            XCTAssertEqual(try encoder.encode(messages[0].content[0]), reference,
                           "the cached prefix moved at \(length) turns")
        }
    }

    /// …and it has to be the *first* thing in the *first* message: a cache prefix
    /// match starts at byte zero, so a turn replayed in front of the document
    /// would silently cost a full cache write on every question.
    func testTheConversationIsReplayedAfterTheDocumentNotBeforeIt() throws {
        let messages = AnthropicRequestBuilder.messages(
            question: plainQuestion(), attachment: attachment,
            conversation: conversation([("what is a Kan extension?", "A universal…")])
        )
        XCTAssertEqual(messages.first?.content.first,
                       .document(fileID: attachment.handle, title: attachment.title))
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertEqual(messages[1].content, [.text("A universal…")])
    }

    func testEachTurnBecomesAUserAndAnAssistantMessageInOrder() throws {
        let messages = AnthropicRequestBuilder.messages(
            question: Question(text: "third"), attachment: attachment,
            conversation: conversation([("first", "a1"), ("second", "a2")])
        )
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "user", "assistant", "user"])
        XCTAssertEqual(messages[3].content, [.text("a2")])
        XCTAssertEqual(messages[4].content.last, .text("third"))
    }

    /// Roles have to alternate and assistant turns have to say something, so a
    /// question that produced no answer cannot be replayed as half a turn.
    func testATurnWithNoAnswerIsDroppedWholeRatherThanLeftHalfThere() throws {
        let thread = conversation([("asked", "answered"), ("stopped dead", "  ")])
        let messages = AnthropicRequestBuilder.messages(
            question: plainQuestion(), attachment: attachment, conversation: thread
        )
        XCTAssertEqual(messages.map(\.role), ["user", "assistant", "user"])
        XCTAssertFalse(messages.contains { $0.content.contains(.text("stopped dead")) })
    }

    /// A crop is described rather than re-uploaded once it is in the past: ten
    /// follow-ups must not re-send ten screenshots.
    func testAPastCropIsDescribedRatherThanResent() throws {
        let messages = AnthropicRequestBuilder.messages(
            question: plainQuestion(), attachment: attachment,
            conversation: Conversation(turns: [
                ConversationTurn(question: loadedQuestion(), answer: "It reports ablations."),
            ])
        )
        let replayed = messages[0].content
        XCTAssertFalse(replayed.contains { if case .imagePNG = $0 { return true } else { return false } },
                       "the past turn's screenshot was uploaded again")
        XCTAssertTrue(replayed.contains { block in
            if case .text(let text) = block { return text.contains("cropped a region from page 12") }
            return false
        }, replayed.debugDescription)
        // The live question's crop is still sent in full — this is about the past.
        let live = AnthropicRequestBuilder.volatileSuffix(for: loadedQuestion())
        XCTAssertTrue(live.contains { if case .imagePNG = $0 { return true } else { return false } })
    }

    // MARK: Request envelope

    func testRequestEnvelopeStreamsAndNamesTheSelectedModel() throws {
        let body = AnthropicRequestBuilder.body(
            question: plainQuestion(), attachment: attachment, model: .sonnet5
        )
        XCTAssertEqual(body.model, "claude-sonnet-5")
        XCTAssertTrue(body.stream)
        XCTAssertEqual(body.maxTokens, AnthropicRequestBuilder.maxTokens)
        XCTAssertGreaterThan(body.maxTokens, 4096, "thinking counts against max_tokens on Opus 5")
        XCTAssertEqual(body.outputConfig.effort, AnthropicRequestBuilder.effort)
        XCTAssertEqual(body.fallbacks, "default")
        XCTAssertEqual(body.messages.count, 1, "a question with no conversation behind it is one turn")
    }

    func testModelPageCaps() {
        XCTAssertEqual(AnthropicModel.opus5.pageCap, 600)
        XCTAssertEqual(AnthropicModel.sonnet5.pageCap, 600)
        XCTAssertEqual(AnthropicModel.haiku45.pageCap, 100)
    }
}
