import Foundation
import SwiftUI

struct Citation: Identifiable, Hashable {
    let id = UUID()
    let page: Int          // 1-indexed
    let citedText: String
}

/// A text selection staged in the composer ("Ask About Selection" / ⌘L).
struct PendingSelection: Equatable {
    let text: String
    let page: Int?         // 1-indexed
}

struct QACard: Identifiable {
    var id = UUID()
    var askedAt = Date()
    let question: Question
    /// Who answered. Recorded per card because a restored transcript can predate
    /// a provider or model change — the panel header only names the current one.
    var providerName: String = ""
    var modelName: String?
    /// Rates in force when the question was asked. Not persisted: `costUSD` is
    /// computed while the card is live so a later model change can't reprice it.
    var pricing: TokenPricing?
    var answer: String = ""
    var citations: [Citation] = []
    var notices: [String] = []
    var inputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var outputTokens: Int?
    var costUSD: Double?
    var error: String?
    var isStreaming = true

    /// Share of this question's input that was read from the document cache.
    /// Zero on question 2 means something is mutating the cached prefix (PLAN.md §5.1).
    var cachedFraction: Double? {
        guard let read = cacheReadTokens, let input = inputTokens else { return nil }
        let total = read + input + (cacheWriteTokens ?? 0)
        guard total > 0 else { return nil }
        return Double(read) / Double(total)
    }
}

@MainActor
final class ChatEngine: ObservableObject {
    @Published private(set) var cards: [QACard] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var attachError: String?
    /// Non-nil while the document is being uploaded / extracted / primed. The
    /// first question blocks on this, so silence here reads as a hang.
    @Published private(set) var attachStatus: String?

    // Composer state: attachments staged for the next question, and a focus signal.
    @Published var pendingSelection: PendingSelection?
    @Published var pendingCrop: PendingCrop?
    /// A one-line message about what just happened to a staged attachment — e.g.
    /// a crop a text-only provider can't see (PLAN.md §4). Cleared when the next
    /// question is sent.
    @Published var composerNotice: String?
    @Published private(set) var composerFocusRequest = 0

    func requestComposerFocus() { composerFocusRequest += 1 }

    private let provider: ChatProvider
    private let history: HistoryStore
    private var documentURL: URL?
    private var attachTask: Task<DocumentAttachment, Error>?
    private var askTask: Task<Void, Never>?

    init(provider: ChatProvider, history: HistoryStore = .shared) {
        self.provider = provider
        self.history = history
    }

    var providerName: String { provider.displayName }
    var providerID: String { provider.id }
    var capabilities: ProviderCapabilities { provider.capabilities }
    var hasHistory: Bool { !cards.isEmpty }

    /// Kick off document attachment (upload / extraction / session priming) at open,
    /// and restore whatever transcript this document already has.
    func attach(_ info: PDFDocumentInfo) {
        documentURL = info.fileURL
        restoreHistory(for: info.fileURL)

        let provider = self.provider
        attachStatus = "Preparing this document for \(provider.displayName)…"
        attachTask = Task {
            do {
                let attachment = try await provider.attach(document: info) { status in
                    Task { @MainActor in self.attachStatus = status }
                }
                await MainActor.run { self.attachStatus = nil }
                return attachment
            } catch {
                await MainActor.run {
                    self.attachStatus = nil
                    self.attachError = error.localizedDescription
                }
                throw error
            }
        }
    }

    func ask(_ question: Question) {
        guard !isStreaming else { return }
        cards.append(QACard(
            question: question,
            providerName: provider.displayName,
            modelName: provider.modelName,
            pricing: provider.pricing
        ))
        let cardID = cards[cards.count - 1].id
        isStreaming = true

        askTask = Task {
            do {
                guard let attachment = try await attachTask?.value else {
                    throw ProviderError.attachmentMissing
                }
                for try await event in provider.ask(question, in: attachment) {
                    apply(event, to: cardID)
                }
                // A cancelled AsyncThrowingStream ends iteration rather than
                // throwing, so Stop lands here, not in the catch below.
                if Task.isCancelled {
                    update(cardID) { $0.error = "Cancelled" }
                }
            } catch is CancellationError {
                update(cardID) { $0.error = "Cancelled" }
            } catch {
                update(cardID) { $0.error = error.localizedDescription }
            }
            update(cardID) { $0.isStreaming = false }
            isStreaming = false
            // Only completed cards are written: a half-streamed answer restored
            // as if it were finished would read as a truncation bug.
            persist()
        }
    }

