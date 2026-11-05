import AppKit
import CryptoKit
import Foundation

/// Polls GitHub Releases for a newer published (non-draft, non-prerelease) version,
/// downloads the macOS DMG, verifies its SHA-256 digest, swaps the app bundle in place
/// after InputBridge quits and relaunches it.
@MainActor
final class UpdateManager: ObservableObject {
    enum State: Equatable { case idle, checking, upToDate, downloading, readyToInstall, installing, failed }

    struct Release: Equatable {
        let version: String
        let tag: String
        let pageURL: URL?
        let downloadURL: URL
        let size: Int64
        let sha256: String?
    }

    static let owner = "ArdanucAKAR"
    static let repository = "InputBridge"
    static let assetName = "InputBridge-macOS.dmg"
    private static let startupDelay: UInt64 = 45 * 1_000_000_000
    private static let checkInterval: UInt64 = 6 * 60 * 60 * 1_000_000_000

    @Published private(set) var state: State = .idle
    @Published private(set) var status: String
    @Published private(set) var latest: Release?
    @Published var autoCheck: Bool {
        didSet { UserDefaults.standard.set(autoCheck, forKey: "updates-auto-check") }
    }
    @Published var autoInstall: Bool {
        didSet { UserDefaults.standard.set(autoInstall, forKey: "updates-auto-install") }
    }

    let currentVersion: String
    var isDevelopmentBuild: Bool { Self.isDevelopmentVersion(currentVersion) }
    var isBusy: Bool { state == .checking || state == .downloading || state == .installing }

    private var downloadedDMG: URL?
    private var loop: Task<Void, Never>?
    private let session: URLSession
    private let cacheRoot: URL
    private let workDirectory: URL

    init() {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        currentVersion = version
        autoCheck = UserDefaults.standard.object(forKey: "updates-auto-check") as? Bool ?? true
        autoInstall = UserDefaults.standard.bool(forKey: "updates-auto-install")
        status = Self.isDevelopmentVersion(version)
            ? "Development build — automatic update checks are off."
            : "Version \(version)."

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 600
        session = URLSession(configuration: configuration)

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        cacheRoot = caches.appendingPathComponent("com.inputbridge.mac", isDirectory: true)
        workDirectory = cacheRoot.appendingPathComponent("Updates", isDirectory: true)
    }

