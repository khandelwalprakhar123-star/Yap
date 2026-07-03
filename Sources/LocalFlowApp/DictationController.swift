import AppKit
import Foundation
import LocalFlowCore

/// Owns the whole dictation pipeline and its state machine:
/// hotkey → record → VAD+ASR → (optional) Ollama cleanup → inject into focused app.
@MainActor
final class DictationController: ObservableObject {
    enum State: Equatable {
        case loadingModels
        case idle
        case recording
        case transcribing
        case cleaning
        case error(String)

        var label: String {
            switch self {
            case .loadingModels: return "Loading speech models…"
            case .idle: return "Ready"
            case .recording: return "Recording…"
            case .transcribing: return "Transcribing…"
            case .cleaning: return "Cleaning up…"
            case .error(let message): return "Error: \(message)"
            }
        }
    }

    @Published private(set) var state: State = .loadingModels
    @Published private(set) var lastTranscript: String = ""
    @Published private(set) var cleanupModel: String?
    @Published var config: AppConfig

    var onStateChange: ((State) -> Void)?

    private var transcriber: Transcriber
    private var ollama: OllamaClient
    private let recorder = AudioRecorder()
    private var hotkey: HotkeyListener?

    init() {
        let config = AppConfig.load()
        self.config = config
        self.transcriber = Transcriber(config: config)
        self.ollama = OllamaClient(config: config)
    }

    // MARK: - Lifecycle

    func startup() {
        setState(.loadingModels)
        Task {
            do {
                try await transcriber.load()
                setState(.idle)
            } catch {
                setState(.error("Model load failed: \(error.localizedDescription)"))
            }
            await resolveCleanupModel()
            startHotkeyIfPossible()
        }
    }

    func resolveCleanupModel() async {
        guard config.cleanupEnabled else {
            cleanupModel = nil
            return
        }
        do {
            let model = try await ollama.resolveModel()
            cleanupModel = model
            Task.detached { [ollama] in await ollama.warmup(model: model) }
        } catch {
            cleanupModel = nil
        }
    }

    @discardableResult
    func startHotkeyIfPossible() -> Bool {
        // Input Monitoring enables the event tap; Accessibility alone is enough
        // for the NSEvent fallback with modifier-key hotkeys.
        guard HotkeyListener.inputMonitoringGranted() || TextInjector.accessibilityGranted()
        else { return false }
        hotkey?.stop()
        let listener = HotkeyListener(keyCode: config.hotkeyKeyCode, holdToTalk: config.holdToTalk)
        listener.onPress = { [weak self] in
            Task { @MainActor in self?.beginRecording() }
        }
        listener.onRelease = { [weak self] in
            Task { @MainActor in self?.endRecordingAndProcess() }
        }
        do {
            try listener.start()
            hotkey = listener
            return true
        } catch {
            setState(.error(error.localizedDescription))
            return false
        }
    }

    var hotkeyActive: Bool { hotkey != nil }

    /// Re-save config, then rebuild every component that depends on it.
    func apply(config newConfig: AppConfig) {
        let asrChanged = newConfig.asrModelVersion != config.asrModelVersion
            || newConfig.vadThreshold != config.vadThreshold
            || newConfig.vadEnabled != config.vadEnabled
        config = newConfig
        config.save()
        ollama = OllamaClient(config: config)
        if asrChanged {
            transcriber = Transcriber(config: config)
            setState(.loadingModels)
            Task {
                do {
                    try await transcriber.load()
                    setState(.idle)
                } catch {
                    setState(.error("Model load failed: \(error.localizedDescription)"))
                }
            }
        }
        Task { await resolveCleanupModel() }
        startHotkeyIfPossible()
    }

    // MARK: - Pipeline

    private func beginRecording() {
        guard state == .idle else { return }
        guard AudioRecorder.microphonePermissionGranted() else {
            Task {
                let granted = await AudioRecorder.requestMicrophonePermission()
                if granted { beginRecording() }
            }
            return
        }
        do {
            try recorder.start()
            setState(.recording)
            NSSound(named: "Pop")?.play()
        } catch {
            setState(.error(error.localizedDescription))
            resetToIdleSoon()
        }
    }

    private func endRecordingAndProcess() {
        guard state == .recording else { return }
        let samples = recorder.stop()
        NSSound(named: "Bottle")?.play()

        guard Double(samples.count) / AudioRecorder.targetSampleRate > 0.25 else {
            setState(.idle)
            return
        }

        setState(.transcribing)
        Task {
            do {
                let result = try await transcriber.transcribe(samples)
                guard !result.text.isEmpty else {
                    setState(.idle)
                    return
                }

                var finalText = result.text
                if config.cleanupEnabled, let model = cleanupModel {
                    setState(.cleaning)
                    finalText = await cleanupWithTimeout(raw: result.text, model: model)
                }

                lastTranscript = finalText
                TextInjector.inject(finalText, method: config.injectionMethod)
                setState(.idle)
            } catch {
                setState(.error(error.localizedDescription))
                resetToIdleSoon()
            }
        }
    }

    /// Runs Ollama cleanup, but falls back to the raw transcript if it errors
    /// or exceeds the configured timeout — dictation must never hang.
    private func cleanupWithTimeout(raw: String, model: String) async -> String {
        let timeout = config.cleanupTimeoutSeconds
        let client = ollama
        return await withTaskGroup(of: String?.self) { group in
            group.addTask { try? await client.cleanup(raw, model: model) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? raw
        }
    }

    private func setState(_ newState: State) {
        state = newState
        onStateChange?(newState)
    }

    private func resetToIdleSoon() {
        Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if case .error = state { setState(.idle) }
        }
    }
}
