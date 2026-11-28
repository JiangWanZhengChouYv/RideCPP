import AppKit
import Combine
import Foundation
import BuildKit
import EditorCore

/// Owns the in-app update flow: check, download, install, relaunch.
///
/// Extracted from `AppState` so that type stays about documents and building. This
/// is an `ObservableObject` in its own right, so SwiftUI can observe download
/// progress without routing it through the app's global state.
@MainActor
public final class UpdateController: ObservableObject {

    public enum Phase: Equatable {
        case idle
        case downloading
        case installing
        case failed(String)
        case readyToRelaunch
    }

    @Published public private(set) var phase: Phase = .idle
    /// 0...1 while downloading.
    @Published public private(set) var progress: Double = 0
    @Published public private(set) var bytes: (received: Int64, total: Int64) = (0, 0)
    /// Newer release, when one exists.
    @Published public private(set) var available: ReleaseInfo?

    private var downloader: UpdateDownloader?
    /// Repeats the automatic check while the app runs.
    private var periodicTimer: Timer?
    private let currentVersion: () -> SemanticVersion
    /// Saves documents before the relaunch; supplied by the app state.
    private let prepareForRelaunch: () -> Void

    /// Automatic checks are throttled: GitHub allows 60 unauthenticated API calls
    /// per hour, which a check on every launch would exhaust.
    ///
    /// One hour is 24 calls a day — far inside that limit — and means a release
    /// published during the day is noticed the same day rather than up to six
    /// hours later.
    static let automaticCheckInterval: TimeInterval = UpdateThrottle.interval
    static let lastCheckKey = "update.lastAutomaticCheck"

    public init(currentVersion: @escaping () -> SemanticVersion,
                prepareForRelaunch: @escaping () -> Void) {
        self.currentVersion = currentVersion
        self.prepareForRelaunch = prepareForRelaunch
    }

    // MARK: - Checking

    public func checkAutomatically() {
        let last = UserDefaults.standard.double(forKey: Self.lastCheckKey)
        guard UpdateThrottle.shouldCheck(lastCheck: last,
                                         now: Date().timeIntervalSince1970) else { return }
        check(userInitiated: false)
    }

    /// Re-checks periodically while the app stays open.
    ///
    /// `checkAutomatically()` only runs at launch, so an app left running for days
    /// never noticed a new release. The timer calls the same throttled entry point,
    /// so the GitHub rate limit still holds.
    public func startPeriodicChecks(interval: TimeInterval = 30 * 60) {
        periodicTimer?.invalidate()
        periodicTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) {
            [weak self] _ in
            self?.checkAutomatically()
        }
    }

    /// Looks for a newer release. Calls back with an error only for user-initiated
    /// checks, so a silent background check never interrupts.
    public func check(userInitiated: Bool, onError: ((String, String) -> Void)? = nil) {
        let version = currentVersion()
        Task { [weak self] in
            do {
                let release = try await UpdateChecker.checkForUpdate(current: version)
                guard let self else { return }
                if !userInitiated {
                    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Self.lastCheckKey)
                }
                if let release {
                    self.available = release
                } else if userInitiated {
                    onError?(L10n.t("update.upToDate.title"),
                                     L10n.t("update.upToDate.message", version.description))
                }
            } catch {
                guard userInitiated else { return }
                if let updateError = error as? UpdateChecker.UpdateError,
                   case .rateLimited = updateError {
                    onError?(L10n.t("update.rateLimited.title"), L10n.t("update.rateLimited.message"))
                } else {
                    onError?(L10n.t("update.failed.title"), error.localizedDescription)
                }
            }
        }
    }

    public func dismiss() {
        available = nil
        phase = .idle
    }

    /// Opens the release page, used when there is no downloadable asset.
    public func openReleasePage() {
        guard let url = available?.htmlURL else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Installing

    public func install() {
        guard let release = available, let url = release.downloadURL else {
            openReleasePage()
            return
        }
        guard phase != .downloading, phase != .installing else { return }

        phase = .downloading
        progress = 0
        bytes = (0, 0)

        let downloader = UpdateDownloader()
        self.downloader = downloader
        downloader.onProgress = { [weak self] fraction, received, total in
            self?.progress = fraction
            self?.bytes = (received, total)
        }
        downloader.onCompletion = { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let file):
                self.installDownloaded(file)
            case .failure(let error):
                self.phase = .failed(error.localizedDescription)
            }
        }
        downloader.start(from: url)
    }

    public func cancel() {
        downloader?.cancel()
        downloader = nil
        phase = .idle
        progress = 0
    }

    private func installDownloaded(_ file: URL) {
        phase = .installing
        let destination = Bundle.main.bundleURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let staged = try UpdateInstaller.install(diskImage: file, destination: destination)
                let script = try UpdateInstaller.scheduleRelaunch(staged: staged, destination: destination)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.phase = .readyToRelaunch
                    // Persist work, then hand over to the relaunch helper.
                    self.prepareForRelaunch()
                    let launcher = Process()
                    launcher.executableURL = URL(fileURLWithPath: "/bin/bash")
                    launcher.arguments = [script.path]
                    try? launcher.run()
                    NSApp.terminate(nil)
                }
            } catch {
                DispatchQueue.main.async { self?.phase = .failed(error.localizedDescription) }
            }
        }
    }
}
