import SwiftUI

struct SettingsView: View {
    @State private var anthropicKey = ""
    @State private var deepseekKey = ""
    @AppStorage(AppSettings.pdfAppearanceKey) private var pdfAppearance = PDFAppearanceMode.matchSystem.rawValue
    @AppStorage(AppSettings.providerChoiceKey) private var providerChoice = ProviderChoice.automatic.rawValue
    @AppStorage(AppSettings.anthropicModelKey) private var anthropicModel = AnthropicModel.opus5.rawValue
    @AppStorage(AppSettings.claudeCodeEffortKey) private var claudeCodeEffort = ClaudeCodeEffort.cliDefault.rawValue
    @AppStorage(AppSettings.deepseekModelKey) private var deepseekModel = DeepSeekModel.v4Flash.rawValue
    @AppStorage(AppSettings.deepseekThinkingKey) private var deepseekThinking = DeepSeekThinking.low.rawValue

    private var cliInstalled: Bool { ClaudeCodeCLI.isInstalled }

    /// Makes the cheap-cache-hit economics of PLAN.md §7 visible at the point of choice.
    private var deepseekPriceLine: String {
        let model = DeepSeekModel(rawValue: deepseekModel) ?? .v4Flash
        let price = model.pricing
        return "About $\(Self.money(price.cacheMiss))/M tokens for the first "
            + "question on a document, $\(Self.money(price.cacheHit))/M for the rest."
    }

    /// Two decimals minimum, four maximum: a fixed "%.2f" would round v4-pro's
    /// $0.435 down to $0.43 and its cache hit to $0.00.
    private static func money(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 4
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("PDF pages", selection: $pdfAppearance) {
                    ForEach(PDFAppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                Text("Dark pages invert the document on screen, keeping colours at their own "
                     + "hue. The document itself is untouched: a region screenshot still "
                     + "reaches the provider the way the PDF was authored. ⇧⌘D toggles it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                Picker("Model", selection: $deepseekModel) {
                    ForEach(DeepSeekModel.allCases) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }
                Picker("Thinking", selection: $deepseekThinking) {
                    ForEach(DeepSeekThinking.allCases) { level in
                        Text(level.displayName).tag(level.rawValue)
                    }
                }
                Text("Text-only provider: it reads the PDF's extracted text, so scanned "
                     + "documents and region screenshots need Claude. \(deepseekPriceLine)")
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
