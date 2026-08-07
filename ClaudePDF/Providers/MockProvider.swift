import Foundation

/// Streams a canned answer so the chat UI is demoable before any real provider lands.
/// Wired as the default in DocumentWindow until Phase 3.
struct MockProvider: ChatProvider {
    let id = "mock"
    let displayName = "Mock (offline)"
    let capabilities = ProviderCapabilities(
        supportsVision: true, supportsNativePDF: true, supportsCitations: true
    )

    func attach(document: PDFDocumentInfo) async throws -> DocumentAttachment {
        DocumentAttachment(providerID: id, handle: document.fileURL.lastPathComponent)
    }

    func ask(_ question: Question, in attachment: DocumentAttachment)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                var preamble = "(mock) You asked: “\(question.text)”"
                if let selected = question.selectedText {
                    preamble += "\nAbout the selection: “\(selected.prefix(80))…”"
                }
                if let png = question.regionImagePNG {
                    preamble += "\nWith a \(png.count / 1024) KB region crop"
                    if let page = question.regionPage { preamble += " from page \(page)" }
                    if let text = question.regionText {
                        preamble += ", text under it: “\(text.prefix(60))…”"
                    } else {
                        preamble += " (no text layer under the crop)"
                    }
                }
                preamble += "\nThis is a placeholder answer streamed word by word. "
                preamble += "Configure a real provider in Settings once Phase 3+ lands.\n\n"
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
