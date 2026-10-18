import SwiftUI
import AppKit
import HushnoteCore

/// Settings → Summaries: which engine writes the notes, with what leaves the Mac stated plainly.
struct SummarySettingsView: View {
    @Bindable var state: AppState
    @State private var keyDraft = ""

    private var settings: SummarySettings { state.summarySettings }
    private var engine: SummaryEngine { settings.engine }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SummaryEngine.allCases, id: \.self) { option in engineRow(option) }
            configuration
            if settings.sendsOffDevice(engine) {
                SettingRow("Privacy") {
                    Text("Send transcripts to \(engine.recipient) to write summaries").font(.hnBody)
                    Spacer()
                    Toggle("Allow sending transcripts", isOn: Binding(get: { settings.consented.contains(engine) },
                                                                      set: { state.setConsent($0, for: engine) }))
                        .toggleStyle(InstrumentSwitch()).labelsHidden()
                }
            }
            SettingRow("Check") {
                Button(state.engineTesting ? "Testing…" : "Test engine") { state.testSummaryEngine() }.disabled(!state.canTestEngine)
                if let result = state.engineTest, result.engine == engine {
                    Lamp(color: result.ok ? HN.cool : HN.signal, filled: result.ok)
                    Text(result.text).font(.system(size: 12)).foregroundStyle(result.ok ? HN.ink2 : HN.signal)
                        .lineLimit(2).textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            note
        }
        .onAppear { if engine == .chatGPT { Task { await state.refreshChatGPT() } } }
        .onChange(of: engine) { _, new in keyDraft = ""; if new == .chatGPT { Task { await state.refreshChatGPT() } } }
    }

    private func engineRow(_ option: SummaryEngine) -> some View {
        let selected = option == engine, offDevice = settings.sendsOffDevice(option)
        return Button { state.summarySettings.engine = option; state.engineTest = nil } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Circle().strokeBorder(selected ? HN.ink : HN.ruleStrong, lineWidth: selected ? 4.5 : 1.2)
                        .frame(width: 14, height: 14)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(option.title).font(.system(size: 13, weight: selected ? .semibold : .regular)).foregroundStyle(HN.ink)
                        Text(option.detail).font(.system(size: 11)).foregroundStyle(HN.muted)
                    }
                    Spacer()
                    Tag(offDevice ? "Sends transcript" : "On this Mac", color: offDevice ? HN.amber : HN.cool)
                }
                .padding(.vertical, 9).padding(.leading, 112)
                Hairline()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityValue(offDevice ? "Sends the transcript off this Mac" : "Stays on this Mac")
    }

    @ViewBuilder private var configuration: some View {
        switch engine {
        case .bundled:
            SettingRow("Model") {
                Text(state.hasSummaryModel ? "Installed · 1.12 GB" : "Not downloaded yet").font(.hnBody).foregroundStyle(state.hasSummaryModel ? HN.ink2 : HN.muted)
                Spacer()
                if !state.hasSummaryModel { Button("Download") { state.installSummaryModel() } }
            }
        case .localModel:
            SettingRow("Model file") {
                Text(settings.modelPath.isEmpty ? "None chosen" : URL(fileURLWithPath: settings.modelPath).lastPathComponent)
                    .font(.hnData).foregroundStyle(settings.modelPath.isEmpty ? HN.muted : HN.ink).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose…") { state.chooseModelFile() }
            }
        case .localServer:
            SettingRow("Address") {
                Field(placeholder: "http://127.0.0.1:11434/v1", text: $state.summarySettings.serverURL, font: .hnData)
                Button("Ollama") { state.summarySettings.serverURL = "http://127.0.0.1:11434/v1" }.buttonStyle(.instrument(.quiet))
                Button("LM Studio") { state.summarySettings.serverURL = "http://127.0.0.1:1234/v1" }.buttonStyle(.instrument(.quiet))
            }
            modelRow(text: $state.summarySettings.serverModel, placeholder: "e.g. llama3.2")
        case .chatGPT:
            SettingRow("Account") { chatGPTAccount }
        case .openAI, .anthropic:
            SettingRow("API key") {
                if state.savedKeys.contains(engine) {
                    Lamp(color: HN.cool)
                    Text("Saved in your Keychain").font(.hnBody).foregroundStyle(HN.ink2)
                    Spacer()
                    Button("Remove") { state.removeAPIKey(for: engine) }
                } else {
                    SecureField(engine == .openAI ? "sk-…" : "sk-ant-…", text: $keyDraft)
                        .textFieldStyle(.plain).font(.hnData).focusEffectDisabled()
                        .padding(.horizontal, 9).frame(height: 30)
                        .background(HN.well, in: RoundedRectangle(cornerRadius: HN.corner))
                        .overlay(RoundedRectangle(cornerRadius: HN.corner).strokeBorder(HN.rule, lineWidth: 1))
                        .onSubmit { state.saveAPIKey(keyDraft, for: engine); keyDraft = "" }
                    Button("Save") { state.saveAPIKey(keyDraft, for: engine); keyDraft = "" }.disabled(keyDraft.isEmpty)
                }
            }
            modelRow(text: engine == .openAI ? $state.summarySettings.openAIModel : $state.summarySettings.anthropicModel,
                     placeholder: engine == .openAI ? "Load the list, or type a model ID" : "claude-opus-5-5")
        }
    }

    private func modelRow(text: Binding<String>, placeholder: String) -> some View {
        SettingRow("Model") {
            Field(placeholder: placeholder, text: text, font: .hnData)
            if let models = state.engineModels[engine], !models.isEmpty {
                Menu("Choose") { ForEach(models, id: \.self) { id in Button(id) { text.wrappedValue = id } } }
                    .menuStyle(.borderlessButton).fixedSize()
            }
            Button("Load list") { state.loadEngineModels() }.buttonStyle(.instrument(.quiet))
                .disabled(engine != .localServer && !state.savedKeys.contains(engine))
        }
    }

    @ViewBuilder private var chatGPTAccount: some View {
        switch state.chatGPTSignIn {
        case .chatGPT?:
            Lamp(color: HN.cool)
            Text("Signed in with ChatGPT").font(.hnBody).foregroundStyle(HN.ink2)
            Spacer()
        case .notInstalled?:
            Text("Needs the ChatGPT app or OpenAI's Codex CLI").font(.hnBody).foregroundStyle(HN.muted)
            Spacer()
            Link("Get the ChatGPT app", destination: URL(string: "https://openai.com/chatgpt/download/")!).font(.system(size: 12))
        default:
            if state.chatGPTSigningIn {
                Text("Finish signing in on OpenAI's page…").font(.hnBody).foregroundStyle(HN.ink2)
                Spacer()
                if let url = state.chatGPTSignInURL { Link("Open sign-in page", destination: url).font(.system(size: 12)) }
                Button("Cancel") { state.cancelChatGPTSignIn() }.buttonStyle(.instrument(.quiet))
            } else {
                Text(state.chatGPTSignIn == .apiKey ? "Codex is using an API key, not your plan" : state.chatGPTSignIn == nil ? "Checking…" : "Not signed in")
                    .font(.hnBody).foregroundStyle(HN.muted)
                Spacer()
                Button("Continue with ChatGPT") { state.signInWithChatGPT() }.buttonStyle(.instrument(.primary))
            }
        }
    }

    private var note: some View {
        Text(noteText).font(.system(size: 11)).foregroundStyle(HN.muted).lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true).padding(.top, 12).padding(.bottom, 4).padding(.leading, 112)
    }

    private var noteText: String {
        let always = "Recording and transcription always stay on this Mac; only the summary step changes."
        switch engine {
        case .bundled, .localModel: return "\(always) Local models get 9 KB of transcript at a time and combine the results."
        case .localServer: return "\(always) Works with any OpenAI-compatible server. An address on another computer counts as sending the transcript."
        case .chatGPT: return "\(always) Sign-in happens on OpenAI's own page through its Codex CLI, which Hushnote runs with tools, shell and web access switched off. Your plan's limits apply; Hushnote never falls back to a paid API."
        case .openAI: return "\(always) Usage is billed to the API account the key belongs to. The key is stored in your Keychain."
        case .anthropic: return "\(always) Claude Pro and Max subscriptions can't be used by other apps under Anthropic's terms, so this uses an API key, stored in your Keychain. If Claude declines a request, Anthropic retries it on another Claude model."
        }
    }
}
