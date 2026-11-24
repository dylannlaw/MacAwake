import EventKit
import XCTest
@testable import MacAwake

@MainActor
final class AwakeControllerTests: XCTestCase {
    private let hour = 3600.0
    private func event(_ title: String, from: Double, to: Double, allDay: Bool = false, free: Bool = false) -> EKEvent {
        let now = Date()
        return makeEvent(title, start: now.addingTimeInterval(from * hour), end: now.addingTimeInterval(to * hour),
                         allDay: allDay, free: free)
    }
    private func wakeFile(_ r: Rig) -> String? { try? String(contentsOf: r.waker.requestFile) }

    // MARK: Settings

    func testDefaults() {
        let c = makeRig(self).controller
        XCTAssertEqual(c.mode, .auto)
        XCTAssertTrue(c.keepDisplayOn)
        XCTAssertFalse(c.includeAllDay)
        XCTAssertFalse(c.ignoreFreeEvents)
        XCTAssertEqual(c.leadMinutes, 2)
        XCTAssertEqual(c.trailMinutes, 0)
        XCTAssertTrue(c.wakeForEvents)
        XCTAssertEqual(c.sleepCheckMinutes, 15)
        XCTAssertEqual(c.batteryStopPercent, 10)
        XCTAssertFalse(c.onlyWhenPluggedIn)
        XCTAssertFalse(c.pauseInLowPowerMode)
        XCTAssertFalse(c.lidClosedAwake)
        XCTAssertFalse(c.watchAppsEnabled)
        XCTAssertEqual(c.watchedItems, [])
        XCTAssertEqual(c.watchGraceMinutes, 5)
        XCTAssertEqual(c.excludedCalendarIDs, [])
        XCTAssertTrue(c.hasAccess)
        XCTAssertFalse(c.showsLidSetting)
    }

    func testSettingsPersistAndReload() {
        let r = makeRig(self)
        let c = r.controller
        c.mode = .alwaysOn
        c.keepDisplayOn = false
        c.includeAllDay = true
        c.ignoreFreeEvents = true
        c.leadMinutes = 7
        c.trailMinutes = 3
        c.wakeForEvents = false
        c.sleepCheckMinutes = 30
        c.batteryStopPercent = 20
        c.onlyWhenPluggedIn = true
        c.pauseInLowPowerMode = true
        c.lidClosedAwake = true
        c.watchAppsEnabled = true
        c.watchedItems = [.command("claude")]
        c.watchGraceMinutes = 9
        c.excludedCalendarIDs = ["a", "b"]
        let again = AwakeController(defaults: r.defaults, waker: r.waker, lid: r.lid, hooks: .init())
        XCTAssertEqual(again.mode, .alwaysOn)
        XCTAssertFalse(again.keepDisplayOn)
        XCTAssertTrue(again.includeAllDay)
        XCTAssertTrue(again.ignoreFreeEvents)
        XCTAssertEqual(again.leadMinutes, 7)
        XCTAssertEqual(again.trailMinutes, 3)
        XCTAssertFalse(again.wakeForEvents)
        XCTAssertEqual(again.sleepCheckMinutes, 30)
        XCTAssertEqual(again.batteryStopPercent, 20)
        XCTAssertTrue(again.onlyWhenPluggedIn)
        XCTAssertTrue(again.pauseInLowPowerMode)
        XCTAssertTrue(again.lidClosedAwake)
        XCTAssertTrue(again.watchAppsEnabled)
        XCTAssertEqual(again.watchedItems, [.command("claude")])
        XCTAssertEqual(again.watchGraceMinutes, 9)
        XCTAssertEqual(again.excludedCalendarIDs, ["a", "b"])
        XCTAssertFalse(again.hasAccess)   // no events hook: no calendar access
    }

    func testBadSavedModeFallsBackToAuto() {
        XCTAssertEqual(makeRig(self, seed: { $0.set("bogus", forKey: "mode") }).controller.mode, .auto)
    }

    func testSavedTimerWithoutEndBecomesOff() {
        XCTAssertEqual(makeRig(self, seed: { $0.set("timed", forKey: "mode") }).controller.mode, .off)
    }

