import Foundation

enum ModelPreferences {
    private static let key = "modelID"

    /// The model chosen from the menu bar, or nil to follow the recommended
    /// one. An id that no longer exists in the registry reads back as nil.
    static var selected: TranscriptionModel? {
        get {
            guard let id = UserDefaults.standard.string(forKey: key) else { return nil }
            return ModelRegistry.find(id)
        }
        set {
            if let newValue {
                UserDefaults.standard.set(newValue.id, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }
}
