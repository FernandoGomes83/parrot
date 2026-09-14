import Foundation
import XCTest
@testable import ParrotTranslation
@testable import parrot

private actor StubTranslator: TextTranslating {
    enum Failure: Error { case unavailable }
    private(set) var loads = 0
    private(set) var unloads = 0
    var shouldFail = false
    var output = "Translated text"

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        loads += 1
        progress(0.5)
        try await Task.sleep(nanoseconds: 20_000_000)
        progress(1)
    }
    func translate(_ text: String, languages: TranslationPair) async throws -> String {
        if shouldFail { throw Failure.unavailable }
        return output
    }
    func unload() async { unloads += 1 }
    func failNext() { shouldFail = true }
    func returnEmpty() { output = "  \n" }
}

@MainActor
final class TranslationTests: XCTestCase {
    private func preferences() -> (TranslationPreferences, UserDefaults, String) {
        let suite = "parrot.translation.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        return (TranslationPreferences(defaults: defaults), defaults, suite)
    }

    private func waitUntilReady(_ coordinator: TranslationCoordinator) async throws {
        for _ in 0..<100 {
            if coordinator.state == .ready { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("Translation never became ready")
    }

    func testCodeCurrencyAndNumbersRoundTripExactly() throws {
        let original = "Execute `pnpm test` em 14/10 às 14:30. Custa R$ 250,00.\n```swift\nlet count = 12\n```"
        let protected = ProtectedTranslationInput(original)
        XCTAssertFalse(protected.text.contains("pnpm test"))
        XCTAssertFalse(protected.text.contains("250,00"))
        XCTAssertEqual(try protected.restoring(in: protected.text), original)
    }

    func testUnquotedTechnicalIdentifiersRemainProtected() throws {
        let original = "Não altere API_KEY, fetchUser() ou config.json em /api/v1/users."
        let protected = ProtectedTranslationInput(original)
        for literal in ["API_KEY", "fetchUser()", "config.json", "/api/v1/users"] {
            XCTAssertFalse(protected.text.contains(literal))
        }
        XCTAssertTrue(protected.text.hasSuffix("__."))
        XCTAssertEqual(try protected.restoring(in: protected.text), original)
    }

    func testMissingOrDuplicatedLiteralRejectsTheTranslation() {
        let protected = ProtectedTranslationInput("Valor: R$ 250,00")
        XCTAssertThrowsError(try protected.restoring(in: "Value: 250"))
        XCTAssertThrowsError(try protected.restoring(in: protected.text + protected.text))
    }

    func testExistingMarkerTextCannotCollideWithGeneratedPlaceholders() throws {
        let original = "Preserve __PARROT_LITERAL_0__ e `API_KEY`."
        let protected = ProtectedTranslationInput(original)
        XCTAssertEqual(try protected.restoring(in: protected.text), original)
    }

    func testPreferencesSurviveRecreationAndInvalidLanguagesFallBack() {
        let (prefs, defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertFalse(prefs.enabled)
        XCTAssertEqual(prefs.languages, TranslationPair(source: .portuguese, target: .english))
        prefs.enabled = true
        prefs.source = .french
        prefs.target = .spanish
        let restored = TranslationPreferences(defaults: defaults)
        XCTAssertTrue(restored.enabled)
        XCTAssertEqual(restored.languages, TranslationPair(source: .french, target: .spanish))
        defaults.set("unknown", forKey: "translationTargetLanguage")
        XCTAssertEqual(restored.target, .english)
    }

    func testDisabledAndPreparingModesKeepOriginalDictationAvailable() async throws {
        let (prefs, defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = StubTranslator()
        let coordinator = TranslationCoordinator(preferences: prefs, engine: engine)
        coordinator.restore()
        XCTAssertNil(coordinator.beginRequest())
        let loads = await engine.loads
        XCTAssertEqual(loads, 0)
        coordinator.toggle()
        XCTAssertNil(coordinator.beginRequest())
        try await waitUntilReady(coordinator)
        // A late progress callback must not turn Ready back into Preparing.
        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(coordinator.state, .ready)
        XCTAssertNotNil(coordinator.beginRequest())
        coordinator.endRequest()
        coordinator.toggle()
    }

    func testLanguageChangeAndDisableDoNotInvalidateAnInFlightRequest() async throws {
        let (prefs, defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = StubTranslator()
        let coordinator = TranslationCoordinator(preferences: prefs, engine: engine)
        coordinator.toggle()
        try await waitUntilReady(coordinator)
        let captured = try XCTUnwrap(coordinator.beginRequest())
        coordinator.setTarget(.japanese)
        coordinator.toggle()
        XCTAssertEqual(captured.target, .english)
        XCTAssertNil(coordinator.beginRequest())
        let before = await engine.unloads
        XCTAssertEqual(before, 0)
        let output = try await coordinator.translate("Texto original", languages: captured)
        XCTAssertEqual(output, "Translated text")
        coordinator.endRequest()
        try await Task.sleep(nanoseconds: 30_000_000)
        let after = await engine.unloads
        XCTAssertEqual(after, 1)
    }

    func testRapidOffAndOnCannotPublishStaleSetupState() async throws {
        let (prefs, defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let coordinator = TranslationCoordinator(preferences: prefs, engine: StubTranslator())
        coordinator.toggle()
        coordinator.toggle()
        coordinator.toggle()
        try await waitUntilReady(coordinator)
        XCTAssertTrue(prefs.enabled)
        coordinator.setTarget(.portuguese)
        XCTAssertNil(coordinator.beginRequest())
        coordinator.toggle()
    }

    func testFailurePreservesOriginalUntilUserCopiesIt() async throws {
        let (prefs, defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = StubTranslator()
        await engine.failNext()
        let coordinator = TranslationCoordinator(preferences: prefs, engine: engine)
        coordinator.toggle()
        try await waitUntilReady(coordinator)
        let pair = try XCTUnwrap(coordinator.beginRequest())
        let original = "Altere fetchUser(), sem mexer em API_KEY."
        do {
            _ = try await coordinator.translate(original, languages: pair)
            XCTFail("Expected translation failure")
        } catch {}
        coordinator.endRequest()
        XCTAssertEqual(coordinator.failedOriginal, original)
        XCTAssertEqual(coordinator.takeOriginal(), original)
        XCTAssertNil(coordinator.takeOriginal())
        coordinator.toggle()
    }

    func testEmptyModelOutputIsNeverTreatedAsSuccessfulTranslation() async throws {
        let (prefs, defaults, suite) = preferences()
        defer { defaults.removePersistentDomain(forName: suite) }
        let engine = StubTranslator()
        await engine.returnEmpty()
        let coordinator = TranslationCoordinator(preferences: prefs, engine: engine)
        do {
            _ = try await coordinator.translate("Original", languages: prefs.languages)
            XCTFail("Expected empty output failure")
        } catch {
            XCTAssertEqual(error as? TranslationError, .emptyOutput)
        }
        XCTAssertEqual(coordinator.failedOriginal, "Original")
    }
}