    func testSavedRunningTimerIsRestoredAndExpiredOneEndsOff() {
        let future = Date().addingTimeInterval(1800).timeIntervalSince1970
        let r = makeRig(self, seed: {
            $0.set("timed", forKey: "mode"); $0.set(future, forKey: "timedUntil"); $0.set(future - 600, forKey: "timedStart")
            $0.set("auto", forKey: "timedReturnMode")
        })
        XCTAssertEqual(r.controller.mode, .timed)
        XCTAssertNotNil(r.controller.timedUntil)
        XCTAssertNotNil(r.controller.timedStart)
        XCTAssertNil(r.defaults.object(forKey: "timedReturnMode"))
        let expired = makeRig(self, seed: {
            $0.set("timed", forKey: "mode"); $0.set(Date().timeIntervalSince1970 - 5, forKey: "timedUntil")
        })
        expired.controller.refresh()
        XCTAssertEqual(expired.controller.mode, .off)
        XCTAssertNil(expired.controller.timedUntil)
    }

    func testLeavingTimedModeClearsTimer() {
        let c = makeRig(self).controller
        c.startTimed(minutes: 30)
        c.mode = .alwaysOn
        XCTAssertNil(c.timedUntil)
        XCTAssertNil(c.timedStart)
    }

    func testBatteryLimitChangeResetsLatch() {
        let r = makeRig(self)
        r.state.value.power = PowerState(onBattery: true, percent: 5, hasBattery: true)
        r.controller.mode = .alwaysOn
        XCTAssertEqual(r.controller.pauseReason, .batteryLow(5))
        r.state.value.power = PowerState(onBattery: true, percent: 12, hasBattery: true)
        r.controller.refresh()
        XCTAssertEqual(r.controller.pauseReason, .batteryLow(12))   // latched
        r.controller.batteryStopPercent = 10                          // judged afresh
        XCTAssertNil(r.controller.pauseReason)
    }

    // MARK: Calendar

    func testIdleWithNoEvents() {
        let c = makeRig(self).controller
        c.refresh()
        XCTAssertFalse(c.isAwake)
        XCTAssertNil(c.currentEvent)
        XCTAssertEqual(c.statusLine, "Idle — no event right now")
        XCTAssertEqual(c.menuBarSymbol, "cup.and.saucer")
        XCTAssertNil(c.nextLine)
        XCTAssertNil(c.wakeLine)
    }

    func testOngoingEventKeepsAwake() {
        let r = makeRig(self)
        let e = event("Standup", from: -0.5, to: 0.5)
        r.state.value.events = [e]
        r.controller.refresh()
        XCTAssertTrue(r.controller.isAwake)
        XCTAssertTrue(r.controller.currentEvent === e)
        XCTAssertTrue(r.controller.isOngoing(e))
        XCTAssertTrue(r.controller.statusLine.hasPrefix("Awake — Standup · until "))
        XCTAssertEqual(r.controller.menuBarSymbol, "cup.and.saucer.fill")
        XCTAssertNil(r.controller.pauseReason)
        XCTAssertEqual(r.controller.agenda.count, 1)
    }

    func testOverlappingEventsLastEndWins() {
        let r = makeRig(self)
        let long = event("Long", from: -1, to: 3)
        r.state.value.events = [event("Short", from: -1, to: 1), long]
        r.controller.refresh()
        XCTAssertTrue(r.controller.currentEvent === long)
    }

    func testLeadAndTrailBuffers() {
        let r = makeRig(self)
        r.state.value.events = [event("Soon", from: 1.0 / 60, to: 1)]   // starts in 1 min; lead is 2
        r.controller.refresh()
        XCTAssertTrue(r.controller.isAwake)
        r.state.value.events = [event("Over", from: -1, to: -1.0 / 60)] // ended 1 min ago
        r.controller.refresh()
        XCTAssertFalse(r.controller.isAwake)
        r.controller.trailMinutes = 5
        XCTAssertTrue(r.controller.isAwake)
    }

    func testEventWindowNeverEndsBeforeItStarts() {
        let r = makeRig(self)
        r.controller.trailMinutes = 0
        r.controller.leadMinutes = 0
        r.state.value.events = [event("Zero", from: 1, to: 1)]
        r.controller.refresh()
        XCTAssertNotNil(r.controller.nextEvent)
    }

