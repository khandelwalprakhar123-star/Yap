import Foundation

/// Stage B: transcript cleanup through the local Ollama HTTP API.
public struct OllamaClient {
    /// Used verbatim, per spec. Only fixes fillers/punctuation/casing/paragraphs.
    public static let cleanupSystemPrompt = """
        You clean up speech-to-text transcripts. Fix ONLY: leftover filler/pause words (um, uh, \
        like), missing punctuation, capitalization, and paragraph breaks. Do NOT rephrase, summarize, \
        add, or remove meaning. Output only the corrected text with no commentary or preamble.
        """

    public let baseURL: URL
    public let config: AppConfig

    public init(config: AppConfig) {
        self.config = config
        self.baseURL = URL(string: config.ollamaURL) ?? URL(string: "http://localhost:11434")!
    }

    public struct ServerError: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// Names of models currently available in Ollama. Empty array = server unreachable.
    public func installedModels() async -> [String] {
        struct Tags: Decodable {
            struct Model: Decodable { let name: String }
            let models: [Model]
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/tags"))
        request.timeoutInterval = 3
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let tags = try? JSONDecoder().decode(Tags.self, from: data)
        else { return [] }
        return tags.models.map(\.name)
    }

    /// Picks the configured model if installed, otherwise the first installed fallback.
    public func resolveModel() async throws -> String {
        let installed = await installedModels()
        guard !installed.isEmpty else {
            throw ServerError(message:
                "Ollama is not reachable at \(baseURL.absoluteString). Start it with: ollama serve")
        }
        for candidate in [config.ollamaModel] + config.ollamaFallbackModels {
            if installed.contains(where: { $0 == candidate || $0.hasPrefix(candidate + ":") }) {
                return candidate
            }
        }
        throw ServerError(message: """
            None of the configured models are installed in Ollama. \
            Run: ollama pull \(config.ollamaModel)
            """)
    }

    /// Loads the model into memory ahead of time so the first real cleanup is fast.
    public func warmup(model: String) async {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: [
            "model": model, "stream": false, "keep_alive": "30m",
        ])
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Runs the cleanup pass. Throws if Ollama is unreachable or errors;
    /// callers fall back to the raw transcript.
    public func cleanup(_ transcript: String, model: String) async throws -> String {
        struct ChatResponse: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message?
            let error: String?
        }

        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "keep_alive": "30m",
            "options": ["temperature": config.cleanupTemperature],
            "messages": [
                ["role": "system", "content": Self.cleanupSystemPrompt],
                ["role": "user", "content": transcript],
            ],
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = max(config.cleanupTimeoutSeconds, 5)

        let (data, _) = try await URLSession.shared.data(for: request)
        let response = try JSONDecoder().decode(ChatResponse.self, from: data)
        if let error = response.error {
            throw ServerError(message: "Ollama error: \(error)")
        }
        guard let content = response.message?.content else {
            throw ServerError(message: "Ollama returned no message content")
        }

        let cleaned = Self.stripModelWrapping(content)
        // Guardrail: if the model went off-script (huge length change), keep the raw text.
        if cleaned.isEmpty || cleaned.count < transcript.count / 3 {
            return transcript
        }
        return cleaned
    }

    /// Removes chat-model artifacts: thinking tags, code fences, quote wrapping.
    static func stripModelWrapping(_ text: String) -> String {
        var result = text
        if let range = result.range(of: "</think>") {
            result = String(result[range.upperBound...])
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.hasPrefix("```") {
            result = result
                .replacingOccurrences(of: "```[a-z]*\n?", with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if result.hasPrefix("\""), result.hasSuffix("\""), result.count > 1 {
            result = String(result.dropFirst().dropLast())
        }
        return result
    }
}
