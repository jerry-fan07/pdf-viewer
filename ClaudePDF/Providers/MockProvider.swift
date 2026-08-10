import Foundation
import PDFKit

/// Streams a canned answer so the chat UI is demoable before any real provider lands.
/// Wired as the default in DocumentWindow until Phase 3.
struct MockProvider: ChatProvider {
    let id = "mock"
    let displayName = "Mock (offline)"
    let capabilities = ProviderCapabilities(
        supportsVision: true, supportsNativePDF: true, supportsCitations: true
    )

    func attach(document: PDFDocumentInfo) async throws -> DocumentAttachment {
        DocumentAttachment(
            providerID: id,
            handle: document.fileURL.lastPathComponent,
            sourceURL: document.fileURL
        )
    }

    func ask(_ question: Question, in attachment: DocumentAttachment, conversation: Conversation)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                var preamble = "(mock) You asked: “\(question.text)”"
                // Named so threading is visible offline: this is the count that
                // goes back to a real provider, and that "New conversation" zeroes.
                let turns = conversation.replayableTurns
                if let last = turns.last {
                    preamble += "\nFollowing \(turns.count) earlier question"
                    preamble += turns.count == 1 ? "" : "s"
                    preamble += " in this conversation, the last being “\(last.question.text)”."
                }
                if let selected = question.selectedText {
                    preamble += "\nAbout the selection: “\(selected.prefix(80))…”"
                }
                if question.regionImagePNG != nil {
                    preamble += "\nAbout the cropped region on page \(question.regionPage ?? 0)"
                    if let fallback = question.regionFallbackText {
                        preamble += " (its text: “\(fallback.prefix(60))…”)"
                    }
                    preamble += "."
                }
                preamble += "\nThis is a placeholder answer streamed word by word. "
                preamble += "Configure a real provider in Settings once Phase 3+ lands.\n\n"
                if let passage = Self.realPassage(
                    from: attachment.sourceURL, page: question.pageHint ?? 1
                ) {
                    preamble += "The document itself says \"\(passage)\", "
                    preamble += "and \"this sentence is a paraphrase that is not in the document\".\n\n"
                }
                preamble += Self.latexSample
                for word in preamble.split(separator: " ", omittingEmptySubsequences: false) {
                    try Task.checkCancellation()
                    continuation.yield(.textDelta(String(word) + " "))
                    try await Task.sleep(for: .milliseconds(20))
                }
                continuation.yield(.citation(pageNumber: min(2, max(1, question.selectedTextPage ?? 1)), citedText: "mock citation"))
                continuation.yield(.usage(inputTokens: 1200, cacheReadTokens: 1100, cacheWriteTokens: 0, outputTokens: 60))
                continuation.yield(.done)
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// A run of words genuinely on the page the reader is looking at, so the offline
    /// answer exercises answer-to-source highlighting the same way `latexSample`
    /// exercises the typesetter — one quotation that must be found and flashed, and
    /// one that must come back "not in the document".
    ///
    /// Words are taken from the middle of a line rather than its start, so the match
    /// has to survive the line breaks around it rather than getting them for free.
    private static func realPassage(from url: URL?, page: Int) -> String? {
        guard let url, let document = PDFDocument(url: url),
              let text = document.page(at: min(max(page, 1), document.pageCount) - 1)?.string
        else { return nil }
        let words = text
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { $0.count > 1 }
        guard words.count >= 14 else { return nil }
        // A stray `"` on the page would close the demo quote early, in the one place
        // whose whole job is to be a well-formed quotation.
        return words[4..<12].joined(separator: " ").replacingOccurrences(of: "\"", with: "")
    }

    /// Every LaTeX shape the answer renderer has to survive: both inline delimiters, both
    /// display delimiters, a bare environment, `$` used as money right next to real math,
    /// and math inside a code span. Streamed word by word like everything else, so a
    /// half-arrived `$$` is exercised on every run.
    private static let latexSample = """
        Inline TeX-style: \\(E = mc^2\\); dollar-style: $\\alpha_1 + \\beta^2$.

        $$\\int_0^\\infty e^{-x^2}\\,dx = \\frac{\\sqrt{\\pi}}{2}$$

        \\[ \\sum_{n=1}^{N} \\frac{1}{n^2} = \\frac{\\pi^2}{6} \\]

        \\begin{aligned} a &= b + c \\\\ d &= e - f \\end{aligned}

        Money stays money: it costs $5 and $6, so $x = 5n$ is the total. \
        Code stays code: `$not_math$`. Markdown still works: **bold**, *italic*.
        """
}