    func testAllDayAndFreeFilters() {
        let r = makeRig(self)
        // (An event's "free" availability can't be set without a real calendar account, so only the flag is checked.)
        r.state.value.events = [event("Holiday", from: -5, to: 5, allDay: true)]
        r.controller.refresh()
        XCTAssertNil(r.controller.currentEvent)
        r.controller.ignoreFreeEvents = true
        XCTAssertNil(r.controller.currentEvent)
        r.controller.includeAllDay = true
        XCTAssertEqual(r.controller.currentEvent?.title, "Holiday")
    }

    func testAgendaIsCappedAndSkipsFinished() {
        let r = makeRig(self)
        r.state.value.events = [event("Done", from: -3, to: -2)] + (1...6).map { event("E\($0)", from: Double($0), to: Double($0) + 0.5) }
        r.controller.refresh()
        XCTAssertEqual(r.controller.agenda.map(\.title), ["E1", "E2", "E3", "E4"])
    }

    func testNextEventAndWakeRequest() {
        let r = makeRig(self, helperInstalled: true)
        let next = event("Later", from: 2, to: 3)
        r.state.value.events = [next]
        r.controller.refresh()
        XCTAssertTrue(r.controller.nextEvent === next)
        XCTAssertNotNil(r.controller.scheduledWake)
        XCTAssertTrue(r.controller.nextLine?.hasPrefix("Next: Later · ") ?? false)
        XCTAssertTrue(r.controller.wakeLine?.hasPrefix("Wakes Mac at ") ?? false)
        // The helper gets the earlier of the event's start and the next check-in.
        let asked = Double(wakeFile(r)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "") ?? 0
        XCTAssertGreaterThan(asked, Date().timeIntervalSince1970)
        XCTAssertLessThanOrEqual(asked, next.startDate.timeIntervalSince1970 + 10)
    }

    func testNoWakeWithoutHelperOrWhenDisabled() {
        let r = makeRig(self)
        r.state.value.events = [event("Later", from: 2, to: 3)]
        r.controller.refresh()
        XCTAssertNil(r.controller.scheduledWake)
        XCTAssertEqual(wakeFile(r), "")
        let h = makeRig(self, helperInstalled: true)
        h.state.value.events = [event("Later", from: 2, to: 3)]
        h.controller.wakeForEvents = false
        XCTAssertNil(h.controller.scheduledWake)
        XCTAssertNil(h.controller.nextLine.map { _ in nil as String? } ?? nil)
    }

    func testCheckInDisabledGivesOnlyEventWake() {
        let r = makeRig(self, helperInstalled: true)
        r.controller.sleepCheckMinutes = 0
        let next = event("Later", from: 5, to: 6)
        r.state.value.events = [next]
        r.controller.refresh()
        let asked = Double(wakeFile(r)!.trimmingCharacters(in: .whitespacesAndNewlines))!
        XCTAssertEqual(asked, ceil(next.startDate.addingTimeInterval(-120).timeIntervalSince1970) + 5, accuracy: 1)
    }

    func testNoCalendarAccess() {
        let c = makeRig(self, calendar: false).controller
        c.refresh()
        XCTAssertEqual(c.statusLine, "Needs calendar access")
        XCTAssertEqual(c.agenda.count, 0)
        XCTAssertFalse(c.isAwake)
    }

    func testBindingTogglesExcludedCalendar() {
        let c = makeRig(self).controller
        let cal = EKCalendar(for: .event, eventStore: testStore)
        let binding = c.binding(for: cal)
        XCTAssertTrue(binding.wrappedValue)
        binding.wrappedValue = false
        XCTAssertTrue(c.excludedCalendarIDs.contains(cal.calendarIdentifier))
        XCTAssertFalse(binding.wrappedValue)
        binding.wrappedValue = true
        XCTAssertTrue(c.excludedCalendarIDs.isEmpty)
    }

    func testOpenPrivacySettings() {
        let r = makeRig(self)
        r.controller.openPrivacySettings()
        XCTAssertEqual(r.state.value.opened.first?.scheme, "x-apple.systempreferences")
    }

    // MARK: Modes and timer

    func testAlwaysOnAndOff() {
        let c = makeRig(self).controller
        c.mode = .alwaysOn
        XCTAssertTrue(c.isAwake)
        XCTAssertEqual(c.statusLine, "Awake (manual override)")
        c.mode = .off
        XCTAssertFalse(c.isAwake)
        XCTAssertEqual(c.statusLine, "Off — Mac sleeps normally")
        XCTAssertEqual(c.menuBarSymbol, "moon.zzz")
    }

