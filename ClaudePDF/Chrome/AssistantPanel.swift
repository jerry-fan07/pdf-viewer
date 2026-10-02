import SwiftUI
import AppKit

enum AssistantTab: String {
    case chat, notes
}

/// The docked AI assistant: the conversation in one tab, the answers saved onto
/// pages in the other.
struct AssistantPanel: View {
    @ObservedObject var engine: ChatEngine
    @ObservedObject var viewer: PDFViewerController
    @ObservedObject var pins: PinnedNotes
    @Binding var tab: AssistantTab
    var onClose: () -> Void
    var onSnapshot: () -> Void

    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            tabStrip
            HDivider()
            switch tab {
            case .chat:
                conversationBar
                HDivider()
                transcript
                composer
            case .notes:
                SavedNotesList(pins: pins, viewer: viewer, engine: engine, onAsk: { tab = .chat })
            }
        }
        .background(ChromeInk.panel)
        .onChange(of: engine.composerFocusRequest) { _, _ in
            tab = .chat
            inputFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            AssistantBadge(size: 24)
            VStack(alignment: .leading, spacing: 0) {
                Text("AI Assistant")
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(ChromeInk.text)
                providerMenu
            }
            Spacer(minLength: 4)
            ChromeIconButton(systemImage: "square.and.pencil", help: "New conversation (⇧⌘N)",
                             size: 26, iconSize: 12.5) {
                tab = .chat
                engine.startNewThread(at: viewer.currentPageAnchor)
                engine.requestComposerFocus()
            }
            ChromeIconButton(systemImage: "sidebar.right", help: "Hide the assistant (⌥⌘I)",
                             size: 26, iconSize: 12.5, action: onClose)
        }
        .padding(.leading, 12)
        .padding(.trailing, 6)
        .frame(height: 48)
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
            HStack(spacing: 4) {
                Circle().fill(statusColor).frame(width: 5, height: 5)
                Text(engine.providerName)
                Image(systemName: "chevron.down").font(.system(size: 6.5, weight: .bold))
            }
            .font(.system(size: 10.5))
            .foregroundStyle(ChromeInk.secondary)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(engine.isStreaming)
        .help("Who answers — switch without reopening the document")
    }

    private var statusColor: Color {
        if engine.attachError != nil { return .red }
        if engine.attachStatus != nil || engine.isStreaming { return .orange }
        return engine.providerID == "mock" ? ChromeInk.tertiary : .green
    }

    private var tabStrip: some View {
        HStack(spacing: 16) {
            tabButton(.chat, title: "Chat", count: nil)
            tabButton(.notes, title: "Saved notes", count: pins.notes.count)
            Spacer()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private func tabButton(_ value: AssistantTab, title: String, count: Int?) -> some View {
        let selected = tab == value
        return Button {
            tab = value
        } label: {
            HStack(spacing: 5) {
                Text(title)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.system(size: 9.5, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(selected ? Color.white : ChromeInk.secondary)
                        .padding(.horizontal, 5)
                        .frame(height: 14)
                        .background(Capsule().fill(selected ? ChromeInk.accent : ChromeInk.hover))
                }
            }
            .font(.system(size: 11.5, weight: selected ? .semibold : .regular))
            .foregroundStyle(selected ? ChromeInk.text : ChromeInk.secondary)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                Rectangle().fill(selected ? ChromeInk.accent : .clear).frame(height: 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Conversation switcher

    /// Which conversation the chat is — and the way to another one.
    private var conversationBar: some View {
        HStack(spacing: 6) {
            Menu {
                let threads = engine.threads.filter { $0.title != nil }
                Section("Conversations about this document") {
                    if threads.isEmpty { Text("None yet") }
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
                }
                Divider()
                Button("New Conversation") {
                    engine.startNewThread(at: viewer.currentPageAnchor)
                    engine.requestComposerFocus()
                }
                if engine.selectedThread?.title != nil {
                    Button("Delete This Conversation", role: .destructive) {
                        engine.deleteThread(engine.threadID)
                    }
                    .disabled(engine.isStreamingHere)
                }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 10))
                        .foregroundStyle(ChromeInk.tertiary)
                    Text(engine.selectedThread?.displayTitle ?? ConversationThread.untitled)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(ChromeInk.text)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 7.5, weight: .semibold))
                        .foregroundStyle(ChromeInk.tertiary)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help("Switch conversation")
            Spacer(minLength: 6)
            Text(summary)
                .font(.system(size: 10.5))
                .monospacedDigit()
                .foregroundStyle(ChromeInk.tertiary)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
        .background(ChromeInk.bar)
    }

    private var summary: String {
        let cards = engine.threadCards
        guard !cards.isEmpty else { return "" }
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
                        emptyChat
                    }
                    ForEach(cards) { card in
                        VStack(alignment: .leading, spacing: 10) {
                            QuestionBubble(question: card.question)
                            AnswerBlock(card: card, viewer: viewer, pins: pins,
                                        onShowNote: { tab = .notes })
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 14)
                        .id(card.id)
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
            banner("Placeholder answers — pick a provider in Settings",
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
            .padding(.vertical, 4)
            HDivider()
        }
        if let error = engine.attachError {
            banner(error, symbol: "exclamationmark.triangle", tint: .red)
        }
    }

    private func banner(_ text: String, symbol: String, tint: Color) -> some View {
        VStack(spacing: 0) {
            Label(text, systemImage: symbol)
                .font(.system(size: 10.5))
                .foregroundStyle(tint)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            HDivider()
        }
    }

    private var emptyChat: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                AssistantBadge(size: 32)
                Text("Ask about \(engine.documentTitle ?? "this document")")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(ChromeInk.text)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Answers cite the pages they come from. Save any answer to its page as a note.")
                    .font(.system(size: 11))
                    .foregroundStyle(ChromeInk.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("SUGGESTED")
                    .font(.system(size: 9.5, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(ChromeInk.tertiary)
                suggestion("Summarize this document", symbol: "text.alignleft")
                suggestion("Explain page \(viewer.currentPageNumber)", symbol: "doc.text.magnifyingglass")
                suggestion("List the key terms and definitions", symbol: "list.bullet.rectangle")
            }
            VStack(alignment: .leading, spacing: 5) {
                Text("ASK ABOUT A PASSAGE")
                    .font(.system(size: 9.5, weight: .semibold))
                    .kerning(0.6)
                    .foregroundStyle(ChromeInk.tertiary)
                shortcutRow("Select text, then", keys: "⌘L")
                shortcutRow("Snapshot a region", keys: "⇧⌘A")
            }
        }
        .padding(16)
    }

    private func suggestion(_ text: String, symbol: String) -> some View {
        SuggestionRow(text: text, symbol: symbol) {
            input = text
            submit()
        }
    }

    private func shortcutRow(_ text: String, keys: String) -> some View {
        HStack {
            Text(text).font(.system(size: 11)).foregroundStyle(ChromeInk.secondary)
            Spacer()
            Text(keys)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ChromeInk.secondary)
                .padding(.horizontal, 5)
                .frame(height: 17)
                .background(RoundedRectangle(cornerRadius: 4).strokeBorder(ChromeInk.dividerStrong))
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
            VStack(alignment: .leading, spacing: 8) {
                if let selection = engine.pendingSelection {
                    AttachmentChip(symbol: "text.quote",
                                   text: selection.text.trimmingCharacters(in: .whitespacesAndNewlines),
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
                    .lineLimit(2...8)
                    .focused($inputFocused)
                    .onSubmit(submit)
                HStack(spacing: 4) {
                    ChromeIconButton(systemImage: "viewfinder", help: "Snapshot a region (⇧⌘A)",
                                     size: 24, iconSize: 11.5, action: onSnapshot)
                    HStack(spacing: 3) {
                        Image(systemName: "doc.text").font(.system(size: 9))
                        Text("Page \(viewer.currentPageNumber)")
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(ChromeInk.secondary)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(Capsule().fill(ChromeInk.hover))
                    .help("The page you are reading goes with the question")
                    Spacer()
                    sendButton
                }
            }
            .padding(EdgeInsets(top: 10, leading: 11, bottom: 7, trailing: 7))
            .background(RoundedRectangle(cornerRadius: 10).fill(ChromeInk.bar))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(inputFocused ? ChromeInk.accent : ChromeInk.dividerStrong,
                                  lineWidth: inputFocused ? 1.5 : 1)
            )
            .shadow(color: .black.opacity(inputFocused ? 0.06 : 0.03), radius: 4, y: 1)
            HStack {
                Text("↵ send  ·  ⇧↵ new line")
                Spacer()
                Text("Answers can be wrong — check the pages")
            }
            .font(.system(size: 9.5))
            .foregroundStyle(ChromeInk.tertiary)
            .padding(.horizontal, 2)
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
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(ChromeInk.text))
            }
            .buttonStyle(.plain)
            .help("Stop")
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 11.5, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
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

/// The assistant's mark: a sparkle on the accent.
struct AssistantBadge: View {
    var size: CGFloat = 24

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28)
            .fill(LinearGradient(colors: [ChromeInk.accent, ChromeInk.accent.opacity(0.78)],
                                 startPoint: .top, endPoint: .bottom))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: "sparkles")
                    .font(.system(size: size * 0.48, weight: .semibold))
                    .foregroundStyle(.white)
            )
    }
}

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
            .background(RoundedRectangle(cornerRadius: 7).fill(hovering ? ChromeInk.hover : ChromeInk.bar))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ChromeInk.divider))
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
        HStack(alignment: .top, spacing: 7) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit().frame(height: 28)
                    .overlay(Rectangle().strokeBorder(ChromeInk.divider))
            } else {
                Rectangle().fill(ChromeInk.accent).frame(width: 2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .font(.system(size: 10.5).italic())
                    .foregroundStyle(ChromeInk.text)
                    .lineLimit(2)
                if let page {
                    Label("Page \(page)", systemImage: symbol)
                        .font(.system(size: 9.5))
                        .foregroundStyle(ChromeInk.tertiary)
                }
            }
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold))
                    .foregroundStyle(ChromeInk.secondary)
                    .frame(width: 16, height: 16)
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(7)
        .background(RoundedRectangle(cornerRadius: 6).fill(ChromeInk.well))
    }
}

