import XCTest
@testable import ClaudePDF

/// Fixtures are real records captured from `claude -p … --output-format stream-json
/// --include-partial-messages --verbose` on CLI 2.1.223, trimmed of noise fields.
final class ClaudeCodeStreamTests: XCTestCase {

    private func drain(_ lines: [String]) throws -> ([ChatEvent], ClaudeCodeStreamDecoder) {
        var decoder = ClaudeCodeStreamDecoder()
        var events: [ChatEvent] = []
        for line in lines { events += try decoder.consume(line) }
        return (events, decoder)
    }

    private func text(in events: [ChatEvent]) -> String {
        events.reduce(into: "") { total, event in
            if case .textDelta(let delta) = event { total += delta }
        }
    }

    private func notices(in events: [ChatEvent]) -> [String] {
        events.compactMap { if case .notice(let text) = $0 { return text } else { return nil } }
    }

    // MARK: Session id

    func testSessionIDIsTakenFromTheInitRecord() throws {
        let (_, decoder) = try drain([
            #"{"type":"system","subtype":"init","cwd":"/tmp","session_id":"cb6fd400-e252-4ae2-a204-8c570ff0ac8d","model":"claude-opus-5[1m]"}"#
        ])
        XCTAssertEqual(decoder.sessionID, "cb6fd400-e252-4ae2-a204-8c570ff0ac8d")
    }

    func testFirstSessionIDWins() throws {
        let (_, decoder) = try drain([
            #"{"type":"system","subtype":"init","session_id":"first"}"#,
            #"{"type":"stream_event","session_id":"second","event":{"type":"message_stop"}}"#,
        ])
        XCTAssertEqual(decoder.sessionID, "first")
    }

    // MARK: Text

    func testTextDeltasAreUnwrappedFromStreamEvents() throws {
        let (events, _) = try drain([
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}},"session_id":"s"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"h"}},"session_id":"s"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"ello"}},"session_id":"s"}"#,
        ])
        XCTAssertEqual(text(in: events), "hello")
    }

    func testThinkingToolAndCompleteMessageRecordsAreIgnored() throws {
        let (events, _) = try drain([
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"pondering"}},"session_id":"s"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"file\":"}},"session_id":"s"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"duplicate of the deltas"}]},"session_id":"s"}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"pdf bytes"}]},"session_id":"s"}"#,
            #"{"type":"invented_next_year","payload":1}"#,
            "",
            "not json at all",
        ])
        XCTAssertEqual(text(in: events), "", "only text_delta should reach the transcript")
    }

    /// The CLI runs an agent loop, so a single question can contain several
    /// message_start…message_stop cycles. Only the final `result` ends the card.
    func testMessageStopDoesNotEndTheAnswer() throws {
        let (events, _) = try drain([
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"reading… "}},"session_id":"s"}"#,
            #"{"type":"stream_event","event":{"type":"message_stop"},"session_id":"s"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"the answer"}},"session_id":"s"}"#,
            #"{"type":"stream_event","event":{"type":"message_stop"},"session_id":"s"}"#,
        ])
        XCTAssertEqual(text(in: events), "reading… the answer")
        XCTAssertFalse(events.contains { if case .done = $0 { return true } else { return false } })
    }

    // MARK: Result

    func testResultCarriesUsageCostAndDone() throws {
        let (events, decoder) = try drain([
            """
            {"type":"result","subtype":"success","is_error":false,"duration_api_ms":4772,\
            "session_id":"s","total_cost_usd":0.0998335,\
            "usage":{"input_tokens":2,"cache_creation_input_tokens":9117,\
            "cache_read_input_tokens":15967,"output_tokens":4}}
            """
        ])

        guard case .usage(let input, let read, let write, let output) = events.first else {
            return XCTFail("result must report usage")
        }
        XCTAssertEqual(input, 2)
        XCTAssertEqual(read, 15_967, "cache_read proves the primed PDF read was reused")
        XCTAssertEqual(write, 9_117)
        XCTAssertEqual(output, 4)

        guard case .done = events.last else { return XCTFail("result must end the answer") }
        XCTAssertEqual(decoder.totalCostUSD ?? 0, 0.0998335, accuracy: 1e-9)
    }

    func testErrorResultThrows() throws {
        var decoder = ClaudeCodeStreamDecoder()
        XCTAssertThrowsError(
            try decoder.consume(
                #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":"session not found","session_id":"s"}"#
            )
        ) { error in
            XCTAssertTrue(error.localizedDescription.contains("session not found"),
                          error.localizedDescription)
        }
    }

    // MARK: Rate limits

    func testRateLimitWarningBecomesANotice() throws {
        let (events, _) = try drain([
            """
            {"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning",\
            "resetsAt":1786122000,"rateLimitType":"seven_day","utilization":0.92,\
            "isUsingOverage":false},"session_id":"s"}
            """
        ])
        let notice = try XCTUnwrap(notices(in: events).first)
        XCTAssertTrue(notice.contains("92%"), notice)
        XCTAssertTrue(notice.contains("seven-day"), notice)
        XCTAssertTrue(notice.contains("resets"), notice)
    }

    func testHealthyRateLimitIsSilent() throws {
        let (events, _) = try drain([
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","utilization":0.1},"session_id":"s"}"#
        ])
        XCTAssertTrue(notices(in: events).isEmpty)
    }
}

