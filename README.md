# parrot

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

## Install

```sh
curl -fsSL https://digimata.github.io/parrot/install.sh | sh
parrot setup                       # grants mic + accessibility, downloads the model
parrot install --launch-at-login   # optional — runs in the background on login
parrot install --select-model      # optional — choose the launch-at-login model
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The installer drops the binary in `/usr/local/bin/parrot`. It downloads the published
`.sha256` and verifies the tarball before extracting it, prints the digest, and refuses to
install if the checksum is missing or doesn't match. It also checks the archive contains
exactly one member (`parrot`) and no absolute or `..` paths.

Pin a version — piping to `sh` leaves no way to pass arguments, so use the environment:

```sh
PARROT_VERSION=v0.0.5 curl -fsSL https://digimata.github.io/parrot/install.sh | sh
```

**Builds are unsigned and un-notarized.** The installer removes the quarantine attribute
if one is present, but `curl` does not set it — quarantine is applied by apps that opt into
`LSFileQuarantineEnabled`, like browsers — so in the piped path there is nothing to remove
and the script says so. It matters only if you downloaded the tarball in a browser.

### Verifying a release by hand

```sh
TAG=v0.0.5
curl -fsSLO https://github.com/digimata/parrot/releases/download/$TAG/parrot-macos-arm64.tar.gz
curl -fsSLO https://github.com/digimata/parrot/releases/download/$TAG/parrot-macos-arm64.tar.gz.sha256
shasum -a 256 -c parrot-macos-arm64.tar.gz.sha256

# releases built after provenance was enabled can also be checked against GitHub's
# signed attestation (requires the gh CLI, logged in):
gh attestation verify parrot-macos-arm64.tar.gz --repo digimata/parrot
```

A checksum published in the same release as the artifact only proves the download wasn't
corrupted in transit — whoever can replace the tarball can replace the `.sha256` beside it.
The attestation is the stronger check: GitHub signs a statement binding the artifact to a
specific workflow run at a specific commit, which the repo owner cannot forge. Releases
published before provenance was enabled have no attestation, so the installer reports a
failed provenance check as a warning rather than aborting. Set
`PARROT_REQUIRE_ATTESTATION=1` to make it abort instead.

## How to use

1. **Run it.** Either `parrot install --launch-at-login` (daemonized, runs forever, lives in the menu bar), or `parrot` in any terminal tab.
2. **Click into the text field you want to dictate into** — Messages, the address bar, a Slack thread, anywhere a cursor blinks.
3. **Hold the `fn` key, speak, release.** A small pill appears at the bottom of the screen while the mic is hot.
4. **The transcript types itself in at the cursor** when you release. Usually within 200-300ms.

That's it. There is no record button, no stop button, no "send" — `fn` is the whole interface.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to flip it back to plain `fn`.

## CLI

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time setup: permissions + model download
parrot install --launch-at-login       # register a LaunchAgent (background daemon)
parrot install --select-model [model]  # update the LaunchAgent model (prompts if omitted)
parrot install --uninstall             # remove the LaunchAgent
parrot install --purge-legacy-logs     # delete world-readable /tmp logs from older versions
parrot doctor                          # check permissions + fn key setting
parrot models list                     # list available models
parrot models download <id>            # pre-download a model
parrot --model whisper-large-v3-turbo  # bigger, multilingual, slower first-run
parrot --model parakeet-tdt-0.6b-v3    # multilingual (25 langs, incl. pt), fast
parrot --hotkey right-option           # change the push-to-talk key
parrot --inject-mode type-unicode      # type the text instead of pasting it
parrot --no-overlay                    # disable the bottom-of-screen pill
```

### Injection modes

`--inject-mode paste` (the default) puts the transcript on the pasteboard,
sends ⌘V, and restores your previous pasteboard contents. Terminals and
Electron apps discard synthesized unicode key events but all handle paste, so
this is the mode that works everywhere.

`--inject-mode type-unicode` synthesizes the characters directly and never
touches the pasteboard, at the cost of silently dropping text in those apps.

You can also change the push-to-talk key while Parrot is running: click its
menu-bar icon, open **Push-to-talk key**, and choose a modifier. The selection
is applied immediately and remembered for future launches.

The same menu has a **Model** submenu. Picking a model loads it in the
background (downloading it first if needed) — dictation keeps using the current
model until the new one is ready, and the choice is remembered for future
launches. Note that a LaunchAgent installed with `--select-model` pins `--model`
in its plist, and that flag wins over the menu choice the next time the daemon
restarts; install with plain `parrot install --launch-at-login` if you want the
menu to govern the model.

## Privacy

Transcripts are never written to disk. The daemon logs timing and length only
(`→ 0.42s · 63 chars`); `--echo-transcripts` prints the full text to stderr, and its
help text says so, but it is never used by the LaunchAgent.

`parrot install --launch-at-login` discards the daemon's output. To keep it, add
`--log-file` and it goes to `~/Library/Logs/parrot.log`, created `0600` and owned by you.
Either way the log holds no transcript text.

> **If you installed parrot before this change**, the daemon was writing every transcript
> in plaintext to `/tmp/parrot.err.log`, which any local user can read, with no rotation
> and no size cap. `parrot doctor` will flag the file if it's still there. Read it, then
> remove it with `parrot install --purge-legacy-logs`.

`--dump-wav` writes raw recorded audio to `~/Library/Caches/parrot/last-capture.wav`
(`0600`, in a `0700` directory).

## Stack

- **Swift** — single SPM executable target
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **FluidAudio** — Parakeet TDT 0.6B v3 inference (multilingual, CoreML/ANE)
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — recording-indicator pill

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
swift build -c release
.build/release/parrot --help
```
