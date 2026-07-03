import FluidAudio
import Foundation

/// Stage A: Silero VAD gating + Parakeet TDT 0.6B ASR (CoreML, runs on the ANE).
public actor Transcriber {
    public struct Result {
        public let text: String
        public let confidence: Float
        /// Seconds of audio that were actually sent to the ASR after VAD trimming.
        public let speechSeconds: Double
        public let totalSeconds: Double
    }

    private var asrManager: AsrManager?
    private var vadManager: VadManager?
    private let config: AppConfig

    public init(config: AppConfig) {
        self.config = config
    }

    public var isLoaded: Bool { asrManager != nil }

    /// Downloads (first run only) and loads the CoreML models.
    public func load() async throws {
        guard asrManager == nil else { return }

        let version: AsrModelVersion = config.asrModelVersion == "v3" ? .v3 : .v2
        let models = try await AsrModels.downloadAndLoad(version: version)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        asrManager = manager

        if config.vadEnabled {
            vadManager = try await VadManager(
                config: VadConfig(defaultThreshold: Float(config.vadThreshold)))
        }
    }

    /// Transcribes 16 kHz mono Float32 samples. VAD (when enabled) trims the audio
    /// to speech regions first so the ASR never chews on silence.
    public func transcribe(_ samples: [Float]) async throws -> Result {
        guard let asrManager else {
            throw NSError(domain: "LocalFlow", code: 10, userInfo: [
                NSLocalizedDescriptionKey: "ASR models not loaded — call load() first"
            ])
        }
        let totalSeconds = Double(samples.count) / AudioRecorder.targetSampleRate

        var speechAudio = samples
        if let vadManager {
            var segmentation = VadSegmentationConfig.default
            segmentation.minSpeechDuration = 0.15
            segmentation.minSilenceDuration = 0.4
            segmentation.speechPadding = 0.15
            let segments = try await vadManager.segmentSpeech(samples, config: segmentation)
            if segments.isEmpty {
                return Result(text: "", confidence: 0, speechSeconds: 0, totalSeconds: totalSeconds)
            }
            var trimmed: [Float] = []
            let gap = [Float](repeating: 0, count: 1600)  // 100 ms of silence between segments
            for segment in segments {
                let start = max(0, Int(segment.startTime * AudioRecorder.targetSampleRate))
                let end = min(samples.count, Int(segment.endTime * AudioRecorder.targetSampleRate))
                guard end > start else { continue }
                if !trimmed.isEmpty { trimmed.append(contentsOf: gap) }
                trimmed.append(contentsOf: samples[start..<end])
            }
            speechAudio = trimmed
        }

        let speechSeconds = Double(speechAudio.count) / AudioRecorder.targetSampleRate
        // Parakeet needs a minimum amount of audio to produce output; pad very short clips.
        if speechAudio.count < 16_000 {
            speechAudio.append(contentsOf:
                [Float](repeating: 0, count: 16_000 - speechAudio.count))
        }

        var decoderState = TdtDecoderState.make()
        let asrResult = try await asrManager.transcribe(speechAudio, decoderState: &decoderState)
        return Result(
            text: asrResult.text.trimmingCharacters(in: .whitespacesAndNewlines),
            confidence: asrResult.confidence,
            speechSeconds: speechSeconds,
            totalSeconds: totalSeconds
        )
    }
}
