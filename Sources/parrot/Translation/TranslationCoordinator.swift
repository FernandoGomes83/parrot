import Foundation
import ParrotTranslation

/// Owns setup, preferences, and recovery. A language pair is captured for each
/// dictation; menu changes apply to subsequent requests. No transcript is logged.
@MainActor
final class TranslationCoordinator {
    enum State: Equatable {
        case off
        case preparing(Int)
        case ready
        case failed
    }

    let preferences: TranslationPreferences
    private let engine: any TextTranslating
    private var work: Task<Void, Never>?
    private var revision = 0
    private var activeRequests = 0
    private(set) var state: State = .off
    private(set) var setupFailure: String?
    private(set) var failedOriginal: String?
    private(set) var failureDescription: String?
    var onChange: (() -> Void)?

    init(preferences: TranslationPreferences = TranslationPreferences(), engine: any TextTranslating) {
        self.preferences = preferences
        self.engine = engine
    }

    func restore() {
        if preferences.enabled { startSetup() }
    }

    func toggle() {
        preferences.enabled.toggle()
        if preferences.enabled {
            startSetup()
        } else {
            revision += 1
            work?.cancel()
            state = .off
            if activeRequests == 0 { scheduleUnload() }
            onChange?()
        }
    }

    func setSource(_ language: TranslationLanguage) {
        preferences.source = language
        onChange?()
    }

    func setTarget(_ language: TranslationLanguage) {
        preferences.target = language
        onChange?()
    }

    /// Normal dictation stays available while the optional model is being set up.
    func beginRequest() -> TranslationPair? {
        guard preferences.enabled, state == .ready else { return nil }
        let pair = preferences.languages
        guard pair.source != pair.target else { return nil }
        activeRequests += 1
        return pair
    }

    func endRequest() {
        activeRequests = max(0, activeRequests - 1)
        if activeRequests == 0, !preferences.enabled { scheduleUnload() }
    }

    func translate(_ text: String, languages: TranslationPair) async throws -> String {
        do {
            let output = try await engine.translate(text, languages: languages)
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw TranslationError.emptyOutput
            }
            return output
        } catch {
            failedOriginal = text
            failureDescription = (error as? TranslationError)?.localizedDescription
                ?? "Translation failed. You can copy the original dictation below."
            onChange?()
            throw error
        }
    }

    func takeOriginal() -> String? {
        let text = failedOriginal
        failedOriginal = nil
        failureDescription = nil
        onChange?()
        return text
    }

    private func startSetup() {
        revision += 1
        let current = revision
        let previous = work
        previous?.cancel()
        setupFailure = nil
        state = .preparing(0)
        onChange?()
        let engine = self.engine
        work = Task { [weak self] in
            // Finish a cancelled download/unload before another attempt touches
            // the same files or model. Cancelling never marks a partial cache ready.
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await engine.prepare { [weak self] fraction in
                    guard fraction.isFinite else { return }
                    let percent = Int(min(1, max(0, fraction)) * 100)
                    Task { @MainActor [weak self] in
                        guard let self, self.revision == current,
                              case .preparing = self.state,
                              self.state != .preparing(percent) else { return }
                        self.state = .preparing(percent)
                        self.onChange?()
                    }
                }
                try Task.checkCancellation()
                guard let self, self.revision == current else { return }
                self.state = .ready
                self.onChange?()
            } catch {
                guard let self, self.revision == current, !Task.isCancelled else { return }
                self.preferences.enabled = false
                self.setupFailure = (error as? TranslationError)?.localizedDescription
                    ?? "The translator could not be downloaded or loaded. Check your connection and enable translation to retry."
                self.state = .failed
                self.onChange?()
            }
        }
    }

    private func scheduleUnload() {
        let previous = work
        let engine = self.engine
        work = Task {
            await previous?.value
            guard !Task.isCancelled else { return }
            await engine.unload()
        }
    }
}
