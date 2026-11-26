import Foundation

/// Thin wrapper over `NSLocalizedString` so views stay readable and every
/// user-visible string lives in the `.strings` files.
public enum L10n {
    public static func t(_ key: String) -> String {
        NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: "")
    }

    public static func t(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: NSLocalizedString(key, tableName: nil, bundle: .main, value: key, comment: ""), arguments: arguments)
    }

    /// Menu title for the editor-only commands (comment, indent, format).
    public static var codeMenuTitle: String { t("menu.edit") }

    /// Display name of this build.
    ///
    /// Prefers the bundle's own name over the localized `app.name`: a renamed
    /// copy (the "/Applications/RideCpp-Test" build used for trying builds) must
    /// identify itself, or its window would claim to be the stable app and the
    /// two would be impossible to tell apart.
    public static var appName: String {
        guard let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
              !name.isEmpty else { return t("app.name") }
        return name
    }
}
