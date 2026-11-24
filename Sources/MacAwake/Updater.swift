import CryptoKit
import Foundation

/// A newer release on GitHub, with the two files the update needs.
struct AvailableUpdate: Equatable {
    let version: String      // "1.0.42", without the tag's "v"
    let zipURL: URL
    let checksumURL: URL
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Checks GitHub Releases for a newer MacAwake and installs it, the same way `install.sh` does:
/// download over https, check the zip against the release's SHA-256 file, check the app's signature,
/// then swap the app in place and relaunch.
///
/// The app isn't sandboxed and doesn't set `LSFileQuarantineEnabled`, so what URLSession downloads gets
/// no quarantine flag and the new app opens without Gatekeeper's Open Anyway step. The swap clears the
/// flag anyway, like `install.sh`.
///
/// Testing: `MACAWAKE_UPDATE_FEED=<url>` reads a release JSON from there instead of the GitHub API, and
/// then also allows `file://` download URLs, so the whole flow can run against local files.
enum Updater {
    static let repo = "dylannlaw/MacAwake"

    private static let feedOverride = ProcessInfo.processInfo.environment["MACAWAKE_UPDATE_FEED"]
        .flatMap(URL.init(string:))
    static var isTesting: Bool { feedOverride != nil }
    private static var feedURL: URL {
        feedOverride ?? URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// Local builds are "1.0-dev". They don't check by themselves (every release would look newer).
    static var isDevBuild: Bool { currentVersion.contains("-") }

    // MARK: - Versions

    /// "v1.0.42" / "1.0.42" / "1.0-dev" → [1, 0, 42] / [1, 0, 42] / [1, 0]. nil if it isn't a version.
    nonisolated static func components(_ version: String) -> [Int]? {
        var v = Substring(version)
        if v.hasPrefix("v") { v = v.dropFirst() }
        if let dash = v.firstIndex(of: "-") { v = v[..<dash] }
        let parts = v.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(parts.count) else { return nil }
        let nums = parts.compactMap { p in p.allSatisfy(\.isASCII) ? Int(p) : nil }
        return nums.count == parts.count && nums.allSatisfy { $0 >= 0 } ? nums : nil
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        guard let x = components(a), let y = components(b) else { return false }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    // MARK: - Check

    private struct Release: Decodable {
        let tag_name: String
        let draft: Bool?
        let prerelease: Bool?
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
    }

    /// The latest release if it's newer than this app, nil if this app is up to date.
    static func checkLatest() async throws -> AvailableUpdate? {
        var req = URLRequest(url: feedURL, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("MacAwake/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("GitHub answered \(http.statusCode).")
        }
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.draft != true, release.prerelease != true,
              let nums = components(release.tag_name), release.tag_name.first == "v" || isTesting
        else { throw UpdateError("The latest release has an unexpected version (\(release.tag_name)).") }
        let version = nums.map(String.init).joined(separator: ".")
        guard isNewer(version, than: currentVersion) else { return nil }

        func asset(_ name: String) throws -> URL {
            guard let a = release.assets.first(where: { $0.name == name }),
                  let url = URL(string: a.browser_download_url), isAllowedDownload(url)
            else { throw UpdateError("The latest release is missing \(name).") }
            return url
        }
        return AvailableUpdate(version: version, zipURL: try asset("MacAwake.zip"),
                               checksumURL: try asset("MacAwake.zip.sha256"))
    }

    /// Only this repository's release downloads, over https. (Local files too while testing.)
    nonisolated static func isAllowedDownload(_ url: URL) -> Bool {
        if isTesting, url.isFileURL { return true }
        return url.scheme == "https" && url.host == "github.com"
            && url.path.hasPrefix("/\(repo)/releases/download/")
    }

    // MARK: - Download and verify

    /// Downloads and checks the update. Returns the new MacAwake.app, in a temporary folder.
    static func download(_ update: AvailableUpdate) async throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macawake-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

        let zip = tmp.appendingPathComponent("MacAwake.zip")
        let (downloaded, zipResponse) = try await session.download(from: update.zipURL)
        try checkStatus(zipResponse, "the update")
        try FileManager.default.moveItem(at: downloaded, to: zip)

        let (sumData, sumResponse) = try await session.data(from: update.checksumURL)
        try checkStatus(sumResponse, "the checksum file")
        let expected = String(decoding: sumData, as: UTF8.self)
            .split(whereSeparator: \.isWhitespace).first.map { $0.lowercased() } ?? ""
        guard expected.count == 64, expected.allSatisfy(\.isHexDigit) else {
            throw UpdateError("The checksum file isn't valid.")
        }
        let actual = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw UpdateError("The download doesn't match its checksum. Try again later.") }

        let unpacked = tmp.appendingPathComponent("unpacked", isDirectory: true)
        guard try await run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path]) == 0 else {
            throw UpdateError("Couldn't unpack the update.")
        }
        let app = unpacked.appendingPathComponent("MacAwake.app", isDirectory: true)
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw UpdateError("The update doesn't contain MacAwake.app.")
        }
        guard try await run("/usr/bin/codesign", ["--verify", "--strict", app.path]) == 0 else {
            throw UpdateError("The update's signature is broken.")
        }
        // The right app, at the version the release says.
        let info = Bundle(url: app)?.infoDictionary
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              let v = info?["CFBundleShortVersionString"] as? String, components(v) == components(update.version)
        else { throw UpdateError("The update isn't the expected MacAwake version.") }
        return app
    }

    private static func checkStatus(_ response: URLResponse, _ what: String) throws {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw UpdateError("Couldn't download \(what) (\(http.statusCode)).")
        }
    }

    // MARK: - Install

    /// Where this app is installed, if it can be replaced in place.
    static func installedLocation() throws -> URL {
        let dest = Bundle.main.bundleURL
        guard dest.pathExtension == "app" else { throw UpdateError("MacAwake isn't running from an app bundle.") }
        guard !dest.path.contains("/AppTranslocation/") else {
            throw UpdateError("Move MacAwake to the Applications folder first, then update.")
        }
        return dest
    }

    /// A /bin/sh script that swaps `newApp` into `dest`, putting the old app back if the copy fails.
    static func swapScript(newApp: URL, dest: URL) -> String {
        let q = AdminShell.q
        let old = newApp.deletingLastPathComponent().appendingPathComponent("previous.app").path
        return [
            "set -e",
            "rm -rf \(q(old))",
            "mv \(q(dest.path)) \(q(old))",
            "if /usr/bin/ditto \(q(newApp.path)) \(q(dest.path)); then",
            "  /usr/bin/xattr -dr com.apple.quarantine \(q(dest.path)) 2>/dev/null || true",
            "  rm -rf \(q(old))",
            "else",
            "  rm -rf \(q(dest.path)); mv \(q(old)) \(q(dest.path)); exit 1",
            "fi",
        ].joined(separator: "\n")
    }

    /// True if the app can be swapped without an administrator password.
    static func canWriteWithoutAdmin(_ dest: URL) -> Bool {
        let fm = FileManager.default
        return fm.isWritableFile(atPath: dest.deletingLastPathComponent().path) && fm.isWritableFile(atPath: dest.path)
    }

    /// Deletes the temporary folder `download(_:)` made for `app`.
    static func cleanUp(_ app: URL) {
        let tmp = app.deletingLastPathComponent().deletingLastPathComponent()
        guard tmp.lastPathComponent.hasPrefix("macawake-update-") else { return }
        try? FileManager.default.removeItem(at: tmp)
    }

    /// Opens `app` again once this process has quit.
    static func relaunchAfterExit(_ app: URL) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$2\"",
                       "sh", String(ProcessInfo.processInfo.processIdentifier), app.path]
        try? p.run()
    }

    // MARK: - Plumbing

    /// Refuses redirects away from https, like `install.sh`'s `--proto-redir '=https'`.
    private final class HTTPSOnly: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest) async -> URLRequest? {
            request.url?.scheme == "https" ? request : nil
        }
    }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForResource = 300
        return URLSession(configuration: c, delegate: HTTPSOnly(), delegateQueue: nil)
    }()

    static func run(_ path: String, _ args: [String]) async throws -> Int32 {
        try await withCheckedThrowingContinuation { cont in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            p.terminationHandler = { cont.resume(returning: $0.terminationStatus) }
            do { try p.run() } catch { cont.resume(throwing: error) }
        }
    }
}

