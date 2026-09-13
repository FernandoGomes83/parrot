import Foundation

enum OverlayStyle: String, CaseIterable {
    case simple
    case reactor

    var displayName: String {
        switch self {
        case .simple: return "Simple"
        case .reactor: return "Reactor"
        }
    }

    var size: CGSize {
        switch self {
        case .simple: return CGSize(width: 96, height: 44)
        case .reactor: return CGSize(width: 124, height: 124)
        }
    }
}

enum OverlayPreferences {
    private static let key = "recordingOverlayStyle"

    static var selected: OverlayStyle {
        get {
            guard let rawValue = UserDefaults.standard.string(forKey: key),
                  let style = OverlayStyle(rawValue: rawValue)
            else { return .reactor }
            return style
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: key)
        }
    }
}