/// The question, as the reader's side of the exchange.
private struct QuestionBubble: View {
    let question: Question

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            VStack(alignment: .trailing, spacing: 5) {
                if let selected = question.selectedText {
                    HStack(alignment: .top, spacing: 6) {
                        Rectangle().fill(ChromeInk.accent.opacity(0.7)).frame(width: 2)
                        Text(selected.trimmingCharacters(in: .whitespacesAndNewlines))
                            .font(.system(size: 10.5).italic())
                            .foregroundStyle(ChromeInk.secondary)
                            .lineLimit(2)
                        if let page = question.selectedTextPage {
                            Text("p. \(page)")
                                .font(.system(size: 9.5))
                                .foregroundStyle(ChromeInk.tertiary)
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 6).fill(ChromeInk.well))
                }
                if let png = question.regionImagePNG, let image = NSImage(data: png) {
                    Image(nsImage: image).resizable().scaledToFit().frame(maxHeight: 72)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(ChromeInk.divider))
                }
                Text(question.text)
                    .font(.system(size: 12))
                    .foregroundStyle(ChromeInk.text)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(
                        UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12,
                                               bottomTrailingRadius: 3, topTrailingRadius: 12)
                            .fill(ChromeInk.accentSoft)
                    )
            }
        }
    }
}

