import Foundation

enum ClaudeCodeError: LocalizedError {
    case cliNotFound
    case cliTooOld(found: String, required: String)
    case notLoggedIn(detail: String)
    case cliFailed(status: Int32, stderr: String)
    case noSessionID
    case runFailed(String)

    var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Claude Code isn't installed where this app can find it. Install it "
                + "(npm i -g @anthropic-ai/claude-code, or brew install claude), run `claude` "
                + "once in a terminal to sign in, then reopen this document."
        case .cliTooOld(let found, let required):
            return "Claude Code \(found) is older than the \(required) this app was built "
                + "against. Update the CLI, then reopen this document."
        case .notLoggedIn(let detail):
            return "Claude Code isn't signed in. Run `claude` once in a terminal and complete "
                + "the login, then reopen this document.\n\n\(detail)"
        case .cliFailed(let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Claude Code exited with status \(status)."
                + (detail.isEmpty ? "" : "\n\n\(detail)")
        case .noSessionID:
            return "Claude Code never reported a session id, so questions can't reuse the "
                + "document it just read. Try reopening the document."
        case .runFailed(let detail):
            return "Could not run Claude Code: \(detail)"
        }
    }
}

/// Locates and drives the locally installed Claude Code CLI as a child process.
/// This is the whole subscription path — the app stores no credential of its own
/// and never sees one (PLAN.md §5.3).
enum ClaudeCodeCLI {
    /// Verified working in the Phase 0 spike; `--include-partial-messages` and
    /// `--fork-session` both need to exist.
    static let minimumVersion = "2.1.0"

    /// A GUI app doesn't inherit the user's shell PATH, so `which` is useless here.
    private static let candidatePaths = [
        "/opt/homebrew/bin/claude",
        "/usr/local/bin/claude",
        "/usr/bin/claude",
        "\(NSHomeDirectory())/.claude/local/claude",
        "\(NSHomeDirectory())/.local/bin/claude",
        "\(NSHomeDirectory())/.bun/bin/claude",
    ]

    static func locate() throws -> URL {
        if let override = UserDefaults.standard.string(forKey: "claudeCode.path"),
           !override.isEmpty, FileManager.default.isExecutableFile(atPath: override) {
            return URL(fileURLWithPath: override)
        }
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw ClaudeCodeError.cliNotFound
    }

    /// `true` when the CLI is present — used to pick a sensible default provider.
    static var isInstalled: Bool { (try? locate()) != nil }

    // MARK: Environment

    /// Deliberately *not* `ProcessInfo.environment`. An inherited
    /// `ANTHROPIC_API_KEY` silently takes precedence in `-p` mode and would bill
    /// the user's API account instead of using their subscription; the spike also
    /// saw `ANTHROPIC_BASE_URL` and `CLAUDE_CODE_*` leak in from a parent session.
    static func sanitizedEnvironment() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var child: [String: String] = [
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "TERM": "dumb",
        ]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG"] {
            if let value = inherited[key] { child[key] = value }
        }
        return child
    }

    /// Stable working directory for every invocation. Claude Code files sessions
    /// under a slug of the cwd, so prime and ask **must** share one or `--resume`
    /// won't find the primed session. A dedicated directory also keeps unrelated
    /// CLAUDE.md / project context out of the conversation.
    static func workingDirectory() throws -> URL {
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        let directory = support.appendingPathComponent("ClaudePDF/cli", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Scratch space for crop PNGs handed to the CLI as file paths.
    static func cropsDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ClaudePDF/crops", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: Running

    static func version(of executable: URL) async throws -> String {
        var output = ""
        try await run(executable: executable, arguments: ["--version"],
                      workingDirectory: try workingDirectory()) { output += $0 }
        // "2.1.223 (Claude Code)"
        let token = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ").first.map(String.init) ?? ""
        guard !token.isEmpty else { throw ClaudeCodeError.runFailed("unreadable --version output") }
        return token
    }

    static func verifyVersion(of executable: URL) async throws {
        let found = try await version(of: executable)
        if found.compare(minimumVersion, options: .numeric) == .orderedAscending {
            throw ClaudeCodeError.cliTooOld(found: found, required: minimumVersion)
        }
    }

    /// Runs the CLI, handing each stdout line to `onLine` as it arrives.
    /// Cancelling the enclosing task terminates the child.
    static func run(executable: URL,
                    arguments: [String],
                    workingDirectory: URL,
                    onLine: (String) throws -> Void) async throws
    {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.environment = sanitizedEnvironment()

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ClaudeCodeError.runFailed(error.localizedDescription)
        }

        // Drain stderr concurrently: a chatty child that fills the pipe buffer
        // while we're only reading stdout would deadlock.
        let stderrTask = Task.detached {
            (try? errors.fileHandleForReading.readToEnd()).flatMap {
                String(data: $0 ?? Data(), encoding: .utf8)
            } ?? ""
        }

        do {
            try await withTaskCancellationHandler {
                for try await line in output.fileHandleForReading.bytes.lines {
                    try Task.checkCancellation()
                    try onLine(line)
                }
            } onCancel: {
                process.terminate()
            }
        } catch {
            process.terminate()
            _ = await stderrTask.value
            throw error
        }

        process.waitUntilExit()
        let stderr = await stderrTask.value

        guard process.terminationStatus == 0 else {
            if looksLikeLoginFailure(stderr) {
                throw ClaudeCodeError.notLoggedIn(detail: stderr)
            }
            throw ClaudeCodeError.cliFailed(status: process.terminationStatus, stderr: stderr)
        }
    }

    static func looksLikeLoginFailure(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return ["not logged in", "please run /login", "authentication_error",
                "invalid api key", "oauth token has expired", "credentials"]
            .contains { lowered.contains($0) }
    }
}
