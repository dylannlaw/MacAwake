import CryptoKit
import XCTest
@testable import MacAwake

final class UpdaterTests: XCTestCase {
    override func setUp() {
        super.setUp()
        let saved = Updater.feedOverride
        addTeardownBlock { Updater.feedOverride = saved }
    }

    // MARK: Versions

    func testComponents() {
        XCTAssertEqual(Updater.components("v1.0.42"), [1, 0, 42])
        XCTAssertEqual(Updater.components("1.0-dev"), [1, 0])
        XCTAssertEqual(Updater.components("7"), [7])
        XCTAssertNil(Updater.components(""))
        XCTAssertNil(Updater.components("1.2.3.4.5"))
        XCTAssertNil(Updater.components("1.-2"))
        XCTAssertNil(Updater.components("1.x"))
        XCTAssertNil(Updater.components("1..2"))
    }

    func testIsNewer() {
        XCTAssertTrue(Updater.isNewer("1.0.100", than: "1.0.99"))
        XCTAssertTrue(Updater.isNewer("v1.1", than: "1.0.99"))
        XCTAssertTrue(Updater.isNewer("1.0.1", than: "1.0-dev"))
        XCTAssertFalse(Updater.isNewer("1.0.0", than: "1.0"))
        XCTAssertFalse(Updater.isNewer("1.0", than: "1.0.0"))
        XCTAssertFalse(Updater.isNewer("1.0.41", than: "1.0.42"))
        XCTAssertFalse(Updater.isNewer("junk", than: "1.0"))
    }

    func testAllowedDownloads() {
        let repo = Updater.repo
        XCTAssertTrue(Updater.isAllowedDownload(URL(string: "https://github.com/\(repo)/releases/download/v1/MacAwake.zip")!))
        XCTAssertFalse(Updater.isAllowedDownload(URL(string: "http://github.com/\(repo)/releases/download/v1/x")!))
        XCTAssertFalse(Updater.isAllowedDownload(URL(string: "https://github.com/other/MacAwake/releases/download/v1/x")!))
        XCTAssertFalse(Updater.isAllowedDownload(URL(string: "https://evil.example/\(repo)/releases/download/v1/x")!))
        XCTAssertFalse(Updater.isAllowedDownload(URL(fileURLWithPath: "/tmp/x")))   // files only while testing
        Updater.feedOverride = URL(fileURLWithPath: "/tmp/feed.json")
        XCTAssertTrue(Updater.isTesting)
        XCTAssertTrue(Updater.isAllowedDownload(URL(fileURLWithPath: "/tmp/x")))
    }

    func testVersionHelpers() {
        XCTAssertFalse(Updater.currentVersion.isEmpty)
        _ = Updater.isDevBuild
    }

    // MARK: Fixtures

    /// A release feed on disk that points at local files, as `MACAWAKE_UPDATE_FEED` allows.
    private struct Fixture {
        let feed: URL
        let zip: URL
        let sum: URL
    }

