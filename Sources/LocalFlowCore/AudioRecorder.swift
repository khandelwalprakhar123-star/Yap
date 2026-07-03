import FluidAudio
import AVFoundation
import Foundation

/// Captures the default microphone and accumulates 16 kHz mono Float32 samples,
/// which is exactly what Parakeet (and Silero VAD) expect.
public final class AudioRecorder {
    public static let targetSampleRate: Double = 16_000

    private let engine = AVAudioEngine()
    private var converter: AVAudioConverter?
    private var samples: [Float] = []
    private let samplesLock = NSLock()
    /// Peak input level (0...1) of the most recent buffer, for UI level meters.
    public private(set) var currentLevel: Float = 0

    public init() {}

    public static func requestMicrophonePermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            return true
        case .notDetermined:
            return await AVCaptureDevice.requestAccess(for: .audio)
        default:
            return false
        }
    }

    public static func microphonePermissionGranted() -> Bool {
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    }

    public func start() throws {
        samplesLock.lock()
        samples.removeAll(keepingCapacity: true)
        samplesLock.unlock()

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0 else {
            throw NSError(domain: "LocalFlow", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No usable microphone input format (is a mic connected and permission granted?)"
            ])
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Self.targetSampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw NSError(domain: "LocalFlow", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Could not create 16 kHz mono format"
            ])
        }

        converter = AVAudioConverter(from: inputFormat, to: targetFormat)

        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat) { [weak self] buffer, _ in
            self?.append(buffer: buffer, targetFormat: targetFormat)
        }

        engine.prepare()
        try engine.start()
    }

    /// Stops capture and returns everything recorded as 16 kHz mono Float32.
    public func stop() -> [Float] {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        converter = nil
        samplesLock.lock()
        defer { samplesLock.unlock() }
        let result = samples
        samples = []
        return result
    }

    private func append(buffer: AVAudioPCMBuffer, targetFormat: AVAudioFormat) {
        guard let converter else { return }
        let ratio = targetFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 64
        guard let converted = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity)
        else { return }

        var consumed = false
        var conversionError: NSError?
        converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard conversionError == nil,
              converted.frameLength > 0,
              let channel = converted.floatChannelData?[0]
        else { return }

        let chunk = Array(UnsafeBufferPointer(start: channel, count: Int(converted.frameLength)))
        var peak: Float = 0
        for sample in chunk { peak = max(peak, abs(sample)) }
        currentLevel = peak

        samplesLock.lock()
        samples.append(contentsOf: chunk)
        samplesLock.unlock()
    }
}

/// Loads any audio file (wav/aiff/m4a/mp3/...) as 16 kHz mono Float32 samples
/// using FluidAudio's converter. Used by the CLI harness's `file` mode.
public enum AudioFileLoader {
    public static func loadSamples16kMono(url: URL) throws -> [Float] {
        try AudioConverter().resampleAudioFile(url)
    }
}
