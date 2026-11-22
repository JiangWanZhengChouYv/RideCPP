import Foundation

/// A semantic version as used by releases ("1.0.1", optionally with a build
/// number such as "1.0.1 (3)").
public struct SemanticVersion: Comparable, CustomStringConvertible, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int
    public let build: Int

    public init?(_ text: String) {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.hasPrefix("v") || body.hasPrefix("V") { body.removeFirst() }

        var buildNumber = 0
        if let parenStart = body.firstIndex(of: "("), let parenEnd = body.lastIndex(of: ")"), parenStart < parenEnd {
            let inside = body[body.index(after: parenStart)..<parenEnd]
            buildNumber = Int(inside.trimmingCharacters(in: .whitespaces)) ?? 0
            body = String(body[..<parenStart]).trimmingCharacters(in: .whitespaces)
        }

        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard let first = parts.first, let major = Int(first) else { return nil }
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        let patch = parts.count > 2 ? Int(parts[2]) ?? 0 : 0
        self.init(major: major, minor: minor, patch: patch, build: buildNumber)
    }

    public init(major: Int, minor: Int, patch: Int, build: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.build = build
    }

    /// The current app version, read from the bundle when available.
    public static func current(bundle: Bundle = .main) -> SemanticVersion {
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
        let build = Int(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
        if let parsed = SemanticVersion(short) {
            return SemanticVersion(major: parsed.major, minor: parsed.minor, patch: parsed.patch, build: build)
        }
        return SemanticVersion(major: 0, minor: 0, patch: 0, build: build)
    }

    /// True when `latest` (tag + build number) is a newer release than `current`.
    public static func isNewer(latest: String, build: Int, than current: String, build currentBuild: Int) -> Bool {
        guard let newer = SemanticVersion(latest) else { return false }
        guard let older = SemanticVersion(current) else { return true }
        let latestVersion = SemanticVersion(major: newer.major, minor: newer.minor, patch: newer.patch, build: build)
        let currentVersion = SemanticVersion(major: older.major, minor: older.minor, patch: older.patch, build: currentBuild)
        return latestVersion > currentVersion
    }

    public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        if lhs.patch != rhs.patch { return lhs.patch < rhs.patch }
        return lhs.build < rhs.build
    }

    public var description: String {
        build > 0 ? "\(major).\(minor).\(patch) (\(build))" : "\(major).\(minor).\(patch)"
    }
}

/// A release published on GitHub.
public struct ReleaseInfo: Equatable, Sendable {
    public let tag: String
    public let name: String
    public let notes: String
    public let htmlURL: URL
    public let downloadURL: URL?
    public let publishedAt: Date?

    public init(tag: String, name: String, notes: String, htmlURL: URL, downloadURL: URL?, publishedAt: Date?) {
        self.tag = tag
        self.name = name
        self.notes = notes
        self.htmlURL = htmlURL
        self.downloadURL = downloadURL
        self.publishedAt = publishedAt
    }
}

/// Checks GitHub for a newer release.
///
/// This is the network entry point for the in-app updater. It is deliberately
/// small and testable: parsing lives in `ReleasePayload.parse`, and the network
/// call is injectable.
public enum UpdateChecker {

    /// Repository releases API endpoint (replace owner/repo at release time).
    public static let releasesEndpoint = URL(string: "https://api.github.com/repos/JiangWanZhengChouYv/RideCPP/releases/latest")!

    public typealias Transport = (URL) async throws -> Data

    public static let defaultTransport: Transport = { url in
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub asks API clients to identify themselves.
        request.setValue("RideCPP-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError.httpStatus(http.statusCode)
        }
        return data
    }

    public enum UpdateError: LocalizedError {
        case httpStatus(Int)
        case malformedResponse

        public var errorDescription: String? {
            switch self {
            case .httpStatus(let code):
                return code == 404 ? "No published release found." : "GitHub returned status \(code)."
            case .malformedResponse:
                return "Could not read the release information."
            }
        }
    }

    /// Returns the newest release, or nil when it is not newer than `current`.
    ///
    /// The build number comes from the tag ("1.0.1 (3)") or from a `build_number`
    /// field in the release payload, whichever is present.
    public static func checkForUpdate(current: SemanticVersion,
                                      transport: Transport = defaultTransport,
                                      endpoint: URL = releasesEndpoint) async throws -> ReleaseInfo? {
        let data = try await transport(endpoint)
        guard let release = ReleasePayload.parse(data) else { throw UpdateError.malformedResponse }
        let tagBuild = ReleasePayload.buildNumber(inTag: release.tag)
        let build = tagBuild > 0 ? tagBuild : payloadBuildNumber(data)
        let currentString = "\(current.major).\(current.minor).\(current.patch)"
        return SemanticVersion.isNewer(latest: release.tag, build: build,
                                       than: currentString, build: current.build) ? release : nil
    }

    /// Optional explicit build number in the payload.
    static func payloadBuildNumber(_ data: Data) -> Int {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return 0 }
        return root["build_number"] as? Int ?? 0
    }
}

/// Parsing of the GitHub "release" JSON payload.
enum ReleasePayload {
    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        guard let tag = root["tag_name"] as? String, let html = root["html_url"] as? String,
              let htmlURL = URL(string: html) else { return nil }
        let name = root["name"] as? String ?? tag
        let notes = root["body"] as? String ?? ""

        // Prefer a .dmg asset; fall back to the first asset that looks like one.
        var download: URL?
        if let assets = root["assets"] as? [[String: Any]] {
            let candidates = assets.compactMap { asset -> (String, URL)? in
                guard let assetName = asset["name"] as? String,
                      let link = asset["browser_download_url"] as? String,
                      let url = URL(string: link) else { return nil }
                return (assetName, url)
            }
            download = candidates.first { $0.0.lowercased().hasSuffix(".dmg") }?.1 ?? candidates.first?.1
        }

        let published = (root["published_at"] as? String).flatMap { ISO8601DateFormatter().date(from: $0) }
        return ReleaseInfo(tag: tag,
                           name: name,
                           notes: notes,
                           htmlURL: htmlURL,
                           downloadURL: download,
                           publishedAt: published)
    }

    /// Build number of a release tag such as "1.0.1 (3)".
    static func buildNumber(inTag tag: String) -> Int {
        SemanticVersion(tag)?.build ?? 0
    }
}
