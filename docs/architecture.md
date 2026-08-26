# Architecture

This describes the system as it is. The original pre-implementation design doc
lives in git history; the notable places where reality diverged from it are
collected at the end.

## Goals

1. **Single binary.** One SPM executable target, launched from a terminal or as
   a LaunchAgent. No `.app` bundle, no dock icon, no settings window.
2. **Push-to-talk.** Hold a modifier key (`fn` by default, configurable), speak,
   release — the transcript is pasted at the cursor.
3. **Minimal UI.** A menu bar status item (model, input device, push-to-talk
   key, quit) and a click-through recording pill at the bottom of the screen.
   Nothing else.
4. **On-device.** No network calls for transcription. Audio never leaves the
   machine. Transcripts are never written to disk.
5. **Pluggable engines.** A `Transcriber` protocol with WhisperKit and
   FluidAudio (Parakeet) implementations; a hardcoded registry is the single
   source of truth for models.

## Non-goals

- Cross-platform (macOS only, Apple Silicon only — inference runs on the ANE)
- Cloud transcription providers
- AI post-processing, summarization, agents
- Speaker diarization, meeting recording, semantic search
- Streaming partial transcripts, VAD-based hands-free mode
- History, transcript log, custom vocabulary

## Why Swift

- **CoreML / ANE access.** WhisperKit and FluidAudio are Swift-native and run
  inference on the Apple Neural Engine — lower power, lower latency than
  CPU/GPU paths in Rust.
- **No FFI for platform APIs.** `AVAudioEngine`, `CGEventTap`, `CGEvent`,
  `AXIsProcessTrusted`, `NSWindow`, `NSStatusItem` — all first-party.
- **Permissions plumbing** (microphone, accessibility) is dramatically smoother
  in a Swift binary than via Rust crates.

## High-level shape

```
$ parrot
                  ┌───────────────────┐
                  │    Parrot.swift   │  argument parsing, wiring,
                  │  (ParsableCommand)│  NSApp.run() as .accessory
                  └─────────┬─────────┘
                            ▼
┌──────────────────┐  hold  ┌──────────────────┐      ┌────────────────────┐
│  HotkeyMonitor   │ ─────▶ │   AudioCapture   │      │  MenuBarController │
│  (CGEventTap)    │ release│  (AVAudioEngine, │      │  (NSStatusItem)    │
└──────────────────┘ ◀───── │  fresh per rec.) │      ├────────────────────┤
                            └────────┬─────────┘      │  RecordingOverlay  │
                                     │ [Float] PCM    │  (SwiftUI pill)    │
                                     ▼                └────────────────────┘
                            ┌──────────────────┐
                            │   Transcriber    │  WhisperKitTranscriber
                            │   (protocol)     │  ParakeetTranscriber
                            └────────┬─────────┘
                                     │ String
                                     ▼
                            ┌──────────────────┐
                            │   TextInjector   │  paste (default) or
                            │   (CGEvent)      │  type-unicode fallback
                            └──────────────────┘
```

## Modules

### `Parrot.swift`

Argument parsing via `swift-argument-parser`. Subcommands:

- `run` (default) — the daemon: permission checks (skippable with
  `--skip-doctor`), model load, then `NSApplication` with `.accessory`
  activation policy and `NSApp.run()` (needed for the status item, the overlay
  window, the event tap, and AVFoundation).
- `setup` — walk through first-run permissions + model download.
- `doctor` — check microphone, accessibility, fn-key mapping, and leftover
  legacy logs, with remediation steps.
- `models list` / `models download <id>`.
- `install` — manage the launch-at-login LaunchAgent (see below).

**Exit-code convention:** conditions that are not transient — missing
Accessibility permission, unknown model id — exit `0`, not `1`. The
LaunchAgent's `KeepAlive` is `{SuccessfulExit: false}`, so a non-zero exit
would relaunch a hopeless process forever.

### `Input/`

`HotkeyMonitor` — global hotkey via a listen-only `CGEventTap` at
`.cgSessionEventTap` (requires Accessibility). The mask is deliberately
narrowed to `flagsChanged` — keystroke contents never reach the process
(`--debug-hotkey` widens it). If macOS disables the tap (timeout or user
input), the callback re-enables it from the main run loop instead of dying
silently. The key is a modifier (`fn`, left/right option, right command, …),
chosen via `--hotkey` or the menu bar; `HotkeyPreferences` persists it in
`UserDefaults`.

`TextInjector` — two modes. **`paste` (default):** snapshot the pasteboard,
put the transcript on it, synthesize ⌘V (posted to
`.cgAnnotatedSessionEventTap`), restore the snapshot after a grace period.
Works everywhere, including terminals and Electron apps, which discard
synthesized unicode events. **`type-unicode`:** posts the characters directly
in ~20-char chunks — never touches the pasteboard, but silently drops text in
those apps. Synthetic events must be posted to `.cgAnnotatedSessionEventTap`:
posting at `.cgSessionEventTap` gets them swallowed by our own listen-only tap.

### `Audio/`

`AudioCapture` — an `AVAudioEngine` input tap streaming 16 kHz mono `Float32`.
The engine is **built fresh for every recording** (stale engines survive device
changes and capture silence). `start(device:)` takes an optional
`AudioDeviceID`; `InputDeviceStore` persists the chosen input's UID in
`UserDefaults`, and the menu bar's **Input** submenu sets it — applied on the
next recording.

### `Transcription/`

```swift
protocol Transcriber {
    func transcribe(_ audio: [Float]) async throws -> String
}
```

- `WhisperKitTranscriber` — WhisperKit (CoreML, ANE). Detects the spoken
  language on multilingual models; `.en` models skip detection (they have no
  language tokens). Models live under
  `~/Library/Application Support/parrot/huggingface/` (earlier versions used
  `~/Documents`, where iCloud could evict files and the LaunchAgent needed a
  TCC grant to read them; a migration note is printed rather than silently
  re-downloading gigabytes).