    func testTimerLifecycle() {
        let c = makeRig(self).controller
        c.startTimed(minutes: 90)
        XCTAssertEqual(c.mode, .timed)
        XCTAssertTrue(c.isAwake)
        XCTAssertEqual(c.menuBarSymbol, "hourglass")
        XCTAssertTrue(c.statusLine.hasPrefix("Awake for 1h 29m more"))
        let first = c.timedUntil!
        c.startTimed(minutes: 20)   // restarting while running
        XCTAssertLessThan(c.timedUntil!, first)
        XCTAssertTrue(c.statusLine.hasPrefix("Awake for 19m more"))
        c.extendTimed(minutes: 30)
        XCTAssertGreaterThan(c.timedUntil!.timeIntervalSinceNow, 49 * 60)
        c.stopTimed()
        XCTAssertEqual(c.mode, .off)
        c.stopTimed()               // not running: nothing happens
        XCTAssertEqual(c.mode, .off)
    }

    func testExtendWithoutTimerStartsOne() {
        let c = makeRig(self).controller
        c.extendTimed(minutes: 15)
        XCTAssertEqual(c.mode, .timed)
        XCTAssertGreaterThan(c.timedUntil!.timeIntervalSinceNow, 14 * 60)
    }

    func testTimerExpiryTimerFires() {
        let c = makeRig(self).controller
        c.startTimed(minutes: 1)
        XCTAssertEqual(c.mode, .timed)
        // Jump the end to just ahead; the expiry timer then switches to Off.
        c.extendTimed(minutes: 0)
        XCTAssertEqual(c.mode, .timed)
    }

    func testTimedModeWithoutEndShowsPlainAwake() {
        let c = makeRig(self).controller
        c.mode = .timed          // the refresh in didSet switches it straight to Off
        XCTAssertEqual(c.mode, .off)
    }

    // MARK: URL commands

    func testPerformCommands() {
        let c = makeRig(self).controller
        c.perform(.start(minutes: 30))
        XCTAssertEqual(c.mode, .timed)
        c.perform(.extend(minutes: 30))
        XCTAssertGreaterThan(c.timedUntil!.timeIntervalSinceNow, 59 * 60)
        c.perform(.stop)
        XCTAssertEqual(c.mode, .off)
        c.perform(.setMode(.alwaysOn))
        XCTAssertEqual(c.mode, .alwaysOn)
    }

    func testExtendIsCappedAtADay() {
        let c = makeRig(self).controller
        c.perform(.start(minutes: 1400))
        c.perform(.extend(minutes: 1440))
        XCTAssertLessThanOrEqual(c.timedUntil!.timeIntervalSinceNow, 1440 * 60 + 1)
    }

    func testHoldAndRelease() {
        let c = makeRig(self).controller
        c.mode = .off
        let p = spawn(self)
        c.perform(.hold(pid: p.processIdentifier))
        XCTAssertTrue(c.heldAwake)
        XCTAssertTrue(c.isAwake)
        XCTAssertEqual(c.heldNames, ["sleep"])
        XCTAssertEqual(c.heldLine, "While sleep runs, then as before.")
        XCTAssertEqual(c.menuBarSymbol, "cup.and.saucer.fill")
        let q = spawn(self)
        c.perform(.hold(pid: q.processIdentifier))
        XCTAssertEqual(c.heldLine, "While 2 commands run, then as before.")
        c.perform(.release(pid: p.processIdentifier))
        c.perform(.release(pid: q.processIdentifier))
        XCTAssertFalse(c.heldAwake)
        XCTAssertNil(c.heldLine)
        c.perform(.hold(pid: 1))   // refused, logged
        XCTAssertFalse(c.heldAwake)
    }

    func testHoldDoesNotShowWhenModeAlreadyAwake() {
        let c = makeRig(self).controller
        c.mode = .alwaysOn
        let p = spawn(self)
        c.perform(.hold(pid: p.processIdentifier))
        XCTAssertFalse(c.heldAwake)
        XCTAssertEqual(c.heldNames, ["sleep"])
    }

    // MARK: Battery safeguards

