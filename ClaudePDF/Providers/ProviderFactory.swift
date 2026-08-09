import Foundation

/// Which backend a newly opened document should talk to.
enum ProviderChoice: String, CaseIterable, Identifiable, Sendable {
    /// Whatever is actually usable on this machine — subscription first.
    case automatic
    case claudeCode
    case anthropicAPI
    case deepseek
    case mock

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .claudeCode: return "Claude subscription (Claude Code)"
        case .anthropicAPI: return "Claude API (API key)"
        case .deepseek: return "DeepSeek API (API key)"
        case .mock: return "Mock (offline)"
        }
    }

    /// The choices a window can switch *to*. `.automatic` is a rule for resolving
    /// a provider at open, not a destination.
    static var switchable: [ProviderChoice] { [.claudeCode, .anthropicAPI, .deepseek, .mock] }

    /// The `ChatProvider.id` this choice builds, so a live provider can be matched
    /// back to the menu item it came from.
    var providerID: String? {
        switch self {
        case .automatic: return nil
        case .claudeCode: return "claude-code"
        case .anthropicAPI: return "anthropic"
        case .deepseek: return "deepseek"
        case .mock: return "mock"
        }
    }

    init?(providerID: String) {
        guard let match = ProviderChoice.allCases.first(where: { $0.providerID == providerID })
        else { return nil }
        self = match
    }

    /// Why this can't be picked right now, if it can't. Offering a provider whose
    /// key is missing would trade a greyed-out menu item for an attach that fails
    /// a second later.
    var unavailableReason: String? {
        unavailableReason(
            cliInstalled: ClaudeCodeCLI.isInstalled,
            hasAnthropicKey: AppSettings.hasAnthropicKey,
            hasDeepSeekKey: AppSettings.hasDeepSeekKey
        )
    }

    /// The same question with the environment passed in. Separated because the
    /// property above reads the Keychain, and a test that touches the Keychain can
    /// block on an unlock prompt that never comes.
    func unavailableReason(cliInstalled: Bool,
                           hasAnthropicKey: Bool,
                           hasDeepSeekKey: Bool) -> String?
    {
        switch self {
        case .automatic, .mock:
            return nil
        case .claudeCode:
            return cliInstalled
                ? nil : "Claude Code isn't installed. Install it and run `claude` once to sign in."
        case .anthropicAPI:
            return hasAnthropicKey ? nil : "Add an Anthropic API key in Settings (⌘,)."
        case .deepseek:
            return hasDeepSeekKey ? nil : "Add a DeepSeek API key in Settings (⌘,)."
        }
    }
}

/// Non-secret provider preferences. API keys live in the Keychain (PLAN.md §7);
/// the subscription path stores nothing at all.
enum AppSettings {
    /// Appearance is app-wide rather than viewer-side now, but this is the app's one defaults
    /// namespace and the string is what is already on disk: renaming it would silently reset
    /// the setting for everyone. Read through `@AppStorage`.
    static let appearanceKey = "viewer.pdfAppearance"
    static let anthropicModelKey = "anthropic.model"
    static let providerChoiceKey = "provider.choice"
    static let claudeCodeEffortKey = "claudeCode.effort"
    static let deepseekModelKey = "deepseek.model"
    static let deepseekThinkingKey = "deepseek.thinking"
    static let ocrEnabledKey = "ocr.enabled"

    /// OCR for pages with no text layer, on the text-only path. On by default:
    /// without it a scanned document is a dead end there.
    ///
    /// Turning it off changes the extracted body, which *is* the cached prefix —
    /// so a document attached afterwards pays one fresh cache miss. Documents
    /// already open keep the text they were attached with.
    static var ocrEnabled: Bool {
        UserDefaults.standard.object(forKey: ocrEnabledKey) as? Bool ?? true
    }

    static var anthropicModel: AnthropicModel {
        AnthropicModel(rawValue: UserDefaults.standard.string(forKey: anthropicModelKey) ?? "") ?? .opus5
    }

    static var deepseekModel: DeepSeekModel {
        DeepSeekModel(rawValue: UserDefaults.standard.string(forKey: deepseekModelKey) ?? "") ?? .v4Flash
    }

    /// Defaults to `.low`, not DeepSeek's own `high` — see DeepSeekThinking.
    static var deepseekThinking: DeepSeekThinking {
        DeepSeekThinking(rawValue: UserDefaults.standard.string(forKey: deepseekThinkingKey) ?? "") ?? .low
    }

    static var providerChoice: ProviderChoice {
        ProviderChoice(rawValue: UserDefaults.standard.string(forKey: providerChoiceKey) ?? "") ?? .automatic
    }

    static var claudeCodeEffort: ClaudeCodeEffort {
        ClaudeCodeEffort(rawValue: UserDefaults.standard.string(forKey: claudeCodeEffortKey) ?? "") ?? .cliDefault
    }

    static var hasAnthropicKey: Bool { hasKey(.anthropicAPIKey) }
    static var hasDeepSeekKey: Bool { hasKey(.deepseekAPIKey) }

    private static func hasKey(_ account: KeychainStore.Account) -> Bool {
        let key = KeychainStore.get(account)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !key.isEmpty
    }
}

/// Builds the provider a document talks to.
///
/// Since Phase 7 this is not a once-per-window decision: `ChatEngine.switchProvider`
/// re-attaches an open document, so both the chat panel's picker and a change in
/// Settings can be applied live. The factory stays a pure builder — which provider
/// a given window should be using is the engine's business, not its own.
enum ProviderFactory {
    static func make() -> ChatProvider { make(AppSettings.providerChoice) }

    static func make(_ choice: ProviderChoice) -> ChatProvider {
        switch choice {
        case .claudeCode:
            return claudeCode()
        case .anthropicAPI:
            return anthropic()
        case .deepseek:
            return deepseek()
        case .mock:
            return MockProvider()
        case .automatic:
            // Subscription first: no key to configure and no per-token billing.
            // A missing/!logged-in CLI still surfaces a readable error at attach,
            // so only fall through when it isn't installed at all. Claude before
            // DeepSeek: it reads pages natively, so it works on any document.
            if ClaudeCodeCLI.isInstalled { return claudeCode() }
            if AppSettings.hasAnthropicKey { return anthropic() }
            if AppSettings.hasDeepSeekKey { return deepseek() }
            return MockProvider()
        }
    }

    private static func claudeCode() -> ChatProvider {
        ClaudeCodeProvider(effort: AppSettings.claudeCodeEffort)
    }

    private static func anthropic() -> ChatProvider {
        AnthropicProvider(model: AppSettings.anthropicModel)
    }

    private static func deepseek() -> ChatProvider {
        DeepSeekProvider(model: AppSettings.deepseekModel, thinking: AppSettings.deepseekThinking)
    }
}