final class ClaudeCodePromptTests: XCTestCase {

    func testPrimePromptReadsTheDocumentAndNothingElse() {
        let prompt = ClaudeCodePrompt.prime(documentPath: "/Users/x/paper.pdf")
        XCTAssertTrue(prompt.contains("/Users/x/paper.pdf"))
        XCTAssertTrue(prompt.lowercased().contains("ready"))
    }

    func testAskPromptCarriesSelectionCropAndPageHint() {
        var question = Question(text: "What does this show?")
        question.selectedText = "Table 3 reports the ablation."
        question.selectedTextPage = 12
        question.regionPage = 12
        question.pageHint = 12

        let prompt = ClaudeCodePrompt.ask(question, cropPath: "/tmp/crops/crop-1.png")
        XCTAssertTrue(prompt.contains("Table 3 reports the ablation."))
        XCTAssertTrue(prompt.contains("page 12"))
        XCTAssertTrue(prompt.contains("/tmp/crops/crop-1.png"))
        XCTAssertTrue(prompt.contains("What does this show?"))
        XCTAssertTrue(prompt.contains("page numbers"), "no native citations on this path")
        XCTAssertTrue(prompt.contains("LaTeX"), "models answer in Unicode unless asked")
        XCTAssertTrue(prompt.contains("$$"))
    }

    func testAskPromptOmitsAbsentAttachments() {
        let prompt = ClaudeCodePrompt.ask(Question(text: "Summarise it."), cropPath: nil)
        XCTAssertFalse(prompt.contains("cropped"))
        XCTAssertFalse(prompt.contains("selected"))
        XCTAssertTrue(prompt.contains("Summarise it."))
    }

    /// The thread normally lives in the resumed session, so there is nothing to
    /// retell and the prompt must not start retelling it.
    func testNothingIsReplayedWhenTheSessionAlreadyHasTheConversation() {
        XCTAssertNil(ClaudeCodePrompt.replay([]))
        let prompt = ClaudeCodePrompt.ask(Question(text: "and then?"), cropPath: nil)
        XCTAssertFalse(prompt.contains("Earlier in this conversation"))
    }

    /// The case that needs it: the conversation started on another provider, so
    /// this session has never seen any of it.
    func testAConversationFromAnotherProviderIsRetoldInThePrompt() throws {
        let turns = [
            ConversationTurn(question: Question(text: "what is a Kan extension?"),
                             answer: "A universal way to extend a functor."),
            ConversationTurn(question: Question(text: "and the left one?"), answer: "The colimit."),
        ]
        let prompt = ClaudeCodePrompt.ask(Question(text: "give me an example"),
                                          cropPath: nil, replaying: turns)

        XCTAssertTrue(prompt.contains("what is a Kan extension?"))
        XCTAssertTrue(prompt.contains("A universal way to extend a functor."))
        XCTAssertTrue(prompt.contains("The colimit."))
        // Retold first, so the question the CLI is answering is still the last thing it reads.
        let retold = try XCTUnwrap(prompt.range(of: "Earlier in this conversation"))
        let asked = try XCTUnwrap(prompt.range(of: "Question: give me an example"))
        XCTAssertLessThan(retold.lowerBound, asked.lowerBound)
    }

