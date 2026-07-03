import LocalFlowCore
import SwiftUI

/// Settings window: hotkey, ASR model, cleanup model, VAD, injection method.
struct SettingsView: View {
    @State private var draft: AppConfig
    @State private var installedModels: [String] = []
    let controller: DictationController
    let onClose: () -> Void

    init(controller: DictationController, onClose: @escaping () -> Void) {
        self.controller = controller
        self.onClose = onClose
        _draft = State(initialValue: controller.config)
    }

    var body: some View {
        Form {
            Section("Hotkey") {
                Picker("Push-to-talk key", selection: $draft.hotkeyKeyCode) {
                    ForEach(HotkeyListener.knownKeys, id: \.code) { key in
                        Text(key.name).tag(key.code)
                    }
                }
                Picker("Mode", selection: $draft.holdToTalk) {
                    Text("Hold to talk").tag(true)
                    Text("Tap to start / tap to stop").tag(false)
                }
                .pickerStyle(.radioGroup)
            }

            Section("Speech recognition (Stage A)") {
                Picker("Parakeet model", selection: $draft.asrModelVersion) {
                    Text("v2 — English, best accuracy").tag("v2")
                    Text("v3 — 25 languages").tag("v3")
                }
                Toggle("Voice activity detection (skip silence)", isOn: $draft.vadEnabled)
                if draft.vadEnabled {
                    VStack(alignment: .leading) {
                        Slider(value: $draft.vadThreshold, in: 0.3...0.9, step: 0.05) {
                            Text("VAD sensitivity")
                        }
                        Text("Threshold \(draft.vadThreshold, specifier: "%.2f") — higher = stricter about what counts as speech")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Transcript cleanup (Stage B — Ollama)") {
                Toggle("Clean up transcript with local LLM", isOn: $draft.cleanupEnabled)
                if draft.cleanupEnabled {
                    Toggle("Allow paragraph breaks", isOn: $draft.paragraphBreaks)
                    Text("Off = newlines from the cleanup model are flattened to spaces (recommended for chat/Slack).")
                        .font(.caption).foregroundStyle(.secondary)
                    if installedModels.isEmpty {
                        TextField("Model", text: $draft.ollamaModel)
                        Text("Ollama not reachable — start it with `ollama serve`")
                            .font(.caption).foregroundStyle(.orange)
                    } else {
                        Picker("Model", selection: $draft.ollamaModel) {
                            ForEach(installedModels, id: \.self) { model in
                                Text(model).tag(model)
                            }
                        }
                    }
                    TextField("Ollama URL", text: $draft.ollamaURL)
                    VStack(alignment: .leading) {
                        Slider(value: $draft.cleanupTimeoutSeconds, in: 2...30, step: 1) {
                            Text("Cleanup timeout")
                        }
                        Text("\(Int(draft.cleanupTimeoutSeconds))s — if cleanup takes longer, the raw transcript is pasted instead")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Text injection") {
                Picker("Method", selection: $draft.injectionMethod) {
                    Text("Paste (Cmd+V, clipboard restored)").tag("paste")
                    Text("Type keystrokes (slower, max compatibility)").tag("type")
                }
            }

            Section("Feedback") {
                Toggle("Show floating “Listening…” indicator", isOn: $draft.showHUD)
            }

            HStack {
                Spacer()
                Button("Cancel") { onClose() }
                Button("Save & Apply") {
                    controller.apply(config: draft)
                    onClose()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            let client = OllamaClient(config: draft)
            let models = await client.installedModels()
            installedModels = models
            // Keep the picker valid if the configured model isn't installed.
            if !models.isEmpty, !models.contains(draft.ollamaModel) {
                if let match = models.first(where: { $0.hasPrefix(draft.ollamaModel) }) {
                    draft.ollamaModel = match
                } else {
                    installedModels.append(draft.ollamaModel)
                }
            }
        }
    }
}
