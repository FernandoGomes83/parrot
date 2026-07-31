import Foundation

protocol Transcriber: Sendable {
    var modelID: String { get }
    /// Load (downloading first if needed) the model so the first transcription
    /// isn't blocked on it.
    func warmUp() async throws
    func transcribe(_ audio: [Float]) async throws -> String
}

enum TranscriberFactory {
    static func make(for model: TranscriptionModel) -> any Transcriber {
        switch model.engine {
        case .whisperKit: WhisperKitTranscriber(model: model)
        case .parakeet: ParakeetTranscriber(model: model)
        }
    }
}
