import SwiftUI

struct SettingsView: View {
    @State private var anthropicKey = ""
    @State private var deepseekKey = ""
    @AppStorage(AppSettings.providerChoiceKey) private var providerChoice = ProviderChoice.automatic.rawValue
    @AppStorage(AppSettings.anthropicModelKey) private var anthropicModel = AnthropicModel.opus5.rawValue
    @AppStorage(AppSettings.claudeCodeEffortKey) private var claudeCodeEffort = ClaudeCodeEffort.cliDefault.rawValue

    private var cliInstalled: Bool { ClaudeCodeCLI.isInstalled }

    var body: some View {
        Form {
            Section("Provider") {
                Picker("Use", selection: $providerChoice) {
                    ForEach(ProviderChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice.rawValue)
                    }
                }
                Text("Applies to documents opened after the change — a document keeps the "
                     + "provider it was attached with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Claude subscription") {
                Label(
                    cliInstalled
                        ? "Claude Code found — no key needed; your existing login is used."
                        : "Claude Code not found. Install it and run `claude` once to sign in.",
                    systemImage: cliInstalled ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(cliInstalled ? Color.secondary : Color.orange)

                Picker("Effort", selection: $claudeCodeEffort) {
                    ForEach(ClaudeCodeEffort.allCases) { level in
                        Text(level.displayName).tag(level.rawValue)
                    }
                }
                Text("Answers take roughly 20–30 seconds at the CLI default. Lower effort "
                     + "trades depth for speed. Nothing is stored by this app on this path.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Anthropic API") {
                SecureField("API key (sk-ant-…)", text: $anthropicKey)
                    .onSubmit { KeychainStore.set(anthropicKey, for: .anthropicAPIKey) }
                Picker("Model", selection: $anthropicModel) {
                    ForEach(AnthropicModel.allCases) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }
                Text("Stored in the macOS Keychain, and billed per token. "
                     + "Haiku caps native PDFs at 100 pages.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("DeepSeek API") {
                SecureField("API key", text: $deepseekKey)
                    .onSubmit { KeychainStore.set(deepseekKey, for: .deepseekAPIKey) }
                Text("Text-only provider: region screenshots require Claude.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
        .onAppear {
            anthropicKey = KeychainStore.get(.anthropicAPIKey) ?? ""
            deepseekKey = KeychainStore.get(.deepseekAPIKey) ?? ""
        }
        .onDisappear {
            KeychainStore.set(anthropicKey, for: .anthropicAPIKey)
            KeychainStore.set(deepseekKey, for: .deepseekAPIKey)
        }
    }
}
