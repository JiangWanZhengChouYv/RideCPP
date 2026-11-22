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
}
