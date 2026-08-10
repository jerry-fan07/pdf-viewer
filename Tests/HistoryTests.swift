import XCTest
@testable import ClaudePDF

/// Phase 6: per-document history is display-only state that has to survive a
/// reopen exactly as the reader left it — and has to *not* record things that
/// would read as bugs on the way back (a half-streamed answer, a megabyte crop).
final class HistoryTests: XCTestCase {

    private var directory: URL!
    private var store: HistoryStore!
    private var document: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-tests-\(UUID().uuidString)")
        store = HistoryStore(directory: directory)
        document = directory.appendingPathComponent("doc.pdf")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("%PDF-1.4 fake".utf8).write(to: document)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Round trip

    func testRoundTripsEveryFieldTheCardShows() throws {
        var question = Question(text: "What does Table 2 report?")
        question.selectedText = "mean recall"
        question.selectedTextPage = 12
        question.regionPage = 12

        var card = QACard(question: question, providerName: "Claude (API)", modelName: "Claude Opus 5")
        card.answer = "It reports recall at k."
        card.citations = [Citation(page: 12, citedText: "recall@10")]
        card.notices = ["approaching the rate limit"]
        card.inputTokens = 40
        card.cacheReadTokens = 26_941
        card.cacheWriteTokens = 78
        card.outputTokens = 310
        card.costUSD = 0.0212
        card.isStreaming = false

        store.save(StoredHistory(documentURL: document, cards: [card]), for: document)
        let restored = try XCTUnwrap(store.load(for: document)).cards.map { QACard(stored: $0) }

        XCTAssertEqual(restored.count, 1)
        let back = try XCTUnwrap(restored.first)
        XCTAssertEqual(back.id, card.id)
        XCTAssertEqual(back.question.text, question.text)
        XCTAssertEqual(back.question.selectedText, "mean recall")
        XCTAssertEqual(back.question.selectedTextPage, 12)
        XCTAssertEqual(back.answer, card.answer)
        XCTAssertEqual(back.citations.map(\.page), [12])
        XCTAssertEqual(back.notices, ["approaching the rate limit"])
        XCTAssertEqual(back.providerName, "Claude (API)")
        XCTAssertEqual(back.modelName, "Claude Opus 5")
        XCTAssertEqual(back.cacheReadTokens, 26_941)
        XCTAssertEqual(back.outputTokens, 310)
        XCTAssertEqual(back.costUSD, 0.0212)
        XCTAssertFalse(back.isStreaming, "a restored card is never mid-stream")
    }

    /// Where one conversation ended and the next began is part of the transcript:
    /// without it, a reopened document would draw two unrelated conversations as
    /// one continuous thread.
    func testConversationBoundariesSurviveAReopen() throws {
        let first = UUID(), second = UUID()
        let cards = ["a", "b", "c"].enumerated().map { index, text -> QACard in
            var card = QACard(threadID: index < 2 ? first : second,
                              question: Question(text: text))
            card.isStreaming = false
            return card
        }
        store.save(StoredHistory(documentURL: document, cards: cards), for: document)

        let back = try XCTUnwrap(store.load(for: document)).cards.map { QACard(stored: $0) }
        XCTAssertEqual(back.map(\.threadID), [first, first, second])
    }

    /// Transcripts written before conversations were threaded have no ids at all.
    /// They were one conversation, and have to read back as one rather than as a
    /// break before every question.
    func testATranscriptWrittenBeforeThreadsReadsBackAsOneConversation() throws {
        let legacy = StoredHistory(
            documentPath: document.path,
            cards: (0..<3).map { index in
                StoredCard(id: UUID(), askedAt: Date(), questionText: "q\(index)",
                           answer: "a\(index)", citations: [], notices: [],
                           providerName: "Claude (API)")
            }
        )
        store.save(legacy, for: document)

        let shared = UUID()
        let back = try XCTUnwrap(store.load(for: document)).cards
            .map { QACard(stored: $0, fallbackThreadID: shared) }
        XCTAssertEqual(Set(back.map(\.threadID)), [shared])
    }

    /// The provider badge is per card precisely so a transcript can outlive the
    /// provider that produced it.
    func testRestoredCardKeepsTheProviderThatAnsweredIt() throws {
        var card = QACard(question: Question(text: "q"), providerName: "DeepSeek", modelName: "DeepSeek V4 Flash")
        card.isStreaming = false
        store.save(StoredHistory(documentURL: document, cards: [card]), for: document)

        let back = try XCTUnwrap(store.load(for: document)?.cards.first)
        XCTAssertEqual(back.providerName, "DeepSeek")
        XCTAssertEqual(back.modelName, "DeepSeek V4 Flash")
    }

