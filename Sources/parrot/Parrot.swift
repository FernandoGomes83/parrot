import AppKit
import ArgumentParser
import Foundation
import ParrotTranslation
import WhisperKit

@main
struct Parrot: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "parrot",
        abstract: "Minimal macOS dictation daemon. Hold the push-to-talk key (Fn by default), speak, release.",
        subcommands: [Run.self, Setup.self, Doctor.self, Models.self, Install.self, Translate.self],
        defaultSubcommand: Run.self
    )
}

struct Run: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run the daemon (default)."
    )

    @Flag(name: .long, help: "Skip permission checks at startup.")
    var skipDoctor: Bool = false

    @Flag(name: .long, help: "Print the modifier flags on each flagsChanged event the tap sees (debug).")
    var debugHotkey: Bool = false

    @Flag(name: .long, help: "Write each capture to ~/Library/Caches/parrot/last-capture.wav for inspection. The file holds raw recorded audio.")
    var dumpWav: Bool = false

    @Flag(name: .long, help: "Print the full transcript text to stderr. The text of everything you dictate will appear in logs.")
    var echoTranscripts: Bool = false

    @Flag(name: .long, help: "Disable the on-screen recording overlay.")
    var noOverlay: Bool = false

    @Option(name: .long, help: "Model id to use. Defaults to the recommended model.")
    var model: String?

    @Option(
        name: .long,
        help: "Push-to-talk key. Options: \(HotkeyMonitor.Hotkey.allCases.map(\.rawValue).joined(separator: ", "))."
    )
    var hotkey: HotkeyMonitor.Hotkey?

    @Option(
        name: .long,
        help: "How the transcript reaches the app: paste (⌘V, works everywhere; pasteboard restored) or type-unicode (no pasteboard, but terminals and Electron apps drop it)."
    )
    var injectMode: TextInjector.Mode = .paste

    func run() throws {
        let selectedHotkey = hotkey ?? HotkeyPreferences.selected
        if let hotkey {
            HotkeyPreferences.selected = hotkey
        }

        if !skipDoctor {
            let checks = DoctorReport.run(checkFnMapping: selectedHotkey == .fn)
            if !DoctorReport.allOK(checks) {
                FileHandle.standardError.write(Data("startup checks failed:\n".utf8))
                DoctorReport.print(checks)
                FileHandle.standardError.write(Data("\nfix the above or pass --skip-doctor\n".utf8))
                throw ExitCode(1)
            }
        }

        let chosenModel: TranscriptionModel
        if let id = model {
            guard let m = ModelRegistry.find(id) else {
                FileHandle.standardError.write(Data("unknown model: \(id)\n".utf8))
                FileHandle.standardError.write(Data("run `parrot models list` to see options.\n".utf8))
                // Exit 0 for the same reason as a missing permission: a bad model id
                // is not transient, and KeepAlive would relaunch us forever.
                throw ExitCode(0)
            }
            chosenModel = m
            ModelPreferences.selected = m
        } else if let saved = ModelPreferences.selected {
            chosenModel = saved
        } else {
            guard let m = ModelRegistry.recommended() else {
                FileHandle.standardError.write(Data("no models registered\n".utf8))
                throw ExitCode(1)
            }
            chosenModel = m
        }

        let transcriber = TranscriberFactory.make(for: chosenModel)
        let warmupSemaphore = DispatchSemaphore(value: 0)
        var warmupError: Error?
        Task.detached {
            do {
                try await transcriber.warmUp()
            } catch {
                warmupError = error
            }
            warmupSemaphore.signal()
        }
        warmupSemaphore.wait()
        if let warmupError {
            FileHandle.standardError.write(Data("warmup failed: \(warmupError)\n".utf8))
            throw ExitCode(1)
        }

        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        let monitor = HotkeyMonitor(hotkey: selectedHotkey, debug: debugHotkey)
        let devices = InputDeviceStore()
        let capture = AudioCapture()
        let translation = MainActor.assumeIsolated {
            TranslationCoordinator(engine: LocalTranslator())
        }
        let lifecycle = MainActor.assumeIsolated { DictationLifecycle() }
        let dumpWav = self.dumpWav
        let echoTranscripts = self.echoTranscripts
        let injectMode = self.injectMode
        let overlay: RecordingOverlay? = noOverlay ? nil : MainActor.assumeIsolated { RecordingOverlay() }
        if let overlay {
            capture.onLevel = { level in overlay.pushLevel(level) }
        }
        // Swapping models at runtime means the transcriber can't be captured
        // directly by the hotkey closure. Both the menu callbacks and the
        // monitor events run on the main queue, so plain main-thread access to
        // the holder needs no further synchronization.
        let holder = MainActor.assumeIsolated { TranscriberHolder(transcriber) }
        let menuBar = MainActor.assumeIsolated {
            let controller = MenuBarController(
                model: chosenModel,
                hotkey: selectedHotkey,
                devices: devices,
                translation: translation,
                onHotkeyChanged: { monitor.setHotkey($0) }
            )
            controller.onOverlayStyleChanged = { style in
                overlay?.setStyle(style)
            }
            controller.onModelChanged = { [weak controller] newModel in
                guard let controller else { return }
                switchModel(to: newModel, holder: holder, menuBar: controller)
            }
            return controller
        }

        MainActor.assumeIsolated { translation.restore() }

        do {
            try monitor.start { event in
                MainActor.assumeIsolated {
                    switch event {
                    case .pressed:
                        guard !lifecycle.isProcessing else {
                            NSSound.beep()
                            return
                        }
                        do {
                            try capture.start(device: devices.resolved()?.id)
                            lifecycle.isCapturing = true
                            FileHandle.standardError.write(Data("● recording\n".utf8))
                            MainActor.assumeIsolated {
                                overlay?.show(.recording)
                                menuBar.setRecording(true)
                            }
                        } catch {
                            FileHandle.standardError.write(Data("capture failed: \(error)\n".utf8))
                        }
                    case .released:
                        guard lifecycle.isCapturing else { return }
                        lifecycle.isCapturing = false
                        lifecycle.isProcessing = true
                        let samples = capture.stop()
                        MainActor.assumeIsolated {
                            overlay?.show(.transcribing)
                            menuBar.setTranscribing()
                        }
                        let seconds = Double(samples.count) / AudioCapture.targetSampleRate
                        let rms = computeRMS(samples)
                        FileHandle.standardError.write(Data(
                            String(format: "○ captured %.2fs · rms %.3f\n", seconds, rms).utf8
                        ))
                        if dumpWav, !samples.isEmpty {
                            do {
                                let path = try dumpWavPath()
                                try WAVWriter.write(samples: samples, sampleRate: 16_000, to: path)
                                FileHandle.standardError.write(Data("  wrote \(path)\n".utf8))
                            } catch {
                                FileHandle.standardError.write(Data("  wav write failed: \(error)\n".utf8))
                            }
                        }
                        guard !samples.isEmpty else {
                            lifecycle.isProcessing = false
                            MainActor.assumeIsolated {
                                overlay?.hide()
                                menuBar.setRecording(false)
                            }
                            return
                        }
                        let active = MainActor.assumeIsolated { holder.transcriber }
                        let languagePair = MainActor.assumeIsolated { translation.beginRequest() }
                        Task {
                            let started = Date()
                            do {
                                let text = try await active.transcribe(samples)
                                var output = text
                                if let languagePair, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                    await MainActor.run {
                                        overlay?.show(.translating)
                                        menuBar.setTranslating(to: languagePair.target)
                                    }
                                    do {
                                        output = try await translation.translate(text, languages: languagePair)
                                    } catch {
                                        FileHandle.standardError.write(Data("translation failed — original available in menu\n".utf8))
                                        await MainActor.run {
                                            translation.endRequest()
                                            lifecycle.isProcessing = false
                                            overlay?.hide()
                                            menuBar.setTranslationFailed()
                                        }
                                        return
                                    }
                                }
                                let elapsed = Date().timeIntervalSince(started)
                                let line = echoTranscripts
                                    ? String(format: "→ %.2fs · %@\n", elapsed, output)
                                    : String(format: "→ %.2fs · %ld chars\n", elapsed, output.count)
                                FileHandle.standardError.write(Data(line.utf8))
                                let finalOutput = output
                                await MainActor.run {
                                    TextInjector.inject(finalOutput, mode: injectMode)
                                    if languagePair != nil { translation.endRequest() }
                                    lifecycle.isProcessing = false
                                    overlay?.hide()
                                    menuBar.setRecording(false)
                                }
                            } catch {
                                FileHandle.standardError.write(Data("transcription failed: \(error)\n".utf8))
                                await MainActor.run {
                                    if languagePair != nil { translation.endRequest() }
                                    lifecycle.isProcessing = false
                                    overlay?.hide()
                                    menuBar.setRecording(false)
                                }
                            }
                        }
                    }
                }
            }
        } catch {
            FileHandle.standardError.write(Data("failed to register hotkey tap: \(error)\n".utf8))
            FileHandle.standardError.write(Data("run `parrot setup` to configure permissions.\n".utf8))
            // Exit 0: a missing permission is not transient, and the LaunchAgent's
            // KeepAlive would otherwise restart us into an endless prompt loop.
            throw ExitCode(0)
        }

        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        sigint.setEventHandler {
            FileHandle.standardError.write(Data("\nshutting down\n".utf8))
            monitor.stop()
            NSApp.terminate(nil)
        }
        sigint.resume()
        signal(SIGINT, SIG_IGN)

        FileHandle.standardError.write(Data(
            "listening on \(selectedHotkey.rawValue) hold · model: \(chosenModel.id) · ^C to quit\n".utf8
        ))
        app.run()
    }
}

