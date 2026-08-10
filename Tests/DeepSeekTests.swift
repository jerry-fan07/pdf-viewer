import XCTest
import PDFKit
@testable import ClaudePDF

/// The DeepSeek path has no cache parameters to set (PLAN.md §5.2): caching is
/// automatic on repeated prefixes, so a byte-identical prefix is the only thing
/// standing between question 2 and a ~50× more expensive miss. These tests hold
/// that line, plus the OpenAI-compatible stream shapes the Anthropic decoder
/// never had to face.
final class DeepSeekTests: XCTestCase {

    // MARK: Fixtures

    private let document = ExtractedDocument(
        text: "[Page 1]\nIntro.\n\n[Page 12]\nTable 3 reports the ablation results.",
        pageCount: 12,
        includedPages: 12
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

    // MARK: Extraction

    func testPageMarkersAreOneIndexedAndInOrder() throws {
        let extracted = try DeepSeekExtractor.assemble(pageTexts: ["alpha", "beta", "gamma"])
        XCTAssertEqual(extracted.text, "[Page 1]\nalpha\n\n[Page 2]\nbeta\n\n[Page 3]\ngamma")
        XCTAssertEqual(extracted.pageCount, 3)
        XCTAssertEqual(extracted.includedPages, 3)
        XCTAssertFalse(extracted.wasTruncated)
    }

    func testEmptyPagesAreSkippedButStillCounted() throws {
        let extracted = try DeepSeekExtractor.assemble(pageTexts: ["alpha", "   \n ", nil, "delta"])
        XCTAssertFalse(extracted.text.contains("[Page 2]"))
        XCTAssertFalse(extracted.text.contains("[Page 3]"))
        XCTAssertTrue(extracted.text.contains("[Page 4]\ndelta"))
        // A blank page is covered, not missing — it must not read as truncation.
        XCTAssertEqual(extracted.includedPages, 4)
        XCTAssertFalse(extracted.wasTruncated)
    }

    func testOverBudgetDocumentTruncatesAtPageGranularity() throws {
        let page = String(repeating: "x", count: 100)
        let extracted = try DeepSeekExtractor.assemble(
            pageTexts: Array(repeating: page, count: 10), characterBudget: 250
        )
        XCTAssertTrue(extracted.wasTruncated)
        XCTAssertEqual(extracted.pageCount, 10)
        XCTAssertEqual(extracted.includedPages, 2)
        XCTAssertLessThanOrEqual(extracted.text.count, 250)
        // Page granularity: no half-page tail.
        XCTAssertTrue(extracted.text.hasSuffix(page))
        XCTAssertFalse(extracted.text.contains("[Page 3]"))
    }

    func testScannedDocumentWithNoTextLayerIsARefusalNotAnEmptyPrefix() {
        XCTAssertThrowsError(try DeepSeekExtractor.assemble(pageTexts: [nil, "  ", nil])) { error in
            guard case DeepSeekError.noTextLayer(let pages) = error else {
                return XCTFail("expected noTextLayer, got \(error)")
            }
            XCTAssertEqual(pages, 3)
            XCTAssertTrue(error.localizedDescription.contains("Claude"),
                          "the dead end must point somewhere: \(error.localizedDescription)")
        }
    }

    func testExtractsFromARealPDFWithATextLayer() throws {
        let url = try makeTextPDF(pages: ["Hello from page one", "Second page body"])
        defer { try? FileManager.default.removeItem(at: url) }

        let extracted = try DeepSeekExtractor.extract(from: url)
        XCTAssertEqual(extracted.pageCount, 2)
        XCTAssertTrue(extracted.text.hasPrefix("[Page 1]"), extracted.text)
        XCTAssertTrue(extracted.text.contains("Hello from page one"), extracted.text)
        XCTAssertTrue(extracted.text.contains("[Page 2]"), extracted.text)
        XCTAssertTrue(extracted.text.contains("Second page body"), extracted.text)
    }

    // MARK: The cached prefix

    func testPrefixIsByteIdenticalAcrossDifferentQuestions() throws {
        let encoder = DeepSeekRequestBuilder.encoder()
        let bare = DeepSeekRequestBuilder.messages(
            question: plainQuestion(), document: document, title: "paper.pdf", canSeeImages: false
        )
        let loaded = DeepSeekRequestBuilder.messages(
            question: loadedQuestion(), document: document, title: "paper.pdf", canSeeImages: false
        )

        XCTAssertEqual(bare.count, 2)
        XCTAssertEqual(bare[0].role, "system")
        XCTAssertEqual(bare[1].role, "user")
        XCTAssertEqual(try encoder.encode(bare[0]), try encoder.encode(loaded[0]))

        // …and the questions really do differ, so the test isn't vacuous.
        XCTAssertNotEqual(try encoder.encode(bare), try encoder.encode(loaded))
    }

    func testPrefixCarriesTheFrozenPreambleAndTheWholeDocument() {
        let system = DeepSeekRequestBuilder.systemMessage(document: document, title: "paper.pdf")
        XCTAssertTrue(system.hasPrefix(DeepSeekRequestBuilder.systemPreamble))
        XCTAssertTrue(system.contains("paper.pdf"))
        XCTAssertTrue(system.hasSuffix(document.text))
    }

    /// See `AnthropicRequestTests.testSystemPromptAsksForLaTeX` — same contract, and it has
    /// to hold on every provider or the renderer is dead weight on that path.
    func testPreambleAsksForLaTeX() {
        let preamble = DeepSeekRequestBuilder.systemPreamble
        XCTAssertTrue(preamble.contains("$$"))
        XCTAssertTrue(preamble.contains("LaTeX"))
        XCTAssertTrue(preamble.contains("\\phi"))
    }

    func testTruncationNoticeRidesInThePrefixNotTheQuestion() {
        let clipped = ExtractedDocument(text: "[Page 1]\nonly this", pageCount: 400, includedPages: 3)
        let system = DeepSeekRequestBuilder.systemMessage(document: clipped, title: "big.pdf")
        XCTAssertTrue(system.contains("pages 1–3 of 400"), system)

        // Stable per document: two different questions still share the prefix.
        let a = DeepSeekRequestBuilder.messages(question: plainQuestion(), document: clipped,
                                                title: "big.pdf", canSeeImages: false)
        let b = DeepSeekRequestBuilder.messages(question: loadedQuestion(), document: clipped,
                                                title: "big.pdf", canSeeImages: false)
        XCTAssertEqual(a[0].content, b[0].content)
    }

    func testVolatileContentIsConfinedToTheUserTurn() {
        let user = DeepSeekRequestBuilder.userMessage(for: loadedQuestion(), canSeeImages: false)
        XCTAssertTrue(user.contains("page 12"))
        XCTAssertTrue(user.contains("Table 3 reports the ablation results."))
        XCTAssertTrue(user.hasSuffix("Question: Explain this table."), user)

        let system = DeepSeekRequestBuilder.systemMessage(document: document, title: "paper.pdf")
        XCTAssertFalse(system.contains("Explain this table."),
                       "the question must never enter the cached prefix")
    }

    // MARK: Vision degradation (PLAN.md §4)

    func testCropWithTextFallsBackToThatTextInsteadOfTheImage() {
        let user = DeepSeekRequestBuilder.userMessage(for: loadedQuestion(), canSeeImages: false)
        XCTAssertTrue(user.contains("cannot see images"), user)
        XCTAssertTrue(user.contains("Table 3"), user)
        XCTAssertFalse(user.contains("iVBOR"), "no base64 image data on a text-only provider")
        XCTAssertFalse(user.contains(Data([0x89, 0x50, 0x4E, 0x47]).base64EncodedString()))
    }

    func testCropWithNoTextLayerSaysWhatItCouldNotSee() {
        var question = Question(text: "What does this figure show?")
        question.regionImagePNG = Data([0x89])
        question.regionPage = 7
        let user = DeepSeekRequestBuilder.userMessage(for: question, canSeeImages: false)
        XCTAssertTrue(user.contains("no selectable text"), user)
        XCTAssertTrue(user.contains("page 7"), user)
    }

    func testVisionProvidersGetNoCropChatterInTheText() {
        let user = DeepSeekRequestBuilder.userMessage(for: loadedQuestion(), canSeeImages: true)
        XCTAssertFalse(user.contains("cannot see images"), user)
    }

    // MARK: Request envelope

    func testEnvelopeStreamsWithUsageAndNamesTheModel() throws {
        let body = DeepSeekRequestBuilder.body(
            question: plainQuestion(), document: document, title: "paper.pdf",
            model: .v4Pro, thinking: .low, canSeeImages: false
        )
        XCTAssertEqual(body.model, "deepseek-v4-pro")
        XCTAssertTrue(body.stream)
        XCTAssertEqual(body.maxTokens, DeepSeekRequestBuilder.maxTokens(for: .low))
        XCTAssertEqual(body.messages.count, 2, "each question is an independent conversation")

        let json = try XCTUnwrap(String(data: try DeepSeekRequestBuilder.encoder().encode(body),
                                        encoding: .utf8))
        // Without include_usage the stream carries no usage, and the "% cached"
        // cache-regression alarm goes blind.
        XCTAssertTrue(json.contains("\"include_usage\":true"), json)
        XCTAssertTrue(json.contains("\"thinking\":{\"type\":\"enabled\"}"), json)
        XCTAssertTrue(json.contains("\"reasoning_effort\":\"low\""), json)
    }

    func testThinkingOffDisablesItAndSendsNoEffort() throws {
        let body = DeepSeekRequestBuilder.body(
            question: plainQuestion(), document: document, title: "paper.pdf",
            model: .v4Flash, thinking: .off, canSeeImages: false
        )
        let json = try XCTUnwrap(String(data: try DeepSeekRequestBuilder.encoder().encode(body),
                                        encoding: .utf8))
        XCTAssertTrue(json.contains("\"thinking\":{\"type\":\"disabled\"}"), json)
        XCTAssertFalse(json.contains("reasoning_effort"), json)
    }

    /// Reasoning spends the same budget as the answer, so more effort has to buy
    /// more room — otherwise the thinking eats the answer and the reader gets a
    /// sentence that stops mid-word.
    func testOutputBudgetGrowsWithThinkingEffort() {
        let budgets = DeepSeekThinking.allCases.map(DeepSeekRequestBuilder.maxTokens(for:))
        XCTAssertEqual(budgets, budgets.sorted(), "budget must not shrink as effort rises")
        XCTAssertGreaterThanOrEqual(DeepSeekRequestBuilder.maxTokens(for: .off), 16_000)
        XCTAssertGreaterThan(DeepSeekRequestBuilder.maxTokens(for: .low),
                             DeepSeekRequestBuilder.maxTokens(for: .off),
                             "thinking has to be paid for out of somewhere")
        for thinking in DeepSeekThinking.allCases {
            XCTAssertLessThanOrEqual(DeepSeekRequestBuilder.maxTokens(for: thinking), 384_000,
                                     "the models cap output at 384K")
        }
    }

    func testRetiredModelAliasesAreNotOffered() {
        let ids = DeepSeekModel.allCases.map(\.rawValue)
        XCTAssertEqual(ids, ["deepseek-v4-flash", "deepseek-v4-pro"])
        XCTAssertFalse(ids.contains("deepseek-chat"), "retired 2026-07-24")
        XCTAssertFalse(ids.contains("deepseek-reasoner"), "retired 2026-07-24")
    }

    // MARK: Stream decoding

    func testTextDeltasAccumulateAndReasoningIsSkipped() throws {
        var decoder = DeepSeekStreamDecoder()
        var text = ""
        for payload in [
            #"{"choices":[{"delta":{"role":"assistant","content":""}}]}"#,
            #"{"choices":[{"delta":{"reasoning_content":"let me think"}}]}"#,
            #"{"choices":[{"delta":{"content":"The claim"}}]}"#,
            #"{"choices":[{"delta":{"content":" is X."}}]}"#,
        ] {
            for event in try decoder.consume(payload) {
                if case .textDelta(let chunk) = event { text += chunk }
            }
        }
        XCTAssertEqual(text, "The claim is X.")
    }

    func testUsageChunkWithEmptyChoicesIsSafeAndMapsHitsToCacheReads() throws {
        var decoder = DeepSeekStreamDecoder()
        _ = try decoder.consume(#"{"choices":[{"delta":{"content":"hi"}}]}"#)

        // The real usage chunk: choices is *always* an empty array here.
        let usageChunk = #"{"choices":[],"usage":{"prompt_tokens":12000,"completion_tokens":210,"#
            + #""prompt_cache_hit_tokens":11840,"prompt_cache_miss_tokens":160}}"#
        XCTAssertTrue(try decoder.consume(usageChunk).isEmpty)

        let events = try decoder.consume("[DONE]")
        XCTAssertTrue(decoder.sawTerminator)

        guard case .usage(let input, let read, let write, let output) = events.first else {
            return XCTFail("expected usage, got \(events)")
        }
        // miss → input, hit → cacheRead, and no write concept on this API.
        XCTAssertEqual(input, 160)
        XCTAssertEqual(read, 11840)
        XCTAssertEqual(write, 0)
        XCTAssertEqual(output, 210)
        guard case .done = events.last else { return XCTFail("expected .done last") }

        // The "% cached" indicator has to read as a cache hit, not 0%.
        var card = QACard(question: plainQuestion())
        card.inputTokens = input
        card.cacheReadTokens = read
        card.cacheWriteTokens = write
        let fraction = try XCTUnwrap(card.cachedFraction)
        XCTAssertGreaterThan(fraction, 0.98)
    }

    func testTerminatorIsNotTreatedAsJSON() throws {
        var decoder = DeepSeekStreamDecoder()
        let events = try decoder.consume(" [DONE] ")
        XCTAssertTrue(decoder.sawTerminator)
        XCTAssertEqual(events.count, 2, "[DONE] is the only reliable end of stream")
    }

    func testTruncatedAnswerIsFlaggedBesideIt() throws {
        var decoder = DeepSeekStreamDecoder()
        _ = try decoder.consume(#"{"choices":[{"delta":{"content":"…"},"finish_reason":"length"}]}"#)
        let events = try decoder.consume("[DONE]")
        let notices = events.compactMap { event -> String? in
            if case .notice(let text) = event { return text }
            return nil
        }
        XCTAssertEqual(notices.count, 1)
        XCTAssertTrue(notices[0].contains("cut short"), notices[0])
    }

    /// The notice names the ceiling it hit, because 16K / 64K / 128K / 256K each
    /// identify a thinking setting — which is how a "the limit is still 16K"
    /// report can be told apart from a genuinely long answer.
    func testTruncationNoticeNamesTheBudgetTheRequestCarried() throws {
        var decoder = DeepSeekStreamDecoder(
            outputBudget: DeepSeekRequestBuilder.maxTokens(for: .high)
        )
        _ = try decoder.consume(#"{"choices":[{"delta":{"content":"…"},"finish_reason":"length"}]}"#)
        let notice = try XCTUnwrap(try decoder.consume("[DONE]").compactMap { event -> String? in
            if case .notice(let text) = event { return text }
            return nil
        }.first)
        XCTAssertTrue(notice.contains("128K-token"), notice)
    }

    func testMalformedPayloadsAreSkippedButErrorsThrow() throws {
        var decoder = DeepSeekStreamDecoder()
        XCTAssertTrue(try decoder.consume("not json at all").isEmpty)
        XCTAssertTrue(try decoder.consume("").isEmpty)
        XCTAssertTrue(try decoder.consume(#"{"choices":[{"delta":{}}]}"#).isEmpty)

        XCTAssertThrowsError(
            try decoder.consume(#"{"error":{"type":"server_error","message":"upstream exploded"}}"#)
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("upstream exploded"),
                          error.localizedDescription)
        }
    }

    func testStreamThatDiesBeforeDoneStillReportsUsage() throws {
        var decoder = DeepSeekStreamDecoder()
        _ = try decoder.consume(#"{"choices":[{"delta":{"content":"partial"}}]}"#)
        XCTAssertFalse(decoder.sawTerminator)

        let events = decoder.finalEvents()
        guard case .usage = events.first else { return XCTFail("expected usage") }
        guard case .done = events.last else { return XCTFail("expected .done") }
    }

    // MARK: Errors

    func testInsufficientBalanceGetsItsOwnMessage() {
        let error = DeepSeekError.api(status: 402, detail: "")
        XCTAssertTrue(error.localizedDescription.contains("balance"), error.localizedDescription)

        let unauthorized = DeepSeekError.api(status: 401, detail: "")
        XCTAssertTrue(unauthorized.localizedDescription.contains("API key"))
    }

    func testErrorDetailReadsTheOpenAIStyleEnvelope() {
        let body = Data(#"{"error":{"type":"invalid_request_error","message":"bad model"}}"#.utf8)
        XCTAssertEqual(DeepSeekProvider.errorDetail(from: body),
                       "invalid_request_error: bad model")
    }

    // MARK: Session store

    func testSessionStoreEvictsOldestAndKeyTracksTheFile() throws {
        let store = DeepSeekTextStore.shared
        let keys = (0..<12).map { "evict-test-\(UUID().uuidString)-\($0)" }
        for key in keys {
            store.store(ExtractedDocument(text: key, pageCount: 1, includedPages: 1), for: key)
        }
        XCTAssertNil(store.lookup(keys[0]), "oldest entries are evicted, and a miss re-extracts")
        XCTAssertEqual(store.lookup(keys[11])?.text, keys[11])

        // The key folds in size/mtime, so editing the file invalidates it.
        let url = try makeTextPDF(pages: ["one"])
        defer { try? FileManager.default.removeItem(at: url) }
        let before = DeepSeekProvider.storeKey(for: url)
        try Data(repeating: 0, count: 32).write(to: url)
        XCTAssertNotEqual(before, DeepSeekProvider.storeKey(for: url))
    }

    // MARK: Helpers

    /// A real PDF with a real text layer, so `PDFPage.string` has something to find.
    private func makeTextPDF(pages: [String]) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("deepseek-test-\(UUID().uuidString).pdf")
        var mediaBox = CGRect(x: 0, y: 0, width: 400, height: 300)
        let context = try XCTUnwrap(CGContext(url as CFURL, mediaBox: &mediaBox, nil))

        for text in pages {
            context.beginPDFPage(nil)
            let attributed = NSAttributedString(
                string: text,
                attributes: [.font: NSFont.systemFont(ofSize: 18)]
            )
            let line = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 40, y: 150)
            CTLineDraw(line, context)
            context.endPDFPage()
        }
        context.closePDF()
        return url
    }
}