    private func makeApp(in dir: URL, version: String, withApp: Bool = true, bundleID: String? = Bundle.main.bundleIdentifier) throws -> URL {
        let src = dir.appendingPathComponent("src", isDirectory: true)
        let app = src.appendingPathComponent("MacAwake.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: withApp ? app.appendingPathComponent("MacOS") : src, withIntermediateDirectories: true)
        if withApp {
            try FileManager.default.copyItem(atPath: "/bin/echo", toPath: app.appendingPathComponent("MacOS/MacAwake").path)
            let idKey = bundleID.map { "<key>CFBundleIdentifier</key><string>\($0)</string>" } ?? ""
            try """
            <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>\(idKey)\
            <key>CFBundleExecutable</key><string>MacAwake</string>\
            <key>CFBundleShortVersionString</key><string>\(version)</string></dict></plist>
            """.write(to: app.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
            try run("/usr/bin/codesign", ["--force", "-s", "-", src.appendingPathComponent("MacAwake.app").path])
        } else {
            try "nothing".write(to: src.appendingPathComponent("readme.txt"), atomically: true, encoding: .utf8)
        }
        return src
    }

    @discardableResult
    private func run(_ path: String, _ args: [String]) throws -> Int32 {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        return p.terminationStatus
    }

    private func makeFixture(tag: String = "v99999.9.9", appVersion: String = "99999.9.9", withApp: Bool = true,
                             checksum: ((String) -> String)? = nil, draft: Bool = false, prerelease: Bool = false,
                             assets: [String] = ["MacAwake.zip", "MacAwake.zip.sha256"], bundleID: String? = Bundle.main.bundleIdentifier) throws -> Fixture {
        let dir = makeTempDir(self)
        let src = try makeApp(in: dir, version: appVersion, withApp: withApp, bundleID: bundleID)
        let zip = dir.appendingPathComponent("MacAwake.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", src.path, zip.path])
        // `ditto --keepParent` puts the folder in the zip; we want MacAwake.app at the top, so zip its contents.
        try FileManager.default.removeItem(at: zip)
        try run("/usr/bin/ditto", ["-c", "-k", src.path, zip.path])
        let hash = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
        let sum = dir.appendingPathComponent("MacAwake.zip.sha256")
        try (checksum?(hash) ?? "\(hash)  MacAwake.zip\n").write(to: sum, atomically: true, encoding: .utf8)
        let urls = ["MacAwake.zip": zip, "MacAwake.zip.sha256": sum]
        let list = assets.map { "{\"name\":\"\($0)\",\"browser_download_url\":\"\(urls[$0]?.absoluteString ?? "https://example.com/x")\"}" }
        let feed = dir.appendingPathComponent("feed.json")
        try """
        {"tag_name":"\(tag)","draft":\(draft),"prerelease":\(prerelease),"assets":[\(list.joined(separator: ","))]}
        """.write(to: feed, atomically: true, encoding: .utf8)
        Updater.feedOverride = feed
        return Fixture(feed: feed, zip: zip, sum: sum)
    }

    private func expectError(_ text: String, file: StaticString = #filePath, line: UInt = #line,
                             _ body: () async throws -> Void) async {
        do { try await body(); XCTFail("expected an error", file: file, line: line) }
        catch { XCTAssertTrue(text.isEmpty || error.localizedDescription.contains(text), "\(error.localizedDescription)", file: file, line: line) }
    }

    // MARK: Check

    func testCheckLatestFindsNewerRelease() async throws {
        let f = try makeFixture()
        let u = try await Updater.checkLatest()
        XCTAssertEqual(u?.version, "99999.9.9")
        XCTAssertEqual(u?.zipURL, f.zip)
        XCTAssertEqual(u?.checksumURL, f.sum)
    }

    func testCheckLatestUpToDate() async throws {
        _ = try makeFixture(tag: "v0.0.1", appVersion: "0.0.1")
        let none = try await Updater.checkLatest()
        XCTAssertNil(none)
    }

    func testCheckLatestRejectsBadReleases() async throws {
        _ = try makeFixture(draft: true)
        await expectError("unexpected version") { _ = try await Updater.checkLatest() }
        _ = try makeFixture(prerelease: true)
        await expectError("unexpected version") { _ = try await Updater.checkLatest() }
        _ = try makeFixture(tag: "latest")
        await expectError("unexpected version") { _ = try await Updater.checkLatest() }
        _ = try makeFixture(assets: ["MacAwake.zip"])
        await expectError("missing MacAwake.zip.sha256") { _ = try await Updater.checkLatest() }
        _ = try makeFixture(assets: [])
        await expectError("missing MacAwake.zip") { _ = try await Updater.checkLatest() }
    }

    func testCheckLatestFailsOnMissingFeed() async {
        Updater.feedOverride = URL(fileURLWithPath: "/nonexistent/feed.json")
        await expectError("") { _ = try await Updater.checkLatest() }
    }

    func testCheckLatestRefusesDisallowedDownloadHost() async throws {
        _ = try makeFixture(assets: ["MacAwake.zip", "MacAwake.zip.sha256"])
        // A release whose files live somewhere else than this repo's releases.
        let dir = makeTempDir(self)
        let feed = dir.appendingPathComponent("feed.json")
        try """
        {"tag_name":"v99999.9.9","assets":[{"name":"MacAwake.zip","browser_download_url":"https://evil.example/x.zip"},
        {"name":"MacAwake.zip.sha256","browser_download_url":"https://evil.example/x.sha"}]}
        """.write(to: feed, atomically: true, encoding: .utf8)
        Updater.feedOverride = feed
        await expectError("missing MacAwake.zip") { _ = try await Updater.checkLatest() }
    }

    // MARK: Download

    func testDownloadVerifiesAndUnpacks() async throws {
        _ = try makeFixture()
        let update = try await Updater.checkLatest()!
        let app = try await Updater.download(update)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path))
        Updater.cleanUp(app)
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path))
    }

    func testDownloadRejectsBadChecksums() async throws {
        _ = try makeFixture(checksum: { _ in "not-a-hash\n" })
        var update = try await Updater.checkLatest()!
        await expectError("checksum file isn't valid") { _ = try await Updater.download(update) }
        _ = try makeFixture(checksum: { _ in String(repeating: "0", count: 64) })
        update = try await Updater.checkLatest()!
        await expectError("doesn't match its checksum") { _ = try await Updater.download(update) }
    }

    func testDownloadRejectsWrongContents() async throws {
        _ = try makeFixture(withApp: false)
        var update = try await Updater.checkLatest()!
        await expectError("doesn't contain MacAwake.app") { _ = try await Updater.download(update) }
        _ = try makeFixture(appVersion: "1.2.3")
        update = try await Updater.checkLatest()!
        await expectError("isn't the expected MacAwake version") { _ = try await Updater.download(update) }
        _ = try makeFixture(bundleID: "local.someone.else")
        update = try await Updater.checkLatest()!
        await expectError("isn't the expected MacAwake version") { _ = try await Updater.download(update) }
    }

    func testDownloadRejectsBrokenSignatureAndBadZip() async throws {
        let f = try makeFixture()
        let update = try await Updater.checkLatest()!
        // Not a zip at all (with a matching checksum).
        try "plain".write(to: f.zip, atomically: true, encoding: .utf8)
        let hash = SHA256.hash(data: Data("plain".utf8)).map { String(format: "%02x", $0) }.joined()
        try hash.write(to: f.sum, atomically: true, encoding: .utf8)
        await expectError("Couldn't unpack") { _ = try await Updater.download(update) }
        // Missing files.
        try FileManager.default.removeItem(at: f.zip)
        await expectError("") { _ = try await Updater.download(update) }
    }

    func testDownloadRejectsUnsignedApp() async throws {
        let dir = makeTempDir(self)
        let src = try makeApp(in: dir, version: "99999.9.9")
        try run("/usr/bin/codesign", ["--remove-signature", src.appendingPathComponent("MacAwake.app").path])
        let zip = dir.appendingPathComponent("MacAwake.zip")
        try run("/usr/bin/ditto", ["-c", "-k", src.path, zip.path])
        let sum = dir.appendingPathComponent("sum")
        try SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            .write(to: sum, atomically: true, encoding: .utf8)
        Updater.feedOverride = dir.appendingPathComponent("feed.json")
        await expectError("signature is broken") {
            _ = try await Updater.download(AvailableUpdate(version: "99999.9.9", zipURL: zip, checksumURL: sum))
        }
    }

    // MARK: Install helpers

    func testInstalledLocationRefusesNonApp() {
        // Tests run from the xctest tool, not from an app bundle.
        XCTAssertThrowsError(try Updater.installedLocation())
    }

    func testSwapScriptReplacesApp() throws {
        let dir = makeTempDir(self)
        let dest = dir.appendingPathComponent("MacAwake.app", isDirectory: true)
        let new = dir.appendingPathComponent("new/MacAwake.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: new, withIntermediateDirectories: true)
        try "old".write(to: dest.appendingPathComponent("v"), atomically: true, encoding: .utf8)
        try "new".write(to: new.appendingPathComponent("v"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try run("/bin/sh", ["-c", Updater.swapScript(newApp: new, dest: dest)]), 0)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("v")), "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("new/previous.app").path))
    }

    func testSwapScriptPutsOldAppBackOnFailure() throws {
        let dir = makeTempDir(self)
        let dest = dir.appendingPathComponent("MacAwake.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "old".write(to: dest.appendingPathComponent("v"), atomically: true, encoding: .utf8)
        let missing = dir.appendingPathComponent("nope/MacAwake.app")
        try FileManager.default.createDirectory(at: missing.deletingLastPathComponent(), withIntermediateDirectories: true)
        XCTAssertNotEqual(try run("/bin/sh", ["-c", Updater.swapScript(newApp: missing, dest: dest)]), 0)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("v")), "old")
    }

    func testWritableAndCleanUp() throws {
        let dir = makeTempDir(self)
        XCTAssertTrue(Updater.canWriteWithoutAdmin(dir.appendingPathComponent("x.app")) == false)   // x.app doesn't exist
        let app = dir.appendingPathComponent("x.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        XCTAssertTrue(Updater.canWriteWithoutAdmin(app))
        XCTAssertFalse(Updater.canWriteWithoutAdmin(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
        // Only its own temporary folders are deleted.
        let inner = dir.appendingPathComponent("unpacked/MacAwake.app")
        try FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true)
        Updater.cleanUp(inner)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path))
    }

    func testRelaunchAfterExitStartsAWaitingShell() {
        Updater.relaunchAfterExit(URL(fileURLWithPath: "/nonexistent/Nothing.app"))
    }

    func testRunReportsStatusAndErrors() async throws {
        let ok = try await Updater.run("/usr/bin/true", [])
        let bad = try await Updater.run("/usr/bin/false", [])
        XCTAssertEqual(ok, 0)
        XCTAssertEqual(bad, 1)
        await expectError("") { _ = try await Updater.run("/nonexistent/program", []) }
    }

    // MARK: Self-test

    func testSelfTestChecksPass() async {
        let r = await updateSelfTest(arguments: ["MacAwake"])
        XCTAssertEqual(r.failed, 0)
        XCTAssertEqual(r.lines.last, "All passed.")
    }

    func testSelfTestRunsTheWholeFlow() async throws {
        _ = try makeFixture()
        let dest = makeTempDir(self).appendingPathComponent("MacAwake.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let r = await updateSelfTest(arguments: ["MacAwake", "--self-test-update", dest.path])
        XCTAssertEqual(r.failed, 0, r.lines.joined(separator: "\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Contents/Info.plist").path))
    }

    func testSelfTestReportsFailures() async throws {
        _ = try makeFixture(tag: "v0.0.1", appVersion: "0.0.1")
        let dest = makeTempDir(self).appendingPathComponent("MacAwake.app")
        var r = await updateSelfTest(arguments: ["MacAwake", "--self-test-update", dest.path])
        XCTAssertEqual(r.failed, 1)   // nothing newer
        Updater.feedOverride = URL(fileURLWithPath: "/nonexistent")
        r = await updateSelfTest(arguments: ["MacAwake", "--self-test-update", dest.path])
        XCTAssertEqual(r.failed, 1)
    }
}

