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
    let id = UUID()
    let question: Question
    var answer: String = ""
    var citations: [Citation] = []
    var inputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var outputTokens: Int?
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
    @Published private(set) var composerFocusRequest = 0

    func requestComposerFocus() { composerFocusRequest += 1 }

    private let provider: ChatProvider
    private var attachTask: Task<DocumentAttachment, Error>?
    private var askTask: Task<Void, Never>?

    init(provider: ChatProvider) {
        self.provider = provider
    }

    var providerName: String { provider.displayName }
    var providerID: String { provider.id }
    var capabilities: ProviderCapabilities { provider.capabilities }

    /// Kick off document attachment (upload / extraction / session priming) at open.
    func attach(_ info: PDFDocumentInfo) {
        let provider = self.provider
        attachStatus = "Preparing this document for \(provider.displayName)…"
        attachTask = Task {
            do {
                let attachment = try await provider.attach(document: info)
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
        cards.append(QACard(question: question))
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
        }
    }

    func cancel() {
        askTask?.cancel()
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
            case .done:
                card.isStreaming = false
            }
        }
    }

    private func update(_ cardID: UUID, _ mutate: (inout QACard) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        mutate(&cards[index])
    }
}