    func testEffortMapsToCLIArguments() {
        XCTAssertEqual(ClaudeCodeEffort.cliDefault.arguments, [])
        XCTAssertEqual(ClaudeCodeEffort.low.arguments, ["--effort", "low"])
        XCTAssertEqual(ClaudeCodeEffort.max.arguments, ["--effort", "max"])
    }

    func testModelMapsToCLIArguments() {
        XCTAssertEqual(ClaudeCodeModel.cliDefault.arguments, [],
                       "the default must pass no --model, leaving the CLI's own choice alone")
        XCTAssertEqual(ClaudeCodeModel.fable.arguments, ["--model", "fable"])
        XCTAssertEqual(ClaudeCodeModel.opus.arguments, ["--model", "opus"])
        XCTAssertEqual(ClaudeCodeModel.sonnet.arguments, ["--model", "sonnet"])
        XCTAssertEqual(ClaudeCodeModel.haiku.arguments, ["--model", "haiku"])
    }

    /// Raw values are the CLI's public aliases, not pinned model ids: a dated id
    /// here would go stale on the next release, and `claude --model` documents
    /// exactly these four.
    func testModelRawValuesAreCLIAliases() {
        XCTAssertEqual(Set(ClaudeCodeModel.allCases.map(\.rawValue)),
                       ["", "fable", "opus", "sonnet", "haiku"])
        for model in ClaudeCodeModel.allCases where model != .cliDefault {
            XCTAssertFalse(model.rawValue.hasPrefix("claude-"), "\(model.rawValue) is pinned")
        }
    }

    /// The badge says which voice answered, and can only do that when the app
    /// picked the model — on "CLI default" it genuinely doesn't know.
    func testOnlyThePickedModelReachesTheAnswerBadge() {
        XCTAssertNil(ClaudeCodeProvider(model: .cliDefault).modelName)
        XCTAssertEqual(ClaudeCodeProvider(model: .fable).modelName, "Fable")
        XCTAssertEqual(ClaudeCodeProvider(model: .haiku).modelName, "Haiku")
    }
}

final class ClaudeCodeCLITests: XCTestCase {

    /// The single most expensive mistake on this path: an inherited API key
    /// silently outranks subscription auth in `-p` mode and misbills the user.
    func testSanitizedEnvironmentDropsCredentialCarryingVariables() {
        let environment = ClaudeCodeCLI.sanitizedEnvironment()
        for leaked in environment.keys {
            XCTAssertFalse(leaked.hasPrefix("ANTHROPIC_"), "leaked \(leaked)")
            XCTAssertFalse(leaked.hasPrefix("CLAUDE_"), "leaked \(leaked)")
        }
        XCTAssertNotNil(environment["PATH"])
        XCTAssertNotNil(environment["HOME"])
    }

    func testLoginFailureDetection() {
        XCTAssertTrue(ClaudeCodeCLI.looksLikeLoginFailure("Error: Not logged in. Please run /login"))
        XCTAssertTrue(ClaudeCodeCLI.looksLikeLoginFailure("authentication_error: invalid api key"))
        XCTAssertFalse(ClaudeCodeCLI.looksLikeLoginFailure("ENOENT: no such file or directory"))
    }

    /// Exercises the real process wrapper — spawn, sanitized env, async line
    /// reading, exit-status check — without spending any subscription quota.
    func testRunCapturesStdoutFromTheInstalledCLI() async throws {
        guard let executable = try? ClaudeCodeCLI.locate() else {
            throw XCTSkip("Claude Code is not installed on this machine")
        }
        let version = try await ClaudeCodeCLI.version(of: executable)
        XCTAssertEqual(version.split(separator: ".").count, 3, "expected semver, got \(version)")
        XCTAssertNoThrow(try { try XCTUnwrap(Int(version.split(separator: ".")[0])) }())
        try await ClaudeCodeCLI.verifyVersion(of: executable)
    }

    func testWorkingDirectoryIsStableAcrossCalls() throws {
        // Prime and ask must share a cwd or --resume can't find the session.
        let first = try ClaudeCodeCLI.workingDirectory()
        let second = try ClaudeCodeCLI.workingDirectory()
        XCTAssertEqual(first, second)
        XCTAssertTrue(FileManager.default.fileExists(atPath: first.path))
    }
}
