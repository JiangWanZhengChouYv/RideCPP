import Foundation

/// Downloads an update disk image, reporting real byte progress.
///
/// Progress is measured from the transport itself (`URLSessionDownloadDelegate`
/// reports cumulative bytes written), not estimated from a timer, so the bar
/// matches what has actually arrived.
public final class UpdateDownloader: NSObject {

    public enum Failure: LocalizedError {
        case badResponse(Int)
        case emptyDownload
        case checksumMismatch
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .badResponse(let code):
                return "The download server returned status \(code)."
            case .emptyDownload:
                return "The downloaded update file was empty."
            case .checksumMismatch:
                return "The downloaded update appears to be corrupt."
            case .cancelled:
                return "The download was cancelled."
            }
        }
    }

    /// Called on the main queue with the fraction complete (0...1) and byte counts.
    public var onProgress: ((Double, Int64, Int64) -> Void)?
    /// Called on the main queue when the file has been saved to a temporary path.
    public var onCompletion: ((Result<URL, Error>) -> Void)?

    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var destination: URL?
    private var lastReportedFraction = -1.0
    /// The URL being fetched, kept so a failed attempt can be retried.
    private var sourceURL: URL?
    /// Which transport is in use: proxy first (if one is configured), then direct.
    private enum Transport { case systemProxy, direct }
    private var pendingTransports: [Transport] = []
    private var currentTransport: Transport = .direct

    public override init() { super.init() }

    /// Starts downloading `url` into a temporary file.
    ///
    /// If the machine has a proxy configured it is tried first (some networks
    /// require it), but a proxy failure is **not** fatal: the download then retries
    /// directly, so a stale or broken proxy setting cannot block updates.
    public func start(from url: URL) {
        cancel()
        sourceURL = url
        // Order of attempts: honour the system proxy when there is one, then go
        // direct. A working direct connection always wins over a dead proxy.
        pendingTransports = SystemProxy.settings() != nil ? [.systemProxy, .direct] : [.direct]
        lastReportedFraction = -1
        attemptNextTransport()
    }

    /// Starts a download attempt with the next available transport.
    private func attemptNextTransport() {
        guard !pendingTransports.isEmpty else {
            DispatchQueue.main.async { [weak self] in
                self?.onCompletion?(.failure(Failure.cancelled))
            }
            return
        }
        let transport = pendingTransports.removeFirst()
        currentTransport = transport
        guard let url = sourceURL else { return }

        let configuration = URLSessionConfiguration.default
        // A short request timeout matters: it is what lets a dead proxy be detected
        // quickly enough to retry directly instead of hanging for minutes.
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 900
        configuration.waitsForConnectivity = false
        switch transport {
        case .systemProxy:
            // `URLSession` does not read `http_proxy`, but macOS stores the proxy
            // in the system configuration.
            configuration.connectionProxyDictionary = SystemProxy.settings()
        case .direct:
            // Explicitly empty: no proxy at all, even if one is configured. Keeping
            // the key (rather than leaving it nil) stops URLSession from falling
            // back to the system settings again.
            configuration.connectionProxyDictionary = [:]
        }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        let task = session.downloadTask(with: url)
        self.task = task
        // Reset the bar only for the first attempt, so a proxy→direct retry does
        // not visibly jump back to zero after real progress was made.
        if lastReportedFraction < 0 {
            onProgress?(0, 0, 0)
        }
        task.resume()
    }

    public func cancel() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    /// Moves the finished download somewhere permanent for unmounting.
    ///
    /// `URLSession` deletes its temporary file when the delegate returns, so the file
    /// has to be copied before then.
    private func adopt(_ temporaryURL: URL) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-Update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let target = directory.appendingPathComponent(temporaryURL.lastPathComponent)
        if FileManager.default.fileExists(atPath: target.path) {
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.moveItem(at: temporaryURL, to: target)
        return target
    }
}

extension UpdateDownloader: URLSessionDownloadDelegate {

