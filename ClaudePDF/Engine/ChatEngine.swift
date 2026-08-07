import Foundation
import SwiftUI

struct Citation: Identifiable, Hashable {
    let id = UUID()
    let page: Int          // 1-indexed
    let citedText: String
}

struct QACard: Identifiable {
    let id = UUID()
    let question: Question
    var answer: String = ""
    var citations: [Citation] = []
    var cacheReadTokens: Int?
    var inputTokens: Int?
    var error: String?
    var isStreaming = true
}

@MainActor
final class ChatEngine: ObservableObject {
    @Published private(set) var cards: [QACard] = []
    @Published private(set) var isStreaming = false
    @Published private(set) var attachError: String?

    private let provider: ChatProvider
    private var attachTask: Task<DocumentAttachment, Error>?
    private var askTask: Task<Void, Never>?

    init(provider: ChatProvider) {
        self.provider = provider
    }

    var providerName: String { provider.displayName }
    var capabilities: ProviderCapabilities { provider.capabilities }

    /// Kick off document attachment (upload / extraction / session priming) at open.
    func attach(_ info: PDFDocumentInfo) {
        let provider = self.provider
        attachTask = Task {
            do {
                return try await provider.attach(document: info)
            } catch {
                await MainActor.run { self.attachError = error.localizedDescription }
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
                card.citations.append(Citation(page: page, citedText: citedText))
            case .usage(let input, let cacheRead, _, _):
                card.inputTokens = input
                card.cacheReadTokens = cacheRead
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
