import EventKit
import IOKit.ps
import XCTest
@testable import MacAwake

@MainActor
final class DemoTests: XCTestCase {
    private func demo(_ choice: String) -> AwakeController {
        let dir = makeTempDir(self)
        let suite = "macawake-demo-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        var hooks = AwakeController.TestHooks()
        hooks.demo = choice
        hooks.device = .laptop
        return AwakeController(
            defaults: defaults,
            waker: WakeScheduler(requestDir: dir.appendingPathComponent("w"), daemonPlist: dir.appendingPathComponent("w.plist"),
                                 helperPath: "/nope", bundle: .main),
            lid: LidScheduler(leaseDir: dir.appendingPathComponent("l"), daemonPlist: dir.appendingPathComponent("l.plist"),
                              helperPath: "/nope", statePath: "/nope", bundle: .main, readOnly: true),
            hooks: hooks)
    }

    func testCalendarDemo() {
        let c = demo("calendar")
        XCTAssertEqual(c.mode, .auto)
        XCTAssertTrue(c.hasAccess)
        XCTAssertEqual(c.calendars.count, 2)
        XCTAssertEqual(c.currentEvent?.title, "AI coding session")
        XCTAssertTrue(c.isAwake)
        XCTAssertEqual(c.nextEvent?.title, "Team standup")
        XCTAssertEqual(c.agenda.count, 4)
        XCTAssertTrue(c.showsLidSetting)
        XCTAssertNotNil(c.scheduledWake)
        XCTAssertEqual(c.lidStatus, .off)
    }

    func testModeDemos() {
        XCTAssertEqual(demo("always").mode, .alwaysOn)
        let timer = demo("timer")
        XCTAssertEqual(timer.mode, .timed)
        XCTAssertTrue(timer.isAwake)
        XCTAssertNotNil(timer.timedUntil)
        let off = demo("off")
        XCTAssertEqual(off.mode, .off)
        XCTAssertFalse(off.isAwake)
    }

    func testAppsRunAndLidDemos() {
        let apps = demo("apps")
        XCTAssertEqual(apps.activeWatched.map(\.id), ["claude"])
        XCTAssertEqual(apps.watchedItems.count, 3)
        XCTAssertTrue(apps.isAwake)
        XCTAssertNil(apps.currentEvent)
        let run = demo("run")
        XCTAssertTrue(run.heldAwake)
        XCTAssertEqual(run.heldNames, ["claude"])
        let lid = demo("lid")
        XCTAssertTrue(lid.lidClosedAwake)
        XCTAssertTrue(lid.lidHelperInstalled)
        XCTAssertEqual(lid.lidStatus, .active)
    }

    func testBatteryDemoIsPaused() {
        let c = demo("battery")
        XCTAssertEqual(c.pauseReason, .batteryLow(8))
        XCTAssertFalse(c.isAwake)
        XCTAssertNil(c.scheduledWake)
    }

    func testDemoNeverChangesRealHelpers() {
        let seen = withFakeAdmin(self)
        let c = demo("calendar")
        c.installWakeHelper()
        c.uninstallWakeHelper()
        c.launchAtLogin = true
        XCTAssertTrue(seen.value.isEmpty)
    }

    func testResetDefaultsPerChoice() {
        func fresh(_ choice: String) -> UserDefaults {
            let d = UserDefaults(suiteName: "macawake-reset-\(UUID().uuidString)")!
            Demo.resetDefaults(choice: choice, in: d)
            return d
        }
        XCTAssertEqual(fresh("always").string(forKey: "mode"), "alwaysOn")
        XCTAssertEqual(fresh("calendar").string(forKey: "mode"), "auto")
        let apps = fresh("apps")
        XCTAssertTrue(apps.bool(forKey: "watchAppsEnabled"))
        XCTAssertNotNil(apps.data(forKey: "watchedItems"))
        XCTAssertTrue(fresh("lid").bool(forKey: "lidClosedAwake"))
        let timer = fresh("timer")
        XCTAssertEqual(timer.string(forKey: "mode"), "timed")
        XCTAssertGreaterThan(timer.double(forKey: "timedUntil"), Date().timeIntervalSince1970)
    }
}

