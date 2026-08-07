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
        XCTAssertEqual(body.messages.count, 1, "each question is an independent conversation")
    }

    func testModelPageCaps() {
        XCTAssertEqual(AnthropicModel.opus5.pageCap, 600)
        XCTAssertEqual(AnthropicModel.sonnet5.pageCap, 600)
        XCTAssertEqual(AnthropicModel.haiku45.pageCap, 100)
    }
}