    func cancel() {
        askTask?.cancel()
    }

    /// Drop this document's transcript, on screen and on disk.
    func clearHistory() {
        guard !isStreaming else { return }
        cards.removeAll()
        guard let documentURL else { return }
        let history = self.history
        Task.detached(priority: .utility) { history.clear(for: documentURL) }
    }

    private func apply(_ event: ChatEvent, to cardID: UUID) {
        update(cardID) { card in
            switch event {
            case .textDelta(let text):
                card.answer += text
            case .citation(let page, let citedText):
                // One chip per page: a long answer often cites the same page many times.
                if !card.citations.contains(where: { $0.page == page }) {
                    card.citations.append(Citation(page: page, citedText: citedText))
                }
            case .usage(let input, let cacheRead, let cacheWrite, let output):
                card.inputTokens = input
                card.cacheReadTokens = cacheRead
                card.cacheWriteTokens = cacheWrite
                card.outputTokens = output
                card.costUSD = card.pricing?.cost(
                    input: input, cacheRead: cacheRead, cacheWrite: cacheWrite, output: output
                )
            case .notice(let text):
                if !card.notices.contains(text) { card.notices.append(text) }
            case .done:
                card.isStreaming = false
            }
        }
    }

    private func update(_ cardID: UUID, _ mutate: (inout QACard) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        mutate(&cards[index])
    }

    // MARK: History

    private func restoreHistory(for url: URL) {
        let history = self.history
        Task.detached(priority: .utility) {
            guard let stored = history.load(for: url) else { return }
            let restored = stored.cards.map(QACard.init(stored:))
            await MainActor.run {
                // Anything asked while the file was being read wins — appending
                // the restored cards in front keeps chronological order.
                guard !restored.isEmpty else { return }
                self.cards = restored + self.cards
            }
        }
    }

    private func persist() {
        guard let documentURL else { return }
        let stored = StoredHistory(documentURL: documentURL, cards: cards)
        let history = self.history
        Task.detached(priority: .utility) { history.save(stored, for: documentURL) }
    }
}

// MARK: - Persistence mapping

extension StoredHistory {
    /// Only *completed* cards are written. A half-streamed answer restored as
    /// though it were finished reads as a truncation bug, and there is no way
    /// for the reader to tell the difference after the fact.
    init(documentURL: URL, cards: [QACard]) {
        self.init(
            documentPath: documentURL.standardizedFileURL.path,
            cards: cards.filter { !$0.isStreaming }.map(StoredCard.init(card:))
        )
    }
}

extension StoredCard {
    init(card: QACard) {
        self.init(
            id: card.id,
            askedAt: card.askedAt,
            questionText: card.question.text,
            selectedText: card.question.selectedText,
            selectedTextPage: card.question.selectedTextPage,
            regionPage: card.question.regionPage,
            regionThumbnailPNG: card.question.regionImagePNG.flatMap { HistoryStore.thumbnail(png: $0) },
            answer: card.answer,
            citations: card.citations.map { StoredCitation(page: $0.page, citedText: $0.citedText) },
            notices: card.notices,
            providerName: card.providerName,
            modelName: card.modelName,
            inputTokens: card.inputTokens,
            cacheReadTokens: card.cacheReadTokens,
            cacheWriteTokens: card.cacheWriteTokens,
            outputTokens: card.outputTokens,
            costUSD: card.costUSD,
            error: card.error
        )
    }
}

extension QACard {
    /// A restored card carries no `pricing`: its cost was computed when it was
    /// asked and is replayed, never recomputed.
    init(stored: StoredCard) {
        var question = Question(text: stored.questionText)
        question.selectedText = stored.selectedText
        question.selectedTextPage = stored.selectedTextPage
        question.regionImagePNG = stored.regionThumbnailPNG
        question.regionPage = stored.regionPage

        self.init(
            id: stored.id,
            askedAt: stored.askedAt,
            question: question,
            providerName: stored.providerName,
            modelName: stored.modelName,
            pricing: nil,
            answer: stored.answer,
            citations: stored.citations.map { Citation(page: $0.page, citedText: $0.citedText) },
            notices: stored.notices,
            inputTokens: stored.inputTokens,
            cacheReadTokens: stored.cacheReadTokens,
            cacheWriteTokens: stored.cacheWriteTokens,
            outputTokens: stored.outputTokens,
            costUSD: stored.costUSD,
            error: stored.error,
            isStreaming: false
        )
    }
}
