import XCTest
@testable import ClaudePDF

/// SSE payloads captured from the shape documented for `/v1/messages`. The decoder
/// has to survive everything Opus 5 actually sends — thinking blocks, pings,
/// fallback blocks — not just the events we care about.
final class AnthropicStreamTests: XCTestCase {

    // MARK: Helpers

    private func drain(_ payloads: [String],
                       outputBudget: Int? = nil) throws -> ([ChatEvent], AnthropicStreamDecoder)
    {
        var decoder = AnthropicStreamDecoder(outputBudget: outputBudget)
        var events: [ChatEvent] = []
        for payload in payloads {
            events += try decoder.consume(Data(payload.utf8))
        }
        return (events, decoder)
    }

    private func text(in events: [ChatEvent]) -> String {
        events.reduce(into: "") { accumulated, event in
            if case .textDelta(let delta) = event { accumulated += delta }
        }
    }

    private func citations(in events: [ChatEvent]) -> [(page: Int, text: String)] {
        events.compactMap { event in
            if case .citation(let page, let text) = event { return (page, text) }
            return nil
        }
    }

    private func notices(in events: [ChatEvent]) -> [String] {
        events.compactMap { event in
            if case .notice(let text) = event { return text }
            return nil
        }
    }

    private func usage(in events: [ChatEvent]) -> (input: Int, read: Int, write: Int, output: Int)? {
        for event in events {
            if case .usage(let input, let read, let write, let output) = event {
                return (input, read, write, output)
            }
        }
        return nil
    }

    // MARK: Text

    func testTextDeltasAccumulateInOrder() throws {
        let (events, _) = try drain([
            #"{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The "}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"thesis"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
        ])
        XCTAssertEqual(text(in: events), "The thesis")
    }

    // MARK: Citations

    func testPageLocationCitationBecomesAChatEvent() throws {
        let (events, _) = try drain([
            """
            {"type":"content_block_delta","index":0,"delta":{"type":"citations_delta",\
            "citation":{"type":"page_location","cited_text":"we find no effect",\
            "document_index":0,"document_title":"paper.pdf",\
            "start_page_number":12,"end_page_number":13}}}
            """
        ])
        let found = citations(in: events)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(found.first?.page, 12, "start_page_number is already 1-indexed")
        XCTAssertEqual(found.first?.text, "we find no effect")
    }

    func testNonPageCitationsAreIgnored() throws {
        let (events, _) = try drain([
            """
            {"type":"content_block_delta","index":0,"delta":{"type":"citations_delta",\
            "citation":{"type":"char_location","cited_text":"x","start_char_index":0,"end_char_index":1}}}
            """
        ])
        XCTAssertTrue(citations(in: events).isEmpty)
    }

    // MARK: Usage

