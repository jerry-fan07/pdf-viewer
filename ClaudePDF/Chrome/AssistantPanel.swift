import SwiftUI
import AppKit

/// The docked AI assistant: one conversation at a time, dense, with the provider
/// and the conversation switcher in its header.
struct AssistantPanel: View {
    @ObservedObject var engine: ChatEngine
    @ObservedObject var viewer: PDFViewerController
    var onClose: () -> Void
    var onSnapshot: () -> Void

    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            HDivider()
            threadBar
            HDivider()
            transcript
            composer
        }
        .background(ChromeInk.panel)
        .onChange(of: engine.composerFocusRequest) { _, _ in inputFocused = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChromeInk.accent)
            Text("AI Assistant")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChromeInk.text)
            providerMenu
            Spacer(minLength: 4)
            ChromeIconButton(systemImage: "square.and.pencil", help: "New conversation (⇧⌘N)",
                             size: 24, iconSize: 12) {
                engine.startNewThread(at: viewer.currentPageAnchor)
                engine.requestComposerFocus()
            }
            historyMenu
            ChromeIconButton(systemImage: "xmark", help: "Close (⌥⌘I)", size: 24, iconSize: 10,
                             action: onClose)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 38)
    }

    private var providerMenu: some View {
        Menu {
            Section("Answer with") {
                ForEach(ProviderChoice.switchable) { choice in
                    Button {
                        engine.switchProvider(to: ProviderFactory.make(choice),
                                              isWindowOverride: choice.providerID != engine.providerID)
                    } label: {
                        if choice.providerID == engine.providerID {
                            Label(choice.displayName, systemImage: "checkmark")
                        } else {
                            Text(choice.displayName)
                        }
                    }
                    .disabled(choice.unavailableReason != nil)
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text(engine.providerName)
                Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(ChromeInk.secondary)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(Capsule().fill(ChromeInk.hover))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(engine.isStreaming)
    }

    private var historyMenu: some View {
        Menu {
            let threads = engine.threads.filter { $0.title != nil }
            if threads.isEmpty {
                Text("No conversations yet")
            }
            ForEach(threads) { thread in
                Button {
                    engine.selectThread(thread.id)
                    viewer.scroll(toPage: thread.anchor.page)
                } label: {
                    if thread.id == engine.threadID {
                        Label(thread.displayTitle, systemImage: "checkmark")
                    } else {
                        Text(thread.displayTitle)
                    }
                }
            }
            if !threads.isEmpty {
                Divider()
                Button("Delete This Conversation", role: .destructive) {
                    engine.deleteThread(engine.threadID)
                }
                .disabled(engine.isStreamingHere)
            }
        } label: {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(ChromeInk.secondary)
                .frame(width: 24, height: 24)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Conversations about this document")
    }

    /// The open conversation's name and what it has cost.
    private var threadBar: some View {
        HStack(spacing: 6) {
            Text(engine.selectedThread?.displayTitle ?? ConversationThread.untitled)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(ChromeInk.text)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 6)
            Text(summary)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(ChromeInk.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 28)
        .background(ChromeInk.bar)
    }

    private var summary: String {
        let cards = engine.threadCards
        var parts = [cards.count == 1 ? "1 answer" : "\(cards.count) answers"]
        let cost = cards.compactMap(\.costUSD).reduce(0, +)
        if cost > 0 { parts.append(TokenPricing.format(cost)) }
        return parts.joined(separator: " · ")
    }

    // MARK: Transcript

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    status
                    let cards = engine.threadCards
                    if cards.isEmpty {
                        suggestions
                    }
                    ForEach(cards) { card in
                        AssistantTurn(card: card, viewer: viewer)
                            .id(card.id)
                        HDivider()
                    }
                }
            }
            .onChange(of: engine.threadCards.count) { follow(proxy) }
            .onChange(of: engine.isStreamingHere) { if !engine.isStreamingHere { follow(proxy) } }
            .onChange(of: engine.threadID) { follow(proxy) }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard let last = engine.threadCards.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    @ViewBuilder
    private var status: some View {
        if engine.providerID == "mock" {
            notice("No provider configured — answers are placeholders. Add one in Settings (⌘,).",
                   symbol: "info.circle", tint: ChromeInk.secondary)
        }
        if let status = engine.attachStatus {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(status).font(.system(size: 11)).foregroundStyle(ChromeInk.secondary)
                Spacer()
                Button("Cancel", action: engine.cancelAttach)
                    .buttonStyle(ChromeTextButtonStyle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            HDivider()
        }
        if let error = engine.attachError {
            notice(error, symbol: "exclamationmark.triangle", tint: .red)
        }
    }

    private func notice(_ text: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 0) {
            Label(text, systemImage: symbol)
                .font(.system(size: 11))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            HDivider()
        }
    }

    private var suggestions: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Ask about this document")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(ChromeInk.text)
                Text("Select text and press ⌘L, or snapshot a region with ⇧⌘A, to ask about a specific passage.")
                    .font(.system(size: 11))
                    .foregroundStyle(ChromeInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(spacing: 0) {
                suggestion("Summarize this document", symbol: "text.alignleft")
                HDivider()
                suggestion("Explain page \(viewer.currentPageNumber)", symbol: "doc.text.magnifyingglass")
                HDivider()
                suggestion("List the key terms and definitions", symbol: "list.bullet.rectangle")
                HDivider()
                suggestion("What are the main open questions?", symbol: "questionmark.bubble")
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(ChromeInk.bar))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(ChromeInk.divider))
        }
        .padding(12)
    }

    private func suggestion(_ text: String, symbol: String) -> some View {
        SuggestionRow(text: text, symbol: symbol) {
            input = text
            submit()
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let notice = engine.composerNotice {
                Label(notice, systemImage: "eye.slash")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 6) {
                if let selection = engine.pendingSelection {
                    AttachmentChip(symbol: "text.quote",
                                   text: "“\(selection.text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(48))…”",
                                   page: selection.page) { engine.pendingSelection = nil }
                }
                if let crop = engine.pendingCrop {
                    AttachmentChip(symbol: "viewfinder", text: "Region snapshot",
                                   page: crop.pageNumber, image: NSImage(data: crop.png)) { engine.pendingCrop = nil }
                }
                TextField("", text: $input, prompt: prompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundStyle(ChromeInk.text)
                    .lineLimit(1...6)
                    .focused($inputFocused)
                    .onSubmit(submit)
                HStack(spacing: 2) {
                    ChromeIconButton(systemImage: "viewfinder", help: "Snapshot a region (⇧⌘A)",
                                     size: 22, iconSize: 11, action: onSnapshot)
                    Text("Page \(viewer.currentPageNumber)")
                        .font(.system(size: 10.5))
                        .foregroundStyle(ChromeInk.tertiary)
                        .padding(.leading, 2)
                    Spacer()
                    sendButton
                }
            }
            .padding(EdgeInsets(top: 8, leading: 10, bottom: 6, trailing: 6))
            .background(RoundedRectangle(cornerRadius: 7).fill(ChromeInk.bar))
            .overlay(
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(inputFocused ? ChromeInk.accent : ChromeInk.dividerStrong,
                                  lineWidth: inputFocused ? 1.5 : 1)
            )
            Text("Answers can be wrong. Check the cited pages.")
                .font(.system(size: 9.5))
                .foregroundStyle(ChromeInk.tertiary)
                .frame(maxWidth: .infinity)
        }
        .padding(10)
        .background(ChromeInk.panel)
        .overlay(alignment: .top) { HDivider() }
    }

    @ViewBuilder
    private var sendButton: some View {
        if engine.isStreamingHere {
            Button(action: engine.cancel) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(ChromeInk.text))
            }
        .buttonStyle(.plain)
            .help("Stop")
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(canSubmit ? ChromeInk.accent : ChromeInk.dividerStrong))
            }
        .buttonStyle(.plain)
            .disabled(!canSubmit)
            .help("Ask (↵)")
        }
    }

    private var prompt: Text {
        Text(engine.conversation.isEmpty ? "Ask anything about this document…" : "Ask a follow-up…")
            .foregroundStyle(ChromeInk.tertiary)
    }

    private var canSubmit: Bool {
        !engine.isStreaming && !input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !engine.isStreaming else { return }
        var question = Question(text: text)
        if let selection = engine.pendingSelection ?? viewer.selectionInfo() {
            question.selectedText = selection.text
            question.selectedTextPage = selection.page
        }
        if let crop = engine.pendingCrop {
            question.regionImagePNG = crop.png
            question.regionPage = crop.pageNumber
            question.regionFallbackText = crop.fallbackText
        }
        question.pageHint = viewer.currentPageNumber
        engine.ask(question)
        engine.pendingSelection = nil
        engine.pendingCrop = nil
        engine.composerNotice = nil
        input = ""
    }
}

