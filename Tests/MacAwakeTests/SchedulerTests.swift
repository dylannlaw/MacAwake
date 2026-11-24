import XCTest
@testable import MacAwake

final class WakeSchedulerTests: XCTestCase {
    private func make(_ dir: URL, installed: Bool = false, bundle: Bundle = .main) -> WakeScheduler {
        let plist = dir.appendingPathComponent("w.plist")
        if installed { try! "x".write(to: plist, atomically: true, encoding: .utf8) }
        return WakeScheduler(requestDir: dir.appendingPathComponent("req"), daemonPlist: plist,
                             helperPath: dir.appendingPathComponent("helper").path, bundle: bundle)
    }

    func testRequestWritesRoundedTimestampAndDedupes() throws {
        let w = make(makeTempDir(self))
        let date = Date(timeIntervalSince1970: 1_000_000.4)
        w.request(date)
        XCTAssertEqual(try String(contentsOf: w.requestFile), "1000006\n")   // ceil + 5 s slack
        try "changed".write(to: w.requestFile, atomically: true, encoding: .utf8)
        w.request(date)                                                      // same value: not rewritten
        XCTAssertEqual(try String(contentsOf: w.requestFile), "changed")
        w.request(nil)                                                       // clear
        XCTAssertEqual(try String(contentsOf: w.requestFile), "")
    }

    func testRequestFailureIsSurvivable() {
        let dir = makeTempDir(self)
        let blocker = dir.appendingPathComponent("file")
        try! "x".write(to: blocker, atomically: true, encoding: .utf8)
        let w = WakeScheduler(requestDir: blocker.appendingPathComponent("sub"),
                              daemonPlist: dir.appendingPathComponent("p"), helperPath: "/nope", bundle: .main)
        w.request(Date())   // logs, doesn't crash
        XCTAssertFalse(FileManager.default.fileExists(atPath: w.requestFile.path))
    }

    func testInstalledFlag() {
        let dir = makeTempDir(self)
        XCTAssertFalse(make(dir).isHelperInstalled)
        XCTAssertTrue(make(dir, installed: true).isHelperInstalled)
    }

    func testInstallRunsScriptAndWritesPlist() {
        let bundle = makeBundle(self, wakeVersion: 2, lidVersion: 2)
        let dir = makeTempDir(self)
        let w = make(dir, bundle: bundle)
        var plistText = ""
        let seen = withFakeAdmin(self) { _ in
            let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("\(WakeScheduler.label).plist")
            plistText = (try? String(contentsOf: tmp)) ?? ""
        }
        var ok: Bool?
        w.request(Date())
        w.install { ok = $0 }
        XCTAssertEqual(ok, true)
        XCTAssertEqual(seen.value.count, 1)
        XCTAssertTrue(seen.value[0].contains("launchctl bootstrap system"))
        XCTAssertTrue(seen.value[0].contains(AdminShell.q(dir.appendingPathComponent("helper").path)))
        XCTAssertTrue(plistText.contains(WakeScheduler.label))
        XCTAssertTrue(plistText.contains(w.requestDir.path))
    }

    func testInstallFailureReported() {
        _ = withFakeAdmin(self, succeed: false)
        var ok: Bool?
        make(makeTempDir(self), bundle: makeBundle(self, wakeVersion: 1, lidVersion: 1)).install { ok = $0 }
        XCTAssertEqual(ok, false)
    }

    func testInstallWithoutBundledHelperFails() {
        var ok: Bool?
        make(makeTempDir(self), bundle: makeBundle(self, wakeVersion: 1, lidVersion: 1)).install { _ in }
        let empty = Bundle(path: makeTempDir(self).path)!
        make(makeTempDir(self), bundle: empty).install { ok = $0 }
        XCTAssertEqual(ok, false)
    }

    func testInstallCannotCreateRequestDir() {
        let dir = makeTempDir(self)
        let blocker = dir.appendingPathComponent("file")
        try! "x".write(to: blocker, atomically: true, encoding: .utf8)
        let w = WakeScheduler(requestDir: blocker.appendingPathComponent("sub"), daemonPlist: dir.appendingPathComponent("p"),
                              helperPath: "/nope", bundle: makeBundle(self, wakeVersion: 1, lidVersion: 1))
        var ok: Bool?
        w.install { ok = $0 }
        XCTAssertEqual(ok, false)
    }

    func testUninstallScript() {
        let seen = withFakeAdmin(self)
        var ok: Bool?
        make(makeTempDir(self)).uninstall { ok = $0 }
        XCTAssertEqual(ok, true)
        XCTAssertTrue(seen.value[0].contains("bootout system/\(WakeScheduler.label)"))
        XCTAssertTrue(seen.value[0].contains("pmset schedule cancel wake"))
    }

    func testHelperNeedsUpdate() throws {
        let dir = makeTempDir(self)
        let bundle = makeBundle(self, wakeVersion: 3, lidVersion: 3)
        let w = make(dir, installed: true, bundle: bundle)
        XCTAssertFalse(w.helperNeedsUpdate)   // no installed copy to compare with
        func installedCopy(_ marker: String) { try! "#!/bin/sh\n\(marker)".write(toFile: dir.appendingPathComponent("helper").path, atomically: true, encoding: .utf8) }
        installedCopy("# macawake-helper-version: 2\n")
        XCTAssertTrue(w.helperNeedsUpdate)
        installedCopy("# macawake-helper-version: 3\n")
        XCTAssertFalse(w.helperNeedsUpdate)
        installedCopy("")                     // the very first helpers had no marker: version 1
        XCTAssertTrue(w.helperNeedsUpdate)
        XCTAssertFalse(make(makeTempDir(self), installed: false, bundle: bundle).helperNeedsUpdate)
    }
}