@MainActor
final class ControllerUpdateTests: XCTestCase {
    private let update = AvailableUpdate(version: "9.9.9", zipURL: URL(string: "https://x/z")!, checksumURL: URL(string: "https://x/s")!)

    private func rig(_ check: @escaping () async throws -> AvailableUpdate?) -> Rig {
        makeRig(self, checkLatest: check)
    }

    func testManualCheckFindsUpdate() async throws {
        let r = rig { self.update }
        r.controller.checkForUpdatesNow()
        XCTAssertTrue(r.controller.updateBusy)
        XCTAssertEqual(r.controller.updateMessage, "Checking for updates…")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(r.controller.updateBusy)
        XCTAssertEqual(r.controller.availableUpdate, update)
        XCTAssertEqual(r.controller.shownUpdate, update)
        XCTAssertNil(r.controller.updateMessage)
        r.controller.dismissUpdate()
        XCTAssertNil(r.controller.shownUpdate)
        XCTAssertEqual(r.defaults.string(forKey: "dismissedUpdateVersion"), "9.9.9")
    }

    func testManualCheckUpToDateAndFailure() async throws {
        let none = rig { nil }
        none.controller.checkForUpdatesNow()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(none.controller.updateMessage?.hasSuffix("is up to date.") ?? false)
        XCTAssertFalse(none.controller.updateFailed)
        struct Offline: LocalizedError { var errorDescription: String? { "offline" } }
        let bad = rig { throw Offline() }
        bad.controller.checkForUpdatesNow()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(bad.controller.updateMessage, "Couldn't check for updates: offline")
        XCTAssertTrue(bad.controller.updateFailed)
        XCTAssertFalse(bad.controller.updateBusy)
    }

