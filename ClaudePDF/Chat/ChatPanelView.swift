import SwiftUI
import AppKit

struct ChatPanelView: View {
    @ObservedObject var engine: ChatEngine
    let viewer: PDFViewerController

    @State private var input = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            composer
        }
        .background(.background)
        .onChange(of: engine.composerFocusRequest) { _, _ in
            inputFocused = true
        }
    }

    private var header: some View {
        HStack {
            Text("Ask about this document")
                .font(.headline)
            Spacer()
            if engine.hasHistory {
                Button(role: .destructive) {
                    engine.clearHistory()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .disabled(engine.isStreaming)
                .help("Clear this document's saved questions and answers")
            }
            Text(engine.providerName)
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.quaternary, in: Capsule())
        }
        .padding(10)
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if engine.providerID == "mock" {
                        Label(
                            "No provider configured — answers are placeholders. Install Claude Code and run `claude` once to sign in, or add an Anthropic or DeepSeek API key in Settings (⌘,). Then reopen this document.",
                            systemImage: "info.circle"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    if let status = engine.attachStatus {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let attachError = engine.attachError {
                        Label(attachError, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    ForEach(engine.cards) { card in
                        QACardView(card: card, viewer: viewer)
                            .id(card.id)
                    }
                }
                .padding(10)
            }
            .onChange(of: engine.cards.last?.answer.count ?? 0) {
                if let last = engine.cards.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    // MARK: Composer

    private var composer: some View {
        VStack(spacing: 6) {
            if let notice = engine.composerNotice {
                HStack(spacing: 4) {
                    Label(notice, systemImage: "eye.slash")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Spacer(minLength: 0)
                    Button {
                        engine.composerNotice = nil
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.caption)
                    }
                    .buttonStyle(.plain)
                }
            }
            if engine.pendingSelection != nil || engine.pendingCrop != nil {
                attachmentChips
            }
            HStack(spacing: 8) {
                TextField("Ask a question…", text: $input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($inputFocused)
                    .onSubmit(submit)
                if engine.isStreaming {
                    Button(action: engine.cancel) {
                        Image(systemName: "stop.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .help("Stop")
                } else {
                    Button(action: submit) {
                        Image(systemName: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                    .help("Ask")
                }
            }
        }
        .padding(10)
    }

    private var attachmentChips: some View {
        HStack(spacing: 6) {
            if let selection = engine.pendingSelection {
                ChipView(
                    systemImage: "text.quote",
                    label: selectionChipLabel(selection),
                    help: selection.text
                ) {
                    engine.pendingSelection = nil
                }
            }
            if let crop = engine.pendingCrop {
                CropChipView(crop: crop) {
                    engine.pendingCrop = nil
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func selectionChipLabel(_ selection: PendingSelection) -> String {
        let prefix = selection.text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(28)
        let page = selection.page.map { " · p. \($0)" } ?? ""
        return "“\(prefix)…”\(page)"
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

// MARK: - Chips

private struct ChipView: View {
    let systemImage: String
    let label: String
    var help: String = ""
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.caption)
            Text(label)
                .font(.caption)
                .lineLimit(1)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: Capsule())
        .help(help)
    }
}

private struct CropChipView: View {
    let crop: PendingCrop
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            if let image = NSImage(data: crop.png) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(height: 28)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            }
            Text("Region · p. \(crop.pageNumber)")
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        .help(crop.fallbackText ?? "Cropped region from page \(crop.pageNumber)")
    }
}

// MARK: - Cards

private struct QACardView: View {
    let card: QACard
    let viewer: PDFViewerController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Anchors: what the question was asked about
            if let selected = card.question.selectedText {
                Text("“\(selected.prefix(120))\(selected.count > 120 ? "…" : "")”")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            if let pngData = card.question.regionImagePNG, let image = NSImage(data: pngData) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxHeight: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .overlay(alignment: .bottomTrailing) {
                        if let page = card.question.regionPage {
                            Text("p. \(page)")
                                .font(.caption2)
                                .padding(2)
                                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 3))
                                .padding(3)
                        }
                    }
            }
            Text(card.question.text)
                .font(.body.weight(.semibold))

            if card.answer.isEmpty && card.isStreaming {
                ProgressView().controlSize(.small)
            } else {
                AnswerView(answer: card.answer)
                    .font(.body)
            }

            if !card.citations.isEmpty {
                HStack(spacing: 6) {
                    ForEach(card.citations) { citation in
                        Button("p. \(citation.page)") {
                            viewer.scroll(toPage: citation.page)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .help(citation.citedText)
                    }
                }
            }

            ForEach(card.notices, id: \.self) { notice in
                Label(notice, systemImage: "gauge.with.needle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if let error = card.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }

            if let footer = usageSummary {
                Text(footer)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .help("Who answered, how much of this question's input was read from "
                          + "the cached document, and what it cost. 0% cached after the first "
                          + "question means the cached prefix is being mutated.")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
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