final class LidSchedulerTests: XCTestCase {
    private func make(_ dir: URL, installed: Bool = false, readOnly: Bool = false, bundle: Bundle = .main) -> LidScheduler {
        let plist = dir.appendingPathComponent("l.plist")
        if installed { try! "x".write(to: plist, atomically: true, encoding: .utf8) }
        return LidScheduler(leaseDir: dir.appendingPathComponent("lid"), daemonPlist: plist,
                            helperPath: dir.appendingPathComponent("helper").path,
                            statePath: dir.appendingPathComponent("state").path, bundle: bundle, readOnly: readOnly)
    }

    func testLeaseWrittenRenewedAndCleared() throws {
        let l = make(makeTempDir(self))
        let t0 = Date(timeIntervalSince1970: 5000)
        l.request(true, now: t0)
        XCTAssertEqual(try String(contentsOf: l.leaseFile), "5180\n")
        try "marker".write(to: l.leaseFile, atomically: true, encoding: .utf8)
        l.request(true, now: t0.addingTimeInterval(30))    // plenty left: not rewritten
        XCTAssertEqual(try String(contentsOf: l.leaseFile), "marker")
        l.request(true, now: t0.addingTimeInterval(100))   // under 120 s left: renewed
        XCTAssertEqual(try String(contentsOf: l.leaseFile), "5280\n")
        l.request(false, now: t0)
        XCTAssertEqual(try String(contentsOf: l.leaseFile), "")
        try "marker".write(to: l.leaseFile, atomically: true, encoding: .utf8)
        l.request(false)                                    // already cleared: not rewritten
        XCTAssertEqual(try String(contentsOf: l.leaseFile), "marker")
    }

    func testReadOnlyNeverWrites() {
        let l = make(makeTempDir(self), readOnly: true)
        l.request(true)
        l.request(false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.leaseFile.path))
    }

    func testWriteFailureIsSurvivable() {
        let dir = makeTempDir(self)
        let blocker = dir.appendingPathComponent("file")
        try! "x".write(to: blocker, atomically: true, encoding: .utf8)
        let l = LidScheduler(leaseDir: blocker.appendingPathComponent("sub"), daemonPlist: dir.appendingPathComponent("p"),
                             helperPath: "/nope", statePath: "/nope", bundle: .main, readOnly: false)
        l.request(true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: l.leaseFile.path))
        var ok: Bool?
        LidScheduler(leaseDir: blocker.appendingPathComponent("sub"), daemonPlist: dir.appendingPathComponent("p"),
                     helperPath: "/nope", statePath: "/nope", bundle: makeBundle(self, wakeVersion: 1, lidVersion: 1),
                     readOnly: false).install { ok = $0 }
        XCTAssertEqual(ok, false)
    }

    func testStateAndInstalled() throws {
        let dir = makeTempDir(self)
        let l = make(dir)
        XCTAssertFalse(l.isHelperInstalled)
        XCTAssertFalse(l.isHoldActive)
        try "1\n".write(toFile: l.statePath, atomically: true, encoding: .utf8)
        XCTAssertTrue(l.isHoldActive)
        try "0\n".write(toFile: l.statePath, atomically: true, encoding: .utf8)
        XCTAssertFalse(l.isHoldActive)
        XCTAssertTrue(make(dir, installed: true).isHelperInstalled)
    }

    func testInstall() {
        let dir = makeTempDir(self)
        let l = make(dir, bundle: makeBundle(self, wakeVersion: 1, lidVersion: 1))
        let seen = withFakeAdmin(self)
        var ok: Bool?
        l.request(true)
        l.install { ok = $0 }
        XCTAssertEqual(ok, true)
        XCTAssertTrue(seen.value[0].contains("bootstrap system"))
        XCTAssertEqual(try? String(contentsOf: l.leaseFile), "")   // starts with no lease
    }

    func testInstallFailsWithoutHelperOrAdmin() {
        var ok: Bool?
        make(makeTempDir(self), bundle: Bundle(path: makeTempDir(self).path)!).install { ok = $0 }
        XCTAssertEqual(ok, false)
        _ = withFakeAdmin(self, succeed: false)
        make(makeTempDir(self), bundle: makeBundle(self, wakeVersion: 1, lidVersion: 1)).install { ok = $0 }
        XCTAssertEqual(ok, false)
    }

    func testUninstall() {
        let seen = withFakeAdmin(self)
        var ok: Bool?
        make(makeTempDir(self)).uninstall { ok = $0 }
        XCTAssertEqual(ok, true)
        XCTAssertTrue(seen.value[0].contains("disablesleep 0"))
        _ = withFakeAdmin(self, succeed: false)
        make(makeTempDir(self)).uninstall { ok = $0 }
        XCTAssertEqual(ok, false)
    }

    func testHelperNeedsUpdate() {
        let dir = makeTempDir(self)
        let bundle = makeBundle(self, wakeVersion: 1, lidVersion: 2)
        let l = make(dir, installed: true, bundle: bundle)
        XCTAssertFalse(l.helperNeedsUpdate)
        try! "#!/bin/sh\n# macawake-helper-version: 1\n".write(toFile: dir.appendingPathComponent("helper").path, atomically: true, encoding: .utf8)
        XCTAssertTrue(l.helperNeedsUpdate)
    }
}
