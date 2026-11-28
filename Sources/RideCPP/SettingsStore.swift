import Foundation
import EditorCore
import BuildKit

/// Persistent, observable settings.
///
/// Values are stored in `UserDefaults`; the class is an `ObservableObject` so the
/// editor and the settings window stay in sync. Plain `@Published` properties
/// (no Swift macro) keep the build free of macro-plugin dependencies.
public final class SettingsStore: ObservableObject {

    public static let shared = SettingsStore()

    // Editor
    @Published public var fontSize: Double { didSet { defaults.set(fontSize, forKey: Keys.fontSize) } }
    @Published public var indentWidth: Int { didSet { defaults.set(indentWidth, forKey: Keys.indentWidth) } }
    @Published public var indentWithTabs: Bool { didSet { defaults.set(indentWithTabs, forKey: Keys.indentWithTabs) } }
    @Published public var autoPair: Bool { didSet { defaults.set(autoPair, forKey: Keys.autoPair) } }
    /// Whether the completion list opens while typing.
    @Published public var autoComplete: Bool { didSet { defaults.set(autoComplete, forKey: Keys.autoComplete) } }
    @Published public var autoIndent: Bool { didSet { defaults.set(autoIndent, forKey: Keys.autoIndent) } }
    @Published public var showLineNumbers: Bool { didSet { defaults.set(showLineNumbers, forKey: Keys.showLineNumbers) } }

    // Inline predictions
    /// Whether inline suggestions are enabled.
    ///
    /// Off by default: every suggestion is a model request, which costs power.
    /// The user turns it on deliberately.
    @Published public var inlineModelEnabled: Bool {
        didSet { defaults.set(inlineModelEnabled, forKey: Keys.inlineModelEnabled) }
    }
    /// Model used for inline suggestions, empty to pick automatically.
    @Published public var inlineModel: String { didSet { defaults.set(inlineModel, forKey: Keys.inlineModel) } }

    // Build
    @Published public var compilerPath: String { didSet { defaults.set(compilerPath, forKey: Keys.compilerPath) } }
    @Published public var standard: String { didSet { defaults.set(standard, forKey: Keys.standard) } }
    @Published public var optimization: String { didSet { defaults.set(optimization, forKey: Keys.optimization) } }
    @Published public var extraFlags: String { didSet { defaults.set(extraFlags, forKey: Keys.extraFlags) } }
    @Published public var runArguments: String { didSet { defaults.set(runArguments, forKey: Keys.runArguments) } }

    // Formatting
    @Published public var clangFormatPath: String { didSet { defaults.set(clangFormatPath, forKey: Keys.clangFormatPath) } }
    @Published public var clangFormatStyle: String { didSet { defaults.set(clangFormatStyle, forKey: Keys.clangFormatStyle) } }

    public let availableCompilers: [CompilerInfo]
    public let availableClangFormat: String?

    private let defaults: UserDefaults

    public static let standards = ["c++11", "c++14", "c++17", "c++20", "c++23", "gnu++14", "gnu++17", "gnu++20"]
    public static let optimizations = ["-O0", "-O1", "-O2", "-O3", "-Os"]
    public static let clangFormatStyles = ["LLVM", "Google", "Chromium", "Mozilla", "WebKit", "Microsoft", "file"]

    private enum Keys {
        static let fontSize = "editor.fontSize"
        static let indentWidth = "editor.indentWidth"
        static let indentWithTabs = "editor.indentWithTabs"
        static let autoPair = "editor.autoPair"
        static let autoComplete = "editor.autoComplete"
        static let autoIndent = "editor.autoIndent"
        static let inlineModelEnabled = "completion.inlineModelEnabled"
        static let inlineModel = "completion.inlineModel"
        static let showLineNumbers = "editor.showLineNumbers"
        static let compilerPath = "build.compilerPath"
        static let standard = "build.standard"
        static let optimization = "build.optimization"
        static let optimizationMigrated = "build.optimizationMigratedToO2"
        static let extraFlags = "build.extraFlags"
        static let runArguments = "build.runArguments"
        static let clangFormatPath = "format.clangFormatPath"
        static let clangFormatStyle = "format.clangFormatStyle"
    }