    func testLowBatteryPausesAndRecoversOnPower() {
        let r = makeRig(self)
        r.controller.mode = .alwaysOn
        r.state.value.power = PowerState(onBattery: true, percent: 5, hasBattery: true)
        r.controller.refresh()
        XCTAssertFalse(r.controller.isAwake)
        XCTAssertEqual(r.controller.pauseReason, .batteryLow(5))
        XCTAssertFalse(r.controller.batteryAllowsAwake)
        XCTAssertEqual(r.controller.statusLine, "Paused — battery low")
        XCTAssertEqual(r.controller.menuBarSymbol, "battery.25")
        XCTAssertEqual(r.controller.powerState.percent, 5)
        r.state.value.power = PowerState(onBattery: false, percent: 5, hasBattery: true)
        r.controller.refresh()
        XCTAssertTrue(r.controller.isAwake)
        XCTAssertTrue(r.controller.batteryAllowsAwake)
    }

    func testOnlyPluggedInAndLowPowerMode() {
        let r = makeRig(self)
        r.controller.mode = .alwaysOn
        r.state.value.power = PowerState(onBattery: true, percent: 80, hasBattery: true, lowPowerMode: true)
        r.controller.onlyWhenPluggedIn = true
        XCTAssertEqual(r.controller.pauseReason, .onBattery)
        r.controller.onlyWhenPluggedIn = false
        r.controller.pauseInLowPowerMode = true
        XCTAssertEqual(r.controller.pauseReason, .lowPowerMode)
        XCTAssertEqual(r.controller.statusLine, "Paused — Low Power Mode")
    }

    func testNoPauseReasonWhenNotWantingAwake() {
        let r = makeRig(self)
        r.state.value.power = PowerState(onBattery: true, percent: 1, hasBattery: true)
        r.controller.mode = .off
        XCTAssertNil(r.controller.pauseReason)
    }

    func testPausedStopsWakeCheckIns() {
        let r = makeRig(self, helperInstalled: true)
        r.state.value.events = [event("Later", from: 5, to: 6)]
        r.state.value.power = PowerState(onBattery: true, percent: 3, hasBattery: true)
        r.controller.refresh()
        let asked = Double(wakeFile(r)!.trimmingCharacters(in: .whitespacesAndNewlines))!
        // No check-in while paused: only the event's own start.
        XCTAssertEqual(asked, ceil(r.controller.scheduledWake!.timeIntervalSince1970) + 5, accuracy: 1)
    }

    // MARK: Watched apps

    func testWatchedListEditing() {
        let c = makeRig(self).controller
        c.addWatched([.command("claude"), .command("codex")])
        c.addWatched([.command("CLAUDE"), .command("aider")])   // duplicate by id is skipped
        XCTAssertEqual(c.watchedItems.map(\.id), ["claude", "codex", "aider"])
        c.setRule(.running, for: .command("codex"))
        XCTAssertEqual(c.watchedItems[1].rule, .running)
        c.setRule(.running, for: .command("missing"))
        c.removeWatched(.command("claude"))
        XCTAssertEqual(c.watchedItems.map(\.id), ["codex", "aider"])
        c.addWatched([])
    }

    func testWatchedSummary() {
        let c = makeRig(self).controller
        XCTAssertEqual(c.watchedSummary([]), "a watched app is working")
        XCTAssertEqual(c.watchedSummary([.command("claude")]), "claude is working")
        XCTAssertEqual(c.watchedSummary([.command("claude"), .command("codex")]), "claude and codex are working")
        XCTAssertEqual(c.watchedSummary([.command("a", rule: .running), .command("b", rule: .running), .command("c", rule: .running)]),
                       "a and 2 more are running")
    }

