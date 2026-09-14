import Foundation

/// Language codes accepted by the local translation model's chat template.
public enum TranslationLanguage: String, CaseIterable, Sendable {
    case english = "en"
    case portuguese = "pt-BR"
    case spanish = "es"
    case french = "fr"
    case german = "de"
    case italian = "it"
    case dutch = "nl"
    case polish = "pl"
    case swedish = "sv"
    case danish = "da"
    case norwegian = "no"
    case finnish = "fi"
    case czech = "cs"
    case romanian = "ro"
    case greek = "el"
    case turkish = "tr"
    case russian = "ru"
    case ukrainian = "uk"
    case arabic = "ar"
    case hebrew = "he"
    case hindi = "hi"
    case chinese = "zh-Hans"
    case japanese = "ja"
    case korean = "ko"
    case vietnamese = "vi"
    case indonesian = "id"

    public var displayName: String {
        switch self {
        case .english: return "English"
        case .portuguese: return "Portuguese (Brazil)"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .german: return "German"
        case .italian: return "Italian"
        case .dutch: return "Dutch"
        case .polish: return "Polish"
        case .swedish: return "Swedish"
        case .danish: return "Danish"
        case .norwegian: return "Norwegian"
        case .finnish: return "Finnish"
        case .czech: return "Czech"
        case .romanian: return "Romanian"
        case .greek: return "Greek"
        case .turkish: return "Turkish"
        case .russian: return "Russian"
        case .ukrainian: return "Ukrainian"
        case .arabic: return "Arabic"
        case .hebrew: return "Hebrew"
        case .hindi: return "Hindi"
        case .chinese: return "Chinese (Simplified)"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .vietnamese: return "Vietnamese"
        case .indonesian: return "Indonesian"
        }
    }
}

public struct TranslationPair: Equatable, Sendable {
    public let source: TranslationLanguage
    public let target: TranslationLanguage

    public init(source: TranslationLanguage, target: TranslationLanguage) {
        self.source = source
        self.target = target
    }
}

public protocol TextTranslating: Sendable {
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func translate(_ text: String, languages: TranslationPair) async throws -> String
    func unload() async
}

public enum TranslationError: Error, LocalizedError, Equatable {
    case notReady
    case missingShaders
    case gpuUnavailable
    case inputTooLong
    case incompleteOutput
    case emptyOutput
    case alteredLiteral

    public var errorDescription: String? {
        switch self {
        case .notReady: return "The translation model is not ready."
        case .gpuUnavailable: return "The Mac GPU is not available for local translation."
        case .missingShaders: return "The translation runtime is missing. Reinstall Parrot using the full release package."
        case .inputTooLong: return "This dictation is too long to translate in one request. Try shorter passages."
        case .incompleteOutput: return "The model did not finish the translation. Your original dictation is available in the menu."
        case .alteredLiteral: return "The translation changed a code or numeric placeholder. Your original dictation is available in the menu."
        case .emptyOutput: return "The model returned an empty translation. Your original dictation is available in the menu."
        }
    }
}
