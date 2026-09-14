# Changelog

All notable changes to this fork are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[Semantic Versioning](https://semver.org/).

Releases up to and including v0.0.5 were published by the upstream project,
[digimata/parrot](https://github.com/digimata/parrot/releases). This fork
picks up from there.

## [0.4.0] - 2026-09-14

### Added

- Optional, fully local translation with TranslateGemma 4B (4-bit), downloaded
  on first activation. No Ollama process or cloud API is required.
- **Translation** menu with an on/off switch and 26 source/target language
  choices. Defaults to off, with Portuguese (Brazil) → English selected.
- Setup progress, model unloading when disabled, and **Copy original dictation**
  recovery when translation fails.
- `parrot translate --from pt-BR --to en` for text translation without a microphone.
- Protection for code, common identifiers, URLs and numeric/currency literals;
  missing or duplicated placeholders reject the generated result.

### Changed

- Release builds include the matching MLX Metal library and install complete,
  versioned runtimes with a command symlink and automatic LaunchAgent restart.
  The installer continues to accept older single-file releases.
- Prevent a second recording while the previous result is processing, so
  transcriptions and translations cannot overwrite or paste out of order.
- Add focused translation lifecycle and installer tests to the release workflow.

## [0.3.0] - 2026-09-13

### Added

- **Recording indicator** menu with **Simple** (compact bars) and **Reactor**
  (circular animation). The choice is saved across launches and applies
  immediately, with Reactor as the default.

## [0.2.0] - 2026-09-13

### Changed

- Replace the recording pill with a circular audio reactor: a cyan core,
  counter-rotating rings, and radial segments driven by microphone volume.
- Show transcription with amber rings and a central processing indicator.
- Smooth microphone levels and respect the macOS Reduce Motion preference.
- Update installation examples so version and repository overrides reach the
  installer process correctly.

### Fixed

- Cancel a pending overlay dismissal when another recording starts.

## [0.1.0] - 2026-08-26

First release cut from this fork. Rolls up the fork's own work plus several
upstream pull requests merged or cherry-picked ahead of upstream.

### Added

- **Parakeet TDT 0.6B v3** (via FluidAudio) as a second transcription
  backend — multilingual (25 languages, including Portuguese), fast, and now
  the recommended default.
- **Model selection** end to end: `--model` flag, a **Model** submenu in the
  menu bar that switches models live (downloading in the background while
  dictation keeps working), `parrot install --select-model` for the
  LaunchAgent, and `parrot models list` / `parrot models download`.
- **Paste-based text injection** (`--inject-mode paste`, the default): puts
  the transcript on the pasteboard, sends ⌘V, and restores the previous
  pasteboard contents. Works in terminals and Electron apps, which drop
  synthesized unicode key events. (Cherry-picked from upstream PR #4.)
- **Configurable push-to-talk key**: `--hotkey`, plus a persistent,
  menu-configurable choice of modifier. (Upstream PR #7.)
- **Input device picker** in the menu bar. (Upstream PR #14.)
- **Spoken-language detection** instead of assuming English, on multilingual
  models. (Upstream PR #15.)
- **Release integrity**: the install script verifies the published SHA-256
  before extracting (fail-closed) and checks GitHub's signed build-provenance
  attestation (`PARROT_REQUIRE_ATTESTATION=1` makes that fatal); releases are
  attested at build time in CI.
- `scripts/dev-install.sh`: build, sign with a local identity, install, and
  restart the LaunchAgent — signing keeps the Accessibility grant across
  rebuilds.
- MIT license.

### Changed

- Models are cached outside `~/Documents`, so iCloud cannot evict them and
  the LaunchAgent needs no TCC grant to load them. (Upstream PRs #11/#12.)
- The audio engine is rebuilt for each recording, fixing stale captures after
  device changes. (Upstream PR #14.)
- The global event tap listens only to modifier-flag changes — no keystroke
  contents ever reach the process outside `--debug-hotkey`.
- The installer is served from this fork; `PARROT_REPOSITORY` overrides the
  repository it installs from.
- The LaunchAgent preserves its log destination across plist rewrites, and no
  longer sets `Umask`.
- The menu bar icon is no longer tinted during recording (the pill overlay
  already signals it).

### Fixed

- **Privacy:** transcripts are no longer written to a world-readable log in
  `/tmp`. `parrot doctor` flags a leftover legacy log and
  `parrot install --purge-legacy-logs` removes it. (With upstream PR #9.)
- `type-unicode` injection posts past parrot's own event tap
  (`cgAnnotatedSessionEventTap`), which silently swallowed the synthetic
  keystrokes, and no longer sets the unicode string on key-up, which
  duplicated the text in some apps. (Upstream PRs #27 and #24.)
- A missing Accessibility permission and an unknown `--model` id both exit 0,
  so the LaunchAgent's `KeepAlive` does not relaunch a hopeless process
  forever. (Partly upstream PR #20.)
- `parrot models list` no longer truncates long model ids. (Upstream PR #19.)
- Language detection is gated on multilingual models — English-only (`.en`)
  models have no language tokens to detect with.

[0.4.0]: https://github.com/FernandoGomes83/parrot/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/FernandoGomes83/parrot/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/FernandoGomes83/parrot/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/FernandoGomes83/parrot/compare/v0.0.5...v0.1.0
