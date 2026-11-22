import AppKit

/// Colors for the code editor, resolved for the current appearance.
///
/// Every color is created with `NSColor(name:dynamicProvider:)`, so the editor
/// follows the system light/dark setting without any manual bookkeeping.
public enum EditorTheme {

    public static let background = dynamic("RideCPP.background") { $0.isDark ? NSColor(white: 0.11, alpha: 1) : NSColor.white }
    public static let plainText = dynamic("RideCPP.plain") { $0.isDark ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.11, alpha: 1) }
    public static let selection = dynamic("RideCPP.selection") { $0.isDark ? NSColor(red: 0.20, green: 0.36, blue: 0.58, alpha: 1) : NSColor(red: 0.73, green: 0.84, blue: 0.99, alpha: 1) }
    public static let currentLine = dynamic("RideCPP.currentLine") { $0.isDark ? NSColor(white: 1, alpha: 0.045) : NSColor(white: 0, alpha: 0.045) }
    public static let cursor = dynamic("RideCPP.cursor") { $0.isDark ? NSColor(white: 0.95, alpha: 1) : NSColor(white: 0.05, alpha: 1) }

    public static let keyword = dynamic("RideCPP.keyword") { $0.isDark ? NSColor(red: 1.00, green: 0.48, blue: 0.62, alpha: 1) : NSColor(red: 0.68, green: 0.10, blue: 0.42, alpha: 1) }
    public static let type = dynamic("RideCPP.type") { $0.isDark ? NSColor(red: 0.46, green: 0.83, blue: 0.98, alpha: 1) : NSColor(red: 0.07, green: 0.42, blue: 0.60, alpha: 1) }
    public static let number = dynamic("RideCPP.number") { $0.isDark ? NSColor(red: 0.99, green: 0.78, blue: 0.44, alpha: 1) : NSColor(red: 0.70, green: 0.38, blue: 0.00, alpha: 1) }
    public static let string = dynamic("RideCPP.string") { $0.isDark ? NSColor(red: 0.60, green: 0.88, blue: 0.53, alpha: 1) : NSColor(red: 0.13, green: 0.48, blue: 0.13, alpha: 1) }
    public static let character = dynamic("RideCPP.character") { $0.isDark ? NSColor(red: 0.60, green: 0.88, blue: 0.53, alpha: 1) : NSColor(red: 0.13, green: 0.48, blue: 0.13, alpha: 1) }
    public static let comment = dynamic("RideCPP.comment") { $0.isDark ? NSColor(red: 0.48, green: 0.58, blue: 0.49, alpha: 1) : NSColor(red: 0.36, green: 0.45, blue: 0.36, alpha: 1) }
    public static let preprocessor = dynamic("RideCPP.preprocessor") { $0.isDark ? NSColor(red: 0.86, green: 0.66, blue: 0.98, alpha: 1) : NSColor(red: 0.48, green: 0.19, blue: 0.68, alpha: 1) }
    public static let punctuation = dynamic("RideCPP.punctuation") { $0.isDark ? NSColor(white: 0.72, alpha: 1) : NSColor(white: 0.30, alpha: 1) }
    public static let errorUnderline = NSColor.systemRed

    public static let lineNumberText = dynamic("RideCPP.lineNumber") { $0.isDark ? NSColor(white: 0.52, alpha: 1) : NSColor(white: 0.52, alpha: 1) }
    public static let lineNumberActiveText = dynamic("RideCPP.lineNumberActive") { $0.isDark ? NSColor(white: 0.85, alpha: 1) : NSColor(white: 0.20, alpha: 1) }
    public static let lineNumberBackground = dynamic("RideCPP.lineNumberBackground") { $0.isDark ? NSColor(white: 0.155, alpha: 1) : NSColor(white: 0.962, alpha: 1) }
    public static let lineNumberSeparator = dynamic("RideCPP.lineNumberSeparator") { $0.isDark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.11) }

    /// Resolves a syntax color for a token kind.
    public static func color(for kind: SyntaxToken.Kind) -> NSColor {
        switch kind {
        case .keyword: return keyword
        case .type: return type
        case .number: return number
        case .string: return string
        case .character: return character
        case .comment: return comment
        case .preprocessor: return preprocessor
        case .punctuation: return punctuation
        case .identifier: return plainText
        }
    }

    public static func font(size: CGFloat) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    public static func lineNumberFont(size: CGFloat) -> NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: max(9, size - 2), weight: .regular)
    }

    private static func dynamic(_ name: String, provider: @escaping (EffectiveAppearance) -> NSColor) -> NSColor {
        NSColor(name: NSColor.Name(name)) { appearance in
            let match = appearance.bestMatch(from: [.aqua, .darkAqua])
            return provider(EffectiveAppearance(isDark: match == .darkAqua))
        }
    }

    struct EffectiveAppearance {
        let isDark: Bool
    }
}
