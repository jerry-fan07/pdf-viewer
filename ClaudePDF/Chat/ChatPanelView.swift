import SwiftUI
import AppKit

/// The chat panel, set to design 5A: an open, instrumented transcript. No card
/// boxes and no chips — answers sit directly on the paper, separated by hairlines,
/// threaded on a timeline rail, under a per-page histogram of what the
/// conversation has cited so far.
struct ChatPanelView: View {
    @ObservedObject var engine: ChatEngine
    /// Observed, not just held: the citation histogram needs `pageCount` when the
    /// document finishes loading and `currentPageNumber` as the reader scrolls.
    @ObservedObject var viewer: PDFViewerController

    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if viewer.pageCount > 1 {
                citationHistogram
            }
            Rectangle().fill(PanelInk.hairlineEdge).frame(height: 1)
            transcript
            Rectangle().fill(PanelInk.hairlineEdge).frame(height: 1)
            composer
        }
        .background(PanelInk.background)
        .onChange(of: engine.composerFocusRequest) { _, _ in
            inputFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("Reading")
                    .font(.system(size: 11))
                    .kerning(0.2)
                    .foregroundStyle(PanelInk.faint)
                providerMenu
                Spacer(minLength: 8)
                if !engine.conversation.isEmpty {
                    newConversationButton
                }
                if engine.hasHistory {
                    clearButton
                }
                if let summary = answersSummary {
                    Text(summary)
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(PanelInk.faint)
                }
            }
            Text(engine.documentTitle ?? "Untitled")
                .font(.system(size: 15, weight: .medium))
                .kerning(-0.18)
                .foregroundStyle(PanelInk.ink)
                .lineLimit(1)
        }
        .padding(EdgeInsets(top: 16, leading: 24, bottom: 10, trailing: 24))
    }

    /// "7 answers · $0.04". The cost only appears once something has cost
    /// something — the subscription path has no per-token bill to sum.
    private var answersSummary: String? {
        let count = engine.cards.count
        guard count > 0 else { return nil }
        var summary = count == 1 ? "1 answer" : "\(count) answers"
        let cost = engine.cards.compactMap(\.costUSD).reduce(0, +)
        if cost > 0 {
            summary += " · " + TokenPricing.format(cost)
        }
        return summary
    }

    /// Drops what the next question would otherwise carry, and nothing else — the
    /// document stays prepared, so this costs nothing and the transcript above it
    /// stays where it is. Shown only once there is a conversation to end.
    private var newConversationButton: some View {
        Button {
            engine.startNewThread()
        } label: {
            Image(systemName: "square.and.pencil")
                .font(.system(size: 10))
                .foregroundStyle(PanelInk.faint)
        }
        .buttonStyle(.plain)
        .disabled(engine.isStreaming)
        .help("New conversation — the next question starts fresh instead of "
              + "following these \(engine.conversation.turns.count). The document stays "
              + "prepared, so nothing is re-uploaded and no cache is re-paid.")
    }

    private var clearButton: some View {
        Button(role: .destructive) {
            engine.clearHistory()
        } label: {
            Image(systemName: "trash")
                .font(.system(size: 10))
                .foregroundStyle(PanelInk.faint)
        }
        .buttonStyle(.plain)
        .disabled(engine.isStreaming)
        .help("Clear this document's saved questions and answers")
    }

    /// The provider name doubles as the switcher (Phase 7). Disabled while an
    /// answer streams, for the same reason Clear is: swapping the voice halfway
    /// through a sentence has no sensible reading.
    private var providerMenu: some View {
        Menu {
            Section("Ask with") {
                ForEach(ProviderChoice.switchable) { choice in
                    Button {
                        // Re-picking the provider that is already answering is
                        // not steering: it must not be what quietly cuts this
                        // window off from the Settings picker.
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
                    .help(choice.unavailableReason ?? "")
                }
            }
            Divider()
            // Never let a cache write happen silently (PLAN.md §7).
            Text("Switching re-prepares this document for the new provider — the "
                 + "first question after that pays a fresh cache write. Switching "
                 + "back to one it is already prepared for is free. The conversation "
                 + "carries over either way.")
        } label: {
            Text("· \(engine.providerName)")
                .font(.system(size: 11))
                .foregroundStyle(PanelInk.faint)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(engine.isStreaming)
        .help("Who answers questions about this document — switch without reopening it")
    }

    // MARK: Citation histogram

    /// One bar per page (bucketed past 60): tall ink where an answer has cited,
    /// mid-height grey where the reader currently is, a hairline stub elsewhere.
    /// Each bar is also a button to its page.
    private var citationHistogram: some View {
        let cited = citedPages
        let buckets = pageBuckets(cited: cited)
        return VStack(spacing: 5) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(buckets) { bucket in
                    Button {
                        viewer.scroll(toPage: bucket.target)
                    } label: {
                        Rectangle()
                            .fill(bucket.cited ? PanelInk.ink
                                  : bucket.isCurrent ? PanelInk.dim
                                  : PanelInk.hairlineStrong)
                            .frame(height: bucket.cited ? 12 : bucket.isCurrent ? 8 : 4)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.plain)
                    .help(bucket.help)
                }
            }
            .frame(height: 12, alignment: .bottom)
            HStack {
                Text("p. 1")
                Spacer()
                Text(citedCaption(count: cited.count))
                Spacer()
                Text("\(viewer.pageCount)")
            }
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(PanelInk.fainter)
        }
        .padding(EdgeInsets(top: 4, leading: 24, bottom: 12, trailing: 24))
        .help(citedPagesHelp(cited))
    }

    /// Every page the conversation points at, unique and ascending. Not just the
    /// providers' API citations: two of the three paths have none by construction and
    /// name their pages in prose instead, which is what `QACard.citedPages` folds in.
    private var citedPages: [Int] {
        let pageCount = viewer.pageCount
        var pages = Set<Int>()
        for card in engine.cards { pages.formUnion(card.citedPages(inDocumentOf: pageCount)) }
        return pages.sorted()
    }

    /// The caption counts, because the strip's own bars can't: past 60 pages one bar
    /// stands for several, so "4 pages cited" is information the picture has lost.
    private func citedCaption(count: Int) -> String {
        switch count {
        case 0: return "no pages cited yet"
        case 1: return "1 page cited by this conversation"
        default: return "\(count) pages cited by this conversation"
        }
    }

    private func citedPagesHelp(_ cited: [Int]) -> String {
        guard !cited.isEmpty else {
            return "Every page this conversation's answers point at. Nothing cited yet."
        }
        let list = cited.map(String.init).joined(separator: ", ")
        return "Cited by this conversation: p. \(list)"
    }

    private struct PageBucket: Identifiable {
        let id: Int
        let firstPage: Int
        let lastPage: Int
        /// The cited pages inside this bar — plural only when the document is long
        /// enough that one bar stands for several pages.
        let citedPages: [Int]
        let isCurrent: Bool

        var cited: Bool { !citedPages.isEmpty }

        /// Where the bar goes when clicked. A cited bar lands on the page that was
        /// actually cited rather than on the first page of the range it stands for —
        /// in a 600-page document those are ten pages apart.
        var target: Int { citedPages.first ?? firstPage }

        var help: String {
            let range = firstPage == lastPage ? "Page \(firstPage)" : "Pages \(firstPage)–\(lastPage)"
            guard cited else { return range }
            guard firstPage != lastPage else { return "\(range) — cited by an answer" }
            return "\(range) — cited: p. \(citedPages.map(String.init).joined(separator: ", "))"
        }
    }

    private func pageBuckets(cited: [Int]) -> [PageBucket] {
        let pageCount = viewer.pageCount
        guard pageCount > 0 else { return [] }
        let current = viewer.currentPageNumber
        let bars = min(pageCount, 60)
        return (0..<bars).map { index in
            let first = index * pageCount / bars + 1
            let last = (index + 1) * pageCount / bars
            return PageBucket(
                id: index,
                firstPage: first,
                lastPage: last,
                citedPages: cited.filter { $0 >= first && $0 <= last },
                isCurrent: (first...last).contains(current)
            )
        }
    }

    // MARK: Transcript

    /// One row of the transcript, carrying where it sits in its conversation.
    ///
    /// Worked out here rather than inside the row builder, and this is not a
    /// tidying: `LazyVStack` builds rows on demand *while the reader scrolls*, so
    /// a row that reaches for `cards[index - 1]` is indexing an array the engine
    /// has been mutating in the meantime — appending deltas, prepending a restored
    /// transcript, or emptying it entirely in `clearHistory`. Out of range there is
    /// a trap, and it fires on the scroll rather than on the edit that caused it.
    /// A row that knows its own place needs no neighbours.
    ///
    /// Internal rather than private so the boundaries can be tested directly —
    /// where a conversation starts and ends is what the panel draws, and it is
    /// worth asserting somewhere other than by eye.
    struct TranscriptRow: Identifiable {
        let card: QACard
        let isFirstRow: Bool
        let startsThread: Bool
        let endsThread: Bool

        var id: UUID { card.id }
    }

    var transcriptRows: [TranscriptRow] {
        let cards = engine.cards
        return cards.indices.map { index in
            let thread = cards[index].threadID
            return TranscriptRow(
                card: cards[index],
                isFirstRow: index == cards.startIndex,
                startsThread: index == cards.startIndex || cards[index - 1].threadID != thread,
                endsThread: index == cards.index(before: cards.endIndex)
                    || cards[index + 1].threadID != thread
            )
        }
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Deliberately *not* lazy. Rows arrive laid out rather than being
                // measured on demand, which costs a few milliseconds up front on a
                // long transcript and buys the one thing a reading UI cannot do
                // without: scrolling while an answer streams. See `transcript`.
                VStack(alignment: .leading, spacing: 0) {
                    statusItems
                    ForEach(transcriptRows) { row in
                        if !row.isFirstRow {
                            if row.startsThread {
                                // A stronger break than the hairline between two
                                // answers, because it means something stronger:
                                // nothing above it was in front of the model when
                                // the answers below it were written.
                                ThreadBreak()
                            } else {
                                Rectangle().fill(PanelInk.hairline)
                                    .frame(height: 1)
                                    .padding(.leading, AnswerRail.width)
                                    .padding(.trailing, 24)
                            }
                        }
                        QACardView(card: row.card, viewer: viewer)
                            .padding(.leading, AnswerRail.width)
                            .padding(.trailing, 24)
                            .padding(.vertical, 18)
                            .overlay(alignment: .topLeading) {
                                // The rail threads a conversation, so it restarts
                                // with one: each thread gets its own solid first
                                // dot, and the line breaks where they do.
                                AnswerRail(isFirst: row.startsThread, isLast: row.endsThread)
                            }
                            .id(row.id)
                    }
                }
            }
            // Follow the transcript when there is somewhere new to be — a question
            // just asked, an answer just finished — and not on every character in
            // between.
            //
            // Per-delta following was `scrollTo` dozens of times a second, and
            // inside a `LazyVStack` each call makes the stack resolve placements
            // for rows whose heights are still growing; resolving them realizes
            // more rows, which changes the height again. On its own that is merely
            // expensive. With the reader dragging the same scroll view it is a
            // fight over the offset the reader cannot win: every 20 ms the view
            // is dragged back to the bottom, which is most of why scrolling during
            // an answer felt broken. Twice an answer does the same job.
            .onChange(of: engine.cards.count) { follow(proxy) }
            .onChange(of: engine.isStreaming) {
                if !engine.isStreaming { follow(proxy) }
            }
        }
    }

    private func follow(_ proxy: ScrollViewProxy) {
        guard let last = engine.cards.last else { return }
        proxy.scrollTo(last.id, anchor: .bottom)
    }

    /// Everything that is not an answer — the unconfigured-provider notice, attach
    /// progress, attach failure — sits above the thread, in the content column.
    @ViewBuilder
    private var statusItems: some View {
        Group {
            if engine.providerID == "mock" {
                Label(
                    "No provider configured — answers are placeholders. Install Claude Code and run `claude` once to sign in, or add an Anthropic or DeepSeek API key in Settings (⌘,), then pick it from the menu above. This document doesn't need reopening.",
                    systemImage: "info.circle"
                )
                .font(.system(size: 11))
                .foregroundStyle(PanelInk.faint)
            }
            if let status = engine.attachStatus {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(status)
                        .font(.system(size: 11))
                        .foregroundStyle(PanelInk.faint)
                    Button(action: engine.cancelAttach) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(PanelInk.faint)
                    }
                    .buttonStyle(.plain)
                    .help("Stop preparing this document")
                }
            }
            if let attachError = engine.attachError {
                VStack(alignment: .leading, spacing: 4) {
                    Label(attachError, systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundStyle(.red)
                    if engine.canRetryAttach {
                        Button("Try Again", action: engine.retryAttach)
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(EdgeInsets(top: 14, leading: 24, bottom: 0, trailing: 24))
    }

    // MARK: Composer

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let notice = engine.composerNotice {
                HStack(spacing: 4) {
                    Label(notice, systemImage: "eye.slash")
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Button {
                        engine.composerNotice = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(PanelInk.faint)
                    }
                    .buttonStyle(.plain)
                }
            }
            if let selection = engine.pendingSelection {
                StagedQuoteRow(selection: selection) {
                    engine.pendingSelection = nil
                }
            }
            if let crop = engine.pendingCrop {
                StagedCropRow(crop: crop) {
                    engine.pendingCrop = nil
                }
            }
            HStack(spacing: 10) {
                TextField("", text: $input, prompt: askPrompt, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(PanelInk.ink)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit(submit)
                if engine.isStreaming {
                    Button(action: engine.cancel) {
                        Image(systemName: "stop.circle")
                            .font(.system(size: 13))
                            .foregroundStyle(PanelInk.prose)
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                } else {
                    Button(action: submit) {
                        Text("↵")
                            .font(.system(size: 12))
                            .foregroundStyle(canSubmit ? PanelInk.prose : PanelInk.dim)
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSubmit)
                    .help("Ask")
                }
            }
        }
        .padding(EdgeInsets(top: 12, leading: 24, bottom: 14, trailing: 24))
    }

    /// The one place the reader is told, before typing, whether this question
    /// will stand alone or follow the ones above it.
    private var askPrompt: Text {
        Text(engine.conversation.isEmpty ? "Ask…" : "Ask a follow-up…")
            .font(.system(size: 14))
            .foregroundStyle(PanelInk.fainter)
    }

    private var canSubmit: Bool {
        !input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !engine.isStreaming else { return }

        var question = Question(text: text)
        // A staged selection wins; otherwise pick up whatever is live-selected right now.
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

// MARK: - Thread break

/// Where one conversation ended and the next began — pressed by the reader, or
/// created by reopening the document onto a transcript the new conversation
/// cannot see. Full width, rail gutter included, because the rail is exactly what
/// it interrupts.
///
/// Internal rather than private so the snapshot harness renders the real thing.
struct ThreadBreak: View {
    var body: some View {
        HStack(spacing: 8) {
            rule
            Text("new conversation")
                .font(.system(size: 10))
                .kerning(0.3)
                .foregroundStyle(PanelInk.fainter)
            rule
        }
        .padding(EdgeInsets(top: 6, leading: 24, bottom: 6, trailing: 24))
        .help("Questions below this line don't carry the ones above it. The "
              + "document is still the same prepared copy.")
    }

    private var rule: some View {
        Rectangle().fill(PanelInk.hairlineStrong).frame(height: 1)
    }
}

// MARK: - Timeline rail

/// The dot-and-line thread down the left gutter: a solid dot where the
/// conversation started, hollow dots in between, a larger hollow dot on the
/// latest answer. Drawn per row (overlaying it), because a single line behind a
/// stack would not have survived the lazy layout this used to use.
private struct AnswerRail: View {
    let isFirst: Bool
    let isLast: Bool

    static let width: CGFloat = 34
    /// Dot centre below the row's top edge — level with the question's first line.
    private let dotCenter: CGFloat = 29

    var body: some View {
        ZStack(alignment: .top) {
            if isFirst && isLast {
                // A lone answer gets its dot and no line: one end is a dangler.
            } else if isLast {
                line.frame(height: dotCenter)
            } else {
                line.padding(.top, isFirst ? dotCenter : 0)
            }
            dot
        }
        .frame(width: Self.width)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var line: some View {
        Rectangle().fill(PanelInk.hairline).frame(width: 1)
    }

    @ViewBuilder
    private var dot: some View {
        let size: CGFloat = isFirst || isLast ? 9 : 7
        Circle()
            .fill(isFirst ? PanelInk.ink : PanelInk.background)
            .overlay(Circle().stroke(isLast && !isFirst ? PanelInk.ink : PanelInk.dim,
                                     lineWidth: isFirst ? 0 : 1))
            .frame(width: size, height: size)
            .padding(.top, dotCenter - size / 2)
    }
}

// MARK: - Staged attachments

/// A staged text selection, shown the way the design shows any quoted passage:
/// behind a hairline left rule, not in a capsule.
private struct StagedQuoteRow: View {
    let selection: PendingSelection
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Rectangle().fill(PanelInk.quoteRule).frame(width: 1)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundStyle(PanelInk.faint)
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(PanelInk.faint)
            }
            .buttonStyle(.plain)
        }
        .fixedSize(horizontal: false, vertical: true)
        .help(selection.text)
    }

    private var label: String {
        let prefix = selection.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(60)
        let page = selection.page.map { " · p. \($0)" } ?? ""
        return "“\(prefix)…”\(page)"
    }
}

private struct StagedCropRow: View {
    let crop: PendingCrop
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let image = NSImage(data: crop.png) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 24)
                    .border(PanelInk.hairlineStrong, width: 1)
            }
            Text("region · p. \(crop.pageNumber)")
                .font(.system(size: 11.5))
                .foregroundStyle(PanelInk.faint)
            Spacer(minLength: 0)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(PanelInk.faint)
            }
            .buttonStyle(.plain)
        }
        .help(crop.fallbackText ?? "Cropped region from page \(crop.pageNumber)")
    }
}