/// Hotkey callbacks and completion handlers share one main-actor lifecycle.
@MainActor
final class DictationLifecycle {
    var isCapturing = false
    var isProcessing = false
}

/// Mutable seat for the live transcriber, so the model can be swapped from the
/// menu bar without restarting the daemon. Main-thread only: both the menu
/// callbacks and the hotkey events are delivered on the main queue.
@MainActor
final class TranscriberHolder {
    var transcriber: any Transcriber

    init(_ transcriber: any Transcriber) {
        self.transcriber = transcriber
    }
}

/// Warms the new model up in the background — it may have to download hundreds
/// of megabytes — and only then takes it into use. Dictation keeps working with
/// the previous model in the meantime, and a failure leaves it untouched.
@MainActor
private func switchModel(
    to newModel: TranscriptionModel,
    holder: TranscriberHolder,
    menuBar: MenuBarController
) {
    let candidate = TranscriberFactory.make(for: newModel)
    Task {
        do {
            try await candidate.warmUp()
            holder.transcriber = candidate
            ModelPreferences.selected = newModel
            menuBar.modelSwitchSucceeded(newModel)
            FileHandle.standardError.write(Data("model: \(newModel.id)\n".utf8))
        } catch {
            FileHandle.standardError.write(
                Data("switching to \(newModel.id) failed: \(error)\n".utf8)
            )
            menuBar.modelSwitchFailed()
        }
    }
}

