import Foundation

public enum AppLanguage {
    public static let defaultsKey = "appLanguage"

    /// Use the device's primary language on first launch, English for other languages.
    public static func detect(_ preferredLanguages: [String]) -> String {
        let primary = preferredLanguages.first?.lowercased().replacingOccurrences(of: "_", with: "-") ?? "en"
        return primary.split(separator: "-").first == "fr" ? "fr" : "en"
    }

    public static func initialize(defaults: UserDefaults = .standard, preferredLanguages: [String] = Locale.preferredLanguages) {
        guard !["fr", "en"].contains(defaults.string(forKey: defaultsKey) ?? "") else { return }
        defaults.set(detect(preferredLanguages), forKey: defaultsKey)
    }

    public static var current: String {
        let stored = UserDefaults.standard.string(forKey: defaultsKey)
        return ["fr", "en"].contains(stored ?? "") ? stored! : detect(Locale.preferredLanguages)
    }

    public static var locale: Locale { Locale(identifier: current) }
}

/// Explicit bilingual strings also cover errors originating outside SwiftUI.
public func L(_ french: String, _ english: String) -> String {
    AppLanguage.current == "fr" ? french : english
}