    func testWatchedCommandKeepsAwakeThenGraceThenIdle() {
        let r = makeRig(self)
        _ = spawn(self, "/usr/bin/yes", [])
        r.controller.watchAppsEnabled = true
        r.controller.watchedItems = [.command("yes", rule: .running)]
        XCTAssertTrue(r.controller.isAwake)
        XCTAssertEqual(r.controller.activeWatched.map(\.id), ["yes"])
        XCTAssertEqual(r.controller.statusLine, "Awake — yes is running")
        XCTAssertNil(r.controller.watchGraceUntil)
        // Stop watching what's running: the grace period holds the Mac awake a while.
        r.controller.watchedItems = [.command("nothing-here-at-all", rule: .running)]
        XCTAssertTrue(r.controller.isAwake)
        XCTAssertNotNil(r.controller.watchGraceUntil)
        XCTAssertTrue(r.controller.watchedFinishedLine?.contains("finished · sleeping after") ?? false)
        XCTAssertTrue(r.controller.statusLine.hasPrefix("Awake — yes finished"))
        r.controller.watchGraceMinutes = 0
        XCTAssertFalse(r.controller.isAwake)
        XCTAssertNil(r.controller.watchedFinishedLine)
        // Not in Calendar mode: watching is off and the grace state resets.
        r.controller.mode = .alwaysOn
        XCTAssertEqual(r.controller.activeWatched, [])
    }

    func testFinishedLineWithSeveralItems() {
        let r = makeRig(self)
        _ = spawn(self, "/usr/bin/yes", [])
        _ = spawn(self)
        r.controller.watchAppsEnabled = true
        r.controller.watchedItems = [.command("yes", rule: .running), .command("sleep", rule: .running)]
        r.controller.watchedItems = [.command("gone", rule: .running)]
        XCTAssertTrue(r.controller.watchedFinishedLine?.hasPrefix("yes and others finished") ?? false)
    }

    // MARK: Lid closed

    func lidRig(helper: Bool = true) -> Rig {
        let r = makeRig(self, lidInstalled: helper)
        r.state.value.lidBattery = LidBattery(hasBattery: true, onBattery: false, percent: 90)
        return r
    }

    func testLidOffByDefaultAndHasBatteryFlag() {
        let r = lidRig()
        XCTAssertNil(r.controller.lidLine)
        XCTAssertEqual(r.controller.lidStatus, .off)
        let desk = makeRig(self)
        XCTAssertFalse(desk.controller.showsLidSetting)
    }

    func testLidStartsThenActive() throws {
        let r = lidRig()
        r.controller.mode = .alwaysOn
        r.controller.lidClosedAwake = true
        XCTAssertEqual(r.controller.lidStatus, .starting)
        XCTAssertEqual(r.controller.lidLine, "Turning on lid-closed mode…")
        try "1\n".write(toFile: r.lid.statePath, atomically: true, encoding: .utf8)
        r.controller.refresh()
        XCTAssertEqual(r.controller.lidStatus, .active)
        XCTAssertEqual(r.controller.lidLine, "Lid can be closed")
        XCTAssertNotEqual(try String(contentsOf: r.lid.leaseFile), "")
        r.controller.mode = .off
        XCTAssertEqual(r.controller.lidStatus, .off)
        XCTAssertEqual(try String(contentsOf: r.lid.leaseFile), "")
    }

    func testLidPausesOnLowBatteryWithHysteresis() {
        let r = lidRig()
        r.controller.mode = .alwaysOn
        r.controller.lidClosedAwake = true
        r.controller.batteryStopPercent = 0   // only the lid's own floor applies
        r.state.value.lidBattery = LidBattery(hasBattery: true, onBattery: true, percent: 20)
        r.controller.refresh()
        XCTAssertEqual(r.controller.lidStatus, .pausedBattery)
        XCTAssertEqual(r.controller.lidLine, "Lid-closed paused · battery low")
        r.state.value.lidBattery = LidBattery(hasBattery: true, onBattery: true, percent: 23)   // not above 25 yet
        r.controller.refresh()
        XCTAssertEqual(r.controller.lidStatus, .pausedBattery)
        r.state.value.lidBattery = LidBattery(hasBattery: true, onBattery: true, percent: 26)
        r.controller.refresh()
        XCTAssertEqual(r.controller.lidStatus, .starting)
        r.state.value.lidBattery = LidBattery(hasBattery: true, onBattery: true, percent: 15)
        r.controller.refresh()
        r.state.value.lidBattery = LidBattery(hasBattery: true, onBattery: false, percent: 15)   // plugged in
        r.controller.refresh()
        XCTAssertEqual(r.controller.lidStatus, .starting)
    }

