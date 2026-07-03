# LocalFlow — fully local dictation for macOS

A free, offline Wispr Flow equivalent. Hold a hotkey anywhere in macOS, speak,
release — the cleaned-up text is typed into whatever app you're using
(Slack, browser, Notes, VS Code, …). Nothing ever leaves your Mac.

```
hold Right-Option ──▶ mic (16 kHz) ──▶ Silero VAD (skip silence)
                                            │
                                            ▼
                          Stage A: Parakeet TDT 0.6B (CoreML, Apple Neural Engine)
                                            │  raw transcript
                                            ▼
                          Stage B: Ollama (qwen2.5:3b / llama3.2:3b)
                                    fixes fillers, punctuation, casing ONLY
                                            │  cleaned transcript
                                            ▼
                     paste into focused text field (your clipboard is restored)
```

**Measured on this machine (MacBook Air M4, 16 GB, macOS 26.5):**

| Stage | Latency | Memory |
|---|---|---|
| ASR model load (once, at app launch) | ~0.2–13 s (first CoreML compile is slower) | ~40–60 MB app footprint |
| VAD + ASR for a 9 s utterance | **~120–140 ms** | (models run on the ANE) |
| LLM cleanup (3B model, warm) | **~1–3 s** | ~2.4 GB inside the `ollama` server |
| First-ever run | +~1 GB Parakeet download, one-time | |

If cleanup ever takes longer than the timeout (default 10 s) or Ollama is down,
the **raw transcript is pasted instead** — dictation never hangs.

---

## Setup

### 1. Requirements (all free)

- Apple Silicon Mac, macOS 14+
- Xcode **Command Line Tools** (no full Xcode needed): `xcode-select --install`
- [Ollama](https://ollama.com): `brew install ollama` (or the installer app)

### 2. Models

```bash
# Stage B cleanup model (~2 GB). Small on purpose — it must coexist with the ASR model in 16 GB.
ollama pull qwen2.5:3b
# already have llama3.2:3b? that works too — LocalFlow falls back to it automatically
```

Stage A (Parakeet TDT 0.6B v2 + Silero VAD) downloads **automatically on first
run** (~1 GB) into `~/Library/Application Support/FluidAudio/Models/`.

Make sure Ollama is running: `ollama serve` (the desktop app does this for you).

### 3. Phase 0 — validate speed/RAM on your machine (CLI)

```bash
cd LocalFlow
swift build
.build/debug/localflow-cli check                 # environment sanity check
.build/debug/localflow-cli run                   # record mic, Enter to stop
.build/debug/localflow-cli file some-audio.m4a   # or run on a file
```

Every run prints the raw transcript, the cleaned transcript, and per-stage
latency + memory. Useful flags: `--no-cleanup`, `--no-vad`, `--asr v3`
(25 languages), `--model llama3.2:3b`, `--seconds 5`.

> Running `run` from a terminal uses the **terminal's** microphone permission —
> macOS will prompt once.

### 4. Build and run the menu-bar app

```bash
./Scripts/build_app.sh
open dist/LocalFlow.app
```

A mic icon appears in the menu bar. On first launch an onboarding window walks
you through the permissions (System Settings → Privacy & Security):

| Permission | Why | Pane |
|---|---|---|
| **Microphone** | record your voice while the key is held | Microphone |
| **Accessibility** | detect the push-to-talk key + synthesize the Cmd+V paste | Accessibility |
| Input Monitoring *(optional)* | only needed for F-key hotkeys (F13–F15) | Input Monitoring |

If LocalFlow doesn't appear in a pane's list, click **+** and add
`dist/LocalFlow.app` manually. After granting, **quit and reopen LocalFlow**
so the hotkey listener starts cleanly.

### 5. Use it

1. Click into any text field in any app.
2. **Hold Right Option**, speak, release.
3. Cleaned text appears at your cursor. Your previous clipboard is restored ~0.7 s later.

Menu bar icon: 🎤 idle · 🔴 recording · orange waveform = transcribing/cleaning.

## Settings (menu bar → Settings…)

- **Hotkey**: Right Option / Right Command / Right Control / F13–F15; hold-to-talk or tap-toggle
- **ASR model**: Parakeet v2 (English, best accuracy) or v3 (25 languages)
- **VAD**: on/off + sensitivity threshold
- **Cleanup**: on/off, Ollama model picker (lists installed models), URL, timeout
- **Injection**: paste (default) or Unicode keystroke typing for apps where paste fails

Config lives at `~/Library/Application Support/LocalFlow/config.json`.

The cleanup prompt is fixed (temperature 0.2) and only allows: removing
filler words, fixing punctuation/capitalization/paragraph breaks. A guardrail
keeps the raw transcript if the model's output shrinks suspiciously.

## Troubleshooting

- **Hotkey does nothing** → Accessibility not granted, or the app was rebuilt
  (ad-hoc signatures change per build, macOS then silently revokes
  Accessibility/Input Monitoring). Re-toggle the permission for LocalFlow and
  relaunch.
- **Permission prompt never appears / app missing from the pane** → macOS has a
  stale entry from an older build. Reset it, then relaunch and grant again:
  `tccutil reset Accessibility com.localflow.app`
  (same with `ListenEvent` for Input Monitoring), or add the app manually
  with the pane's **+** button.
- **Text doesn't appear but the icon cycles** → grant Accessibility; or switch
  Injection to "Type keystrokes" for terminals/apps that block synthetic Cmd+V.
- **`E5RT encountered an STL exception` in CLI output** → harmless CoreML/ANE
  compiler noise from the Parakeet encoder; transcription is unaffected.
- **Cleanup slow the first time** → the LLM loads into RAM on first use
  (LocalFlow pre-warms it at launch; Ollama keeps it warm for 30 min).
- **Multilingual dictation** → Settings → ASR model → v3. (Parakeet v3 covers
  25 European languages, so the Whisper fallback from the original plan wasn't
  needed; if you ever want more languages, WhisperKit is the drop-in choice.)
- **RAM pressure** → keep the cleanup model ≤3B (qwen2.5:3b ≈ 2.4 GB resident).
  Everything together stays well under 4 GB, fine on 16 GB.

## Project layout

```
Sources/LocalFlowCore/   shared engine: recorder, VAD+ASR, Ollama client,
                         hotkey tap, text injector, config, metrics
Sources/localflow-cli/   Phase 0 test harness
Sources/LocalFlowApp/    menu-bar app (controller, onboarding, settings)
Scripts/build_app.sh     SwiftPM binary → codesigned LocalFlow.app
```