@MainActor
final class ControllerSystemTests: XCTestCase {
    func testRequestAccessGrantedAndDenied() async throws {
        let r = makeRig(self, calendar: false, requestAccess: { true })
        r.controller.requestAccess()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(r.controller.hasAccess)

        struct Boom: Error {}
        let denied = makeRig(self, requestAccess: { throw Boom() })
        denied.controller.requestAccess()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(denied.controller.hasAccess)
        XCTAssertEqual(denied.controller.calendars.count, 0)
    }

    func testCalendarChangeAndPollRefresh() async throws {
        let saved = (AwakeController.pollSeconds, AwakeController.checkInSeconds)
        AwakeController.pollSeconds = 0.1
        AwakeController.checkInSeconds = 0.1
        addTeardownBlock { (AwakeController.pollSeconds, AwakeController.checkInSeconds) = saved }
        let r = makeRig(self, helperInstalled: true, observe: true)
        r.controller.refresh()
        r.state.value.events = [makeEvent("Now", start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(600))]
        try await Task.sleep(nanoseconds: 400_000_000)       // the poll picks it up
        XCTAssertTrue(r.controller.isAwake)
        r.state.value.events = []
        NotificationCenter.default.post(name: .EKEventStoreChanged, object: r.controller.store)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(r.controller.isAwake)
        // A check-in wake looks again shortly after.
        r.state.value.events = [makeEvent("Later", start: Date().addingTimeInterval(-60), end: Date().addingTimeInterval(600))]
        r.controller.handlePowerOn()
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(r.controller.isAwake)
    }

    func testHeldProcessExitRefreshes() async throws {
        let r = makeRig(self, observe: true)
        r.controller.mode = .off
        let p = spawn(self)
        r.controller.perform(.hold(pid: p.processIdentifier))
        XCTAssertTrue(r.controller.heldAwake)
        p.terminate()
        try await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertFalse(r.controller.heldAwake)
    }

    func testCalendarsAreSortedAndFiltered() async throws {
        func cal(_ t: String) -> EKCalendar { let c = EKCalendar(for: .event, eventStore: testStore); c.title = t; return c }
        let b = cal("b work"), a = cal("A home"), c = cal("c")
        let r = makeRig(self, calendar: false, requestAccess: { true }, calendars: [b, c, a])
        r.controller.requestAccess()
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(r.controller.calendars.map(\.title), ["A home", "b work", "c"])
        // The real store has no events for these unsaved calendars; this just walks the lookup path.
        r.controller.excludedCalendarIDs = [a.calendarIdentifier]
        XCTAssertNil(r.controller.currentEvent)
        r.controller.excludedCalendarIDs = [a.calendarIdentifier, b.calendarIdentifier, c.calendarIdentifier]
        XCTAssertNil(r.controller.currentEvent)
    }

    func testPreviewLidStatusArguments() {
        func status(_ s: String) -> LidStatus? { AwakeController.previewLidStatus(from: ["x", "--preview-panel", "--preview-lid-status", s]) }
        XCTAssertEqual(status("active"), .active)
        XCTAssertEqual(status("starting"), .starting)
        XCTAssertEqual(status("battery"), .pausedBattery)
        XCTAssertEqual(status("hot"), .pausedHot)
        XCTAssertNil(status("bogus"))
        XCTAssertNil(AwakeController.previewLidStatus(from: ["--preview-lid-status", "active"]))
        XCTAssertNil(AwakeController.previewLidStatus(from: ["--preview-panel", "--preview-lid-status"]))
    }

    func testModeLabels() {
        XCTAssertEqual(Mode.allCases.map(\.label), ["Auto — follow calendar and watched apps", "Always awake",
                                                     "Awake for a set time", "Off"])
        XCTAssertEqual(Mode.auto.id, "auto")
    }
}

