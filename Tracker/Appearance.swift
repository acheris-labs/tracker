import AppKit

/// Which appearance the app renders in: follow the system (default) or pin
/// light/dark regardless of System Settings.
enum AppearanceMode: String, CaseIterable {
    case auto, light, dark

    static let key = "Appearance"

    var label: String {
        switch self {
        case .auto:  return "Auto"
        case .light: return "Light"
        case .dark:  return "Dark"
        }
    }

    /// nil hands the choice back to the system, which is what makes "auto"
    /// track System Settings live — NSApp.effectiveAppearance follows it.
    var nsAppearance: NSAppearance? {
        switch self {
        case .auto:  return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark:  return NSAppearance(named: .darkAqua)
        }
    }

    static func load() -> AppearanceMode {
        UserDefaults.standard.string(forKey: key)
            .flatMap(AppearanceMode.init(rawValue:)) ?? .auto
    }

    func apply() {
        UserDefaults.standard.set(rawValue, forKey: Self.key)
        NSApp.appearance = nsAppearance
    }

    /// What the app is actually rendering as right now, with `.auto` resolved.
    static var isLight: Bool { NSApp.effectiveAppearance.isLight }

    /// The *system's* appearance, ignoring any app-level override. The dock
    /// tile is drawn onto the Dock's own material, which follows System
    /// Settings — a light card pinned by the app would glare on a dark Dock.
    static var systemIsLight: Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle")?
            .caseInsensitiveCompare("dark") != .orderedSame
    }
}

extension NSAppearance {
    /// Any of the several light variants (aqua, high-contrast aqua, vibrant
    /// light) counts as light — only the dark family needs the dark palette.
    var isLight: Bool { bestMatch(from: [.aqua, .darkAqua]) != .darkAqua }
}
