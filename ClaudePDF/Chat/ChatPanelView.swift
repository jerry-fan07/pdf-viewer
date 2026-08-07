import SwiftUI
import AppKit

struct ChatPanelView: View {
    @ObservedObject var engine: ChatEngine
    @ObservedObject var viewer: PDFViewerController

    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
            anchorBar
            inputBar
        }
        .background(.background)
    }

    private var header: some View {
        HStack {
            Text("Ask about this document")
                .font(.headline)
            Spacer()
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

    /// The staged selection or crop the next question will be about (PLAN.md §6: every
    /// question shows its anchor — here, before it is even sent).
    @ViewBuilder
    private var anchorBar: some View {
        if let error = viewer.anchorError {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 8)
        }
        if let anchor = viewer.anchor {
            HStack(alignment: .top, spacing: 8) {
                AnchorPreview(anchor: anchor)
                Spacer(minLength: 0)
                Button {
                    viewer.clearAnchor()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Remove this anchor")
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField(placeholder, text: $input, axis: .vertical)
                .textFieldStyle(.plain)
                .lineLimit(1...4)
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
        .padding(10)
    }

    private var placeholder: String {
        switch viewer.anchor {
        case .region: return "Ask about this region…"
        case .text: return "Ask about this selection…"
        case nil: return "Ask a question…"
        }
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !engine.isStreaming else { return }
        var question = Question(text: text)
        question.pageHint = viewer.currentPageNumber
        viewer.takeAnchor()?.apply(to: &question)
        engine.ask(question)
        input = ""
    }
}

/// Shared rendering of an anchor — used both in the pending bar and on each answered card.
private struct AnchorPreview: View {
    let anchor: QuestionAnchor

    var body: some View {
        switch anchor {
        case .text(let selected, let page):
            VStack(alignment: .leading, spacing: 2) {
                if let page {
                    Text("Selection · p. \(page)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                Text("“\(selected.prefix(120))\(selected.count > 120 ? "…" : "")”")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        case .region(let capture):
            HStack(alignment: .top, spacing: 8) {
                CropThumbnail(pngData: capture.pngData)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Region · p. \(capture.pageNumber)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let text = capture.text {
                        Text(text.prefix(80) + (text.count > 80 ? "…" : ""))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

private struct CropThumbnail: View {
    let pngData: Data

    var body: some View {
        if let image = NSImage(data: pngData) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 96, maxHeight: 72)
                .background(.white)
                .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
}

private struct QACardView: View {
    let card: QACard
    let viewer: PDFViewerController

    /// Rebuild the anchor from the question so answered cards show the same preview.
    private var anchor: QuestionAnchor? {
        if let png = card.question.regionImagePNG {
            return .region(RegionCapture(
                pngData: png,
                text: card.question.regionText,
                pageNumber: card.question.regionPage ?? 0,
                pageRect: .zero,
                pixelSize: .zero
            ))
        }
        if let selected = card.question.selectedText {
            return .text(selected, page: card.question.selectedTextPage)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let anchor {
                AnchorPreview(anchor: anchor)
            }
            Text(card.question.text)
                .font(.body.weight(.semibold))

            if card.answer.isEmpty && card.isStreaming {
                ProgressView().controlSize(.small)
            } else {
                Text(markdown(card.answer))
                    .font(.body)
                    .textSelection(.enabled)
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

            if let error = card.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if let input = card.inputTokens, let cached = card.cacheReadTokens, input + cached > 0 {
                Text("\(Int((Double(cached) / Double(input + cached)) * 100))% cached")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(text)
    }
}
