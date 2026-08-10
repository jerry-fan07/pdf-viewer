import Foundation

/// Claude via the user's Pro/Max subscription, by driving the locally installed
/// Claude Code CLI as a child process (PLAN.md §5.3). The app stores no
/// credential and never sees one — auth is whatever `claude` already has.
///
///   attach (once per document):
///     claude -p "Read the PDF at <path>. Reply only 'ready'."
///       --output-format stream-json --include-partial-messages --verbose
///       --allowedTools Read --add-dir <document dir>
///     → session_id, read off any record in the stream.
///
///   ask (every question):
///     claude -p "<question>" --resume <thread ?? primed> --fork-session …
///     → forking branches into a NEW session, so the session it resumed is never
///       mutated. The first question of a conversation forks the primed session;
///       every question after it forks the fork the last answer left behind, which
///       is how the thread accumulates while the primed session stays pristine and
///       its cached PDF read keeps being reused. Verified against CLI 2.1.223: a
///       fork of a fork resumes with its parent's context, and the `session_id` on
///       the first stream record is the new fork's, not the resumed one's.
struct ClaudeCodeProvider: ChatProvider {
    let id = "claude-code"
    let displayName = "Claude (subscription)"
    /// Citations are prompted page numbers in prose, not API-native page anchors,
    /// so there are no clickable chips on this path.
    let capabilities = ProviderCapabilities(
        supportsVision: true, supportsNativePDF: true, supportsCitations: false
    )

    var effort: ClaudeCodeEffort = .cliDefault

    private static let sessionCache = DocumentHandleCache(namespace: "claudeCode.sessionIDs")

    // MARK: Attach

    func attach(document: PDFDocumentInfo) async throws -> DocumentAttachment {
        let executable = try ClaudeCodeCLI.locate()
        try await ClaudeCodeCLI.verifyVersion(of: executable)

        let title = document.fileURL.lastPathComponent
        if let primed = Self.sessionCache.lookup(document.fileURL) {
            return DocumentAttachment(providerID: id, handle: primed,
                                      title: title, sourceURL: document.fileURL)
        }

        var decoder = ClaudeCodeStreamDecoder()
        try await ClaudeCodeCLI.run(
            executable: executable,
            arguments: baseArguments(
                prompt: ClaudeCodePrompt.prime(documentPath: document.fileURL.path),
                readableDirectories: [document.fileURL.deletingLastPathComponent()]
            ),
            workingDirectory: try ClaudeCodeCLI.workingDirectory()
        ) { line in
            _ = try decoder.consume(line)
        }

        guard let sessionID = decoder.sessionID else { throw ClaudeCodeError.noSessionID }
        Self.sessionCache.store(sessionID, for: document.fileURL)
        return DocumentAttachment(providerID: id, handle: sessionID,
                                  title: title, sourceURL: document.fileURL)
    }

    // MARK: Ask

    func ask(_ question: Question, in attachment: DocumentAttachment, conversation: Conversation)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(question, in: attachment, conversation: conversation) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ question: Question,
                     in attachment: DocumentAttachment,
                     conversation: Conversation,
                     yield: (ChatEvent) -> Void) async throws
    {
        let executable = try ClaudeCodeCLI.locate()

        var readable: [URL] = []
        if let source = attachment.sourceURL {
            readable.append(source.deletingLastPathComponent())
        }

        // Crops are handed over as file paths for the Read tool, inside a
        // directory covered by --add-dir.
        var cropPath: String?
        if let png = question.regionImagePNG {
            let directory = try ClaudeCodeCLI.cropsDirectory()
            let file = directory.appendingPathComponent("crop-\(UUID().uuidString).png")
            try png.write(to: file)
            cropPath = file.path
            readable.append(directory)
        }
        defer {
            if let cropPath { try? FileManager.default.removeItem(atPath: cropPath) }
        }

        // The thread is a chain of forks: the first question of a conversation
        // forks the primed session, and each answer after that forks the one the
        // previous answer created. The primed session is never resumed directly
        // twice, so it stays as clean as the Phase 0 spike left it, and "New
        // conversation" is just this handle going away — the next question forks
        // the primed session again and the cached PDF read is still there.
        var arguments = baseArguments(
            prompt: ClaudeCodePrompt.ask(question, cropPath: cropPath,
                                         replaying: conversation.unhandledTurns),
            readableDirectories: readable
        )
        arguments += ["--resume", conversation.handle ?? attachment.handle, "--fork-session"]

        var decoder = ClaudeCodeStreamDecoder()
        do {
            try await ClaudeCodeCLI.run(
                executable: executable,
                arguments: arguments,
                workingDirectory: try ClaudeCodeCLI.workingDirectory()
            ) { line in
                for event in try decoder.consume(line) { yield(event) }
            }
        } catch let error as ClaudeCodeError {
            // A primed session that the CLI can no longer resume (pruned, or a
            // different machine) shouldn't wedge the document forever. Only the
            // primed session is cached on disk, so that is the one to drop —
            // a dead thread handle is discarded by the engine either way.
            if case .cliFailed = error, let source = attachment.sourceURL {
                Self.sessionCache.invalidate(source)
            }
            throw error
        }

        // Reported last, and only on a clean run: this is where the thread now
        // lives, and a run that threw left nothing worth resuming.
        if let forked = decoder.sessionID {
            yield(.threadHandle(forked))
        }
    }

    // MARK: Arguments

    private func baseArguments(prompt: String, readableDirectories: [URL]) -> [String] {
        var arguments = [
            "-p", prompt,
            "--output-format", "stream-json",
            "--include-partial-messages",
            "--verbose",
            "--allowedTools", "Read",
        ]
        // Never pass --bare: it disables subscription OAuth credential reading.
        for directory in Set(readableDirectories.map(\.standardizedFileURL.path)).sorted() {
            arguments += ["--add-dir", directory]
        }
        arguments += effort.arguments
        return arguments
    }
}
