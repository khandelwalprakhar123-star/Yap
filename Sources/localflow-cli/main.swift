import Foundation
import LocalFlowCore

// LocalFlow Phase 0 test harness:
//   mic (or file) -> Silero VAD -> Parakeet ASR -> Ollama cleanup -> stdout,
// printing per-stage latency and memory so pipeline performance can be
// validated on this machine before the menu-bar app is used.

let usage = """
localflow-cli — LocalFlow Phase 0 pipeline test harness

USAGE:
  localflow-cli check                    Verify Ollama, models, mic permission
  localflow-cli run [options]           Record mic until you press Enter, then run pipeline
  localflow-cli file <path> [options]   Run pipeline on an audio file (wav/aiff/m4a/mp3)

OPTIONS:
  --seconds <n>     Record for a fixed n seconds instead of waiting for Enter
  --asr <v2|v3>     Parakeet version: v2 = English (default), v3 = 25 languages
  --model <name>    Ollama cleanup model (default from config, qwen2.5:3b)
  --no-cleanup      Skip Stage B (Ollama)
  --no-vad          Skip Silero VAD gating
"""

struct CLIOptions {
    var command: String = "run"
    var filePath: String?
    var seconds: Double?
    var noCleanup = false
    var noVAD = false
    var asrVersion: String?
    var model: String?
}

func parseArgs() -> CLIOptions? {
    var options = CLIOptions()
    var args = Array(CommandLine.arguments.dropFirst())
    guard !args.isEmpty else { return nil }

    options.command = args.removeFirst()
    if options.command == "file" {
        guard !args.isEmpty else { return nil }
        options.filePath = args.removeFirst()
    }

    var index = 0
    while index < args.count {
        switch args[index] {
        case "--seconds":
            index += 1
            guard index < args.count, let value = Double(args[index]) else { return nil }
            options.seconds = value
        case "--asr":
            index += 1
            guard index < args.count else { return nil }
            options.asrVersion = args[index]
        case "--model":
            index += 1
            guard index < args.count else { return nil }
            options.model = args[index]
        case "--no-cleanup": options.noCleanup = true
        case "--no-vad": options.noVAD = true
        default:
            print("Unknown option: \(args[index])")
            return nil
        }
        index += 1
    }
    return options
}

func printStageTable(_ reports: [StageReport]) {
    print("\n┌─ Stage timing & process memory ─────────────────────────────")
    for report in reports {
        let name = report.name.padding(toLength: 28, withPad: " ", startingAt: 0)
        let time = Metrics.formatMS(report.seconds).padding(toLength: 10, withPad: " ", startingAt: 0)
        print("│ \(name) \(time) footprint after: \(Metrics.formatBytes(report.footprintAfter))")
    }
    print("└─────────────────────────────────────────────────────────────")
}

func printOllamaMemory(config: AppConfig) async {
    struct PS: Decodable {
        struct Model: Decodable {
            let name: String
            let size: UInt64
        }
        let models: [Model]
    }
    guard let url = URL(string: config.ollamaURL)?.appendingPathComponent("api/ps"),
          let (data, _) = try? await URLSession.shared.data(from: url),
          let ps = try? JSONDecoder().decode(PS.self, from: data), !ps.models.isEmpty
    else { return }
    for model in ps.models {
        print("│ ollama: \(model.name) resident            \(Metrics.formatBytes(model.size)) (in ollama server process)")
    }
    print("└─────────────────────────────────────────────────────────────")
}

func runCheck(config: AppConfig) async {
    print("LocalFlow environment check")
    print("• Config file: \(AppConfig.configFile.path)")

    let ollama = OllamaClient(config: config)
    let installed = await ollama.installedModels()
    if installed.isEmpty {
        print("✗ Ollama NOT reachable at \(config.ollamaURL) — start it with: ollama serve")
    } else {
        print("✓ Ollama reachable, installed models: \(installed.joined(separator: ", "))")
        if let model = try? await ollama.resolveModel() {
            print("✓ Cleanup model resolved: \(model)")
        } else {
            print("✗ No configured cleanup model installed — run: ollama pull \(config.ollamaModel)")
        }
    }

    print(AudioRecorder.microphonePermissionGranted()
        ? "✓ Microphone permission granted"
        : "• Microphone permission not granted yet — it will be requested on first `run`")

    let cache = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FluidAudio/Models")
    if FileManager.default.fileExists(atPath: cache.path) {
        print("✓ ASR model cache exists: \(cache.path)")
    } else {
        print("• ASR models not downloaded yet (~1 GB, happens automatically on first run)")
    }
}