final class CallbackTests: XCTestCase {
    func testPowerSourceDeliver() {
        var n = 0
        let source = PowerSource { n += 1 }
        PowerSource.deliver(Unmanaged.passUnretained(source).toOpaque())
        PowerSource.deliver(nil)
        XCTAssertEqual(n, 1)
    }

    func testWatcherDeliver() {
        var n = 0
        let w = PowerSourceWatcher { n += 1 }
        PowerSourceWatcher.deliver(Unmanaged.passUnretained(w).toOpaque())
        PowerSourceWatcher.deliver(nil)
        XCTAssertEqual(n, 1)
    }

    func testSystemPowerDeliver() {
        var n = 0
        let p = SystemPower { n += 1 }
        SystemPower.deliver(Unmanaged.passUnretained(p).toOpaque(), 0xE000_0300, nil)
        SystemPower.deliver(nil, 0xE000_0300, nil)
        XCTAssertEqual(n, 1)
    }

    func testPowerStateFromIOKitDescriptions() {
        func battery(_ cur: Int, _ max: Int, present: Bool = true) -> [String: Any] {
            [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSCurrentCapacityKey: cur, kIOPSMaxCapacityKey: max, kIOPSIsPresentKey: present]
        }
        let ups: [String: Any] = [kIOPSTypeKey: kIOPSUPSType, kIOPSCurrentCapacityKey: 40, kIOPSMaxCapacityKey: 100]
        let other: [String: Any] = [kIOPSTypeKey: "Something"]
        var s = PowerSource.state(providing: kIOPSBatteryPowerValue, descriptions: [battery(33, 100)], lowPowerMode: true)
        XCTAssertEqual(s, PowerState(onBattery: true, percent: 33, hasBattery: true, lowPowerMode: true))
        s = PowerSource.state(providing: kIOPMACPowerKey, descriptions: [other, battery(1, 3)], lowPowerMode: false)
        XCTAssertEqual(s, PowerState(onBattery: false, percent: 33, hasBattery: true))
        // The internal battery wins over a UPS; a UPS alone is used when there's no battery.
        s = PowerSource.state(providing: nil, descriptions: [ups, battery(90, 100), battery(10, 100)], lowPowerMode: false)
        XCTAssertEqual(s.percent, 90)
        s = PowerSource.state(providing: nil, descriptions: [ups], lowPowerMode: false)
        XCTAssertEqual(s, PowerState(onBattery: false, percent: 40, hasBattery: true))
        s = PowerSource.state(providing: nil, descriptions: [battery(5, 100, present: false)], lowPowerMode: false)
        XCTAssertFalse(s.hasBattery)
        s = PowerSource.state(providing: nil, descriptions: [battery(5, 0)], lowPowerMode: false)
        XCTAssertTrue(s.hasBattery)
        XCTAssertNil(s.percent)
        XCTAssertEqual(PowerSource.state(providing: nil, descriptions: [], lowPowerMode: false), PowerState())
    }

    func testLidBatteryParse() {
        let on: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSPowerSourceStateKey: kIOPSBatteryPowerValue,
                                 kIOPSCurrentCapacityKey: 50, kIOPSMaxCapacityKey: 200]
        let ac: [String: Any] = [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSPowerSourceStateKey: kIOPSACPowerValue]
        let ups: [String: Any] = [kIOPSTypeKey: kIOPSUPSType]
        let b = LidBattery.parse([ups, on])
        XCTAssertTrue(b.hasBattery); XCTAssertTrue(b.onBattery); XCTAssertEqual(b.percent, 25)
        let p = LidBattery.parse([ac])
        XCTAssertTrue(p.hasBattery); XCTAssertFalse(p.onBattery); XCTAssertNil(p.percent)
        XCTAssertFalse(LidBattery.parse([ups]).hasBattery)
    }
}