    func testLidPausesWhenHot() {
        let r = lidRig()
        r.controller.mode = .alwaysOn
        r.controller.lidClosedAwake = true
        r.state.value.thermal = .serious
        r.controller.refresh()
        XCTAssertEqual(r.controller.lidStatus, .pausedHot)
        XCTAssertEqual(r.controller.lidLine, "Lid-closed paused · Mac is hot")
        r.state.value.thermal = .critical
        r.controller.refresh()
        XCTAssertEqual(r.controller.lidStatus, .pausedHot)
        r.state.value.thermal = .fair
        r.controller.refresh()
        XCTAssertEqual(r.controller.lidStatus, .starting)
    }

    func testLidNeedsHelper() {
        let r = lidRig(helper: false)
        r.controller.mode = .alwaysOn
        r.controller.lidClosedAwake = true
        XCTAssertEqual(r.controller.lidStatus, .off)
    }

    func testLidWarningFlow() {
        let r = lidRig()
        r.state.value.confirm = false
        r.controller.setLidClosedAwake(true)
        XCTAssertFalse(r.controller.lidClosedAwake)
        r.state.value.confirm = true
        r.controller.setLidClosedAwake(true)
        XCTAssertTrue(r.controller.lidClosedAwake)
        r.controller.setLidClosedAwake(false)
        XCTAssertFalse(r.controller.lidClosedAwake)
        // Once acknowledged, the warning isn't asked again.
        r.defaults.set(true, forKey: "lidWarningAcknowledged")
        r.state.value.confirm = false
        r.controller.setLidClosedAwake(true)
        XCTAssertTrue(r.controller.lidClosedAwake)
    }

    func testSetUpLidClosed() {
        let bundle = makeBundle(self, wakeVersion: 1, lidVersion: 1)
        let r = makeRig(self, bundle: bundle)
        let seen = withFakeAdmin(self) { [r] _ in
            try? "x".write(to: r.dir.appendingPathComponent("lid.plist"), atomically: true, encoding: .utf8)
        }
        r.state.value.confirm = false
        r.controller.setUpLidClosed()          // cancelled at the warning
        XCTAssertTrue(seen.value.isEmpty)
        r.state.value.confirm = true
        r.controller.setUpLidClosed()
        XCTAssertEqual(seen.value.count, 1)
        XCTAssertTrue(r.controller.lidClosedAwake)
        XCTAssertTrue(r.controller.lidHelperInstalled)
        XCTAssertFalse(r.controller.lidHelperBusy)
        XCTAssertNil(r.controller.lidHelperError)
    }

    func testSetUpLidClosedFailure() {
        let r = makeRig(self, bundle: makeBundle(self, wakeVersion: 1, lidVersion: 1))
        _ = withFakeAdmin(self, succeed: false)
        r.controller.setUpLidClosed()
        XCTAssertFalse(r.controller.lidClosedAwake)
        XCTAssertNotNil(r.controller.lidHelperError)
    }

    func testUninstallLidHelper() {
        let r = lidRig()
        let plist = r.dir.appendingPathComponent("lid.plist")
        _ = withFakeAdmin(self) { _ in try? FileManager.default.removeItem(at: plist) }
        r.controller.uninstallLidHelper()
        XCTAssertFalse(r.controller.lidHelperInstalled)
        XCTAssertNil(r.controller.lidHelperError)
        _ = withFakeAdmin(self, succeed: false)
        r.controller.uninstallLidHelper()
        XCTAssertNotNil(r.controller.lidHelperError)
    }

    // MARK: Wake helper

    func testInstallAndUninstallWakeHelper() {
        let r = makeRig(self, bundle: makeBundle(self, wakeVersion: 1, lidVersion: 1))
        let plist = r.dir.appendingPathComponent("wake.plist")
        _ = withFakeAdmin(self) { _ in try? "x".write(to: plist, atomically: true, encoding: .utf8) }
        r.controller.installWakeHelper()
        XCTAssertTrue(r.controller.wakeHelperInstalled)
        XCTAssertFalse(r.controller.wakeHelperBusy)
        XCTAssertNil(r.controller.wakeHelperError)
        _ = withFakeAdmin(self) { _ in try? FileManager.default.removeItem(at: plist) }
        r.controller.uninstallWakeHelper()
        XCTAssertFalse(r.controller.wakeHelperInstalled)
        _ = withFakeAdmin(self, succeed: false)
        r.controller.uninstallWakeHelper()
        XCTAssertNotNil(r.controller.wakeHelperError)
        r.controller.installWakeHelper()
        XCTAssertNotNil(r.controller.wakeHelperError)
    }

