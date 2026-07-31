import FluidAudio
import Foundation

/// Parakeet TDT 0.6B v3 (multilingual, 25 languages) via FluidAudio's CoreML
/// pipeline. Faster than Whisper on Apple Silicon and — unlike the `.en`
/// Whisper models — understands Portuguese out of the box.
actor ParakeetTranscriber: Transcriber {
    /// Same rationale as WhisperKitTranscriber.modelStore: keep weights out of
    /// `Documents`, which iCloud replicates and evicts. FluidAudio derives the
    /// repo folder from the last path component, so it must be the repo's
    /// folder name — passing anything else makes the downloader and the loader
    /// disagree about where the files are.
    private static let modelStore = URL.applicationSupportDirectory
        .appending(path: "parrot/fluidaudio/parakeet-tdt-0.6b-v3-coreml")

    let modelID: String
    private var manager: AsrManager?

    init(model: TranscriptionModel) {
        self.modelID = model.id
    }

    /// Downloads (first run) and loads the CoreML bundles. Call at startup so
    /// the first hotkey press isn't blocked on a ~480 MB download.
    func warmUp() async throws {
        if manager != nil { return }
        FileHandle.standardError.write(Data("loading \(modelID)...\n".utf8))
        let models = try await AsrModels.downloadAndLoad(to: Self.modelStore, version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.manager = manager
        FileHandle.standardError.write(Data("✓ \(modelID) ready\n".utf8))
    }

    func transcribe(_ audio: [Float]) async throws -> String {
        if manager == nil { try await warmUp() }
        guard let manager else { throw TranscriberError.notLoaded }

        // Each dictation is an independent utterance, so start from a clean TDT
        // decoder state instead of carrying context across hotkey presses.
        var state = try TdtDecoderState()
        let result = try await manager.transcribe(audio, decoderState: &state)
        // No sanitize pass: Parakeet emits plain text, not Whisper's
        // [BLANK_AUDIO]/(music) placeholders, and stripping bracketed spans
        // would eat legitimately dictated parentheses.
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
