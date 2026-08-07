import Foundation

/// Claude via the user's Pro/Max subscription, by driving the local Claude Code CLI.
/// Mechanics validated in the Phase 0 spike (docs/phase0-spike.md, CLI 2.1.223):
///
///   attach (prime once per document):
///     claude -p "Read the PDF at <path>. Reply only 'ready'." \
///       --output-format json --allowedTools Read --add-dir <dir>
///     → parse the trailing `type == "result"` element of the JSON *array* for session_id.
///
///   ask (every question, strictly independent):
///     claude -p "<question>" --resume <primed_session_id> --fork-session \
///       --output-format stream-json --allowedTools Read --add-dir <dirs>
///     → NDJSON; assistant text deltas → .textDelta, final result → .usage/.done.
///
/// Invariants (from the spike):
///   • Sanitize the child environment: strip ANTHROPIC_* and CLAUDE_* vars — an inherited
///     ANTHROPIC_API_KEY silently overrides subscription auth in -p mode.
///   • Never pass --bare (it disables subscription OAuth credential reading).
///   • Crop PNGs are passed as file paths inside a temp dir covered by --add-dir.
struct ClaudeCodeProvider: ChatProvider {
    let id = "claude-code"
    let displayName = "Claude (subscription)"
    let capabilities = ProviderCapabilities(
        supportsVision: true, supportsNativePDF: true, supportsCitations: false
    )

    /// Minimal environment for the child process — deliberately not `ProcessInfo.environment`.
    static func sanitizedEnvironment() -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var child: [String: String] = [:]
        for key in ["HOME", "USER", "TMPDIR", "SHELL"] {
            child[key] = env[key]
        }
        child["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        child["TERM"] = "dumb"
        return child
    }

    func attach(document: PDFDocumentInfo) async throws -> DocumentAttachment {
        // Phase 5: locate the CLI (verify login state), spawn the prime call above,
        // parse session_id from the result element, persist per document.
        throw ProviderError.notImplemented("Claude Code provider lands in Phase 5 (see PLAN.md §5.3)")
    }

    func ask(_ question: Question, in attachment: DocumentAttachment)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        AsyncThrowingStream { continuation in
            continuation.finish(throwing: ProviderError.notImplemented("Claude Code provider lands in Phase 5"))
        }
    }
}
