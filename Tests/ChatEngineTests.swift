import XCTest
@testable import ClaudePDF

/// Phase 7: a document can change provider without being reopened.
///
/// The three things that make that safe rather than merely possible are all
/// tested here: an attach already in flight is abandoned (not left racing the new
/// one), an attachment already paid for is reused instead of bought twice, and a
/// transcript keeps saying who actually answered each of its cards.
@MainActor
final class ChatEngineTests: XCTestCase {

    private var directory: URL!
    private var history: HistoryStore!
    private var info: PDFDocumentInfo!
    private var log: AttachLog!
    private var originalOCRSetting: Any?

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("engine-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let document = directory.appendingPathComponent("doc.pdf")
        try Data("%PDF-1.4 fake".utf8).write(to: document)

        history = HistoryStore(directory: directory)
        info = PDFDocumentInfo(fileURL: document, pageCount: 3)
        log = AttachLog()
        originalOCRSetting = UserDefaults.standard.object(forKey: AppSettings.ocrEnabledKey)
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.set(originalOCRSetting, forKey: AppSettings.ocrEnabledKey)
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Switching

    func testSwitchingProviderReattachesWithTheNewOne() async throws {
        let claude = stub(id: "claude-code", name: "Claude (subscription)")
        let deepseek = stub(id: "deepseek", name: "DeepSeek", vision: false)
        let engine = ChatEngine(provider: claude, history: history)

        engine.attach(info)
        try await waitUntil { await self.log.attaches("claude-code") == 1 }

        engine.switchProvider(to: deepseek, isWindowOverride: true)
        try await waitUntil { await self.log.attaches("deepseek") == 1 }

        XCTAssertEqual(engine.providerName, "DeepSeek")
        XCTAssertEqual(engine.providerID, "deepseek")
        XCTAssertTrue(engine.providerIsWindowOverride)
        XCTAssertNil(engine.attachError)
    }

    func testSwitchingBackReusesTheAttachmentItAlreadyHas() async throws {
        let claude = stub(id: "claude-code", name: "Claude (subscription)")
        let deepseek = stub(id: "deepseek", name: "DeepSeek", vision: false)
        let engine = ChatEngine(provider: claude, history: history)

        engine.attach(info)
        try await waitUntil { await self.log.attaches("claude-code") == 1 }
        engine.switchProvider(to: deepseek)
        try await waitUntil { await self.log.attaches("deepseek") == 1 }

        // Back to the one this document is already prepared for: no second
        // upload, no second prime, and so no second cache write.
        engine.switchProvider(to: claude)
        try await waitUntil { engine.attachStatus == nil }
        let answer = try await ask(engine, "and now?")

        XCTAssertTrue(answer.contains("claude-code"), answer)
        let attaches = await log.attaches("claude-code")
        XCTAssertEqual(attaches, 1, "switching back re-primed a document that was already prepared")
    }

    func testSwitchingAbandonsAnAttachStillInFlight() async throws {
        let slow = stub(id: "deepseek", name: "DeepSeek", vision: false, stall: .seconds(30))
        let fast = stub(id: "claude-code", name: "Claude (subscription)")
        let engine = ChatEngine(provider: slow, history: history)

        engine.attach(info)
        try await waitUntil { engine.attachStatus != nil }

        engine.switchProvider(to: fast)
        try await waitUntil { await self.log.cancels("deepseek") == 1 }
        try await waitUntil { await self.log.attaches("claude-code") == 1 }

        // The abandoned attach must not write its own failure over the new state.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(engine.attachError)
        XCTAssertNil(engine.attachStatus)
    }

    func testAskTimeSettingsSwapTheProviderWithoutReattaching() async throws {
        // Subscription effort and DeepSeek thinking change how a question is
        // asked, not what was uploaded — same id, same model, same handle.
        let low = stub(id: "deepseek", name: "DeepSeek", vision: false, marker: "low")
        let high = stub(id: "deepseek", name: "DeepSeek", vision: false, marker: "high")
        let engine = ChatEngine(provider: low, history: history)

        engine.attach(info)
        try await waitUntil { await self.log.attaches("deepseek") == 1 }

        engine.switchProvider(to: high)
        let answer = try await ask(engine, "same document, deeper thinking")

        XCTAssertTrue(answer.contains("high"), "the new instance never took over: \(answer)")
        let attaches = await log.attaches("deepseek")
        XCTAssertEqual(attaches, 1, "an ask-time setting change paid for a fresh attach")
    }

    func testModelChangeReattaches() async throws {
        // Anthropic's page cap is per model (Haiku stops at 100), so a model
        // change has to re-run attach and be refused there, not at question one.
        let opus = stub(id: "anthropic", name: "Claude (API)", model: "Claude Opus 5")
        let haiku = stub(id: "anthropic", name: "Claude (API)", model: "Claude Haiku 4.5")
        let engine = ChatEngine(provider: opus, history: history)

        engine.attach(info)
        try await waitUntil { await self.log.attaches("anthropic") == 1 }

        engine.switchProvider(to: haiku)
        try await waitUntil { await self.log.attaches("anthropic") == 2 }
    }

    func testSwitchingIsRefusedWhileAnAnswerStreams() async throws {
        let slow = stub(id: "claude-code", name: "Claude (subscription)", askStall: .seconds(30))
        let other = stub(id: "deepseek", name: "DeepSeek", vision: false)
        let engine = ChatEngine(provider: slow, history: history)

        engine.attach(info)
        engine.ask(Question(text: "what is this about?"))
        try await waitUntil { engine.isStreaming }

        engine.switchProvider(to: other)
        XCTAssertEqual(engine.providerName, "Claude (subscription)")
        engine.cancel()
    }

    // MARK: The transcript across a switch

    func testAnsweredCardsKeepTheProviderThatAnsweredThem() async throws {
        let claude = stub(id: "anthropic", name: "Claude (API)", model: "Claude Opus 5")
        let deepseek = stub(id: "deepseek", name: "DeepSeek", vision: false, model: "DeepSeek V4")
        let engine = ChatEngine(provider: claude, history: history)

        engine.attach(info)
        _ = try await ask(engine, "who wrote this?")

        engine.switchProvider(to: deepseek)
        try await waitUntil { await self.log.attaches("deepseek") == 1 }
        _ = try await ask(engine, "and now?")

        XCTAssertEqual(engine.cards.count, 2, "a provider switch reset the transcript")
        XCTAssertEqual(engine.cards[0].providerName, "Claude (API)")
        XCTAssertEqual(engine.cards[0].modelName, "Claude Opus 5")
        XCTAssertEqual(engine.cards[1].providerName, "DeepSeek")
        XCTAssertEqual(engine.cards[1].modelName, "DeepSeek V4")
    }

    // MARK: Cancelling an attach

    func testCancellingAnAttachStopsItAndOffersARetry() async throws {
        let slow = stub(id: "deepseek", name: "DeepSeek", vision: false, stall: .seconds(30))
        let engine = ChatEngine(provider: slow, history: history)

        engine.attach(info)
        try await waitUntil { engine.attachStatus != nil }

        engine.cancelAttach()
        try await waitUntil { await self.log.cancels("deepseek") == 1 }

        XCTAssertNil(engine.attachStatus)
        XCTAssertNotNil(engine.attachError, "a cancelled attach left the panel with nothing to say")
        XCTAssertTrue(engine.canRetryAttach)

        engine.retryAttach()
        try await waitUntil { await self.log.attaches("deepseek") == 2 }
        engine.cancelAttach()
    }

    func testAskingAfterACancelledAttachStartsAFreshOne() async throws {
        let provider = stub(id: "claude-code", name: "Claude (subscription)", stall: .milliseconds(80))
        let engine = ChatEngine(provider: provider, history: history)

        engine.attach(info)
        try await waitUntil { engine.attachStatus != nil }
        engine.cancelAttach()
        try await waitUntil { await self.log.cancels("claude-code") == 1 }

        // No task left behind, so the question itself is the retry.
        let answer = try await ask(engine, "start over then")
        XCTAssertTrue(answer.contains("claude-code"), answer)
        XCTAssertNil(engine.cards[0].error)
    }

    func testAFailedAttachIsRetriedByTheNextQuestion() async throws {
        let failing = stub(id: "deepseek", name: "DeepSeek", vision: false,
                           failure: ProviderError.notConfigured("Add a DeepSeek API key in Settings"))
        let engine = ChatEngine(provider: failing, history: history)

        engine.attach(info)
        try await waitUntil { engine.attachError != nil }
        XCTAssertTrue(engine.attachError?.contains("DeepSeek API key") == true)
        XCTAssertTrue(engine.canRetryAttach)

        engine.ask(Question(text: "anything?"))
        try await waitUntil { await self.log.attaches("deepseek") == 2 }
        try await waitUntil { !engine.isStreaming }
        XCTAssertNotNil(engine.cards[0].error, "a failing attach reported a successful answer")
    }

    // MARK: Staged crops across a switch

    func testStagedCropDegradesToItsTextWhenTheProviderCannotSeeImages() async throws {
        let claude = stub(id: "claude-code", name: "Claude (subscription)")
        let deepseek = stub(id: "deepseek", name: "DeepSeek", vision: false)
        let engine = ChatEngine(provider: claude, history: history)

        engine.stage(crop: PendingCrop(png: Data("png".utf8), pageNumber: 4,
                                       fallbackText: "Table 2: mean recall"))
        XCTAssertNil(engine.composerNotice, "a vision provider has nothing to warn about")

        engine.switchProvider(to: deepseek)
        XCTAssertEqual(engine.pendingCrop?.pageNumber, 4, "the crop was dropped, not degraded")
        XCTAssertEqual(engine.composerNotice, CropStaging.textOnlyNotice(providerName: "DeepSeek"))

        // …and back: the picture is readable again, so the warning has to go.
        engine.switchProvider(to: claude)
        XCTAssertEqual(engine.pendingCrop?.pageNumber, 4)
        XCTAssertNil(engine.composerNotice)
    }

    func testStagedCropWithNoTextIsDroppedByATextOnlyProvider() async throws {
        UserDefaults.standard.set(false, forKey: AppSettings.ocrEnabledKey)
        let claude = stub(id: "claude-code", name: "Claude (subscription)")
        let deepseek = stub(id: "deepseek", name: "DeepSeek", vision: false)
        let engine = ChatEngine(provider: claude, history: history)

        engine.stage(crop: PendingCrop(png: Data("png".utf8), pageNumber: 9, fallbackText: nil))
        engine.switchProvider(to: deepseek)

        XCTAssertNil(engine.pendingCrop, "a crop nothing can read stayed staged")
        XCTAssertEqual(engine.composerNotice, CropStaging.noVisionNotice(providerName: "DeepSeek"))
    }

    /// The third path a crop can take on a text-only provider: no text under it,
    /// so recognise the pixels and stage what comes back. Vision runs for real.
    func testCropWithNoTextIsRecognisedRatherThanRefused() async throws {
        UserDefaults.standard.set(true, forKey: AppSettings.ocrEnabledKey)
        let claude = stub(id: "claude-code", name: "Claude (subscription)")
        let deepseek = stub(id: "deepseek", name: "DeepSeek", vision: false)
        let engine = ChatEngine(provider: claude, history: history)

        engine.stage(crop: PendingCrop(png: try scanPNG(words: ["SUMMARY"]),
                                       pageNumber: 3, fallbackText: nil))
        engine.switchProvider(to: deepseek)

        try await waitUntil { engine.pendingCrop != nil }
        let recognised = try XCTUnwrap(engine.pendingCrop?.fallbackText)
        XCTAssertTrue(recognised.uppercased().contains("SUMMARY"), "recognised \(recognised)")
        XCTAssertEqual(engine.pendingCrop?.pageNumber, 3, "the page badge was lost in recognition")
        XCTAssertEqual(engine.composerNotice, CropStaging.textOnlyNotice(providerName: "DeepSeek"))
    }

    /// Blank pixels have to end the attempt. Re-deciding on an empty recognition
    /// would ask for recognition again, and Vision would run forever.
    func testACropWithNothingToRecogniseGivesUpOnce() async throws {
        UserDefaults.standard.set(true, forKey: AppSettings.ocrEnabledKey)
        let deepseek = stub(id: "deepseek", name: "DeepSeek", vision: false)
        let engine = ChatEngine(provider: deepseek, history: history)

        engine.stage(crop: PendingCrop(png: try scanPNG(words: [" "]),
                                       pageNumber: 3, fallbackText: nil))

        try await waitUntil {
            engine.composerNotice == CropStaging.unrecognisedNotice(providerName: "DeepSeek")
        }
        XCTAssertNil(engine.pendingCrop)

        // Still settled a moment later: nothing is looping behind the notice.
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(engine.composerNotice,
                       CropStaging.unrecognisedNotice(providerName: "DeepSeek"))
    }

    // MARK: Conversations

    /// The feature in one test: question 2 is asked knowing question 1.
    func testAFollowUpCarriesTheQuestionsBeforeIt() async throws {
        let engine = ChatEngine(provider: stub(id: "anthropic", name: "Claude (API)"),
                                history: history)
        engine.attach(info)

        _ = try await ask(engine, "what is a Kan extension?")
        _ = try await ask(engine, "and why does that matter here?")
        _ = try await ask(engine, "give me an example")

        let sent = await log.conversations()
        XCTAssertEqual(sent.map(\.turns.count), [0, 1, 2],
                       "each question has to be handed the ones before it")
        XCTAssertEqual(sent[2].turns.map(\.question.text),
                       ["what is a Kan extension?", "and why does that matter here?"])
        XCTAssertTrue(sent[2].turns[0].answer.contains("answered by anthropic"),
                      "the answer went into the thread, not just the question")
    }

    /// The other half of the feature. The document is the expensive part, so the
    /// test that matters is not that the thread is gone but that the attachment
    /// survived it: a new conversation must not re-upload, re-extract or re-prime.
    func testANewConversationDropsTheThreadAndKeepsTheDocument() async throws {
        let engine = ChatEngine(provider: stub(id: "anthropic", name: "Claude (API)"),
                                history: history)
        engine.attach(info)

        _ = try await ask(engine, "what is a Kan extension?")
        XCTAssertEqual(engine.conversation.turns.count, 1)

        engine.startNewThread()
        XCTAssertTrue(engine.conversation.isEmpty)

        _ = try await ask(engine, "unrelated: who wrote this?")
        let sent = await log.conversations()
        XCTAssertEqual(sent.map(\.turns.count), [0, 0],
                       "the new conversation was handed the old one's turns")
        let attaches = await log.attaches("anthropic")
        XCTAssertEqual(attaches, 1, "starting a conversation re-prepared the document")
    }

    /// A transcript is one column of cards, but not one conversation. The break is
    /// drawn from these ids, so they are the thing to assert.
    func testCardsAreStampedWithTheConversationTheyWereAskedIn() async throws {
        let engine = ChatEngine(provider: stub(id: "anthropic", name: "Claude (API)"),
                                history: history)
        engine.attach(info)

        _ = try await ask(engine, "first")
        _ = try await ask(engine, "second")
        engine.startNewThread()
        _ = try await ask(engine, "third")

        let threads = engine.cards.map(\.threadID)
        XCTAssertEqual(threads[0], threads[1])
        XCTAssertNotEqual(threads[1], threads[2])
    }

    /// Nothing to end, nothing to do: the affordance is hidden in that state and
    /// pressing its shortcut anyway must not churn the thread id under the cards.
    func testStartingAConversationWithNothingInItChangesNothing() async throws {
        let engine = ChatEngine(provider: stub(id: "anthropic", name: "Claude (API)"),
                                history: history)
        engine.attach(info)
        let before = engine.threadID
        engine.startNewThread()
        XCTAssertEqual(engine.threadID, before)
    }

    /// A handle is one provider's private bookmark. Crossing to another provider
    /// has to keep the conversation and drop the bookmark — the new provider gets
    /// the turns to replay instead.
    func testSwitchingProviderKeepsTheConversationAndDropsTheHandle() async throws {
        let claude = stub(id: "claude-code", name: "Claude (subscription)", session: "session")
        let deepseek = stub(id: "deepseek", name: "DeepSeek", vision: false)
        let engine = ChatEngine(provider: claude, history: history)
        engine.attach(info)

        _ = try await ask(engine, "what is a Kan extension?")
        XCTAssertEqual(engine.conversation.handle, "session-0",
                       "the provider's own thread state was not picked up")

        engine.switchProvider(to: deepseek, isWindowOverride: true)
        try await waitUntil { await self.log.attaches("deepseek") == 1 }
        _ = try await ask(engine, "and in plain words?")

        let toDeepSeek = await log.conversations("deepseek")
        let handed = try XCTUnwrap(toDeepSeek.first)
        XCTAssertNil(handed.handle, "a Claude Code session id was offered to DeepSeek")
        XCTAssertEqual(handed.turns.count, 1, "the conversation was lost at the switch")
        XCTAssertEqual(handed.unhandledTurns.count, 1,
                       "with no handle, every turn has to be replayed")
    }

    /// The provider-side thread advances with each answer, and the engine has to
    /// follow it rather than resuming the same session forever.
    func testTheThreadHandleAdvancesWithEachAnswer() async throws {
        let engine = ChatEngine(provider: stub(id: "claude-code", name: "Claude (subscription)",
                                               session: "session"),
                                history: history)
        engine.attach(info)

        _ = try await ask(engine, "first")
        _ = try await ask(engine, "second")

        XCTAssertEqual(engine.conversation.handle, "session-1")
        XCTAssertEqual(engine.conversation.handledTurns, 2)
        XCTAssertTrue(engine.conversation.unhandledTurns.isEmpty,
                      "nothing needs replaying when the session already has it")

        engine.startNewThread()
        XCTAssertNil(engine.conversation.handle,
                     "a new conversation resumed the old one's session")
    }

    /// A question that failed outright is not a turn: there is no answer to carry,
    /// and replaying the empty one would put two user messages side by side.
    func testAFailedQuestionDoesNotJoinTheConversation() async throws {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let engine = ChatEngine(provider: stub(id: "deepseek", name: "DeepSeek",
                                               vision: false, failure: Boom()),
                                history: history)
        engine.attach(info)

        _ = try await ask(engine, "what does page 3 say?")

        XCTAssertEqual(engine.cards.last?.error, "boom")
        XCTAssertTrue(engine.conversation.turns.isEmpty)
    }

    /// Stop mid-answer and what arrived is still on screen, so a follow-up that
    /// had never heard of it would be the surprise. It is carried — and marked as
    /// not being in any session, so the handle-based path replays it.
    func testAStoppedAnswerIsStillPartOfTheConversation() async throws {
        let name = "Claude (subscription)"
        let engine = ChatEngine(provider: stub(id: "claude-code", name: name, session: "session"),
                                history: history)
        engine.attach(info)
        _ = try await ask(engine, "what is a Kan extension?")
        XCTAssertEqual(engine.conversation.handledTurns, 1)

        // Same provider, now slow enough to interrupt: the attachment and the
        // session it is threading are both untouched by the swap.
        engine.switchProvider(to: stub(id: "claude-code", name: name,
                                       askStall: .seconds(30), session: "session"))
        engine.ask(Question(text: "summarise that"))
        try await waitUntil { engine.cards.last?.answer.isEmpty == false }
        engine.cancel()
        try await waitUntil { !engine.isStreaming }

        XCTAssertEqual(engine.conversation.turns.count, 2, "what arrived before Stop is gone")
        XCTAssertEqual(engine.conversation.handledTurns, 1)
        XCTAssertEqual(engine.conversation.unhandledTurns.map(\.question.text), ["summarise that"],
                       "a stopped answer left no fork behind, so it has to be replayed instead")
    }

    // MARK: Helpers

    /// A crop of an image-only page: pixels with no text layer under them.
    private func scanPNG(words: [String]) throws -> Data {
        let document = PDFFixtures.makeScannedDocument(words: words)
        let page = try XCTUnwrap(document.page(at: 0))
        let (png, _) = try XCTUnwrap(CropRenderer.renderPNG(
            page: page, clampedPageRect: page.bounds(for: .cropBox), scale: 2
        ))
        return png
    }

    private func stub(id: String,
                      name: String,
                      vision: Bool = true,
                      model: String? = nil,
                      marker: String? = nil,
                      stall: Duration = .zero,
                      askStall: Duration = .zero,
                      failure: Error? = nil,
                      session: String? = nil) -> StubProvider
    {
        StubProvider(
            id: id, displayName: name, modelName: model, marker: marker ?? id,
            capabilities: ProviderCapabilities(
                supportsVision: vision, supportsNativePDF: vision, supportsCitations: vision
            ),
            stall: stall, askStall: askStall, failure: failure, session: session, log: log
        )
    }

    /// Ask and wait for the card to finish; returns the answer text.
    private func ask(_ engine: ChatEngine, _ text: String) async throws -> String {
        let before = engine.cards.count
        engine.ask(Question(text: text))
        try await waitUntil(timeout: 10) { engine.cards.count > before && !engine.isStreaming }
        return engine.cards.last?.answer ?? ""
    }

    private func waitUntil(timeout: TimeInterval = 5,
                           file: StaticString = #filePath,
                           line: UInt = #line,
                           _ condition: @MainActor () async -> Bool) async throws
    {
        let deadline = Date().addingTimeInterval(timeout)
        while await !condition() {
            if Date() > deadline {
                XCTFail("timed out waiting for condition", file: file, line: line)
                return
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

// MARK: - Stubs

/// Records what each provider was asked to do, across the actor hops an attach
/// makes. Counting cancellations is the point: "the old attach stopped" is the
/// claim that a switch has to make good on.
private actor AttachLog {
    private var attachCounts: [String: Int] = [:]
    private var cancelCounts: [String: Int] = [:]
    /// Every conversation a provider was handed, in order — what the engine
    /// actually sent is the only evidence that a thread is continuous.
    private var asked: [(id: String, conversation: Conversation)] = []

    func recordAttach(_ id: String) { attachCounts[id, default: 0] += 1 }
    func recordCancel(_ id: String) { cancelCounts[id, default: 0] += 1 }
    func recordAsk(_ id: String, conversation: Conversation) {
        asked.append((id, conversation))
    }

    func attaches(_ id: String) -> Int { attachCounts[id] ?? 0 }
    func cancels(_ id: String) -> Int { cancelCounts[id] ?? 0 }
    func conversations() -> [Conversation] { asked.map(\.conversation) }
    func conversations(_ id: String) -> [Conversation] {
        asked.filter { $0.id == id }.map(\.conversation)
    }
}

private struct StubProvider: ChatProvider {
    let id: String
    let displayName: String
    let modelName: String?
    /// Written into every answer, so a test can tell which *instance* replied
    /// when two of them share an id.
    let marker: String
    let capabilities: ProviderCapabilities
    /// Stands in for a long attach — a scanned document's OCR pass, or an upload.
    let stall: Duration
    let askStall: Duration
    let failure: Error?
    /// Non-nil for a provider that keeps the thread on its own side, the way the
    /// Claude Code path keeps it in a forked CLI session.
    let session: String?
    let log: AttachLog

    var pricing: TokenPricing? { nil }

    func attach(document: PDFDocumentInfo) async throws -> DocumentAttachment {
        try await attach(document: document, progress: { _ in })
    }

    func attach(document: PDFDocumentInfo, progress: @escaping @Sendable (String) -> Void)
        async throws -> DocumentAttachment
    {
        await log.recordAttach(id)
        if stall != .zero {
            progress("Preparing \(displayName)…")
            do {
                try await Task.sleep(for: stall)
            } catch {
                await log.recordCancel(id)
                throw error
            }
        }
        if let failure { throw failure }
        return DocumentAttachment(providerID: id, handle: "\(id)-handle",
                                  title: document.fileURL.lastPathComponent,
                                  sourceURL: document.fileURL)
    }

    func ask(_ question: Question, in attachment: DocumentAttachment, conversation: Conversation)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                await log.recordAsk(id, conversation: conversation)
                if askStall != .zero {
                    continuation.yield(.textDelta("…"))
                    try await Task.sleep(for: askStall)
                }
                continuation.yield(.textDelta("answered by \(marker) from \(attachment.handle)"))
                continuation.yield(.usage(inputTokens: 10, cacheReadTokens: 90,
                                          cacheWriteTokens: 0, outputTokens: 5))
                // Stands in for the Claude Code session chain: a handle the engine
                // is expected to carry into the next question of this conversation
                // and to throw away when the reader starts a new one.
                if let session {
                    continuation.yield(.threadHandle("\(session)-\(conversation.turns.count)"))
                }
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Provider choices

/// The menu is built from these, so their shape is part of the feature.
final class ProviderChoiceTests: XCTestCase {

    func testSwitchableChoicesExcludeAutomatic() {
        XCTAssertFalse(ProviderChoice.switchable.contains(.automatic),
                       "Automatic is a rule for resolving a provider, not a destination")
        XCTAssertEqual(Set(ProviderChoice.switchable).count, ProviderChoice.switchable.count)
    }

    func testEveryConcreteChoiceRoundTripsThroughItsProviderID() {
        for choice in ProviderChoice.switchable {
            let id = try? XCTUnwrap(choice.providerID)
            XCTAssertEqual(id.flatMap { ProviderChoice(providerID: $0) }, choice)
        }
        XCTAssertNil(ProviderChoice.automatic.providerID)
        XCTAssertNil(ProviderChoice(providerID: "nonexistent"))
    }

    /// The menu greys out what can't be picked; the ids it matches on have to be
    /// the ones the providers actually report.
    func testProviderIDsMatchTheProvidersTheyBuild() {
        XCTAssertEqual(ProviderChoice.mock.providerID, MockProvider().id)
        XCTAssertEqual(ProviderChoice.deepseek.providerID, DeepSeekProvider(model: .v4Flash).id)
        XCTAssertEqual(ProviderChoice.anthropicAPI.providerID, AnthropicProvider(model: .opus5).id)
        XCTAssertEqual(ProviderChoice.claudeCode.providerID, ClaudeCodeProvider().id)
    }

    /// Availability is asked with the environment passed in — the property that
    /// reads it for real touches the Keychain, and a unit test that does the same
    /// can sit waiting on an unlock prompt that is never going to arrive.
    func testEveryUnavailableChoiceSaysWhatWouldMakeItAvailable() {
        let missing = ProviderChoice.switchable.compactMap { choice in
            choice.unavailableReason(cliInstalled: false, hasAnthropicKey: false, hasDeepSeekKey: false)
                .map { (choice, $0) }
        }
        XCTAssertEqual(missing.count, 3, "the mock must never be unavailable")
        for (_, reason) in missing {
            XCTAssertFalse(reason.isEmpty)
        }
        XCTAssertTrue(missing.contains { $0.1.contains("Anthropic API key") })
        XCTAssertTrue(missing.contains { $0.1.contains("DeepSeek API key") })
        XCTAssertTrue(missing.contains { $0.1.contains("Claude Code") })
    }

    func testNothingIsUnavailableOnceTheEnvironmentIsThere() {
        for choice in ProviderChoice.switchable {
            XCTAssertNil(choice.unavailableReason(cliInstalled: true, hasAnthropicKey: true,
                                                  hasDeepSeekKey: true), "\(choice)")
        }
    }
}

// MARK: - Crop degradation

/// The decision a crop goes through twice: once when it is dragged, and again
/// every time the provider changes underneath it.
final class CropStagingTests: XCTestCase {

    private let vision = ProviderCapabilities(
        supportsVision: true, supportsNativePDF: true, supportsCitations: true
    )
    private let textOnly = ProviderCapabilities(
        supportsVision: false, supportsNativePDF: false, supportsCitations: false
    )

    private func crop(_ text: String?) -> PendingCrop {
        PendingCrop(png: Data("png".utf8), pageNumber: 7, fallbackText: text)
    }

    func testAVisionProviderTakesTheCropAsItIsWithNoNotice() {
        let decision = CropStaging.decide(for: crop(nil), capabilities: vision,
                                          providerName: "Claude", ocrEnabled: true)
        XCTAssertEqual(decision, .stage(crop(nil), notice: nil))
    }

    func testATextOnlyProviderReadsTheTextUnderTheRegion() {
        let decision = CropStaging.decide(for: crop("Table 2"), capabilities: textOnly,
                                          providerName: "DeepSeek", ocrEnabled: true)
        XCTAssertEqual(decision, .stage(crop("Table 2"),
                                        notice: CropStaging.textOnlyNotice(providerName: "DeepSeek")))
    }

    /// Whitespace under a region is the same as nothing under it — DeepSeek's own
    /// ask-time check treats it that way, and the two must not disagree.
    func testBlankTextUnderTheRegionCountsAsNoText() {
        let decision = CropStaging.decide(for: crop("   \n "), capabilities: textOnly,
                                          providerName: "DeepSeek", ocrEnabled: true)
        XCTAssertEqual(decision, .recognize)
    }

    func testNoTextAndNoOCRIsARefusalThatNamesTheWayOut() {
        let decision = CropStaging.decide(for: crop(nil), capabilities: textOnly,
                                          providerName: "DeepSeek", ocrEnabled: false)
        XCTAssertEqual(decision, .refuse(notice: CropStaging.noVisionNotice(providerName: "DeepSeek")))
        if case .refuse(let notice) = decision {
            XCTAssertTrue(notice.contains("switch to Claude"))
        }
    }
}