extension HotkeyMonitor.Hotkey: ExpressibleByArgument {}
extension TextInjector.Mode: ExpressibleByArgument {}

/// Destination for `--dump-wav`. Recorded audio is as sensitive as the
/// transcript, so it stays out of world-readable /tmp.
private func dumpWavPath() throws -> String {
    let fm = FileManager.default
    let dir = fm.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/parrot", isDirectory: true)
    try fm.createDirectory(
        at: dir,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    // createDirectory doesn't retighten a directory that already exists.
    try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)

    let path = dir.appendingPathComponent("last-capture.wav").path
    // Pre-create 0600; a plain write would land under the process umask (0644).
    _ = fm.createFile(atPath: path, contents: nil, attributes: [.posixPermissions: 0o600])
    return path
}

struct Doctor: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Check microphone, accessibility, and Fn key configuration."
    )

    func run() throws {
        let checks = DoctorReport.run()
        DoctorReport.print(checks)
        if !DoctorReport.allOK(checks) {
            throw ExitCode(1)
        }
    }
}

struct Models: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Manage transcription models.",
        subcommands: [List.self, Download.self]
    )

    struct List: ParsableCommand {
        func run() throws {
            // Column width follows the longest id: `padding(toLength:)` truncates
            // when the string is longer, and a truncated id cannot be copied into
            // `parrot models download`.
            let width = ModelRegistry.shared.map(\.id.count).max() ?? 26
            for m in ModelRegistry.shared {
                let star = m.recommended ? "★" : " "
                let id = m.id.padding(toLength: width, withPad: " ", startingAt: 0)
                let langs = "[\(m.languages.joined(separator: ","))]"
                    .padding(toLength: 9, withPad: " ", startingAt: 0)
                let size = String(format: "%5d MB", m.sizeMB)
                print("\(star) \(id) \(size)  \(langs)  \(m.displayName)")
            }
        }
    }

    struct Download: ParsableCommand {
        @Argument(help: "Model id to download.") var id: String

        func run() throws {
            guard let m = ModelRegistry.find(id) else {
                print("unknown model: \(id)")
                throw ExitCode(1)
            }
            let t = TranscriberFactory.make(for: m)

            let sem = DispatchSemaphore(value: 0)
            var capturedError: Error?
            Task.detached {
                do { try await t.warmUp() } catch { capturedError = error }
                sem.signal()
            }
            sem.wait()
            if let e = capturedError { throw e }
        }
    }
}