    /// A restored card carries no live pricing: its cost was computed at the
    /// rates in force when it was asked, and a later model change must not
    /// silently reprice an old answer.
    func testRestoredCardDoesNotCarryLivePricing() throws {
        var card = QACard(question: Question(text: "q"), pricing: AnthropicModel.opus5.pricing)
        card.costUSD = 1.5
        card.isStreaming = false
        store.save(StoredHistory(documentURL: document, cards: [card]), for: document)

        let back = QACard(stored: try XCTUnwrap(store.load(for: document)?.cards.first))
        XCTAssertNil(back.pricing)
        XCTAssertEqual(back.costUSD, 1.5)
    }

    // MARK: What must not be written

    func testStreamingCardsAreNotPersisted() {
        let finished = { () -> QACard in
            var card = QACard(question: Question(text: "done"))
            card.isStreaming = false
            return card
        }()
        let inFlight = QACard(question: Question(text: "still going"))

        let history = StoredHistory(documentURL: document, cards: [finished, inFlight])
        XCTAssertEqual(history.cards.map(\.questionText), ["done"])
    }

    func testCardLimitDropsOldestFirst() throws {
        let cards = (0..<(HistoryStore.cardLimit + 10)).map { index -> QACard in
            var card = QACard(question: Question(text: "q\(index)"))
            card.isStreaming = false
            return card
        }
        store.save(StoredHistory(documentURL: document, cards: cards), for: document)

        let kept = try XCTUnwrap(store.load(for: document)).cards
        XCTAssertEqual(kept.count, HistoryStore.cardLimit)
        XCTAssertEqual(kept.first?.questionText, "q10", "the oldest questions are the ones dropped")
        XCTAssertEqual(kept.last?.questionText, "q\(HistoryStore.cardLimit + 9)")
    }

    /// Crops go in at up to 1600px; a transcript of a hundred of those would be
    /// hundreds of megabytes. The stored copy is display-sized.
    func testCropIsDownscaledForStorage() throws {
        let page = PDFFixtures.makePage()
        let capture = try XCTUnwrap(CropRenderer.capture(
            page: page, pageIndex: 0, pageRect: page.bounds(for: .cropBox), scale: 8
        ))
        let originalSize = try XCTUnwrap(PNGInspector.size(of: capture.pngData))
        XCTAssertGreaterThan(max(originalSize.width, originalSize.height), 800)

        var question = Question(text: "what is this figure?")
        question.regionImagePNG = capture.pngData
        question.regionPage = 1
        var card = QACard(question: question)
        card.isStreaming = false

        let stored = try XCTUnwrap(StoredHistory(documentURL: document, cards: [card]).cards.first)
        let thumbnail = try XCTUnwrap(stored.regionThumbnailPNG)
        let size = try XCTUnwrap(PNGInspector.size(of: thumbnail))
        XCTAssertLessThanOrEqual(max(size.width, size.height), CGFloat(HistoryStore.thumbnailMaxEdge))
        XCTAssertLessThan(thumbnail.count, capture.pngData.count)
    }

    // MARK: Keying

    /// The key folds in size and modification date, so a document edited behind
    /// an open window gets a fresh transcript rather than one describing bytes
    /// that no longer exist.
    func testEditingTheDocumentInvalidatesItsHistory() throws {
        var card = QACard(question: Question(text: "q"))
        card.isStreaming = false
        store.save(StoredHistory(documentURL: document, cards: [card]), for: document)
        XCTAssertNotNil(store.load(for: document))

        try Data("%PDF-1.4 fake, but longer now".utf8).write(to: document)
        XCTAssertNil(store.load(for: document), "history keyed to the old bytes must not be reused")
    }

    func testSeparateDocumentsGetSeparateFiles() {
        let other = directory.appendingPathComponent("other.pdf")
        try? Data("%PDF-1.4 other".utf8).write(to: other)
        XCTAssertNotEqual(store.fileURL(for: document), store.fileURL(for: other))
    }

    func testMissingHistoryIsEmptyNotAnError() {
        XCTAssertNil(store.load(for: directory.appendingPathComponent("never-saved.pdf")))
    }

    func testAFileFromANewerVersionIsIgnored() throws {
        var history = StoredHistory(documentURL: document, cards: [])
        history.version = StoredHistory.currentVersion + 1
        let data = try JSONEncoder().encode(history)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: store.fileURL(for: document))

        XCTAssertNil(store.load(for: document))
    }

    func testClearRemovesTheFile() throws {
        var card = QACard(question: Question(text: "q"))
        card.isStreaming = false
        store.save(StoredHistory(documentURL: document, cards: [card]), for: document)
        XCTAssertNotNil(store.load(for: document))

        store.clear(for: document)
        XCTAssertNil(store.load(for: document))
    }
}