    func testAutomaticCheckIsQuietAndNotReentrant() async throws {
        let quiet = rig { throw URLError(.notConnectedToInternet) }
        quiet.controller.checkForUpdatesNow(manual: false)
        quiet.controller.checkForUpdatesNow(manual: false)   // already busy
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(quiet.controller.updateMessage)
        let found = rig { self.update }
        found.controller.checkForUpdatesNow(manual: false)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(found.controller.availableUpdate, update)
    }

    func testSettingAndRestoredState() {
        let r = rig { nil }
        XCTAssertTrue(r.controller.checkForUpdates)
        r.controller.checkForUpdates = false
        r.controller.refresh()   // tests never check by themselves
        XCTAssertFalse(r.controller.updateBusy)
        let again = AwakeController(defaults: r.defaults, waker: r.waker, lid: r.lid, hooks: .init())
        XCTAssertFalse(again.checkForUpdates)
    }

    func testInstallNeedsAnApp() async throws {
        let r = rig { self.update }
        r.controller.installUpdate()                 // nothing available yet: nothing happens
        XCTAssertNil(r.controller.updateMessage)
        r.controller.checkForUpdatesNow()
        try await Task.sleep(nanoseconds: 300_000_000)
        r.controller.installUpdate()                 // not running from an app bundle: says so
        XCTAssertTrue(r.controller.updateFailed)
        XCTAssertEqual(r.controller.updateMessage, "MacAwake isn't running from an app bundle.")
    }
}