    func start() {
        guard loop == nil else { return }
        try? FileManager.default.removeItem(at: workDirectory)
        loop = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.startupDelay)
            while !Task.isCancelled {
                guard let self else { return }
                if self.autoCheck && !self.isDevelopmentBuild {
                    await self.check(userInitiated: false)
                }
                try? await Task.sleep(nanoseconds: Self.checkInterval)
            }
        }
    }

    /// Checks GitHub and downloads the DMG when a newer version exists.
    func check(userInitiated: Bool) async {
        if isBusy { return }
        if state == .readyToInstall && !userInitiated { return }

        setState(.checking, "Checking GitHub for updates…")
        do {
            guard let release = try await fetchLatest() else {
                setState(.upToDate, "No macOS build found in the latest release.")
                return
            }
            latest = release
            guard Self.compare(release.version, currentVersion) == .orderedDescending else {
                setState(.upToDate, "InputBridge \(currentVersion) is up to date.")
                return
            }

            let target = workDirectory
                .appendingPathComponent(release.tag, isDirectory: true)
                .appendingPathComponent(Self.assetName)
            if downloadedDMG != target || !FileManager.default.fileExists(atPath: target.path) {
                setState(.downloading, "Downloading InputBridge \(release.version)…")
                try await download(release, to: target)
                downloadedDMG = target
            }

            setState(.readyToInstall, "InputBridge \(release.version) is ready to install.")
            if autoInstall && !userInitiated {
                install()
            }
        } catch {
            setState(.failed, "Update check failed: \(error.localizedDescription)")
        }
    }

    /// Mounts the verified DMG, stages the new app, then quits so a helper can swap the bundle and relaunch.
    func install() {
        guard state == .readyToInstall, let dmg = downloadedDMG, let release = latest else { return }

        let appURL = Bundle.main.bundleURL
        let appPath = appURL.path
        let parentPath = appURL.deletingLastPathComponent().path
        if appPath.contains("/AppTranslocation/") || appPath.hasPrefix("/Volumes/")
            || !FileManager.default.isWritableFile(atPath: parentPath) {
            NSWorkspace.shared.open(dmg)
            setState(.readyToInstall, "Drag the new InputBridge into Applications to finish the update. Automatic install needs InputBridge to run from a writable Applications folder.")
            return
        }

        setState(.installing, "Installing InputBridge \(release.version)… InputBridge will restart.")
        do {
            let staged = try stageApp(from: dmg, expectedVersion: release.version)
            try launchReplacementHelper(staged: staged, target: appURL)
            NSApplication.shared.terminate(nil)
        } catch {
            setState(.failed, "Update install failed: \(error.localizedDescription)")
        }
    }

    // MARK: - GitHub

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let size: Int64
            let digest: String?
            let browserDownloadUrl: String
        }

        let tagName: String
        let htmlUrl: String?
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private var userAgent: String { "InputBridge-Updater/\(currentVersion.isEmpty ? "0.0.0" : currentVersion)" }

    private func fetchLatest() async throws -> Release? {
        guard let url = URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repository)/releases/latest") else {
            throw UpdateError.badResponse
        }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError.badResponse }
        if http.statusCode == 404 { return nil }
        if http.statusCode == 403 || http.statusCode == 429 { throw UpdateError.rateLimited }
        guard (200..<300).contains(http.statusCode) else { throw UpdateError.http(http.statusCode) }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let release = try decoder.decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease, let version = Self.normalizedVersion(release.tagName) else {
            return nil
        }
        guard let asset = release.assets.first(where: { $0.name.caseInsensitiveCompare(Self.assetName) == .orderedSame }),
              let downloadURL = URL(string: asset.browserDownloadUrl),
              downloadURL.scheme == "https",
              downloadURL.host?.lowercased() == "github.com" else {
            return nil
        }

        var sha256: String?
        if let digest = asset.digest?.lowercased(), digest.hasPrefix("sha256:") {
            sha256 = String(digest.dropFirst("sha256:".count))
        }
        var pageURL: URL?
        if let raw = release.htmlUrl, let page = URL(string: raw), page.scheme == "https", page.host?.lowercased() == "github.com" {
            pageURL = page
        }

        return Release(
            version: version,
            tag: release.tagName,
            pageURL: pageURL,
            downloadURL: downloadURL,
            size: asset.size,
            sha256: sha256
        )
    }

    private func download(_ release: Release, to target: URL) async throws {
        var request = URLRequest(url: release.downloadURL)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (temporary, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            try? FileManager.default.removeItem(at: temporary)
            throw UpdateError.badResponse
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fileManager.fileExists(atPath: target.path) { try fileManager.removeItem(at: target) }
        try fileManager.moveItem(at: temporary, to: target)

        let attributes = try fileManager.attributesOfItem(atPath: target.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        if release.size > 0 && size != release.size {
            try? fileManager.removeItem(at: target)
            throw UpdateError.sizeMismatch
        }
        if let expected = release.sha256 {
            let actual = try Self.sha256Hex(of: target)
            guard actual == expected else {
                try? fileManager.removeItem(at: target)
                throw UpdateError.checksumMismatch
            }
        }
    }

    // MARK: - Install

    private func stageApp(from dmg: URL, expectedVersion: String) throws -> URL {
        let fileManager = FileManager.default
        let mountPoint = workDirectory.appendingPathComponent("mount-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: mountPoint, withIntermediateDirectories: true)
        try Self.runTool("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mountPoint.path])
        defer {
            _ = try? Self.runTool("/usr/bin/hdiutil", ["detach", mountPoint.path, "-force"])
            try? fileManager.removeItem(at: mountPoint)
        }

        let source = mountPoint.appendingPathComponent("InputBridge.app", isDirectory: true)
        guard let bundle = Bundle(url: source),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              let newVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              Self.compare(newVersion, expectedVersion) == .orderedSame else {
            throw UpdateError.invalidBundle
        }

        let stagingDirectory = workDirectory.appendingPathComponent("staged-\(expectedVersion)", isDirectory: true)
        try? fileManager.removeItem(at: stagingDirectory)
        try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        let stagedApp = stagingDirectory.appendingPathComponent("InputBridge.app", isDirectory: true)
        try Self.runTool("/usr/bin/ditto", [source.path, stagedApp.path])
        try Self.runTool("/usr/bin/codesign", ["--verify", "--deep", stagedApp.path])
        return stagedApp
    }

    private func launchReplacementHelper(staged: URL, target: URL) throws {
        let script = """
        #!/bin/sh
        # InputBridge self-update helper: waits for the app to quit, swaps the bundle, relaunches.
        PID="$1"; STAGED="$2"; TARGET="$3"
        echo "$(date) updating $TARGET"
        i=0
        while kill -0 "$PID" 2>/dev/null; do
          i=$((i + 1))
          if [ "$i" -gt 120 ]; then echo "app did not quit"; exit 1; fi
          sleep 0.5
        done
        BACKUP="${TARGET}.update-backup"
        rm -rf "$BACKUP"
        if ! mv "$TARGET" "$BACKUP"; then
          echo "could not move the current app aside"
          /usr/bin/open "$TARGET"
          exit 1
        fi
        if /usr/bin/ditto "$STAGED" "$TARGET"; then
          rm -rf "$BACKUP"
          echo "updated"
        else
          echo "copy failed, restoring previous version"
          rm -rf "$TARGET"
          mv "$BACKUP" "$TARGET"
        fi
        /usr/bin/xattr -dr com.apple.quarantine "$TARGET" 2>/dev/null
        rm -rf "$(dirname "$STAGED")"
        /usr/bin/open "$TARGET"
        """

        let scriptURL = workDirectory.appendingPathComponent("install-update.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let logURL = cacheRoot.appendingPathComponent("update-install.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let log = try FileHandle(forWritingTo: logURL)
        try log.seekToEnd()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [
            scriptURL.path,
            String(ProcessInfo.processInfo.processIdentifier),
            staged.path,
            target.path
        ]
        process.standardOutput = log
        process.standardError = log
        try process.run()
    }

    // MARK: - Helpers

    private func setState(_ state: State, _ status: String) {
        self.state = state
        self.status = status
    }

    nonisolated static func isDevelopmentVersion(_ version: String) -> Bool {
        version.isEmpty || compare(version, "0.0.0") == .orderedSame
    }

    nonisolated static func normalizedVersion(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let cut = text.firstIndex(where: { $0 == "-" || $0 == "+" }) {
            text = String(text[..<cut])
        }
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else {
            return nil
        }
        return text
    }

    nonisolated static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = (normalizedVersion(lhs) ?? "0").split(separator: ".").map { Int($0) ?? 0 }
        let right = (normalizedVersion(rhs) ?? "0").split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    private nonisolated static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    @discardableResult
    private nonisolated static func runTool(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw UpdateError.toolFailed(URL(fileURLWithPath: path).lastPathComponent, output)
        }
        return output
    }
}

enum UpdateError: LocalizedError {
    case badResponse, rateLimited, http(Int), sizeMismatch, checksumMismatch, invalidBundle, toolFailed(String, String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "Unexpected response from GitHub."
        case .rateLimited: return "GitHub rate limit reached; InputBridge will retry later."
        case .http(let code): return "GitHub returned HTTP \(code)."
        case .sizeMismatch: return "The downloaded update has the wrong size."
        case .checksumMismatch: return "The downloaded update failed the SHA-256 check."
        case .invalidBundle: return "The downloaded DMG does not contain the expected InputBridge app."
        case .toolFailed(let tool, let output):
            let detail = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "\(tool) failed." : "\(tool) failed: \(detail)"
        }
    }
}
