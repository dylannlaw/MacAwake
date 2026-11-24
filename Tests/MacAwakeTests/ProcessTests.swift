import XCTest
@testable import MacAwake

final class WatchedItemTests: XCTestCase {
    func testCommandItem() {
        let c = WatchedItem.command("Claude")
        XCTAssertEqual(c.id, "claude")
        XCTAssertEqual(c.name, "Claude")
        XCTAssertEqual(c.kind, .command)
        XCTAssertEqual(c.rule, .working)
        XCTAssertEqual(WatchedItem.command("x", rule: .running).rule, .running)
    }

    func testPresets() {
        XCTAssertEqual(WatchedItem.aiAgentPresets.map(\.id),
                       ["claude", "codex", "gemini", "aider", "cursor-agent", "opencode"])
    }

    func testCleanCommandName() {
        XCTAssertEqual(WatchedItem.cleanCommandName("  Claude  "), "claude")
        XCTAssertEqual(WatchedItem.cleanCommandName("/usr/local/bin/Codex"), "codex")
        XCTAssertEqual(WatchedItem.cleanCommandName("cursor-agent"), "cursor-agent")
        XCTAssertEqual(WatchedItem.cleanCommandName("a.b_c+d"), "a.b_c+d")
        XCTAssertNil(WatchedItem.cleanCommandName(""))
        XCTAssertNil(WatchedItem.cleanCommandName("   "))
        XCTAssertNil(WatchedItem.cleanCommandName("bad name"))
        XCTAssertNil(WatchedItem.cleanCommandName("semi;colon"))
        XCTAssertNil(WatchedItem.cleanCommandName(String(repeating: "a", count: 65)))
        XCTAssertEqual(WatchedItem.cleanCommandName(String(repeating: "a", count: 64))?.count, 64)
    }

    func testCodableRoundTrip() throws {
        let items = [WatchedItem.command("claude"), WatchedItem(kind: .app, id: "com.apple.finder", name: "Finder", rule: .running)]
        let back = try JSONDecoder().decode([WatchedItem].self, from: JSONEncoder().encode(items))
        XCTAssertEqual(back, items)
        XCTAssertEqual(Set(Rule.allCases.map(\.rawValue)), ["working", "running"])
    }
    typealias Rule = WatchedItem.Rule
}

@MainActor
final class ProcessHoldsTests: XCTestCase {
    func testAddRemoveAndNames() {
        let holds = ProcessHolds()
        XCTAssertTrue(holds.isEmpty)
        let p = spawn(self)
        XCTAssertTrue(holds.add(pid: p.processIdentifier))
        XCTAssertTrue(holds.add(pid: p.processIdentifier))   // again: already held
        XCTAssertFalse(holds.isEmpty)
        XCTAssertEqual(holds.names, ["sleep"])
        holds.remove(pid: p.processIdentifier)
        XCTAssertTrue(holds.isEmpty)
        holds.remove(pid: p.processIdentifier)               // harmless twice
    }

    func testRefusesOthersAndMissing() {
        let holds = ProcessHolds()
        XCTAssertFalse(holds.add(pid: 1))            // launchd belongs to root
        XCTAssertFalse(holds.add(pid: 99_999_999))   // no such process
        XCTAssertTrue(holds.isEmpty)
    }

    func testLimit() {
        let holds = ProcessHolds()
        let procs = (0...ProcessHolds.maxHolds).map { _ in spawn(self) }
        for p in procs.prefix(ProcessHolds.maxHolds) { XCTAssertTrue(holds.add(pid: p.processIdentifier)) }
        XCTAssertFalse(holds.add(pid: procs.last!.processIdentifier))
        procs.forEach { holds.remove(pid: $0.processIdentifier) }
    }

    func testPruneDropsOldAndEnded() {
        let holds = ProcessHolds()
        let old = spawn(self), ended = spawn(self)
        let now = Date()
        XCTAssertTrue(holds.add(pid: old.processIdentifier, now: now))
        XCTAssertTrue(holds.add(pid: ended.processIdentifier, now: now))
        ended.terminate(); ended.waitUntilExit()
        holds.prune(now: now.addingTimeInterval(1))
        XCTAssertEqual(holds.names.count, 1)
        holds.prune(now: now.addingTimeInterval(ProcessHolds.maxAge + 1))   // too old
        XCTAssertTrue(holds.isEmpty)
    }

    func testNamesAreOldestFirst() {
        let holds = ProcessHolds()
        let a = spawn(self), b = spawn(self, "/usr/bin/tail", ["-f", "/dev/null"])
        XCTAssertTrue(holds.add(pid: b.processIdentifier, now: Date(timeIntervalSince1970: 1)))
        XCTAssertTrue(holds.add(pid: a.processIdentifier, now: Date(timeIntervalSince1970: 2)))
        XCTAssertEqual(holds.names, ["tail", "sleep"])
    }