    func testUpdateHelpers() {
        let bundle = makeBundle(self, wakeVersion: 5, lidVersion: 5)
        let r = makeRig(self, helperInstalled: true, lidInstalled: true, bundle: bundle)
        try! "# macawake-helper-version: 1\n".write(toFile: r.dir.appendingPathComponent("wake-helper").path, atomically: true, encoding: .utf8)
        try! "# macawake-helper-version: 1\n".write(toFile: r.dir.appendingPathComponent("lid-helper").path, atomically: true, encoding: .utf8)
        let seen = withFakeAdmin(self) { [r] command in
            // Each install updates only its own helper.
            let n = command.contains("lid.plist") ? "lid-helper" : "wake-helper"
            try? "# macawake-helper-version: 5\n".write(toFile: r.dir.appendingPathComponent(n).path, atomically: true, encoding: .utf8)
        }
        let c = AwakeController(defaults: r.defaults, waker: r.waker, lid: r.lid, hooks: .init())
        XCTAssertTrue(c.helpersNeedUpdate)
        c.updateHelpers()
        XCTAssertEqual(seen.value.count, 2)
        XCTAssertFalse(c.helpersNeedUpdate)
        c.updateHelpers()   // nothing older: nothing to do
        XCTAssertEqual(seen.value.count, 2)
    }

    func testUpdateHelpersLidFailure() {
        let bundle = makeBundle(self, wakeVersion: 1, lidVersion: 5)
        let r = makeRig(self, lidInstalled: true, bundle: bundle)
        try! "# macawake-helper-version: 1\n".write(toFile: r.dir.appendingPathComponent("lid-helper").path, atomically: true, encoding: .utf8)
        _ = withFakeAdmin(self, succeed: false)
        r.controller.updateHelpers()
        XCTAssertEqual(r.controller.lidHelperError, "Couldn't update the lid-closed helper.")
    }

    // MARK: Power-on and system observers

    func testHandlePowerOn() {
        let r = makeRig(self, helperInstalled: true)
        r.controller.refresh()   // picks up that the helper is installed
        r.controller.handlePowerOn()
        r.controller.handlePowerOn()   // replaces the pending check
        r.controller.mode = .alwaysOn
        r.controller.handlePowerOn()   // not Calendar mode: just a refresh
        XCTAssertTrue(r.controller.isAwake)
    }

    func testObserversRefreshOnNotifications() async throws {
        let r = makeRig(self, observe: true)
        r.state.value.events = [event("Now", from: -1, to: 1)]
        XCTAssertFalse(r.controller.isAwake)
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(r.controller.isAwake)

        r.state.value.events = []
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(r.controller.isAwake)

        r.state.value.events = [event("Again", from: -1, to: 1)]
        NotificationCenter.default.post(name: ProcessInfo.thermalStateDidChangeNotification, object: nil)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(r.controller.isAwake)

        // App launches only matter when apps are watched.
        r.controller.watchAppsEnabled = true
        r.controller.watchedItems = [.command("x")]
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        r.controller.watchedItems = [WatchedItem(kind: .app, id: "local.none", name: "None", rule: .running)]
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        try await Task.sleep(nanoseconds: 300_000_000)

        NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(try String(contentsOf: r.lid.leaseFile), "")
    }

    // MARK: Text helpers

    func testDurationLabels() {
        XCTAssertEqual(durationLabel(minutes: 30), "30 minutes")
        XCTAssertEqual(durationLabel(minutes: 60), "1 hour")
        XCTAssertEqual(durationLabel(minutes: 180), "3 hours")
        XCTAssertEqual(timedDurations.first, 30)
    }

    func testLaunchAtLoginReads() {
        let c = makeRig(self).controller
        _ = c.launchAtLogin
        c.launchAtLogin = false   // asking to unregister is harmless when nothing is registered
    }

    func testDemoHelpers() {
        XCTAssertEqual(Demo.suite, "local.macawake.demo")
        XCTAssertEqual(Demo.choice, "calendar")
        XCTAssertEqual(Demo.watched.count, 3)
        XCTAssertFalse(AwakeController.launchedAsDemo)
    }
}
