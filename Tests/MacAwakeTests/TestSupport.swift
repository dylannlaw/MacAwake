import EventKit
import XCTest
@testable import MacAwake

/// A fresh scratch folder, removed when the test ends.
func makeTempDir(_ test: XCTestCase) -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("macawake-tests-\(UUID().uuidString)", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
    return dir
}

/// Runs `body` with `AdminShell.run` replaced, so no test can show an admin dialog. Returns the scripts it saw.
func withFakeAdmin(_ test: XCTestCase, succeed: Bool = true, onRun: ((String) -> Void)? = nil) -> Box<[String]> {
    let seen = Box<[String]>([])
    let saved = AdminShell.runner
    AdminShell.runner = { command, _, completion in
        seen.value.append(command)
        onRun?(command)
        completion(succeed)
    }
    test.addTeardownBlock { AdminShell.runner = saved }
    return seen
}

final class Box<T> { var value: T; init(_ v: T) { value = v } }

/// Events need a store and a calendar; nothing is saved, so no calendar permission is involved.
let testStore = EKEventStore()

func makeEvent(_ title: String, start: Date, end: Date, allDay: Bool = false, free: Bool = false) -> EKEvent {
    let cal = EKCalendar(for: .event, eventStore: testStore)
    cal.title = "Test"
    let e = EKEvent(eventStore: testStore)
    e.title = title
    e.calendar = cal
    e.startDate = start
    e.endDate = end
    e.isAllDay = allDay
    if free { e.availability = .free }
    return e
}

/// A controller that touches nothing real: its own defaults, scratch helper folders, no observers.
@MainActor
struct Rig {
    let controller: AwakeController
    let defaults: UserDefaults
    let waker: WakeScheduler
    let lid: LidScheduler
    let dir: URL
    let state: Box<TestState>

    final class TestState {
        var events: [EKEvent] = []
        var power = PowerState()
        var lidBattery = LidBattery(hasBattery: false, onBattery: false, percent: nil)
        var thermal = ProcessInfo.ThermalState.nominal
        var confirm = true
        var opened: [URL] = []
    }
}

@MainActor
func makeRig(_ test: XCTestCase, calendar: Bool = true, seed: (UserDefaults) -> Void = { _ in },
             helperInstalled: Bool = false, lidInstalled: Bool = false, bundle: Bundle = .main,
             observe: Bool = false, requestAccess: (() async throws -> Bool)? = nil,
             calendars: [EKCalendar]? = nil) -> Rig {
    let dir = makeTempDir(test)
    let suite = "macawake-tests-\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    test.addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
    seed(defaults)
    let wakePlist = dir.appendingPathComponent("wake.plist")
    let lidPlist = dir.appendingPathComponent("lid.plist")
    if helperInstalled { try! "x".write(to: wakePlist, atomically: true, encoding: .utf8) }
    if lidInstalled { try! "x".write(to: lidPlist, atomically: true, encoding: .utf8) }
    let waker = WakeScheduler(requestDir: dir.appendingPathComponent("wake"), daemonPlist: wakePlist,
                              helperPath: dir.appendingPathComponent("wake-helper").path, bundle: bundle)
    let lid = LidScheduler(leaseDir: dir.appendingPathComponent("lid"), daemonPlist: lidPlist,
                           helperPath: dir.appendingPathComponent("lid-helper").path,
                           statePath: dir.appendingPathComponent("lid-state").path, bundle: bundle, readOnly: false)
    let state = Box(Rig.TestState())
    var hooks = AwakeController.TestHooks()
    if calendar { hooks.events = { _ in state.value.events } }
    hooks.power = { state.value.power }
    hooks.lidBattery = { state.value.lidBattery }
    hooks.thermal = { state.value.thermal }
    hooks.runAlert = { _ in state.value.confirm ? .alertFirstButtonReturn : .alertSecondButtonReturn }
    hooks.openURL = { state.value.opened.append($0) }
    hooks.observe = observe
    hooks.device = .desktop
    hooks.calendars = calendars
    hooks.requestAccess = requestAccess
    let c = AwakeController(defaults: defaults, waker: waker, lid: lid, hooks: hooks)
    return Rig(controller: c, defaults: defaults, waker: waker, lid: lid, dir: dir, state: state)
}

/// A fake bundle folder holding helper scripts with the given version markers.
func makeBundle(_ test: XCTestCase, wakeVersion: Int?, lidVersion: Int?) -> Bundle {
    let dir = makeTempDir(test).appendingPathComponent("Fake.app/Contents/Resources", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let plist = dir.deletingLastPathComponent().appendingPathComponent("Info.plist")
    try! """
    <?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>\
    <key>CFBundleIdentifier</key><string>local.test.fake</string></dict></plist>
    """.write(to: plist, atomically: true, encoding: .utf8)
    func script(_ name: String, _ v: Int?) {
        let marker = v.map { "# macawake-helper-version: \($0)\n" } ?? ""
        try! ("#!/bin/sh\n" + marker).write(to: dir.appendingPathComponent("\(name).sh"), atomically: true, encoding: .utf8)
    }
    script("wake-helper", wakeVersion)
    script("lid-helper", lidVersion)
    return Bundle(url: dir.deletingLastPathComponent().deletingLastPathComponent())!
}

/// Starts `/bin/sleep` (or another command) as a child that the test must stop.
func spawn(_ test: XCTestCase, _ path: String = "/bin/sleep", _ args: [String] = ["60"]) -> Process {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try! p.run()
    test.addTeardownBlock { if p.isRunning { p.terminate(); p.waitUntilExit() } }
    return p
}
