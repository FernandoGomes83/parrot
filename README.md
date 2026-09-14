# parrot

A minimal macOS dictation daemon. Push-to-talk, on-device transcription, text inserted at the cursor.

> A fork of [digimata/parrot](https://github.com/digimata/parrot) (MIT) that tracks
> upstream and adds, among other things, a second transcription backend (Parakeet
> TDT 0.6B v3, multilingual), live model switching from the menu bar, and verified
> binary releases — see [CHANGELOG.md](CHANGELOG.md).

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/FernandoGomes83/parrot/master/scripts/install.sh | sh
parrot setup                       # grants mic + accessibility
parrot install --launch-at-login   # optional — runs in the background on login
parrot install --select-model      # optional — choose the launch-at-login model
```

**Requires:** macOS 14+ on Apple Silicon (M1 or newer). Transcription runs on the Apple Neural Engine via CoreML — so the installer refuses to run on Intel.

The installer puts the executable and its MLX Metal library together in
`/usr/local/lib/parrot/<version>/` and links `/usr/local/bin/parrot` to the executable.
An existing LaunchAgent is restarted after installation. It verifies the published
SHA-256 before extracting and accepts only the expected regular files (`parrot`
and `mlx.metallib`). Older releases containing only `parrot` remain installable.

Pin a version, or install from a different fork — piping to `sh` leaves no way
to pass arguments, so use the environment:

```sh
curl -fsSL https://raw.githubusercontent.com/FernandoGomes83/parrot/master/scripts/install.sh | PARROT_VERSION=v0.4.0 sh
curl -fsSL https://raw.githubusercontent.com/FernandoGomes83/parrot/master/scripts/install.sh | PARROT_REPOSITORY=digimata/parrot sh
```

**Builds are unsigned and un-notarized.** The installer removes the quarantine attribute
if one is present, but `curl` does not set it — quarantine is applied by apps that opt into
`LSFileQuarantineEnabled`, like browsers — so in the piped path there is nothing to remove
and the script says so. It matters only if you downloaded the tarball in a browser.

Two first-run consequences of that, until releases are signed with a stable
Developer ID (planned):

- **Updating re-breaks the Accessibility grant.** macOS ties the grant to the
  code signature, and every release build carries a fresh ad-hoc one, so after
  installing a new version the LaunchAgent logs `accessibility not granted`
  even though System Settings shows parrot enabled. Fix: System Settings →
  Privacy & Security → Accessibility → toggle **parrot** off and on (or remove
  it and re-add `/usr/local/bin/parrot`), then restart the daemon. Running
  `parrot doctor` from a terminal can't detect this — inside a terminal the
  process inherits the *terminal's* grant.
- **The first launch looks stuck for a few minutes.** The CoreML/ANE model
  cache is also keyed by signature, so a new binary recompiles the model for
  the Neural Engine before anything appears — no menu bar icon, no hotkey,
  near-zero CPU in `parrot` while `ANECompilerService` works. It finishes on
  its own (the log shows `✓ <model> ready`) and later launches are instant.

### Verifying a release by hand

```sh
TAG=v0.4.0
curl -fsSLO https://github.com/FernandoGomes83/parrot/releases/download/$TAG/parrot-macos-arm64.tar.gz
curl -fsSLO https://github.com/FernandoGomes83/parrot/releases/download/$TAG/parrot-macos-arm64.tar.gz.sha256
shasum -a 256 -c parrot-macos-arm64.tar.gz.sha256

# releases built after provenance was enabled can also be checked against GitHub's
# signed attestation (requires the gh CLI, logged in):
gh attestation verify parrot-macos-arm64.tar.gz --repo FernandoGomes83/parrot
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
3. **Hold the push-to-talk key (`fn` by default), speak, release.** A circular cyan reactor appears at the bottom of the screen, reacting to your voice; it turns amber while transcribing. Choose **Recording indicator → Simple** in the menu bar for the compact bars, or **Reactor** for the circular animation. Your choice is saved and takes effect immediately. You can switch the key to another modifier with `--hotkey` or from the menu bar (see below).
4. **The transcript is pasted at the cursor** after processing. If translation is enabled, the translated text is pasted instead. Wait for the indicator to disappear before starting another dictation.

That's it. There is no record button, no stop button, no "send" — one held key is the whole interface.

> **Note:** on most modern Macs the `fn` key is the bottom-left key. If yours is set to "Change input source" or "Show emoji & symbols," `parrot setup` will tell you how to flip it back to plain `fn` — or just pick a different push-to-talk key.

## Optional local translation

Open **Translation** in the menu bar:

- **Enable translation / Disable translation** controls whether dictation is translated.
- **From** selects the spoken language; the initial choice is Portuguese (Brazil).
- **To** selects the output language; the initial choice is English. There are 26 choices.

The first activation downloads **TranslateGemma 4B, quantized to 4-bit** (about
2.2 GB). The model runs inside Parrot through MLX; Ollama, a cloud account, and
API keys are not needed. While the menu says **Preparing translator**, ordinary
untranslated dictation remains available. Translation begins once it says **Ready**.
The model is kept in memory while enabled and released when disabled, after any
active request finishes. Preferences survive restarting Parrot.

Weights are stored under `~/Library/Application Support/parrot/translation`.
After the download, translation works offline. The chosen source/target pair is
captured when you release the dictation key, so menu changes do not alter a
request already processing. Use a multilingual transcription model for Portuguese
or other non-English speech; translating cannot fix words an English-only speech
model misheard.

Code spans, common identifiers, URLs, and numeric/currency literals are protected
before translation and restored afterward. If the model drops or duplicates a
protected value, returns nothing, or fails to finish, Parrot does not paste that
result. The menu icon shows **!** and **Translation → Copy original dictation**
recovers the original text. No transcript is stored on disk by this recovery flow.

Translation adds latency. In local checks, short sentences took roughly 0.6–1.2s
for translation alone, plus initial model loading. This is a small sample on one
Mac, not a performance guarantee. Ambiguous phrasing can still be mistranslated;
protecting literal values does not guarantee semantic accuracy. English may use
fewer tokens in your destination model, but the savings depend on its tokenizer
and the particular text.

The model is [TranslateGemma](https://blog.google/innovation-and-ai/technology/developers-tools/translategemma/),
using the [MLX 4-bit conversion](https://huggingface.co/mlx-community/translategemma-4b-it-4bit)
under the Gemma license. The model revision is pinned separately from the executable.

## CLI

```sh
parrot                                 # run in the foreground (^C to quit)
parrot setup                           # one-time permission setup
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
parrot --no-overlay                    # disable the bottom-of-screen reactor
parrot translate --from pt-BR --to en "Quero adicionar uma opção ao menu."
printf '%s' "Não altere o login." | parrot translate --to es
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

An **Input** submenu picks the microphone to capture from, applied on the next
recording.

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

- **Swift** — executable plus an isolated local-translation module
- **WhisperKit** — Whisper inference via CoreML, ANE-accelerated
- **FluidAudio** — Parakeet TDT 0.6B v3 inference (multilingual, CoreML/ANE)
- **MLX Swift / TranslateGemma 4B** — optional offline text translation on the GPU
- **AVAudioEngine** — mic capture
- **CGEventTap** — global hotkey
- **CGEvent** — text injection at cursor
- **NSWindow** (borderless, click-through) — sound-reactive recording indicator

See [docs/architecture.md](docs/architecture.md) for design notes.

## Build from source

```sh
# Xcode with Swift 6.1+ and the Metal toolchain is required.
xcodebuild -downloadComponent MetalToolchain   # once, if missing
sh scripts/build.sh
dist/parrot --help
swift test -c release
python3 Tests/install_test.py
```

`swift build` remains usable for development, but its executable alone lacks the
compiled Metal shaders. Use `scripts/build.sh` and keep both files in `dist`
together to run translation.

For repeated local installs, `scripts/dev-install.sh` builds, signs with a
local `parrot-dev` identity, installs the executable and Metal library together, and restarts the
LaunchAgent. Signing matters: macOS ties the Accessibility grant to the code
signature, so unsigned builds need the permission re-granted after every
update, while builds signed with the same certificate keep it. One-time setup —
create and trust a self-signed code-signing certificate named `parrot-dev`:

```sh
openssl req -new -newkey rsa:2048 -days 3650 -nodes -x509 \
  -subj "/CN=parrot-dev" -keyout parrot-dev.key -out parrot-dev.crt \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false"
openssl pkcs12 -export -legacy -inkey parrot-dev.key -in parrot-dev.crt \
  -out parrot-dev.p12 -passout pass:parrot-dev -name parrot-dev
security import parrot-dev.p12 -k ~/Library/Keychains/login.keychain-db \
  -P parrot-dev -T /usr/bin/codesign
security add-trusted-cert -r trustRoot \
  -k ~/Library/Keychains/login.keychain-db parrot-dev.crt
rm parrot-dev.key parrot-dev.crt parrot-dev.p12
```