// MARK: - Pieces

private struct SuggestionRow: View {
    let text: String
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 11))
                    .foregroundStyle(ChromeInk.accent)
                    .frame(width: 16)
                Text(text)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ChromeInk.text)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 9))
                    .foregroundStyle(hovering ? ChromeInk.secondary : .clear)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(hovering ? ChromeInk.hover : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct AttachmentChip: View {
    let symbol: String
    let text: String
    let page: Int?
    var image: NSImage? = nil
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(height: 18)
                    .overlay(Rectangle().strokeBorder(ChromeInk.divider))
            } else {
                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(ChromeInk.accent)
            }
            Text(text).lineLimit(1)
            if let page {
                Text("p. \(page)").foregroundStyle(ChromeInk.tertiary)
            }
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ChromeInk.secondary)
            }
        .buttonStyle(.plain)
        }
        .font(.system(size: 10.5))
        .foregroundStyle(ChromeInk.secondary)
        .padding(.horizontal, 7)
        .frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 4).fill(ChromeInk.well))
    }
}

/// One question and its answer, compact.
private struct AssistantTurn: View {
    let card: QACard
    let viewer: PDFViewerController
    @State private var missNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            question
            if card.answer.isEmpty && card.isStreaming {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Reading…").font(.system(size: 11)).foregroundStyle(ChromeInk.tertiary)
                }
            } else {
                AnswerView(answer: card.answer)
                    .font(.system(size: 12.5))
                    .lineSpacing(2)
                    .foregroundStyle(ChromeInk.text)
                    .textSelection(.enabled)
                    .environment(\.openURL, OpenURLAction { url in
                        guard let quote = SourceLink.quote(from: url) else { return .systemAction }
                        reveal(quote, nearPage: card.question.pageHint)
                        return .handled
                    })
            }
            if !sourcePages.isEmpty { sources }
            if let missNotice {
                Text(missNotice).font(.system(size: 10.5)).foregroundStyle(ChromeInk.tertiary)
            }
            ForEach(card.notices, id: \.self) { notice in
                Label(notice, systemImage: "gauge.with.needle")
                    .font(.system(size: 10.5)).foregroundStyle(.orange)
            }
            if let error = card.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5)).foregroundStyle(.red).textSelection(.enabled)
            }
            if let footer {
                Text(footer)
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(ChromeInk.tertiary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var question: some View {
        VStack(alignment: .leading, spacing: 5) {
            if let selected = card.question.selectedText {
                HStack(alignment: .top, spacing: 6) {
                    Rectangle().fill(ChromeInk.accent.opacity(0.6)).frame(width: 2)
                    Text(selected.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(.system(size: 10.5).italic())
                        .foregroundStyle(ChromeInk.secondary)
                        .lineLimit(2)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if let png = card.question.regionImagePNG, let image = NSImage(data: png) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 64)
                    .overlay(Rectangle().strokeBorder(ChromeInk.divider))
            }
            Text(card.question.text)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(ChromeInk.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(ChromeInk.well))
    }

    private var sourcePages: [Int] {
        var pages = card.citations.map(\.page)
        pages += card.prosePages(inDocumentOf: viewer.pageCount)
        var seen = Set<Int>()
        return pages.filter { seen.insert($0).inserted }.sorted()
    }

    private var sources: some View {
        FlowLayout {
            Text("Sources")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ChromeInk.tertiary)
                .frame(height: 18)
            ForEach(sourcePages, id: \.self) { page in
                Button {
                    if let citation = card.citations.first(where: { $0.page == page }) {
                        reveal(citation.citedText, nearPage: page, fallbackPage: page)
                    } else {
                        viewer.scroll(toPage: page)
                    }
                } label: {
                    Text("p. \(page)")
                        .font(.system(size: 10.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(ChromeInk.accent)
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(RoundedRectangle(cornerRadius: 4).fill(ChromeInk.accentSoft))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func reveal(_ quote: String, nearPage: Int?, fallbackPage: Int? = nil) {
        if viewer.reveal(quote: quote, nearPage: nearPage) {
            missNotice = nil
        } else if let fallbackPage {
            viewer.scroll(toPage: fallbackPage)
            missNotice = "Couldn't match that wording — jumped to page \(fallbackPage)."
        } else {
            missNotice = "Couldn't find that passage in the document."
        }
    }

    private var footer: String? {
        var parts: [String] = []
        if !card.providerName.isEmpty {
            parts.append([card.providerName, card.modelName].compactMap { $0 }.joined(separator: " "))
        }
        if let fraction = card.cachedFraction { parts.append("\(Int((fraction * 100).rounded()))% cached") }
        if let output = card.outputTokens { parts.append("\(output) tok") }
        if let cost = card.costUSD { parts.append(TokenPricing.format(cost)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
