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
    /// Which conversation this card belongs to. Cards are one transcript on
    /// screen, but only the ones sharing the *current* thread id were part of the
    /// context the last answer was written against — so the panel draws a break
    /// wherever this changes, rather than implying a continuity that isn't there.
    /// Defaulting to a fresh id says "a conversation of one", which is what a card
    /// built outside the engine is.
    var threadID = UUID()
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
    /// Page numbers the finished answer names in its own prose — the only
    /// page-anchored source the two providers without citations have. Read out of
    /// `answer` by `PageReferences` when the answer stops arriving, and never
    /// persisted: it is derived, and deriving it again on restore is what gives a
    /// transcript saved before it existed its pages back.
    var namedPages: [Int] = []
    var notices: [String] = []
    var inputTokens: Int?
    var cacheReadTokens: Int?
    var cacheWriteTokens: Int?
    var outputTokens: Int?
    var costUSD: Double?
    var error: String?
    var isStreaming = true

    /// The answer has stopped arriving — from the stream's own `.done`, from a
    /// cancel, from an error, and from history restore, which is the same moment for
    /// a card that was saved. Idempotent, because several of those coincide.
    ///
    /// Parsing here rather than where the pages are drawn is the difference between
    /// once per answer and once per streamed delta per card: the panel re-renders on
    /// every delta, and re-reading the whole transcript each time is work nobody
    /// asked for. Mid-stream is also the wrong moment to read it — "page 1" is a
    /// prefix of "page 12", so a chip would point at the wrong page for as long as
    /// the next token takes to arrive.
    mutating func finish() {
        isStreaming = false
        namedPages = PageReferences.pages(in: answer)
    }

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
    /// Set once the reader picks a provider for *this* window. The Settings
    /// *provider picker* stops applying to it afterwards: it is the default for
    /// newly opened documents, not a remote control for a window someone has
    /// already steered. The knobs on that provider still apply — see
    /// `applySettings`.
    @Published private(set) var providerIsWindowOverride = false

    /// The thread the next question will be asked inside: the turns since the
    /// conversation started, and wherever a provider is keeping it for us.
    /// Published because the composer and the New Conversation affordance both
    /// change shape the moment a conversation has something in it.
    @Published private(set) var conversation = Conversation()
    /// Stamped onto every card asked in the current thread, so the transcript can
    /// show where one conversation ended and the next began.
    @Published private(set) var threadID = UUID()

    /// What the panel header names. The filename, not PDF metadata: titles in
    /// metadata are wrong or missing often enough that the name the reader chose
    /// for the file is the more reliable label.
    @Published private(set) var documentTitle: String?

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
    /// A Settings change that arrived while an answer was streaming, held until
    /// the stream ends rather than discarded. See `applySettings`.
    private var pendingSettingsChange: (@MainActor () -> Void)?

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
        documentTitle = info.fileURL.deletingPathExtension().lastPathComponent
        restoreHistory(for: info.fileURL)
        startAttach()
    }

    /// Point this document at a different provider without reopening the window.
    ///
    /// The transcript stays: it is display-only and every card already records who
    /// answered it, so a switch reads as a change of voice rather than a reset.
    /// Refused while an answer is streaming — the same guard the Clear button uses.
    ///
    /// The conversation stays too, and changes shape to survive the crossing: its
    /// turns are portable, so the new provider replays them, but a handle is a
    /// session id belonging to the provider that issued it and means nothing to
    /// anyone else. Dropping it is what makes the next question replay the thread
    /// in full rather than resume a session that isn't theirs.
    func switchProvider(to newProvider: ChatProvider, isWindowOverride: Bool = false) {
        guard !isStreaming else { return }
        if isWindowOverride { providerIsWindowOverride = true }

        let previousKey = Self.attachmentKey(for: provider)
        let previousID = provider.id
        provider = newProvider
        if newProvider.id != previousID {
            conversation.handle = nil
            conversation.handledTurns = 0
        }
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

    /// Re-read Settings into this window's provider.
    ///
    /// A window whose provider the reader picked by hand keeps that provider —
    /// but it does not keep the *settings* the provider was built with. Thinking
    /// effort, subscription effort and model are not "who answers", they are how
    /// the answer is asked for, and a reader who moves one of them in Settings
    /// means the window they are reading. Ignoring the change left such a window
    /// asking at whatever effort was current when it was steered, with no sign on
    /// screen that the picker and the request disagreed — a thinking level set to
    /// High that still sent `reasoning_effort: off` and its 16K output budget.
    ///
    /// So an override window rebuilds its own kind of provider from current
    /// settings; only the choice of kind is frozen. A provider that came from
    /// somewhere other than the menu (a test double, a preview) maps to no
    /// choice, and is left exactly as it is.
    func applySettings(using build: @escaping (ProviderChoice) -> ChatProvider = ProviderFactory.make,
                       settingsChoice: ProviderChoice = AppSettings.providerChoice)
    {
        // Refusing mid-answer is right; dropping the change is not. The reader
        // moved a knob and the next question has to obey it.
        guard !isStreaming else {
            pendingSettingsChange = { [weak self] in
                self?.applySettings(using: build, settingsChoice: settingsChoice)
            }
            return
        }

        let choice = providerIsWindowOverride ? ProviderChoice(providerID: provider.id) : settingsChoice
        guard let choice else { return }
        switchProvider(to: build(choice), isWindowOverride: providerIsWindowOverride)
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
            threadID: threadID,
            question: question,
            providerName: provider.displayName,
            modelName: provider.modelName,
            pricing: provider.pricing
        ))
        let cardID = cards[cards.count - 1].id
        isStreaming = true
        // The thread as it stood when the question was asked. Taken here rather
        // than read inside the task, so a New Conversation pressed while this
        // answer streams cannot retroactively change what was sent.
        let asked = conversation

        askTask = Task {
            var handle: String?
            var failed = false
            do {
                guard let attachment = try await attachTask?.value else {
                    throw ProviderError.attachmentMissing
                }
                for try await event in provider.ask(question, in: attachment, conversation: asked) {
                    // Thread state, not card state, and the one event `apply` has
                    // nothing to do with.
                    if case .threadHandle(let reported) = event { handle = reported }
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
                failed = true
                update(cardID) { $0.error = error.localizedDescription }
            }
            // Also the path a cancelled or failed answer leaves by: whatever arrived
            // before it stopped is still an answer, and still points at pages.
            update(cardID) { $0.finish() }
            if !failed { record(cardID, threadHandle: handle) }
            isStreaming = false
            // A Settings change made while this answer streamed was held, not
            // dropped: apply it now, so the next question is asked the new way.
            let pending = pendingSettingsChange
            pendingSettingsChange = nil
            pending?()
            // Only completed cards are written: a half-streamed answer restored
            // as if it were finished would read as a truncation bug.
            persist()
        }
    }

    /// Fold a finished answer into the thread the next question will carry.
    ///
    /// A question that produced no text at all is not a turn: replaying an empty
    /// answer would leave two user messages side by side, which both API paths
    /// reject. A question that was stopped part-way *is* one — the reader read
    /// what arrived, so a follow-up that had never heard of it would be the
    /// surprise. Its fork is usually missing, which `handledTurns` records so the
    /// Claude Code path replays the difference instead of losing it.
    ///
    /// The card's own thread id guards the whole thing: if the reader started a
    /// new conversation while this was streaming, the thread this answer belongs
    /// to is gone, and appending to the one that replaced it would smuggle the old
    /// context into a conversation the reader asked to be free of it.
    private func record(_ cardID: UUID, threadHandle handle: String?) {
        guard let card = cards.first(where: { $0.id == cardID }),
              card.threadID == threadID else { return }

        if !card.answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            conversation.turns.append(ConversationTurn(question: card.question, answer: card.answer))
        }
        if let handle {
            conversation.handle = handle
            conversation.handledTurns = conversation.turns.count
        }
    }

    func cancel() {
        askTask?.cancel()
    }

    /// Start a fresh conversation about the same document.
    ///
    /// This is the counterweight to threading: questions carry the ones before
    /// them, so there has to be a way to say "forget that, I'm on something else"
    /// without paying to prepare the document again. Only the thread goes — the
    /// attachment, and with it the uploaded file, the primed session and the
    /// cached prefix, is untouched, so the first question of the new conversation
    /// is as cheap as the second question of the old one.
    ///
    /// The transcript stays on screen too. It is what the reader was reading, and
    /// the panel marks the break rather than hiding the fact that it happened.
    func startNewThread() {
        guard !isStreaming, !conversation.isEmpty else { return }
        conversation = Conversation()
        threadID = UUID()
    }

    /// Drop this document's transcript, on screen and on disk.
    func clearHistory() {
        guard !isStreaming else { return }
        cards.removeAll()
        // Nothing left to be continuous with.
        conversation = Conversation()
        threadID = UUID()
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
            case .threadHandle:
                break   // taken out of the stream by `ask`: it belongs to the thread
            case .done:
                card.finish()
            }
        }
    }

    private func update(_ cardID: UUID, _ mutate: (inout QACard) -> Void) {
        guard let index = cards.firstIndex(where: { $0.id == cardID }) else { return }
        mutate(&cards[index])
    }

    // MARK: History

    /// A restored transcript is read back as earlier conversations, never as the
    /// one the reader is in. History stays display-only (see `HistoryStore`): the
    /// document has just been attached afresh, nothing on the provider's side
    /// remembers yesterday's thread, and quietly re-billing an old conversation to
    /// give the impression that something does would be the worse surprise. The
    /// panel draws the break, so the transcript says which is which.
    private func restoreHistory(for url: URL) {
        let history = self.history
        Task.detached(priority: .utility) {
            guard let stored = history.load(for: url) else { return }
            // One thread id for anything written before threads existed, so an old
            // transcript reads as the single conversation it was, not as one
            // conversation per question.
            let legacyThread = UUID()
            let restored = stored.cards.map { QACard(stored: $0, fallbackThreadID: legacyThread) }
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
            threadID: card.threadID,
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
    ///
    /// `fallbackThreadID` is for files written before conversations were threaded;
    /// one shared id per file groups them as the single conversation they were.
    init(stored: StoredCard, fallbackThreadID: UUID = UUID()) {
        var question = Question(text: stored.questionText)
        question.selectedText = stored.selectedText
        question.selectedTextPage = stored.selectedTextPage
        question.regionImagePNG = stored.regionThumbnailPNG
        question.regionPage = stored.regionPage

        self.init(
            id: stored.id,
            askedAt: stored.askedAt,
            threadID: stored.threadID ?? fallbackThreadID,
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
        // Restored, not replayed: `namedPages` is derived from the answer rather than
        // saved with it, so a transcript written before any of this existed gets its
        // pages the first time it is reopened.
        finish()
    }
}
