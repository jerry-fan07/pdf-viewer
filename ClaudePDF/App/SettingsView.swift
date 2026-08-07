import SwiftUI

struct SettingsView: View {
    @State private var anthropicKey = ""
    @State private var deepseekKey = ""
    @AppStorage(AppSettings.anthropicModelKey) private var anthropicModel = AnthropicModel.opus5.rawValue

    var body: some View {
        Form {
            Section("Anthropic API") {
                SecureField("API key (sk-ant-…)", text: $anthropicKey)
                    .onSubmit { KeychainStore.set(anthropicKey, for: .anthropicAPIKey) }
                Picker("Model", selection: $anthropicModel) {
                    ForEach(AnthropicModel.allCases) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }
                Text("Stored in the macOS Keychain. Leave empty to use another provider. "
                     + "The model applies to documents opened after the change; "
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
            Section("Claude subscription") {
                Text("Uses your local Claude Code install and its existing login — no key to enter. Run `claude` once in a terminal to sign in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
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