    public func urlSession(_ session: URLSession,
                           downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        // Some servers omit Content-Length; without it there is no honest
        // percentage, so the caller is told the byte count and left indeterminate.
        let fraction: Double
        if totalBytesExpectedToWrite > 0 {
            fraction = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        } else {
            fraction = -1
        }
        // Throttle: repainting the bar on every packet is wasted work.
        if fraction >= 0, fraction - lastReportedFraction < 0.005, fraction < 1 { return }
        lastReportedFraction = max(lastReportedFraction, fraction)
        DispatchQueue.main.async { [weak self] in
            self?.onProgress?(fraction, totalBytesWritten, totalBytesExpectedToWrite)
        }
    }

    /// The data task reports progress as well as the download task; without a
    /// delegate method for it the bar never moves for small responses.
    public func urlSession(_ session: URLSession,
                           dataTask: URLSessionDataTask,
                           didReceive response: URLResponse,
                           completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            DispatchQueue.main.async { [weak self] in
                self?.onCompletion?(.failure(Failure.badResponse(http.statusCode)))
            }
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    public func urlSession(_ session: URLSession,
                           downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
            DispatchQueue.main.async { [weak self] in
                self?.onCompletion?(.failure(Failure.badResponse(response.statusCode)))
            }
            return
        }
        do {
            let size = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
            guard size > 0 else {
                DispatchQueue.main.async { [weak self] in self?.onCompletion?(.failure(Failure.emptyDownload)) }
                return
            }
            let saved = try adopt(location)
            DispatchQueue.main.async { [weak self] in
                self?.onProgress?(1, size, size)
                self?.onCompletion?(.success(saved))
            }
        } catch {
            DispatchQueue.main.async { [weak self] in self?.onCompletion?(.failure(error)) }
        }
    }

    public func urlSession(_ session: URLSession,
                           task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let error else { return }   // success path already reported
        let isCancellation = (error as NSError).code == NSURLErrorCancelled
        guard !isCancellation else {
            DispatchQueue.main.async { [weak self] in
                self?.onCompletion?(.failure(Failure.cancelled))
            }
            return
        }
        // The proxy attempt failed: fall through to a direct connection before
        // giving up, so a broken proxy never blocks the update.
        if !pendingTransports.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.attemptNextTransport()
            }
            return
        }
        DispatchQueue.main.async { [weak self] in
            self?.onCompletion?(.failure(error))
        }
    }
}

/// Reads the system proxy configuration so downloads work behind a proxy.
public enum SystemProxy {

    /// A `URLSession`-shaped proxy dictionary, or nil when no proxy is configured.
    public static func settings() -> [AnyHashable: Any]? {
        guard let proxy = CFNetworkCopySystemProxySettings()?.takeRetainedValue() as? [AnyHashable: Any] else {
            return nil
        }
        // Only HTTP/HTTPS proxying is needed here; SOCKS is passed through as well
        // because some setups only expose that.
        var result: [AnyHashable: Any] = [:]
        if let enabled = proxy[kCFNetworkProxiesHTTPEnable as String] as? Int, enabled == 1,
           let host = proxy[kCFNetworkProxiesHTTPProxy as String] as? String {
            let port = proxy[kCFNetworkProxiesHTTPPort as String] as? Int ?? 0
            result[kCFNetworkProxiesHTTPEnable as String] = 1
            result[kCFNetworkProxiesHTTPProxy as String] = host
            result[kCFNetworkProxiesHTTPPort as String] = port
        }
        if let enabled = proxy[kCFNetworkProxiesHTTPSEnable as String] as? Int, enabled == 1,
           let host = proxy[kCFNetworkProxiesHTTPSProxy as String] as? String {
            let port = proxy[kCFNetworkProxiesHTTPSPort as String] as? Int ?? 0
            result[kCFNetworkProxiesHTTPSEnable as String] = 1
            result[kCFNetworkProxiesHTTPSProxy as String] = host
            result[kCFNetworkProxiesHTTPSPort as String] = port
        }
        if let enabled = proxy[kCFNetworkProxiesSOCKSEnable as String] as? Int, enabled == 1,
           let host = proxy[kCFNetworkProxiesSOCKSProxy as String] as? String {
            let port = proxy[kCFNetworkProxiesSOCKSPort as String] as? Int ?? 0
            result[kCFNetworkProxiesSOCKSEnable as String] = 1
            result[kCFNetworkProxiesSOCKSProxy as String] = host
            result[kCFNetworkProxiesSOCKSPort as String] = port
        }
        return result.isEmpty ? nil : result
    }
}