// MARK: - Self-test

/// Debug: `MacAwake --self-test-update [<dest.app>]` checks version comparison and download URL rules.
/// With `MACAWAKE_UPDATE_FEED` set and a destination, it also runs the real check, download, checks and
/// swap into that destination (never the running app, and no relaunch). Exits 1 on any failure.
func runUpdateSelfTest() -> Never {
    var failed = 0
    func check(_ name: String, _ ok: Bool) {
        if !ok { failed += 1 }
        print("\(ok ? "ok  " : "FAIL") \(name)")
    }
    check("1.0.42 > 1.0.41", Updater.isNewer("1.0.42", than: "1.0.41"))
    check("1.0.100 > 1.0.99 (numeric, not text)", Updater.isNewer("1.0.100", than: "1.0.99"))
    check("v1.1 > 1.0.99", Updater.isNewer("v1.1", than: "1.0.99"))
    check("1.0.42 not > 1.0.42", !Updater.isNewer("1.0.42", than: "1.0.42"))
    check("1.0 == 1.0.0", !Updater.isNewer("1.0.0", than: "1.0") && !Updater.isNewer("1.0", than: "1.0.0"))
    check("1.0.1 > 1.0-dev", Updater.isNewer("1.0.1", than: "1.0-dev"))
    check("junk is never newer", !Updater.isNewer("v1.x", than: "1.0") && !Updater.isNewer("", than: "1.0"))
    check("too many parts rejected", Updater.components("1.2.3.4.5") == nil)
    check("negative rejected", Updater.components("1.-2") == nil)
    let good = URL(string: "https://github.com/\(Updater.repo)/releases/download/v1.0.5/MacAwake.zip")!
    check("release download allowed", Updater.isAllowedDownload(good))
    check("http refused", !Updater.isAllowedDownload(URL(string: "http://github.com/\(Updater.repo)/releases/download/v1/MacAwake.zip")!))
    check("other repo refused", !Updater.isAllowedDownload(URL(string: "https://github.com/someone/MacAwake/releases/download/v1/MacAwake.zip")!))
    check("other host refused", !Updater.isAllowedDownload(URL(string: "https://example.com/\(Updater.repo)/releases/download/v1/MacAwake.zip")!))

    let args = CommandLine.arguments
    if Updater.isTesting, let i = args.firstIndex(of: "--self-test-update"), i + 1 < args.count {
        let dest = URL(fileURLWithPath: args[i + 1])
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                guard let update = try await Updater.checkLatest() else {
                    print("FAIL feed: no newer version than \(Updater.currentVersion)"); failed += 1; done.signal(); return
                }
                print("ok   feed: \(update.version) is newer than \(Updater.currentVersion)")
                let app = try await Updater.download(update)
                print("ok   downloaded and verified \(app.path)")
                let status = try await Updater.run("/bin/sh", ["-c", Updater.swapScript(newApp: app, dest: dest)])
                check("swapped into \(dest.path)", status == 0)
                Updater.cleanUp(app)
            } catch {
                print("FAIL \(error.localizedDescription)"); failed += 1
            }
            done.signal()
        }
        done.wait()
    }
    print(failed == 0 ? "All passed." : "\(failed) failed.")
    exit(failed == 0 ? 0 : 1)
}
