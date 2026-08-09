import SwiftUI

struct SettingsView: View {
    @State private var anthropicKey = ""
    @State private var deepseekKey = ""
    @AppStorage(AppSettings.appearanceKey) private var appearance = AppearanceMode.matchSystem.rawValue
    @AppStorage(AppSettings.providerChoiceKey) private var providerChoice = ProviderChoice.automatic.rawValue
    @AppStorage(AppSettings.anthropicModelKey) private var anthropicModel = AnthropicModel.opus5.rawValue
    @AppStorage(AppSettings.claudeCodeModelKey) private var claudeCodeModel = ClaudeCodeModel.cliDefault.rawValue
    @AppStorage(AppSettings.claudeCodeEffortKey) private var claudeCodeEffort = ClaudeCodeEffort.cliDefault.rawValue
    @AppStorage(AppSettings.deepseekModelKey) private var deepseekModel = DeepSeekModel.v4Flash.rawValue
    @AppStorage(AppSettings.deepseekThinkingKey) private var deepseekThinking = DeepSeekThinking.low.rawValue
    @AppStorage(AppSettings.ocrEnabledKey) private var ocrEnabled = true

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
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.displayName).tag(mode.rawValue)
                    }
                }
                Text("Dark mode darkens a whole window — toolbar, panels and pages together — "
                     + "and this is what every window starts as. ⇧⌘D darkens just the window "
                     + "in front of you, which then keeps what you gave it. Pages are inverted "
                     + "on screen, keeping colours at their own hue; the document itself is "
                     + "untouched, so a region screenshot still reaches the provider the way "
                     + "the PDF was authored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Provider") {
                Picker("Use", selection: $providerChoice) {
                    ForEach(ProviderChoice.allCases) { choice in
                        Text(choice.displayName).tag(choice.rawValue)
                    }
                }
                Text("Applies immediately, to open documents as well as new ones — a window "
                     + "re-prepares itself for the new provider, which costs one fresh cache "
                     + "write on its next question. A window switched by hand from the chat "
                     + "panel's picker keeps what it was given.")
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

                Picker("Model", selection: $claudeCodeModel) {
                    ForEach(ClaudeCodeModel.allCases) { model in
                        Text(model.displayName).tag(model.rawValue)
                    }
                }
                Picker("Effort", selection: $claudeCodeEffort) {
                    ForEach(ClaudeCodeEffort.allCases) { level in
                        Text(level.displayName).tag(level.rawValue)
                    }
                }
                Text("“CLI default” answers on whatever model your Claude Code is already "
                     + "configured for; the rest name one for this app only, and each tracks "
                     + "the latest of its line. "
                     + "Answers take roughly 20–30 seconds at the CLI default. Lower effort "
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
                Text("Text-only provider: it reads the PDF's extracted text, so region "
                     + "screenshots are sent as the text underneath them. \(deepseekPriceLine)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Scanned pages") {
                Toggle("Read scanned pages with OCR", isOn: $ocrEnabled)
                Text("Pages with no text layer are recognised on-device with Apple's Vision "
                     + "framework, so scanned documents work on the text-only path. Recognition "
                     + "runs once per document and is cached; expect transcription errors. "
                     + "Claude reads scanned pages natively and ignores this setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 8)
        // Its own scene, so it needs the preference applied too — otherwise Settings is the
        // one window still following the system while every document window is dark.
        .preferredColorScheme(AppearanceMode(rawValue: appearance)?.preferredColorScheme)
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