func runPipeline(options: CLIOptions) async {
    var config = AppConfig.load()
    if let asrVersion = options.asrVersion { config.asrModelVersion = asrVersion }
    if let model = options.model { config.ollamaModel = model }
    if options.noVAD { config.vadEnabled = false }

    var reports: [StageReport] = []
    print("Baseline process footprint: \(Metrics.formatBytes(Metrics.memoryFootprint()))")

    // ── Stage A models ───────────────────────────────────────────────
    let transcriber = Transcriber(config: config)
    print("Loading Parakeet TDT 0.6B \(config.asrModelVersion) + Silero VAD (first run downloads ~1 GB)...")
    do {
        let (_, report) = try await measureStage("Load ASR + VAD models") {
            try await transcriber.load()
        }
        reports.append(report)
        print("Models loaded in \(Metrics.formatMS(report.seconds))")
    } catch {
        print("✗ Failed to load ASR models: \(error.localizedDescription)")
        exit(1)
    }

    // ── Stage B warmup (concurrent with recording) ───────────────────
    let ollama = OllamaClient(config: config)
    var cleanupModel: String?
    if !options.noCleanup {
        do {
            let model = try await ollama.resolveModel()
            cleanupModel = model
            Task.detached { await ollama.warmup(model: model) }
            print("Cleanup model: \(model) (warming up in background)")
        } catch {
            print("⚠ Cleanup disabled: \(error.localizedDescription)")
        }
    }

    // ── Acquire audio ────────────────────────────────────────────────
    var samples: [Float] = []
    if let path = options.filePath {
        do {
            let url = URL(fileURLWithPath: path)
            let (loaded, report) = try await measureStage("Load + resample audio file") {
                try AudioFileLoader.loadSamples16kMono(url: url)
            }
            samples = loaded
            reports.append(report)
        } catch {
            print("✗ Could not read audio file: \(error.localizedDescription)")
            exit(1)
        }
    } else {
        guard await AudioRecorder.requestMicrophonePermission() else {
            print("""
                ✗ Microphone permission denied.
                  Enable it in System Settings → Privacy & Security → Microphone
                  for the terminal app you are running this from.
                """)
            exit(1)
        }
        let recorder = AudioRecorder()
        do { try recorder.start() } catch {
            print("✗ Could not start microphone: \(error.localizedDescription)")
            exit(1)
        }
        if let seconds = options.seconds {
            print("● Recording for \(seconds)s — speak now...")
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } else {
            print("● Recording — speak now, then press Enter to stop...")
            _ = readLine()
        }
        samples = recorder.stop()
    }

    let audioSeconds = Double(samples.count) / AudioRecorder.targetSampleRate
    print("Captured \(String(format: "%.1f", audioSeconds))s of audio (\(samples.count) samples)")
    guard audioSeconds > 0.2 else {
        print("✗ No audio captured — check your microphone.")
        exit(1)
    }

    // ── Stage A: VAD + ASR ───────────────────────────────────────────
    var rawTranscript = ""
    do {
        let (result, report) = try await measureStage("VAD + ASR (Parakeet)") {
            try await transcriber.transcribe(samples)
        }
        reports.append(report)
        rawTranscript = result.text
        print(String(format: "VAD kept %.1fs of %.1fs as speech",
                     result.speechSeconds, result.totalSeconds))
        print("\n── RAW TRANSCRIPT ──────────────────────────────────────────")
        print(rawTranscript.isEmpty ? "(no speech detected)" : rawTranscript)
    } catch {
        print("✗ Transcription failed: \(error.localizedDescription)")
        exit(1)
    }
    guard !rawTranscript.isEmpty else {
        printStageTable(reports)
        exit(0)
    }

    // ── Stage B: Ollama cleanup ──────────────────────────────────────
    if let cleanupModel {
        do {
            let (cleaned, report) = try await measureStage("LLM cleanup (\(cleanupModel))") {
                try await ollama.cleanup(rawTranscript, model: cleanupModel)
            }
            reports.append(report)
            print("\n── CLEANED TRANSCRIPT ──────────────────────────────────────")
            print(cleaned)
        } catch {
            print("⚠ Cleanup failed (\(error.localizedDescription)) — raw transcript stands.")
        }
    }

    printStageTable(reports)
    await printOllamaMemory(config: AppConfig.load())
}

// ── Entry point ─────────────────────────────────────────────────────
guard let options = parseArgs() else {
    print(usage)
    exit(2)
}

let semaphore = DispatchSemaphore(value: 0)
Task {
    switch options.command {
    case "check":
        await runCheck(config: AppConfig.load())
    case "run", "file":
        await runPipeline(options: options)
    default:
        print(usage)
    }
    semaphore.signal()
}
// AVAudioEngine and CoreML callbacks need a live run loop on the main thread,
// so park it here instead of blocking with the semaphore alone.
while semaphore.wait(timeout: .now()) == .timedOut {
    RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
}
