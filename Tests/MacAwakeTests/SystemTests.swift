import IOKit.pwr_mgt
import XCTest
@testable import MacAwake

final class AdminShellTests: XCTestCase {
    func testQuoting() {
        XCTAssertEqual(AdminShell.q("abc"), "'abc'")
        XCTAssertEqual(AdminShell.q("it's"), "'it'\\''s'")
        XCTAssertEqual(AdminShell.q(""), "''")
    }

    func testAppleScriptEscapes() {
        let s = AdminShell.appleScript(for: #"echo "a\b""#, prompt: "Hi")
        XCTAssertEqual(s, #"do shell script "echo \"a\\b\"" with prompt "Hi" with administrator privileges"#)
    }

    func testHelperVersion() throws {
        let dir = makeTempDir(self)
        func write(_ name: String, _ body: String) -> String {
            let f = dir.appendingPathComponent(name)
            try! body.write(to: f, atomically: true, encoding: .utf8)
            return f.path
        }
        XCTAssertEqual(AdminShell.helperVersion(atPath: write("v3", "#!/bin/sh\n# macawake-helper-version: 3\n")), 3)
        XCTAssertEqual(AdminShell.helperVersion(atPath: write("none", "#!/bin/sh\necho hi\n")), 1)
        XCTAssertEqual(AdminShell.helperVersion(atPath: write("junk", "# macawake-helper-version: x\n")), 1)
        // The marker must be near the top.
        let late = String(repeating: "# filler\n", count: 12) + "# macawake-helper-version: 9\n"
        XCTAssertEqual(AdminShell.helperVersion(atPath: write("late", late)), 1)
        XCTAssertNil(AdminShell.helperVersion(atPath: dir.appendingPathComponent("missing").path))
    }

    func testRunUsesRunner() {
        let seen = withFakeAdmin(self)
        let done = expectation(description: "done")
        AdminShell.run("do it", prompt: "p") { ok in XCTAssertTrue(ok); done.fulfill() }
        wait(for: [done], timeout: 2)
        XCTAssertEqual(seen.value, ["do it"])
    }

    /// The real runner, pointed at a stand-in for osascript.
    private func runOsascript(_ script: String?) -> Bool {
        let dir = makeTempDir(self)
        let saved = AdminShell.osascriptPath
        addTeardownBlock { AdminShell.osascriptPath = saved }
        if let script {
            let f = dir.appendingPathComponent("fake-osascript")
            try! "#!/bin/sh\n\(script)\n".write(to: f, atomically: true, encoding: .utf8)
            try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
            AdminShell.osascriptPath = f.path
        } else {
            AdminShell.osascriptPath = dir.appendingPathComponent("nope").path
        }
        var result: Bool?
        let done = expectation(description: "done")
        AdminShell.runWithOsascript("true", prompt: "p") { ok in result = ok; done.fulfill() }
        wait(for: [done], timeout: 5)
        return result!
    }

    func testOsascriptSuccess() { XCTAssertTrue(runOsascript("exit 0")) }
    func testOsascriptFailureLogs() { XCTAssertFalse(runOsascript("echo cancelled >&2; exit 1")) }
    func testOsascriptMissingProgram() { XCTAssertFalse(runOsascript(nil)) }
}

final class SleepAssertionTests: XCTestCase {
    private func holdsAssertion(named reason: String) -> Bool {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let all = dict?.takeRetainedValue() as? [Int: [[String: Any]]] else { return false }
        return all[Int(getpid())]?.contains { ($0["AssertName"] as? String) == reason } ?? false
    }

    func testEnableAndDisable() {
        let a = SleepAssertion()
        XCTAssertFalse(a.isActive)
        a.enable(reason: "MacAwake test A", keepDisplayOn: true)
        XCTAssertTrue(a.isActive)
        XCTAssertTrue(holdsAssertion(named: "MacAwake test A"))
        a.enable(reason: "MacAwake test A", keepDisplayOn: true)   // no change: no churn
        XCTAssertTrue(a.isActive)
        a.enable(reason: "MacAwake test B", keepDisplayOn: false)  // new reason: replaced
        XCTAssertTrue(holdsAssertion(named: "MacAwake test B"))
        XCTAssertFalse(holdsAssertion(named: "MacAwake test A"))
        a.disable()
        XCTAssertFalse(a.isActive)
        XCTAssertFalse(holdsAssertion(named: "MacAwake test B"))
        a.disable()   // harmless twice
    }

    func testUserActivityAndCheckIn() {
        let a = SleepAssertion()
        a.declareUserActivity(reason: "MacAwake test activity")
        a.holdForCheckIn(seconds: 1)
        a.holdForCheckIn(seconds: 1)   // replaces the first
    }

    func testDeinitReleases() {
        var a: SleepAssertion? = SleepAssertion()
        a?.enable(reason: "MacAwake test C", keepDisplayOn: false)
        a?.holdForCheckIn(seconds: 30)
        a = nil
        XCTAssertFalse(holdsAssertion(named: "MacAwake test C"))
    }
}

final class SystemPowerTests: XCTestCase {
    func testMessages() {
        var wakes = 0
        let p = SystemPower { wakes += 1 }
        p.handle(0xE000_0300, nil)           // powered on
        XCTAssertEqual(wakes, 1)
        p.handle(0xE000_0270, nil)           // can sleep: acknowledged, no wake
        p.handle(0xE000_0280, nil)           // will sleep
        p.handle(0x1234, nil)                // anything else ignored
        XCTAssertEqual(wakes, 1)
    }
}
