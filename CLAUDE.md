# LocalFlow — context for AI assistants working on this repo

Fully local macOS dictation app (Wispr Flow equivalent). Owner: personal use on a
MacBook Air M4, 16 GB RAM, macOS 26.x, Command Line Tools only (NO full Xcode —
never use xcodebuild; build with `swift build` and `Scripts/build_app.sh`).

## Architecture (do not collapse the two stages)
- Stage A (speech→text): Parakeet TDT 0.6B via FluidAudio (CoreML/ANE),
  gated by Silero VAD. All in-process, `Sources/LocalFlowCore/Transcriber.swift`.
- Stage B (text→clean text): local Ollama at localhost:11434, small model
  (default qwen2.5:3b, fallback llama3.2:3b). The cleanup prompt is fixed and
  intentionally narrow (fillers/punctuation/casing only) — never let it rephrase.
  Cleanup failure/timeout must ALWAYS fall back to the raw transcript.

## Hard-won constraints
- FluidAudio API (v0.15): `AsrModels.downloadAndLoad(version:)`,
  `AsrManager.loadModels(_:)`, `transcribe(_, decoderState: &state)` with
  `TdtDecoderState.make()`. Check `.build/checkouts/FluidAudio` before assuming.
- The `E5RT ... STL exception` stderr line from CoreML is harmless noise.
- App is ad-hoc signed → every rebuild changes cdhash → macOS silently
  invalidates Accessibility/Input Monitoring. After each rebuild the user must
  re-toggle Accessibility for LocalFlow. If permission prompts stop appearing:
  `tccutil reset Accessibility com.localflow.app` (and `ListenEvent`).
- Input Monitoring is OPTIONAL: HotkeyListener falls back to NSEvent global
  monitors (Accessibility-only) for modifier-key hotkeys. CGEventTap is used
  when Input Monitoring is granted; F-keys require it.
- Small LLMs add "Here is the corrected text:" preambles and random paragraph
  breaks — `OllamaClient.stripModelWrapping` + `collapseNewlines` handle this.
  Keep those guards when touching cleanup.
- 16 GB budget: keep the cleanup model ≤3B; only one LLM resident (evict old
  ones with keep_alive:0 when switching).

## Test loop
- `swift build && .build/debug/localflow-cli file <audio>` exercises the whole
  pipeline headlessly (generate speech with `say -o test.aiff "..."`).
- `localflow-cli check` verifies environment. App: `./Scripts/build_app.sh &&
  open dist/LocalFlow.app` (menu-bar only; no dock icon).
