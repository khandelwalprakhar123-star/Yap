import Foundation

/// User-tunable settings, persisted as JSON at
/// ~/Library/Application Support/LocalFlow/config.json
public struct AppConfig: Codable, Equatable {
    /// Ollama HTTP endpoint.
    public var ollamaURL: String = "http://localhost:11434"
    /// Preferred cleanup model. If missing from Ollama, fallbacks are tried in order.
    public var ollamaModel: String = "qwen2.5:3b"
    public var ollamaFallbackModels: [String] = ["llama3.2:3b", "gemma2:2b"]
    /// Sampling temperature for the cleanup call.
    public var cleanupTemperature: Double = 0.2
    /// If cleanup takes longer than this, the raw transcript is injected instead.
    public var cleanupTimeoutSeconds: Double = 10
    /// Master switch for the Stage B cleanup pass.
    public var cleanupEnabled: Bool = true

    /// "v2" = Parakeet TDT 0.6B v2 (English, best accuracy)
    /// "v3" = Parakeet TDT 0.6B v3 (25 languages)
    public var asrModelVersion: String = "v2"

    /// Silero VAD speech-probability threshold (0...1). Higher = stricter.
    public var vadThreshold: Double = 0.6
    public var vadEnabled: Bool = true

    /// Virtual keycode of the push-to-talk key. 61 = Right Option.
    public var hotkeyKeyCode: Int64 = 61
    /// true = hold to talk, false = tap to start / tap to stop.
    public var holdToTalk: Bool = true

    /// "paste" = pasteboard + synthetic Cmd+V (clipboard is saved and restored),
    /// "type"  = CGEvent Unicode keystroke synthesis (slower, works where paste fails).
    public var injectionMethod: String = "paste"

    public init() {}

    public static var configDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalFlow", isDirectory: true)
    }

    public static var configFile: URL {
        configDirectory.appendingPathComponent("config.json")
    }

    public static func load() -> AppConfig {
        guard let data = try? Data(contentsOf: configFile),
              let config = try? JSONDecoder().decode(AppConfig.self, from: data)
        else { return AppConfig() }
        return config
    }

    public func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(self) else { return }
        try? FileManager.default.createDirectory(
            at: Self.configDirectory, withIntermediateDirectories: true)
        try? data.write(to: Self.configFile)
    }
}
