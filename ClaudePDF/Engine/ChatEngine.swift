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
    /// Who answers this document's questions right now. Published because it can
    /// change under an open window (Phase 7) — the header names it.
    @Published private(set) var provider: ChatProvider
    /// Set once the reader picks a provider for *this* window. Settings stops
    /// applying to it afterwards: Settings is the default for newly opened
    /// documents, not a remote control for a window someone has already steered.
    @Published private(set) var providerIsWindowOverride = false

    // Composer state: attachments staged for the next question, and a focus signal.
    @Published var pendingSelection: PendingSelection?
    @Published var pendingCrop: PendingCrop?
    /// A one-line message about what just happened to a staged attachment — e.g.
    /// a crop a text-only provider can't see (PLAN.md §4). Cleared when the next
    /// question is sent.
    @Published var composerNotice: String?
    @Published private(set) var composerFocusRequest = 0

    func requestComposerFocus() { composerFocusRequest += 1 }

    private let history: HistoryStore
    private var documentURL: URL?
    private var documentInfo: PDFDocumentInfo?
    private var attachTask: Task<DocumentAttachment, Error>?
    private var askTask: Task<Void, Never>?
    /// Completed attachments, keyed by the provider they belong to, so switching
    /// back to a provider this document is already prepared for costs nothing —
    /// no second upload, no second prime, no second cache write.
    private var attachments: [String: DocumentAttachment] = [:]
    /// Bumped on every (re)attach. An attach whose generation is stale — because
    /// the provider changed or the reader cancelled it — must not write its
    /// status, its error, or its result back into the engine.
    private var attachGeneration = 0

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
        documentInfo = info
        restoreHistory(for: info.fileURL)
        startAttach()
    }

    /// Point this document at a different provider without reopening the window.
    ///
    /// The transcript stays: it is display-only and every card already records who
    /// answered it, so a switch reads as a change of voice rather than a reset.
    /// Refused while an answer is streaming — the same guard the Clear button uses.
    func switchProvider(to newProvider: ChatProvider, isWindowOverride: Bool = false) {
        guard !isStreaming else { return }
        if isWindowOverride { providerIsWindowOverride = true }

        let previousKey = Self.attachmentKey(for: provider)
        provider = newProvider
        // A crop staged for a provider that could see it may be unreadable to the
        // new one — and vice versa (PLAN.md §4).
        restageCropForCurrentProvider()

        // Ask-time settings (subscription effort, DeepSeek thinking) share the
        // document's handle: the attachment is the document, not how it is asked.
        // Swapping the instance is the whole change; nothing needs re-preparing.
        guard Self.attachmentKey(for: newProvider) != previousKey else { return }
        stopAttach()
        startAttach()
    }

    /// Abandon an attach in progress. A scanned document can be minutes of OCR,
    /// and until Phase 7 nothing in the UI could call a halt to it.
    func cancelAttach() {
        guard attachStatus != nil else { return }
        stopAttach()
        attachError = "Preparing this document was cancelled. Ask a question, or "
            + "press Try Again, to start over."
    }

    /// Re-run an attach that failed or was cancelled.
    func retryAttach() {
        guard attachStatus == nil else { return }
        stopAttach()
        startAttach()
    }

    /// Whether there is a document to (re)prepare — the retry affordance is
    /// meaningless in a window that never got one.
    var canRetryAttach: Bool { documentInfo != nil && attachStatus == nil }

    /// Identity of the *attachment* a provider needs. The model is in it because
    /// Anthropic's page cap is per model — Haiku stops at 100 — so a model change
    /// has to re-run attach and be told off there rather than at the first
    /// question. Effort and thinking are deliberately absent: they change how a
    /// question is asked, not what was uploaded.
    private static func attachmentKey(for provider: ChatProvider) -> String {
        "\(provider.id)|\(provider.modelName ?? "")"
    }

    private func startAttach() {
        guard let info = documentInfo else { return }
        let provider = self.provider
        let key = Self.attachmentKey(for: provider)

        attachGeneration += 1
        let generation = attachGeneration
        attachError = nil

        if let ready = attachments[key] {
            attachStatus = nil
            attachTask = Task<DocumentAttachment, Error> { ready }
            return
        }

        attachStatus = "Preparing this document for \(provider.displayName)…"
        attachTask = Task {
            do {
                let attachment = try await provider.attach(document: info) { status in
                    Task { @MainActor in
                        guard self.attachGeneration == generation else { return }
                        self.attachStatus = status
                    }
                }
                await MainActor.run {
                    self.attachments[key] = attachment
                    guard self.attachGeneration == generation else { return }
                    self.attachStatus = nil
                }
                return attachment
            } catch {
                await MainActor.run {
                    guard self.attachGeneration == generation else { return }
                    self.attachStatus = nil
                    self.attachError = error.localizedDescription
                    // Clearing the task is what makes the next question a retry
                    // rather than a replay of the same failure.
                    self.attachTask = nil
                }
                throw error
            }
        }
    }

    /// Orphan whatever attach is in flight: bumping the generation first means its
    /// completion can no longer write status or an error over the new state.
    private func stopAttach() {
        attachGeneration += 1
        attachTask?.cancel()
        attachTask = nil
        attachStatus = nil
        attachError = nil
    }

    func ask(_ question: Question) {
        guard !isStreaming else { return }
        // A cancelled or failed attach leaves no task behind, so asking anyway is
        // the other way to say "try again".
        if attachTask == nil { startAttach() }
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

    // MARK: Staged attachments

    /// Stage a cropped region for the next question, degraded to what the current
    /// provider can actually read (PLAN.md §4). Also the path a provider switch
    /// takes for a crop that is already staged.
    func stage(crop: PendingCrop, focusComposer: Bool = false) {
        switch CropStaging.decide(
            for: crop,
            capabilities: capabilities,
            providerName: providerName,
            ocrEnabled: AppSettings.ocrEnabled
        ) {
        case .stage(let staged, let notice):
            pendingCrop = staged
            composerNotice = notice
            if focusComposer { requestComposerFocus() }

        case .refuse(let notice):
            pendingCrop = nil
            composerNotice = notice

        case .recognize:
            // Off the main actor: Vision on a single crop is fast, but not free.
            pendingCrop = nil
            composerNotice = CropStaging.recognizingNotice
            let png = crop.png
            let page = crop.pageNumber
            let providerName = self.providerName
            Task {
                let recognised = await Task.detached(priority: .userInitiated) {
                    OCRExtractor.recognizeText(inPNG: png)
                }.value
                // Blank output counts as nothing recognised. Recursing on it would
                // decide `.recognize` again and run Vision forever.
                guard let recognised,
                      !recognised.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    self.composerNotice = CropStaging.unrecognisedNotice(providerName: providerName)
                    return
                }
                // Decide again rather than staging directly: by the time the text
                // comes back the provider may have changed under it again.
                self.stage(
                    crop: PendingCrop(png: png, pageNumber: page, fallbackText: recognised),
                    focusComposer: focusComposer
                )
            }
        }
    }

    private func restageCropForCurrentProvider() {
        guard let crop = pendingCrop else { return }
        stage(crop: crop)
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