- `ParakeetTranscriber` — FluidAudio running Parakeet TDT 0.6B v3, under
  `~/Library/Application Support/parrot/fluidaudio/`.

Engines download their model on first load. Adding an engine = one new
conformance + registry entries.

### `Models/`

`ModelRegistry` is a hardcoded array of `TranscriptionModel` values — the
single source of truth for ids, sizes, languages, and the recommended flag.
(The design called for a bundled `models.json`; a Swift literal turned out to
be simpler and type-checked.) `ModelPreferences` persists the selected model in
`UserDefaults`; a LaunchAgent installed with `--select-model` instead pins
`--model` in its plist, which wins on the next daemon restart.

### `UI/`

`MenuBarController` — an `NSStatusItem` (feather icon, tinted while
transcribing) with submenus: **Push-to-talk key**, **Input** (capture device),
**Model** (switches live: the new model loads in the background while dictation
keeps using the current one), and Quit.

`RecordingOverlay` — a borderless, click-through `NSWindow`
(`level: .statusBar`, joins all Spaces) hosting a SwiftUI pill at
bottom-center: hidden → recording → transcribing → hidden.

### `Install.swift`

Writes `~/Library/LaunchAgents/com.digimata.parrot.plist` (label
`com.digimata.parrot`, `KeepAlive: {SuccessfulExit: false}`), pointing at the
installed binary with `run --skip-doctor`. `--log-file` sends output to
`~/Library/Logs/parrot.log` (`0600`); the default discards it. The log
destination is preserved across plist rewrites. Also: `--uninstall`,
`--select-model`, `--purge-legacy-logs`.

## Permissions

1. **Microphone** — standard `AVCaptureDevice` prompt on first engine start.
2. **Accessibility** — required for the event tap and for posting events.

The TCC quirk that matters: **the grant attaches to the responsible process
and the code signature.**

- Launched from a terminal, the process inherits the *terminal's* grant —
  which is why `parrot doctor` in a terminal can say "ok" while the
  LaunchAgent, running the same binary standalone, is denied.
- The LaunchAgent needs a grant for the binary itself, and macOS keys it to
  the code signature. Ad-hoc-signed release builds get a fresh signature every
  build, so **updating breaks the grant** until the user toggles parrot off/on
  in System Settings → Accessibility. `scripts/dev-install.sh` signs local
  builds with a self-signed `parrot-dev` identity so repeated dev installs
  keep the grant; signing releases with a stable Developer ID (planned) fixes
  it for everyone.
- The CoreML/ANE compile cache is also keyed by signature: the first launch of
  a newly-signed binary recompiles the model (minutes of `ANECompilerService`
  CPU, near-zero CPU in parrot, no UI yet — it looks stuck and isn't).

## Models — what ships

| Engine | Model | Size | Notes |
|---|---|---|---|
| FluidAudio | `parakeet-tdt-0.6b-v3` | 483 MB | ★ recommended — multilingual (25 langs, incl. pt), fastest on ANE |
| WhisperKit | `whisper-base.en` | 145 MB | English only, low resource |
| WhisperKit | `whisper-small.en` | 488 MB | English only |
| WhisperKit | `whisper-large-v3-turbo` | 1620 MB | Multilingual, slower first run |

## Data flow, end-to-end

1. `parrot run` — permissions checked, model loaded (downloaded first if
   needed), status item appears, tap armed.
2. User holds the push-to-talk key → overlay shows, a fresh `AVAudioEngine`
   starts on the chosen input device.
3. User releases → overlay switches to transcribing, the buffer goes to the
   active `Transcriber`, CoreML inference runs on the ANE.
4. `TextInjector` pastes the transcript at the cursor and restores the
   pasteboard. Overlay hides. Loop.

Latency target: <500 ms after release for utterances under 10 seconds. The
daemon logs timing and length only (`→ 0.42s · 63 chars`) — never the text.

## Distribution

Tag `v*` → GitHub Actions (`release.yml`) builds arm64 on macOS, strips,
packages `parrot-macos-arm64.tar.gz` + `.sha256`, signs a build-provenance
attestation via OIDC, and publishes the release. `scripts/install.sh`
(`curl | sh`) resolves the latest release, verifies the checksum fail-closed,
checks the attestation (advisory — `PARROT_REQUIRE_ATTESTATION=1` makes it
fatal), inspects the archive, and installs to `/usr/local/bin`.
`PARROT_VERSION` pins a release; `PARROT_REPOSITORY` overrides the repo.

## Where reality diverged from the original design

- **A menu bar item exists** (it was an explicit non-goal): switching model,
  input, and hotkey while running earned it. There is still no dock icon,
  settings window, or `.app` bundle.
- **Launch-at-login is built in** (`parrot install`) rather than left to the
  user's own launchd wiring — the plist details (KeepAlive semantics, exit-0
  convention, log handling, model pinning) were worth owning.
- **Paste replaced synthetic typing as the default injection** — typing drops
  text in terminals and Electron apps.
- **Configuration is `UserDefaults`, not a TOML file.** Preferences changed
  from the menu bar need to persist without a config-file writer; the planned
  `~/.config/parrot/config.toml` never existed.
- **The registry is a Swift literal, not `models.json`** — one fewer resource
  to load and validate, and it's type-checked.
- Resolved open questions: FluidAudio over direct CoreML for Parakeet; tap
  registration failures print remediation and the tap re-enables itself after
  system disables; models are downloaded on demand (nothing bundled); local
  builds are signed with `parrot-dev`, releases with a Developer ID once
  available.
