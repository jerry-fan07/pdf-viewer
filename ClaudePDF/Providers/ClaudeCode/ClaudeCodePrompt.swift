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

    static func ask(_ question: Question, cropPath: String?) -> String {
        var parts: [String] = []

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
        // for (PLAN.md capability matrix: best-effort, prompted).
        parts.append(
            "Answer from the PDF already in this conversation. Reference page numbers "
            + "inline so the reader can find the passage. Lead with the answer and keep it short."
        )

        return parts.joined(separator: "\n\n")
    }
}
