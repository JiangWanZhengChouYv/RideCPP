import AppKit
import EditorCore

/// Colors for the code editor, resolved for the current appearance.
///
/// Every color is created with `NSColor(name:dynamicProvider:)`, so the editor
/// follows the system light/dark setting without any manual bookkeeping.
public enum EditorTheme {

    public static let background = theme("background", light: .white, dark: NSColor(white: 0.11, alpha: 1))
    public static let plainText = theme("plain",
                                        light: NSColor(white: 0.11, alpha: 1),
                                        dark: NSColor(white: 0.88, alpha: 1))
    public static let selection = theme("selection",
                                        light: NSColor(red: 0.73, green: 0.84, blue: 0.99, alpha: 1),
                                        dark: NSColor(red: 0.20, green: 0.36, blue: 0.58, alpha: 1))
    public static let currentLine = theme("currentLine",
                                          light: NSColor(white: 0, alpha: 0.045),
                                          dark: NSColor(white: 1, alpha: 0.045))
    public static let cursor = theme("cursor",
                                     light: NSColor(white: 0.05, alpha: 1),
                                     dark: NSColor(white: 0.95, alpha: 1))

    public static let keyword = theme("keyword",
                                      light: NSColor(red: 0.68, green: 0.10, blue: 0.42, alpha: 1),
                                      dark: NSColor(red: 1.00, green: 0.48, blue: 0.62, alpha: 1))
    public static let type = theme("type",
                                   light: NSColor(red: 0.07, green: 0.42, blue: 0.60, alpha: 1),
                                   dark: NSColor(red: 0.46, green: 0.83, blue: 0.98, alpha: 1))
    public static let number = theme("number",
                                     light: NSColor(red: 0.70, green: 0.38, blue: 0.00, alpha: 1),
                                     dark: NSColor(red: 0.99, green: 0.78, blue: 0.44, alpha: 1))
    public static let string = theme("string",
                                     light: NSColor(red: 0.13, green: 0.48, blue: 0.13, alpha: 1),
                                     dark: NSColor(red: 0.60, green: 0.88, blue: 0.53, alpha: 1))
    public static let character = string
    public static let comment = theme("comment",
                                      light: NSColor(red: 0.36, green: 0.45, blue: 0.36, alpha: 1),
                                      dark: NSColor(red: 0.48, green: 0.58, blue: 0.49, alpha: 1))
    public static let preprocessor = theme("preprocessor",
                                           light: NSColor(red: 0.48, green: 0.19, blue: 0.68, alpha: 1),
                                           dark: NSColor(red: 0.86, green: 0.66, blue: 0.98, alpha: 1))
    public static let punctuation = theme("punctuation",
                                          light: NSColor(white: 0.30, alpha: 1),
                                          dark: NSColor(white: 0.72, alpha: 1))
    public static let errorUnderline = NSColor.systemRed
    public static let warningUnderline = NSColor.systemOrange

    /// Tint behind an offending token.
    ///
    /// A dotted underline alone is easy to miss while reading code, which is why
    /// IDEs wash the token itself. Kept translucent so the syntax colouring
    /// underneath is still legible.
    public static let errorBackground = theme("errorBackground",
                                              light: NSColor.systemRed.withAlphaComponent(0.22),
                                              dark: NSColor.systemRed.withAlphaComponent(0.34))
    public static let warningBackground = theme("warningBackground",
                                                light: NSColor.systemOrange.withAlphaComponent(0.22),
                                                dark: NSColor.systemOrange.withAlphaComponent(0.32))

    /// Grey used for clangd's advisory labels inside the code.
    public static let inlayHint = theme("inlayHint",
                                        light: NSColor(white: 0.45, alpha: 1),
                                        dark: NSColor(white: 0.55, alpha: 1))

    /// Background for every search match, and a stronger one for the selected
    /// match. Translucent so the token underneath stays readable.
    public static let findMatch = theme("findMatch",
                                        light: NSColor.systemYellow.withAlphaComponent(0.35),
                                        dark: NSColor.systemYellow.withAlphaComponent(0.30))
    public static let findCurrentMatch = theme("findCurrentMatch",
                                               light: NSColor.systemOrange.withAlphaComponent(0.55),
                                               dark: NSColor.systemOrange.withAlphaComponent(0.50))

    /// Text colour for an offending token: red rather than the syntax colour, so
    /// the eye lands on it from across the line.
    public static let errorText = theme("errorText",
                                        light: NSColor(red: 0.72, green: 0.08, blue: 0.10, alpha: 1),
                                        dark: NSColor(red: 1.00, green: 0.52, blue: 0.50, alpha: 1))
    public static let warningText = theme("warningText",
                                          light: NSColor(red: 0.62, green: 0.32, blue: 0.00, alpha: 1),
                                          dark: NSColor(red: 1.00, green: 0.72, blue: 0.36, alpha: 1))

    public static let lineNumberText = theme("lineNumber",
                                             light: NSColor(white: 0.52, alpha: 1),
                                             dark: NSColor(white: 0.52, alpha: 1))
    public static let lineNumberActiveText = theme("lineNumberActive",
                                                   light: NSColor(white: 0.20, alpha: 1),
                                                   dark: NSColor(white: 0.85, alpha: 1))
    public static let lineNumberBackground = theme("lineNumberBackground",
                                                   light: NSColor(white: 0.962, alpha: 1),
                                                   dark: NSColor(white: 0.155, alpha: 1))
    public static let lineNumberSeparator = theme("lineNumberSeparator",
                                                  light: NSColor(white: 0, alpha: 0.11),
                                                  dark: NSColor(white: 1, alpha: 0.12))

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

    /// Builds one colour from explicit light and dark variants.
    ///
    /// Keeping the two variants on separate lines makes the palette readable and
    /// keeps each line short, which the inline form did not.
    static func theme(_ name: String, light: NSColor, dark: NSColor) -> NSColor {
        dynamic("RideCPP.\(name)") { $0.isDark ? dark : light }
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