    func testExitCallsOnChange() {
        let holds = ProcessHolds()
        let changed = expectation(description: "changed")
        holds.onChange = { changed.fulfill() }
        let p = spawn(self)
        XCTAssertTrue(holds.add(pid: p.processIdentifier))
        p.terminate()
        wait(for: [changed], timeout: 5)
        XCTAssertTrue(holds.isEmpty)
    }
}

final class ProcessWatcherTests: XCTestCase {
    private func copy(of exe: String, as name: String) -> String {
        let dest = makeTempDir(self).appendingPathComponent(name).path
        try! FileManager.default.copyItem(atPath: exe, toPath: dest)
        // A copied system program is killed by macOS until it carries its own signature.
        let sign = Process()
        sign.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        sign.arguments = ["--force", "-s", "-", dest]
        sign.standardError = FileHandle.nullDevice
        try! sign.run(); sign.waitUntilExit()
        return dest
    }

    func testOpenAppByRule() throws {
        let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        let id = try XCTUnwrap(running.first)
        let w = ProcessWatcher()
        let item = WatchedItem(kind: .app, id: id, name: "App", rule: .running)
        XCTAssertEqual(w.active([item]), [item])
        let missing = WatchedItem(kind: .app, id: "local.macawake.nothing", name: "Nope", rule: .running)
        XCTAssertEqual(w.active([item, missing]), [item])
        XCTAssertEqual(w.active([]), [])
    }

    func testSampling() throws {
        _ = spawn(self, "/usr/bin/yes", [])
        _ = spawn(self)
        let yes = WatchedItem.command("yes"), sleep = WatchedItem.command("sleep")
        let sleepRunning = WatchedItem.command("sleep", rule: .running)
        let w = ProcessWatcher()
        let t0 = Date()
        // First sample has nothing to compare with: only "running" rules can match.
        XCTAssertEqual(w.active([yes, sleep, sleepRunning], now: t0), [sleepRunning])
        XCTAssertGreaterThan(w.lastScanDuration, 0)
        // Too soon: the last answer is reused.
        XCTAssertEqual(w.active([yes, sleep, sleepRunning], now: t0.addingTimeInterval(1)), [sleepRunning])
        // Later: yes used CPU, sleep did not.
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(w.active([yes, sleep, sleepRunning], now: t0.addingTimeInterval(30)), [yes, sleepRunning])
        // A long gap starts over.
        XCTAssertEqual(w.active([yes, sleep, sleepRunning], now: t0.addingTimeInterval(1000)), [sleepRunning])
    }

    func testBusyThresholdAndAppScan() throws {
        let id = try XCTUnwrap(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).first)
        let app = WatchedItem(kind: .app, id: id, name: "App", rule: .working)
        let w = ProcessWatcher()
        w.busyThreshold = 0           // anything counts, even zero CPU
        let t0 = Date()
        XCTAssertEqual(w.active([app], now: t0), [])
        XCTAssertEqual(w.active([app], now: t0.addingTimeInterval(30)), [app])
        // Only open-rule apps: no scan state is kept.
        let open = WatchedItem(kind: .app, id: id, name: "App", rule: .running)
        XCTAssertEqual(w.active([open], now: t0.addingTimeInterval(60)), [open])
    }

    func testScriptsRunByInterpreters() throws {
        let dir = makeTempDir(self)
        let script = dir.appendingPathComponent("codex.js")
        try "sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        _ = spawn(self, "/bin/bash", ["-x", script.path])
        let plain = dir.appendingPathComponent("fakeagent")
        try "sleep 60\n".write(to: plain, atomically: true, encoding: .utf8)
        _ = spawn(self, "/bin/bash", [plain.path])
        let w = ProcessWatcher()
        let items = [WatchedItem.command("codex", rule: .running), WatchedItem.command("fakeagent", rule: .running),
                     WatchedItem.command("bash", rule: .running)]
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(Set(w.active(items).map(\.id)), ["codex", "fakeagent", "bash"])
    }

    func testLongNamesAreMatchedByPath() throws {
        let long = "a-very-long-executable-name"
        let path = copy(of: "/bin/sleep", as: long)
        let p = spawn(self, path, ["60"])
        let item = WatchedItem.command(long, rule: .running)
        let w = ProcessWatcher()
        // Give the process a moment to appear (slow CI runners).
        for _ in 0..<50 where w.active([item]).isEmpty && p.isRunning { Thread.sleep(forTimeInterval: 0.1) }
        try XCTSkipUnless(p.isRunning, "this system won't run a copied, re-signed program")
        XCTAssertEqual(w.active([item]), [item])
    }

    func testChildrenCountTowardParent() throws {
        // A shell whose child burns CPU: the shell itself is idle, the work is below it.
        let sh = spawn(self, "/bin/sh", ["-c", "/usr/bin/yes > /dev/null; true"])
        _ = sh
        let item = WatchedItem.command("sh")
        let w = ProcessWatcher()
        let t0 = Date()
        _ = w.active([item], now: t0)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertEqual(w.active([item], now: t0.addingTimeInterval(30)), [item])
    }
}