/// Installs a downloaded disk image by mounting it, copying the app in and
/// relaunching.
public enum UpdateInstaller {

    public enum Failure: LocalizedError {
        case mountFailed
        case appNotFoundInImage
        case copyFailed(String)

        public var errorDescription: String? {
            switch self {
            case .mountFailed:
                return "Could not open the downloaded disk image."
            case .appNotFoundInImage:
                return "The disk image did not contain RideCPP.app."
            case .copyFailed(let detail):
                return "Could not install the update: \(detail)"
            }
        }
    }

    /// Mounts `diskImage`, copies the app over the one at `destination`, and returns
    /// the app URL to relaunch.
    ///
    /// The running bundle cannot be replaced in place while it is in use, so the new
    /// copy is staged next to it and swapped by a helper script after this process
    /// exits.
    public static func install(diskImage: URL,
                               destination: URL = Bundle.main.bundleURL) throws -> URL {
        let mountPoint = FileManager.default.temporaryDirectory
            .appendingPathComponent("RideCPP-Mount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)

        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        attach.arguments = ["attach", diskImage.path, "-nobrowse", "-readonly", "-mountpoint", mountPoint.path]
        attach.standardOutput = FileHandle.nullDevice
        attach.standardError = FileHandle.nullDevice
        do {
            try attach.run()
            attach.waitUntilExit()
        } catch {
            throw Failure.mountFailed
        }
        guard attach.terminationStatus == 0 else { throw Failure.mountFailed }

        let source = mountPoint.appendingPathComponent("RideCPP.app")
        guard FileManager.default.fileExists(atPath: source.path) else {
            detach(mountPoint)
            throw Failure.appNotFoundInImage
        }

        // Copy next to the destination so the swap is a rename, not a cross-volume
        // copy (which would leave a window where no app exists).
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent("RideCPP.app.new")
        try? FileManager.default.removeItem(at: staging)
        do {
            try FileManager.default.copyItem(at: source, to: staging)
        } catch {
            detach(mountPoint)
            throw Failure.copyFailed(error.localizedDescription)
        }
        detach(mountPoint)
        return staging
    }

    /// Script that swaps the staged app in once the current process has quit, then
    /// relaunches it. Returns the script URL.
    @discardableResult
    public static func scheduleRelaunch(staged: URL, destination: URL) throws -> URL {
        let script = FileManager.default.temporaryDirectory
            .appendingPathComponent("ridecpp-update-\(UUID().uuidString).sh")
        let body = """
        #!/bin/bash
        # Wait for the running app to exit before replacing it.
        while pgrep -f "\(destination.path)/Contents/MacOS/RideCPP" >/dev/null; do
            sleep 0.2
        done
        rm -rf "\(destination.path)"
        mv "\(staged.path)" "\(destination.path)"
        xattr -dr com.apple.quarantine "\(destination.path)" 2>/dev/null
        open "\(destination.path)"
        rm -f "$0"
        """
        try body.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script
    }

    private static func detach(_ mountPoint: URL) {
        let detach = Process()
        detach.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        detach.arguments = ["detach", mountPoint.path, "-quiet"]
        detach.standardOutput = FileHandle.nullDevice
        detach.standardError = FileHandle.nullDevice
        try? detach.run()
        detach.waitUntilExit()
    }
}