// MARK: - Answers

/// One answer in the thread: anchors, the question in large light type, the
/// answer directly on the paper, then a quiet line of sources. No box.
///
/// Internal rather than private so the snapshot harness can render the real thing
/// (`Tests/UISnapshots.swift`) instead of a lookalike.
struct QACardView: View {
    let card: QACard
    let viewer: PDFViewerController

    /// Shown for a few seconds when a quote can't be found on the page — silence
    /// after a click reads as a broken link, and "it isn't in the document" is
    /// exactly the thing this feature exists to tell the reader.
    @State private var missNotice: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Anchors: what the question was asked about
            if let selected = card.question.selectedText {
                HStack(alignment: .top, spacing: 10) {
                    Rectangle().fill(PanelInk.quoteRule).frame(width: 1)
                    Text("“\(selected.prefix(120))\(selected.count > 120 ? "…" : "")”")
                        .font(.system(size: 12).italic())
                        .foregroundStyle(PanelInk.faint)
                        .lineLimit(3)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.bottom, 10)
            }
            if let pngData = card.question.regionImagePNG, let image = NSImage(data: pngData) {
                VStack(alignment: .leading, spacing: 5) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 96)
                        .border(PanelInk.hairlineStrong, width: 1)
                    if let page = card.question.regionPage {
                        Text("region · p. \(page)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(PanelInk.faint)
                    }
                }
                .padding(.bottom, 10)
            }
            Text(card.question.text)
                .font(.system(size: 18))
                .kerning(-0.3)
                .lineSpacing(3)
                .foregroundStyle(PanelInk.ink)
                .padding(.bottom, 12)

            if card.answer.isEmpty && card.isStreaming {
                ProgressView().controlSize(.small)
            } else {
                AnswerView(answer: card.answer)
                    .lineSpacing(3.5)
                    .foregroundStyle(PanelInk.prose)
                    // A quoted passage in the answer is a link back to the page it
                    // came from; anything else in an answer is a real link and is
                    // left to the browser.
                    .environment(\.openURL, OpenURLAction { url in
                        guard let quote = SourceLink.quote(from: url) else { return .systemAction }
                        revealQuote(quote)
                        return .handled
                    })
            }

            if !card.citations.isEmpty || !prosePages.isEmpty || !unquotedQuotes.isEmpty {
                sourceLine.padding(.top, 12)
            }

            if let missNotice {
                Label(missNotice, systemImage: "questionmark.text.page")
                    .font(.system(size: 11))
                    .foregroundStyle(PanelInk.faint)
                    .padding(.top, 8)
            }

            ForEach(card.notices, id: \.self) { notice in
                Label(notice, systemImage: "gauge.with.needle")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .padding(.top, 8)
            }

            if let error = card.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .padding(.top, 8)
            }

            if let footer = usageSummary {
                Text(footer)
                    .font(.system(size: 10.5))
                    .foregroundStyle(PanelInk.faint)
                    .padding(.top, 10)
                    .help("Who answered, how much of this question's input was read from "
                          + "the cached document, and what it cost. 0% cached after the first "
                          + "question means the cached prefix is being mutated.")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Jump-to-source

    /// One quiet line of "show me where that came from": the provider's own
    /// page-anchored citations first, then the pages the answer named itself, then any
    /// passage the answer quoted that no citation already covers. All three end in the
    /// same place — the page, with the passage flashed on it where we can find one — so
    /// they read as one line rather than three mechanisms.
    private var sourceLine: some View {
        FlowLayout {
            ForEach(card.citations) { citation in
                Button {
                    revealCitation(citation)
                } label: {
                    Text("p. \(citation.page)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(PanelInk.faint)
                }
                .buttonStyle(.plain)
                .help(citation.citedText)
            }
            ForEach(prosePages, id: \.self) { page in
                Button {
                    viewer.scroll(toPage: page)
                } label: {
                    Text("p. \(page)")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(PanelInk.faint)
                }
                .buttonStyle(.plain)
                .help("Page \(page) — named by this answer")
            }
            ForEach(unquotedQuotes, id: \.self) { quote in
                Button {
                    revealQuote(quote)
                } label: {
                    Label(AnswerQuotes.chipLabel(for: quote), systemImage: "text.magnifyingglass")
                        .font(.system(size: 11))
                        .foregroundStyle(PanelInk.faint)
                        .lineLimit(1)
                }
                .buttonStyle(.plain)
                .help("Find this passage in the document")
            }
        }
    }

    /// Pages the answer named in its own prose, minus any a citation already points at.
    /// This is the only page-anchored source the Claude Code and DeepSeek paths have —
    /// neither returns citations, and both are asked in the prompt to name pages inline
    /// instead — so without it those two answers had nowhere to send the reader.
    private var prosePages: [Int] {
        card.prosePages(inDocumentOf: viewer.pageCount)
    }

    /// Passages the answer quoted, minus the ones a citation already points at,
    /// deduplicated and capped — an answer that quotes ten times needs an index, not
    /// a wall of links.
    private var unquotedQuotes: [String] {
        var seen = Set<String>()
        let cited = card.citations.map { $0.citedText.lowercased() }
        return AnswerQuotes.quotes(in: card.answer)
            .filter { quote in
                let key = quote.lowercased()
                guard !cited.contains(where: { $0.contains(key) }) else { return false }
                return seen.insert(key).inserted
            }
            .prefix(6)
            .map { $0 }
    }

    /// A citation names its page, so a wording that doesn't match still has somewhere
    /// useful to go — extracted text and the model's rendering of it differ often
    /// enough (ligatures, hyphenation, a trimmed ellipsis) that the page is the floor,
    /// not the failure.
    private func revealCitation(_ citation: Citation) {
        if viewer.reveal(quote: citation.citedText, nearPage: citation.page) {
            note(nil)
        } else {
            viewer.scroll(toPage: citation.page)
            note("Couldn't match that wording — jumped to page \(citation.page).")
        }
    }

    private func revealQuote(_ quote: String) {
        if viewer.reveal(quote: quote, nearPage: card.question.pageHint) {
            note(nil)
        } else {
            // No page to fall back to, and guessing one would be worse than saying so:
            // a quote that isn't in the document is a fact about the answer.
            note("Couldn't find that passage in the document.")
        }
    }

    private func note(_ text: String?) {
        missNotice = text
        guard text != nil else { return }
        Task {
            try? await Task.sleep(for: .seconds(5))
            if missNotice == text { missNotice = nil }
        }
    }

    /// One tertiary line under each answer: provenance, cache share, cost. Every
    /// part is optional — the subscription path has no per-token bill to show,
    /// and a failed question has no usage at all.
    private var usageSummary: String? {
        var parts: [String] = []
        if !card.providerName.isEmpty {
            parts.append([card.providerName, card.modelName].compactMap { $0 }.joined(separator: " · "))
        }
        if let fraction = card.cachedFraction {
            parts.append("\(Int((fraction * 100).rounded()))% cached")
        }
        if let output = card.outputTokens {
            parts.append("\(output) tokens out")
        }
        if let cost = card.costUSD {
            parts.append(TokenPricing.format(cost))
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
