import Foundation

/// Non-secret provider preferences. API keys live in the Keychain (PLAN.md §7).
enum AppSettings {
    static let anthropicModelKey = "anthropic.model"

    static var anthropicModel: AnthropicModel {
        let raw = UserDefaults.standard.string(forKey: anthropicModelKey) ?? ""
        return AnthropicModel(rawValue: raw) ?? .opus5
    }
}

/// Chooses the provider for a newly opened document.
///
/// The provider is fixed for the window's lifetime — switching mid-document would
/// need a re-attach (a fresh upload / session prime), so changing the model in
/// Settings takes effect for documents opened afterwards. Known limitation.
enum ProviderFactory {
    static func make() -> ChatProvider {
        if let key = KeychainStore.get(.anthropicAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty
        {
            return AnthropicProvider(model: AppSettings.anthropicModel)
        }
        // Phase 4/5 add DeepSeek and the Claude Code subscription path here.
        return MockProvider()
    }
}
