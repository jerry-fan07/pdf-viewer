import SwiftUI
import XCTest
@testable import ClaudePDF

/// The panel shows one conversation — the open tab's — and the timeline rail
/// down its gutter starts and ends with it.
///
/// These rows are computed in one pass *before* the stack sees them, which is the
/// point of the type: a row builder that reached for `cards[index - 1]` would be
/// indexing an array the engine had appended to, prepended a restored transcript
/// onto, or emptied since the row was made — a trap that fires on the scroll
/// rather than on the edit that armed it.
@MainActor
final class TranscriptRowTests: XCTestCase {

    private var history: HistoryStore!
    private var directory: URL!
    private var info: PDFDocumentInfo!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("rows-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        history = HistoryStore(directory: directory)
        let document = directory.appendingPathComponent("doc.pdf")
        try Data("%PDF-1.4 fake".utf8).write(to: document)
        info = PDFDocumentInfo(fileURL: document, pageCount: 2)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Asks `count` questions, starting a new conversation every `threadEvery`.
    private func panel(cards count: Int, threadEvery: Int? = nil) async throws -> ChatPanelView {
        let engine = ChatEngine(provider: InstantProvider(), history: history)
        // Attached, and not incidentally: an engine with no document answers every
        // question with `attachmentMissing`, records no turns, and then *silently
        // refuses* to start a second conversation — which is exactly how a test
        // over thread boundaries can pass while proving nothing.
        engine.attach(info)
        for index in 0..<count {
            if let threadEvery, index > 0, index % threadEvery == 0 {
                engine.startNewThread()
            }
            engine.ask(Question(text: "q\(index)"))
            let deadline = Date().addingTimeInterval(5)
            while engine.isStreaming && Date() < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
            XCTAssertNil(engine.cards.last?.error, "the question never reached the provider")
        }
        XCTAssertEqual(engine.cards.count, count)
        return ChatPanelView(engine: engine, viewer: PDFViewerController())
    }

    /// Two conversations are two tabs, not two stretches of one scroll: the rows
    /// are the open tab's, and opening the other swaps them whole.
    func testRowsAreTheOpenTabsAndNoOtherConversations() async throws {
        let panel = try await panel(cards: 5, threadEvery: 3)

        XCTAssertEqual(panel.transcriptRows.map(\.card.question.text), ["q3", "q4"])
        XCTAssertEqual(panel.transcriptRows.map(\.isFirst), [true, false])
        XCTAssertEqual(panel.transcriptRows.map(\.isLast), [false, true])

        panel.engine.selectThread(panel.engine.threads[0].id)
        XCTAssertEqual(panel.transcriptRows.map(\.card.question.text), ["q0", "q1", "q2"])
        XCTAssertEqual(panel.transcriptRows.map(\.isFirst), [true, false, false])
        XCTAssertEqual(panel.transcriptRows.map(\.isLast), [false, false, true])
    }

    /// A lone answer opens and closes its conversation at once — the rail draws it
    /// as a dot with no line, and neither end may be reported as a continuation.
    func testALoneAnswerIsBothEndsOfItsConversation() async throws {
        let rows = try await panel(cards: 1).transcriptRows
        XCTAssertEqual(rows.count, 1)
        XCTAssertTrue(rows[0].isFirst)
        XCTAssertTrue(rows[0].isLast)
    }

    func testAnEmptyTranscriptHasNoRows() async throws {
        let rows = try await panel(cards: 0).transcriptRows
        XCTAssertTrue(rows.isEmpty)
    }

    /// The shape the crash came in: the reader clears the transcript, and rows are
    /// asked for again. Nothing may be left pointing at a card that is gone.
    func testClearingTheTranscriptLeavesNoRowsBehind() async throws {
        let engine = ChatEngine(provider: InstantProvider(), history: history)
        engine.attach(info)
        for index in 0..<3 {
            engine.ask(Question(text: "q\(index)"))
            let deadline = Date().addingTimeInterval(5)
            while engine.isStreaming && Date() < deadline {
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        let panel = ChatPanelView(engine: engine, viewer: PDFViewerController())
        XCTAssertEqual(panel.transcriptRows.count, 3)

        engine.clearHistory()
        XCTAssertTrue(panel.transcriptRows.isEmpty)
        XCTAssertTrue(engine.conversation.isEmpty, "clearing left the thread behind")
    }
}

/// Answers in one delta, so a transcript of any length can be built in a test
/// without waiting on a stream.
private struct InstantProvider: ChatProvider {
    let id = "instant"
    let displayName = "Instant"
    let capabilities = ProviderCapabilities(
        supportsVision: true, supportsNativePDF: true, supportsCitations: true
    )

    func attach(document: PDFDocumentInfo) async throws -> DocumentAttachment {
        DocumentAttachment(providerID: id, handle: "handle")
    }

    func ask(_ question: Question, in attachment: DocumentAttachment, conversation: Conversation)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("answering \(question.text)"))
            continuation.yield(.done)
            continuation.finish()
        }
    }
}
