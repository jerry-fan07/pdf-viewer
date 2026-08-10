import Foundation

/// Effort is the documented latency lever for this path: the Phase 0 spike
/// measured 20–32 s per question at CLI defaults (PLAN.md §5.3).
enum ClaudeCodeEffort: String, CaseIterable, Identifiable, Sendable {
    case cliDefault = ""
    case low, medium, high, xhigh, max

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cliDefault: return "CLI default"
        case .low: return "Low (fastest)"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max (slowest)"
        }
    }

    /// Arguments to append; empty for the CLI's own default.
    var arguments: [String] { self == .cliDefault ? [] : ["--effort", rawValue] }
}

/// Prompt text handed to `claude -p`. Pure and separate from process handling so
/// the wording is testable without spawning anything.
enum ClaudeCodePrompt {
    /// One upfront read per document, so the slow PDF ingest is paid at open
    /// rather than on the first question, and every forked question inherits it.
    static func prime(documentPath: String) -> String {
        "Read the PDF at \(documentPath). Reply only 'ready'."
    }

    /// Turns this session cannot already know about, written into the prompt.
    ///
    /// Normally empty: the thread lives in the session, so continuing it is a
    /// resume rather than a retelling. It fills up in the two cases where the
    /// session and the thread have come apart — the reader switched provider
    /// mid-conversation, so this is the first Claude Code question of a thread
    /// that started elsewhere; or an answer was stopped part-way and left no fork
    /// behind to resume.
    static func replay(_ turns: [ConversationTurn]) -> String? {
        guard !turns.isEmpty else { return nil }
        let exchanges = turns.map { turn in
            "Q: \(turn.question.text)\nA: \(turn.answer)"
        }
        return "Earlier in this conversation, answered elsewhere:\n\n"
            + exchanges.joined(separator: "\n\n")
    }

    static func ask(_ question: Question,
                    cropPath: String?,
                    replaying turns: [ConversationTurn] = []) -> String
    {
        var parts: [String] = []

        if let replayed = replay(turns) {
            parts.append(replayed)
        }

        if let selected = question.selectedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           !selected.isEmpty {
            let page = question.selectedTextPage.map { "page \($0)" } ?? "the document"
            parts.append("The reader selected this text on \(page):\n\"\"\"\n\(selected)\n\"\"\"")
        }

        if let cropPath {
            let page = question.regionPage.map { "page \($0)" } ?? "the document"
            parts.append("The reader cropped a region from \(page). Read the image at \(cropPath).")
        }

        if let page = question.pageHint {
            parts.append("The reader is currently on page \(page).")
        }

        parts.append("Question: \(question.text)")

        // No API-native citations on this path, so page numbers have to be asked
        // for (PLAN.md capability matrix: best-effort, prompted). The verbatim-quote and
        // LaTeX requests are the same story: left alone, models paraphrase what they
        // read — and answer papers in Unicode (φ, ≈, √), so the typesetter never sees
        // anything to typeset. This prompt is volatile, so unlike the two API paths
        // asking for all three costs nothing in cache.
        parts.append(
            "Answer from the PDF already in this conversation. Reference page numbers "
            + "inline so the reader can find the passage. When a specific passage carries "
            + "your answer, quote it in double quotes, copied from the document exactly — "
            + "same words, same order, no tidying up — and under about 25 words: the viewer "
            + "looks each quotation up on the page and highlights it. "
            + "Lead with the answer and keep it short. "
            + "Write mathematics as LaTeX so the viewer can typeset it: $…$ inline, $$…$$ for a "
            + "displayed equation — write $\\phi(H) \\neq 1$, not φ(H) ≠ 1."
        )

        return parts.joined(separator: "\n\n")
    }
}
