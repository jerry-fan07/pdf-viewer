import SwiftUI

struct ChatPanelView: View {
    @ObservedObject var engine: ChatEngine
    let viewer: PDFViewerController

    @State private var input = ""

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            transcript
            Divider()
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

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Ask a question…", text: $input, axis: .vertical)
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

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !engine.isStreaming else { return }
        var question = Question(text: text)
        if let selection = viewer.selectionInfo() {
            question.selectedText = selection.text
            question.selectedTextPage = selection.page
        }
        engine.ask(question)
        input = ""
    }
}

private struct QACardView: View {
    let card: QACard
    let viewer: PDFViewerController

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Anchor: what the question was asked about
            if let selected = card.question.selectedText {
                Text("“\(selected.prefix(120))\(selected.count > 120 ? "…" : "")”")
                    .font(.caption)
                    .italic()
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
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