/// The answer, with what can be done with it underneath.
private struct AnswerBlock: View {
    let card: QACard
    let viewer: PDFViewerController
    @ObservedObject var pins: PinnedNotes
    var onShowNote: () -> Void

    @State private var missNotice: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 6) {
                AssistantBadge(size: 16)
                Text("Assistant")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(ChromeInk.text)
                if let model = modelLabel {
                    Text(model)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ChromeInk.tertiary)
                        .lineLimit(1)
                }
            }
            if card.answer.isEmpty && card.isStreaming {
                ThinkingRow()
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
            if !card.isStreaming && !card.answer.isEmpty {
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var modelLabel: String? {
        let parts = [card.modelName ?? card.providerName].filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined()
    }

    // MARK: Sources

    private var sourcePages: [Int] {
        var pages = card.citations.map(\.page)
        pages += card.prosePages(inDocumentOf: viewer.pageCount)
        var seen = Set<Int>()
        return pages.filter { seen.insert($0).inserted }.sorted()
    }

    private var sources: some View {
        FlowLayout(spacing: 4) {
            ForEach(sourcePages, id: \.self) { page in
                Button {
                    if let citation = card.citations.first(where: { $0.page == page }) {
                        reveal(citation.citedText, nearPage: page, fallbackPage: page)
                    } else {
                        viewer.scroll(toPage: page)
                    }
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "doc.text").font(.system(size: 8.5))
                        Text("Page \(page)")
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(ChromeInk.accent)
                    .padding(.horizontal, 7)
                    .frame(height: 20)
                    .background(Capsule().fill(ChromeInk.accentSoft))
                }
                .buttonStyle(.plain)
                .help("Go to page \(page)")
            }
        }
    }

    // MARK: Actions

    private var actions: some View {
        HStack(spacing: 2) {
            ActionButton(symbol: copied ? "checkmark" : "doc.on.doc",
                         title: copied ? "Copied" : "Copy") { copy() }
            saveButton
            Spacer(minLength: 6)
            if let meta {
                Text(meta)
                    .font(.system(size: 9.5))
                    .monospacedDigit()
                    .foregroundStyle(ChromeInk.tertiary)
                    .lineLimit(1)
                    .help("How much of the question was read from the cached document, and what it cost")
            }
        }
        .padding(.top, 1)
    }

    @ViewBuilder
    private var saveButton: some View {
        if let note = pins.note(forCard: card.id) {
            ActionButton(symbol: "checkmark.circle.fill", title: "Saved to p. \(note.page)", tint: ChromeInk.accent) {
                viewer.scroll(toPage: note.page)
                pins.focusedID = note.id
                onShowNote()
            }
            .help("This answer is a note on page \(note.page) — show it")
        } else {
            ActionButton(symbol: "pin", title: "Save to page") {
                if let note = pins.save(card: card) {
                    viewer.scroll(toPage: note.page)
                }
            }
            .help("Pin this answer to the page it is about, as a note")
        }
    }

    private var meta: String? {
        var parts: [String] = []
        if let fraction = card.cachedFraction { parts.append("\(Int((fraction * 100).rounded()))% cached") }
        if let cost = card.costUSD { parts.append(TokenPricing.format(cost)) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(card.answer, forType: .string)
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            copied = false
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
}

private struct ActionButton: View {
    let symbol: String
    let title: String
    var tint: Color = ChromeInk.secondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 10))
                Text(title)
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(hovering ? ChromeInk.hover : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// Three dots that breathe while the first words are on their way.
private struct ThinkingRow: View {
    var body: some View {
        HStack(spacing: 8) {
            TimelineView(.animation) { context in
                let t = context.date.timeIntervalSinceReferenceDate
                HStack(spacing: 3) {
                    ForEach(0..<3) { index in
                        Circle()
                            .fill(ChromeInk.accent)
                            .frame(width: 5, height: 5)
                            .opacity(0.3 + 0.7 * max(0, sin((t * 4) - Double(index) * 0.7)))
                    }
                }
            }
            Text("Reading the document…")
                .font(.system(size: 11))
                .foregroundStyle(ChromeInk.tertiary)
        }
        .frame(height: 18)
    }
}

// MARK: - Saved notes

private struct SavedNotesList: View {
    @ObservedObject var pins: PinnedNotes
    @ObservedObject var viewer: PDFViewerController
    @ObservedObject var engine: ChatEngine
    var onAsk: () -> Void

    var body: some View {
        if pins.notes.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "pin")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(ChromeInk.tertiary)
                Text("No saved notes")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(ChromeInk.text)
                Text("Choose “Save to page” under any answer to pin it to the page it is about.")
                    .font(.system(size: 11))
                    .foregroundStyle(ChromeInk.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Go to Chat", action: onAsk)
                    .buttonStyle(ChromeTextButtonStyle())
                    .padding(.top, 2)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            VStack(spacing: 0) {
                HStack {
                    Text(countLabel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(ChromeInk.secondary)
                    Spacer()
                    Button {
                        pins.exportCopy()
                    } label: {
                        Label("Export PDF", systemImage: "square.and.arrow.up")
                    }
                    .buttonStyle(ChromeTextButtonStyle())
                    .help("Save a copy of the PDF with these notes in it — the original is not changed")
                }
                .padding(.leading, 12)
                .padding(.trailing, 4)
                .frame(height: 30)
                .background(ChromeInk.bar)
                HDivider()
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                            ForEach(pins.pages, id: \.self) { page in
                                Section {
                                    ForEach(pins.notes.filter { $0.page == page }) { note in
                                        SavedNoteCard(note: note, isFocused: pins.focusedID == note.id,
                                                      onOpenChat: chatOpener(for: note)) {
                                            open(note)
                                        } onDelete: {
                                            pins.delete(note.id)
                                        }
                                        .id(note.id)
                                        .padding(.horizontal, 10)
                                        .padding(.bottom, 8)
                                    }
                                } header: {
                                    pageHeader(page)
                                }
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    .onChange(of: pins.focusedID) { _, id in
                        guard let id else { return }
                        withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(id, anchor: .center) }
                    }
                    .onAppear {
                        if let id = pins.focusedID { proxy.scrollTo(id, anchor: .center) }
                    }
                }
            }
        }
    }

    private var countLabel: String {
        let notes = pins.notes.count
        let pages = pins.pages.count
        return "\(notes) \(notes == 1 ? "note" : "notes") on \(pages) \(pages == 1 ? "page" : "pages")"
    }

    private func pageHeader(_ page: Int) -> some View {
        HStack(spacing: 6) {
            Text("PAGE \(page)")
                .font(.system(size: 9.5, weight: .semibold))
                .kerning(0.6)
                .foregroundStyle(ChromeInk.secondary)
            Rectangle().fill(ChromeInk.divider).frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(ChromeInk.panel)
    }

    /// Back to the conversation the note was saved from — while it still exists.
    private func chatOpener(for note: PinnedNote) -> (() -> Void)? {
        guard let thread = note.threadID, engine.threads.contains(where: { $0.id == thread && $0.title != nil })
        else { return nil }
        return {
            engine.selectThread(thread)
            onAsk()
        }
    }

    private func open(_ note: PinnedNote) {
        pins.focusedID = note.id
        if let quote = note.quote, viewer.reveal(quote: quote, nearPage: note.page) { return }
        viewer.scroll(toPage: note.page)
    }
}

private struct SavedNoteCard: View {
    let note: PinnedNote
    let isFocused: Bool
    var onOpenChat: (() -> Void)?
    let onOpen: () -> Void
    let onDelete: () -> Void
    @State private var hovering = false
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 7) {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(ChromeInk.accent)
                    .padding(.top, 2)
                Text(note.question)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(ChromeInk.text)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if let quote = note.quote {
                HStack(alignment: .top, spacing: 6) {
                    Rectangle().fill(ChromeInk.accent.opacity(0.5)).frame(width: 2)
                    Text(quote)
                        .font(.system(size: 10.5).italic())
                        .foregroundStyle(ChromeInk.secondary)
                        .lineLimit(1)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            if expanded {
                AnswerView(answer: note.answer)
                    .font(.system(size: 11.5))
                    .foregroundStyle(ChromeInk.text)
                    .textSelection(.enabled)
            } else {
                Text(Self.excerpt(note.answer))
                    .font(.system(size: 11))
                    .foregroundStyle(ChromeInk.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(note.createdAt.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))
                if let provider = note.provider, !provider.isEmpty {
                    Text("·")
                    Text(provider).lineLimit(1)
                }
                Spacer(minLength: 4)
                if let onOpenChat {
                    Button("Open chat", action: onOpenChat)
                        .buttonStyle(.plain)
                        .foregroundStyle(ChromeInk.accent)
                        .help("Go back to the conversation this answer came from")
                }
                Button(expanded ? "Less" : "More") { expanded.toggle() }
                    .buttonStyle(.plain)
                    .foregroundStyle(ChromeInk.accent)
                if hovering || isFocused {
                    Button(action: onDelete) {
                        Image(systemName: "trash").font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(ChromeInk.secondary)
                    .help("Delete this note — the answer stays in its conversation")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(ChromeInk.tertiary)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isFocused ? ChromeInk.accentSoft : ChromeInk.bar)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(isFocused ? ChromeInk.accent.opacity(0.7) : hovering ? ChromeInk.dividerStrong : ChromeInk.divider)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onOpen)
        .onHover { hovering = $0 }
    }

    /// Plain words for a three-line preview: the Markdown and math markers go.
    static func excerpt(_ answer: String) -> String {
        var text = answer
        for marker in ["$$", "**", "__", "`", "#", "$", "*"] {
            text = text.replacingOccurrences(of: marker, with: "")
        }
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}