    public init(defaults: UserDefaults = .standard,
                compilers: [CompilerInfo]? = nil,
                clangFormat: String? = nil) {
        self.defaults = defaults
        let discovered = compilers ?? Toolchain.discoverCompilers()
        self.availableCompilers = discovered
        self.availableClangFormat = clangFormat ?? Toolchain.findClangFormat()

        // Defaults (registered with sensible values before reading).
        defaults.register(defaults: [
            Keys.fontSize: 13.0,
            Keys.indentWidth: 4,
            Keys.indentWithTabs: false,
            Keys.autoPair: true,
            Keys.autoComplete: true,
            Keys.autoIndent: true,
            Keys.inlineModelEnabled: false,
            Keys.inlineModel: "",
            Keys.showLineNumbers: true,
            Keys.compilerPath: discovered.first?.path ?? "/usr/bin/clang++",
            Keys.standard: "c++17",
            Keys.optimization: "-O2",
            Keys.extraFlags: "",
            Keys.runArguments: "",
            Keys.clangFormatPath: clangFormat ?? "",
            Keys.clangFormatStyle: "LLVM"
        ])

        fontSize = defaults.double(forKey: Keys.fontSize)
        indentWidth = defaults.integer(forKey: Keys.indentWidth)
        indentWithTabs = defaults.bool(forKey: Keys.indentWithTabs)
        autoPair = defaults.bool(forKey: Keys.autoPair)
        autoComplete = defaults.bool(forKey: Keys.autoComplete)
        autoIndent = defaults.bool(forKey: Keys.autoIndent)
        showLineNumbers = defaults.bool(forKey: Keys.showLineNumbers)
        inlineModelEnabled = defaults.bool(forKey: Keys.inlineModelEnabled)
        inlineModel = defaults.string(forKey: Keys.inlineModel) ?? ""
        compilerPath = defaults.string(forKey: Keys.compilerPath) ?? "/usr/bin/clang++"
        standard = defaults.string(forKey: Keys.standard) ?? "c++17"
        optimization = defaults.string(forKey: Keys.optimization) ?? "-O2"
        extraFlags = defaults.string(forKey: Keys.extraFlags) ?? ""
        runArguments = defaults.string(forKey: Keys.runArguments) ?? ""
        clangFormatPath = defaults.string(forKey: Keys.clangFormatPath) ?? (clangFormat ?? "")
        clangFormatStyle = defaults.string(forKey: Keys.clangFormatStyle) ?? "LLVM"

        // One-time migration: earlier builds defaulted to -O0, which is a poor
        // default for algorithm work. Only replace the stored value when it is
        // still exactly that old default, so an explicit choice is preserved.
        if !defaults.bool(forKey: Keys.optimizationMigrated) {
            defaults.set(true, forKey: Keys.optimizationMigrated)
            if optimization == "-O0" {
                optimization = "-O2"
            }
        }
    }

    /// The edit behaviour derived from settings.
    public var editSettings: EditSettings {
        EditSettings(indentWidth: indentWidth,
                     indentWithTabs: indentWithTabs,
                     autoPair: autoPair,
                     autoIndent: autoIndent,
                     autoComplete: autoComplete)
    }

    /// Extra flags split on whitespace; quoted segments are kept together.
    public var extraFlagList: [String] {
        Self.splitArguments(extraFlags)
    }

    public var runArgumentList: [String] {
        Self.splitArguments(runArguments)
    }

    public var currentCompiler: CompilerInfo? {
        availableCompilers.first { $0.path == compilerPath }
    }

    public var clangFormatExecutable: String? {
        if !clangFormatPath.isEmpty, FileManager.default.isExecutableFile(atPath: clangFormatPath) {
            return clangFormatPath
        }
        return availableClangFormat
    }

    public func restoreDefaults() {
        fontSize = 13
        indentWidth = 4
        indentWithTabs = false
        autoPair = true
        autoIndent = true
        showLineNumbers = true
        compilerPath = availableCompilers.first?.path ?? "/usr/bin/clang++"
        standard = "c++17"
        optimization = "-O2"
        extraFlags = ""
        runArguments = ""
        clangFormatStyle = "LLVM"
        clangFormatPath = availableClangFormat ?? ""
    }

    /// Splits a command-line fragment into arguments, honouring single and
    /// double quotes.
    public static func splitArguments(_ text: String) -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        for character in text {
            if let active = quote {
                if character == active {
                    quote = nil
                } else {
                    current.append(character)
                }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == " " || character == "\t" {
                if !current.isEmpty {
                    result.append(current)
                    current = ""
                }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { result.append(current) }
        return result
    }
}
