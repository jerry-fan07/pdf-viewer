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
}

/// Non-secret provider preferences. API keys live in the Keychain (PLAN.md §7);
/// the subscription path stores nothing at all.
enum AppSettings {
    /// Viewer-side, but this is the app's one defaults namespace. Read through `@AppStorage`.
    static let pdfAppearanceKey = "viewer.pdfAppearance"
    static let anthropicModelKey = "anthropic.model"
    static let providerChoiceKey = "provider.choice"
    static let claudeCodeEffortKey = "claudeCode.effort"
    static let deepseekModelKey = "deepseek.model"
    static let deepseekThinkingKey = "deepseek.thinking"

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

/// Chooses the provider for a newly opened document.
///
/// The provider is fixed for the window's lifetime — switching mid-document would
/// need a re-attach (a fresh upload, or a fresh session prime), so changing this
/// in Settings takes effect for documents opened afterwards. Known limitation.
enum ProviderFactory {
    static func make() -> ChatProvider {
        switch AppSettings.providerChoice {
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
