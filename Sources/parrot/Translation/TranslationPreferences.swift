import Foundation
import ParrotTranslation

final class TranslationPreferences {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var enabled: Bool {
        get { defaults.bool(forKey: "translationEnabled") }
        set { defaults.set(newValue, forKey: "translationEnabled") }
    }

    var source: TranslationLanguage {
        get {
            defaults.string(forKey: "translationSourceLanguage")
                .flatMap(TranslationLanguage.init(rawValue:)) ?? .portuguese
        }
        set { defaults.set(newValue.rawValue, forKey: "translationSourceLanguage") }
    }

    var target: TranslationLanguage {
        get {
            defaults.string(forKey: "translationTargetLanguage")
                .flatMap(TranslationLanguage.init(rawValue:)) ?? .english
        }
        set { defaults.set(newValue.rawValue, forKey: "translationTargetLanguage") }
    }

    var languages: TranslationPair {
        TranslationPair(source: source, target: target)
    }
}
