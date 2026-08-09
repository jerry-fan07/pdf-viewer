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
///   ask (every question, strictly independent):
///     claude -p "<question>" --resume <primed> --fork-session …
///     → forking branches into a NEW session, so the primed one is never mutated:
///       questions reuse the cached PDF read and stay ignorant of each other.
struct ClaudeCodeProvider: ChatProvider {
    let id = "claude-code"
    let displayName = "Claude (subscription)"
    /// Citations are prompted page numbers in prose, not API-native page anchors,
    /// so there are no clickable chips on this path.
    let capabilities = ProviderCapabilities(
        supportsVision: true, supportsNativePDF: true, supportsCitations: false
    )

    var model: ClaudeCodeModel = .cliDefault
    var effort: ClaudeCodeEffort = .cliDefault

    /// Nil while the model is the CLI's own choice — see `ClaudeCodeModel.badgeName`.
    /// This also feeds `ChatEngine`'s attachment key, so picking a model re-attaches:
    /// harmless here, since the primed session is cached per document and comes
    /// straight back without a second read of the PDF.
    var modelName: String? { model.badgeName }

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

    func ask(_ question: Question, in attachment: DocumentAttachment)
        -> AsyncThrowingStream<ChatEvent, Error>
    {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(question, in: attachment) { continuation.yield($0) }
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

        var arguments = baseArguments(
            prompt: ClaudeCodePrompt.ask(question, cropPath: cropPath),
            readableDirectories: readable
        )
        arguments += ["--resume", attachment.handle, "--fork-session"]

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
            // different machine) shouldn't wedge the document forever.
            if case .cliFailed = error, let source = attachment.sourceURL {
                Self.sessionCache.invalidate(source)
            }
            throw error
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
        arguments += model.arguments
        arguments += effort.arguments
        return arguments
    }
}