    func testUsageAndDoneAreEmittedAtMessageStop() throws {
        let (events, _) = try drain([
            """
            {"type":"message_start","message":{"id":"msg_1","usage":{"input_tokens":48,\
            "cache_creation_input_tokens":0,"cache_read_input_tokens":132000,"output_tokens":1}}}
            """,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ok"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn","stop_details":null},"usage":{"output_tokens":210}}"#,
            #"{"type":"message_stop"}"#,
        ])

        let totals = try XCTUnwrap(usage(in: events))
        XCTAssertEqual(totals.input, 48)
        XCTAssertEqual(totals.read, 132_000, "cache_read_input_tokens is the caching exit criterion")
        XCTAssertEqual(totals.write, 0)
        XCTAssertEqual(totals.output, 210)

        guard case .done = events.last else { return XCTFail("stream must end with .done") }
    }

    func testCumulativeUsageNeverGoesBackwards() throws {
        let (events, _) = try drain([
            #"{"type":"message_start","message":{"usage":{"input_tokens":100,"output_tokens":1}}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":50}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"},"usage":{"output_tokens":12}}"#,
            #"{"type":"message_stop"}"#,
        ])
        let totals = try XCTUnwrap(usage(in: events))
        XCTAssertEqual(totals.input, 100)
        XCTAssertEqual(totals.output, 50)
    }

    // MARK: Running out of room

    /// A sentence that stops mid-word used to arrive with nothing beside it. The
    /// notice names the budget, because which ceiling was in force is the whole
    /// diagnosis.
    func testTruncatedAnswerIsFlaggedWithTheBudgetItHit() throws {
        let (events, _) = try drain([
            #"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The thes"}}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"max_tokens"},"usage":{"output_tokens":64000}}"#,
            #"{"type":"message_stop"}"#,
        ], outputBudget: AnthropicRequestBuilder.maxTokens(for: .sonnet5))

        let notice = try XCTUnwrap(notices(in: events).first)
        XCTAssertTrue(notice.contains("cut short"), notice)
        XCTAssertTrue(notice.contains("64K-token"), notice)
        guard case .done = events.last else { return XCTFail("stream must still end with .done") }
    }

    /// The other way an answer runs out of room, and the one a bigger output
    /// budget cannot fix — so it must not read as the same failure.
    func testAContextWindowOverrunSaysSomethingElse() throws {
        let (events, _) = try drain([
            #"{"type":"message_delta","delta":{"stop_reason":"model_context_window_exceeded"}}"#,
            #"{"type":"message_stop"}"#,
        ], outputBudget: 64_000)

        let notice = try XCTUnwrap(notices(in: events).first)
        XCTAssertTrue(notice.contains("context window"), notice)
        XCTAssertFalse(notice.contains("output limit"), "a full context is not a small budget")
    }

    func testAnAnswerThatEndedNormallyIsNotFlagged() throws {
        let (events, _) = try drain([
            #"{"type":"message_delta","delta":{"stop_reason":"end_turn"}}"#,
            #"{"type":"message_stop"}"#,
        ], outputBudget: 64_000)
        XCTAssertTrue(notices(in: events).isEmpty)
    }

    // MARK: Tolerance for everything else on the wire

    func testThinkingPingsAndFallbackBlocksAreSkipped() throws {
        let (events, decoder) = try drain([
            #"{"type":"ping"}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"fallback","from":{"model":"claude-opus-5"},"to":{"model":"claude-opus-4-8"}}}"#,
            #"{"type":"content_block_delta","index":2,"delta":{"type":"text_delta","text":"answer"}}"#,
            #"{"type":"some_event_invented_next_year","payload":{"a":1}}"#,
            #"{"type":"message_stop"}"#,
        ])

        XCTAssertEqual(text(in: events), "answer")
        XCTAssertFalse(decoder.wasRefused)
    }

    func testMalformedPayloadIsSkippedRatherThanThrown() throws {
        var decoder = AnthropicStreamDecoder()
        XCTAssertEqual(try decoder.consume(Data("not json".utf8)).count, 0)
        XCTAssertEqual(try decoder.consume(Data(#"{"no_type":true}"#.utf8)).count, 0)
    }

    // MARK: Failures

    func testErrorEventThrows() throws {
        var decoder = AnthropicStreamDecoder()
        XCTAssertThrowsError(
            try decoder.consume(Data(#"{"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#.utf8))
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("overloaded_error"), error.localizedDescription)
        }
    }

    func testRefusalIsRecordedWithItsCategory() throws {
        let (_, decoder) = try drain([
            #"{"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
            """
            {"type":"message_delta","delta":{"stop_reason":"refusal",\
            "stop_details":{"type":"refusal","category":"cyber","explanation":"declined"}},\
            "usage":{"output_tokens":0}}
            """,
            #"{"type":"message_stop"}"#,
        ])
        XCTAssertTrue(decoder.wasRefused)
        XCTAssertEqual(decoder.refusalCategory, "cyber")

        let message = AnthropicError.refused(category: decoder.refusalCategory).localizedDescription
        XCTAssertTrue(message.contains("cyber"), message)
    }

    // MARK: Multipart upload body

    func testMultipartBodyWrapsThePDFAndSanitizesTheFilename() throws {
        let pdf = Data([0x25, 0x50, 0x44, 0x46])   // "%PDF"
        let body = AnthropicMultipart.body(
            fileData: pdf,
            filename: "wei\"rd\nname.pdf",
            mimeType: "application/pdf",
            boundary: "BOUND"
        )
        let rendered = try XCTUnwrap(String(data: body, encoding: .isoLatin1))

        XCTAssertTrue(rendered.hasPrefix("--BOUND\r\n"))
        XCTAssertTrue(rendered.hasSuffix("\r\n--BOUND--\r\n"))
        XCTAssertTrue(rendered.contains("name=\"file\""))
        XCTAssertTrue(rendered.contains("filename=\"weird name.pdf\""), rendered)
        XCTAssertTrue(rendered.contains("Content-Type: application/pdf"))
        XCTAssertTrue(rendered.contains("%PDF"))
    }
}