@MainActor
final class ControllerStartupAndInstallTests: XCTestCase {
    func testStartupWithFullAccess() {
        let r = makeRig(self, calendar: false, authorization: .fullAccess)
        XCTAssertTrue(r.controller.hasAccess)
    }

    func testStartupWithoutAccess() {
        let r = makeRig(self, calendar: false, authorization: .denied)
        XCTAssertFalse(r.controller.hasAccess)
        XCTAssertEqual(r.controller.statusLine, "Needs calendar access")
    }

    func testStartupAsksWhenUndecided() async throws {
        let r = makeRig(self, calendar: false, requestAccess: { true }, authorization: .notDetermined)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(r.controller.hasAccess)
    }

    func testDeviceReaders() {
        _ = DeviceInfo.productName()
        _ = DeviceInfo.model()
        _ = DeviceInfo.hasClamshell()
        XCTAssertNotNil(DeviceKind.current)
    }

    // MARK: Install

    private func fixture(version: String) throws -> (AvailableUpdate, URL) {
        let dir = makeTempDir(self)
        let src = dir.appendingPathComponent("src/MacAwake.app/Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("MacOS"), withIntermediateDirectories: true)
        try FileManager.default.copyItem(atPath: "/bin/echo", toPath: src.appendingPathComponent("MacOS/MacAwake").path)
        let id = Bundle.main.bundleIdentifier.map { "<key>CFBundleIdentifier</key><string>\($0)</string>" } ?? ""
        try """
        <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>\(id)\
        <key>CFBundleExecutable</key><string>MacAwake</string>\
        <key>CFBundleShortVersionString</key><string>\(version)</string></dict></plist>
        """.write(to: src.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
        func run(_ path: String, _ args: [String]) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
            p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
        try run("/usr/bin/codesign", ["--force", "-s", "-", dir.appendingPathComponent("src/MacAwake.app").path])
        let zip = dir.appendingPathComponent("MacAwake.zip")
        try run("/usr/bin/ditto", ["-c", "-k", dir.appendingPathComponent("src").path, zip.path])
        let sum = dir.appendingPathComponent("MacAwake.zip.sha256")
        try SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            .write(to: sum, atomically: true, encoding: .utf8)
        let saved = Updater.feedOverride
        Updater.feedOverride = dir.appendingPathComponent("feed.json")
        addTeardownBlock { Updater.feedOverride = saved }
        return (AvailableUpdate(version: version, zipURL: zip, checksumURL: sum), dir)
    }

    private func installed(_ dest: URL, in r: Rig, update: AvailableUpdate) async throws {
        r.controller.checkForUpdatesNow()
        try await Task.sleep(nanoseconds: 300_000_000)
        r.controller.installUpdate()
        try await Task.sleep(nanoseconds: 2_000_000_000)
    }

    func testInstallSwapsTheAppAndRelaunches() async throws {
        let (update, dir) = try fixture(version: "99999.9.9")
        let dest = dir.appendingPathComponent("Installed/MacAwake.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        try "old".write(to: dest.appendingPathComponent("old.txt"), atomically: true, encoding: .utf8)
        let relaunched = Box<URL?>(nil)
        let r = makeRig(self, checkLatest: { update }, installDest: dest, relaunch: { relaunched.value = $0 })
        try await installed(dest, in: r, update: update)
        XCTAssertEqual(relaunched.value, dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("Contents/Info.plist").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dest.appendingPathComponent("old.txt").path))
    }

    func testInstallFailureShowsMessage() async throws {
        let (update, dir) = try fixture(version: "1.2.3")   // not the version the release claims
        let bad = AvailableUpdate(version: "99999.9.9", zipURL: update.zipURL, checksumURL: update.checksumURL)
        let dest = dir.appendingPathComponent("Installed/MacAwake.app", isDirectory: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        let r = makeRig(self, checkLatest: { bad }, installDest: dest, relaunch: { _ in XCTFail("must not relaunch") })
        try await installed(dest, in: r, update: bad)
        XCTAssertTrue(r.controller.updateFailed)
        XCTAssertFalse(r.controller.updateBusy)
    }

    func testInstallUsesAdminWhenNotWritable() async throws {
        let (update, _) = try fixture(version: "99999.9.9")
        let seen = withFakeAdmin(self)
        let relaunched = Box<URL?>(nil)
        let dest = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let r = makeRig(self, checkLatest: { update }, installDest: dest, relaunch: { relaunched.value = $0 })
        try await installed(dest, in: r, update: update)
        XCTAssertEqual(seen.value.count, 1)
        XCTAssertEqual(relaunched.value, dest)
    }

    func testInstallAdminRefusedStopsWithMessage() async throws {
        let (update, _) = try fixture(version: "99999.9.9")
        _ = withFakeAdmin(self, succeed: false)
        let dest = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        let r = makeRig(self, checkLatest: { update }, installDest: dest, relaunch: { _ in XCTFail("must not relaunch") })
        try await installed(dest, in: r, update: update)
        XCTAssertEqual(r.controller.updateMessage, "Couldn't replace the app. Nothing was changed.")
    }
}
