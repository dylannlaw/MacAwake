import AppKit
import EventKit
import ServiceManagement
import SwiftUI

enum Mode: String, CaseIterable, Identifiable {
    case auto, alwaysOn, timed, off
    var id: String { rawValue }
    var label: String {
        switch self {
        case .auto: return "Auto — follow calendar and watched apps"
        case .alwaysOn: return "Always awake"
        case .timed: return "Awake for a set time"
        case .off: return "Off"
        }
    }
}

/// What the lid-closed keep-awake is doing, for the panel.
enum LidStatus: Equatable {
    case off            // setting off, or nothing is keeping the Mac awake
    case starting       // asked for, waiting for the helper to act
    case active         // the lid can be closed
    case pausedBattery  // on battery below the safety floor
    case pausedHot      // macOS reports the Mac is too hot
}

/// Lid-closed keep-awake never runs on battery at or below this, whatever other settings say.
let lidBatteryFloor = 20
/// …and after it pauses, waits until the battery is back above this before resuming.
let lidBatteryResume = 25

/// Choices for "Keep awake for", in minutes.
let timedDurations = [30, 60, 120, 180, 240, 360, 480, 720]

func durationLabel(minutes: Int) -> String {
    if minutes < 60 { return "\(minutes) minutes" }
    let h = minutes / 60
    return h == 1 ? "1 hour" : "\(h) hours"
}

@MainActor
final class AwakeController: ObservableObject {
    static let shared = AwakeController()


    // MARK: - Live state

    @Published private(set) var isAwake = false
    @Published private(set) var currentEvent: EKEvent?
    @Published private(set) var awakeUntil: Date?
    @Published private(set) var nextEvent: EKEvent?
    @Published private(set) var hasAccess = false
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var scheduledWake: Date?
    /// Ongoing and upcoming events (up to 4), for the panel's agenda.
    @Published private(set) var agenda: [EKEvent] = []
    /// When the current timer started, for the progress ring.
    @Published private(set) var timedStart: Date? {
        didSet { defaults.set(timedStart?.timeIntervalSince1970, forKey: "timedStart") }
    }
    /// Watched apps/commands that are active right now.
    @Published private(set) var activeWatched: [WatchedItem] = []
    /// The ones that were active last, shown during the grace period ("claude finished").
    @Published private(set) var recentWatched: [WatchedItem] = []
    /// Set while only the grace period is keeping the Mac awake: when it ends.
    @Published private(set) var watchGraceUntil: Date?
    @Published private(set) var wakeHelperInstalled = false
    /// True when only `macawake run` holds (not the mode) are keeping the Mac awake.
    @Published private(set) var heldAwake = false
    /// Names of the processes `macawake run` is holding awake for.
    @Published private(set) var heldNames: [String] = []
    @Published private(set) var wakeHelperBusy = false
    /// Shown in the panel when setting up or removing the helper didn't work.
    @Published private(set) var wakeHelperError: String?
    /// How the Mac is powered, as of the last refresh.
    @Published private(set) var powerState = PowerState()
    /// Set while the mode wants the Mac awake but a battery safeguard stops it. Drives the "Paused" UI.
    @Published private(set) var pauseReason: PauseReason?
    @Published private(set) var lidHelperInstalled = false
    @Published private(set) var lidHelperBusy = false
    @Published private(set) var lidHelperError: String?
    @Published private(set) var lidStatus: LidStatus = .off
    /// MacBook or desktop Mac, read once at launch. Decides which battery and lid settings are offered.
    let device = DeviceKind.current
    /// Shows "Keep awake with lid closed": MacBooks only, plus previews of a lid status.
    @Published private(set) var showsLidSetting = false
    /// Which battery settings the panel shows: always on a MacBook, on a desktop only while a UPS is attached.
    var batterySettings: BatterySettingsStyle? { BatterySettingsStyle.for(device, power: powerState) }
    /// An installed helper is older than the one in this app.
    @Published private(set) var helpersNeedUpdate = false

    // MARK: - Settings (persisted in UserDefaults)

    @Published var mode: Mode {
        didSet {
            if mode != .timed { timedUntil = nil; timedStart = nil }
            defaults.set(mode.rawValue, forKey: "mode")
            refresh()
        }
    }
    /// When the timed mode ends. It then switches to Off.
    @Published private(set) var timedUntil: Date? {
        didSet {
            defaults.set(timedUntil?.timeIntervalSince1970, forKey: "timedUntil")
            scheduleTimedExpiry()
        }
    }
    @Published var keepDisplayOn: Bool {
        didSet { defaults.set(keepDisplayOn, forKey: "keepDisplayOn"); refresh() }
    }
    @Published var includeAllDay: Bool {
        didSet { defaults.set(includeAllDay, forKey: "includeAllDay"); refresh() }
    }
    @Published var ignoreFreeEvents: Bool {
        didSet { defaults.set(ignoreFreeEvents, forKey: "ignoreFreeEvents"); refresh() }
    }
    @Published var leadMinutes: Int {
        didSet { defaults.set(leadMinutes, forKey: "leadMinutes"); refresh() }
    }
    @Published var trailMinutes: Int {
        didSet { defaults.set(trailMinutes, forKey: "trailMinutes"); refresh() }
    }
    @Published var wakeForEvents: Bool {
        didSet { defaults.set(wakeForEvents, forKey: "wakeForEvents"); refresh() }
    }
    /// While asleep, wake briefly this often (minutes) to look for new events. 0 = never.
    @Published var sleepCheckMinutes: Int {
        didSet { defaults.set(sleepCheckMinutes, forKey: "sleepCheckMinutes"); refresh() }
    }
    /// Stop keeping awake on battery below this charge (percent). 0 = never.
    @Published var batteryStopPercent: Int {
        didSet {
            defaults.set(batteryStopPercent, forKey: "batteryStopPercent")
            batteryLatched = false   // a changed limit is judged afresh, not by the old latch
            refresh()
        }
    }
    /// Keep awake only while on the power adapter.
    @Published var onlyWhenPluggedIn: Bool {
        didSet { defaults.set(onlyWhenPluggedIn, forKey: "onlyWhenPluggedIn"); refresh() }
    }
    /// Don't keep awake while Low Power Mode is on (on battery only).
    @Published var pauseInLowPowerMode: Bool {
        didSet { defaults.set(pauseInLowPowerMode, forKey: "pauseInLowPowerMode"); refresh() }
    }
    /// Keep the Mac awake with its lid closed (even on battery) while MacAwake is keeping it awake.
    /// Change it through `setLidClosedAwake(_:)` from the UI, which shows the heat warning first.
    @Published var lidClosedAwake: Bool {
        didSet { defaults.set(lidClosedAwake, forKey: "lidClosedAwake"); refresh() }
    }
    /// In Calendar mode, also stay awake while a watched app or command is working.
    @Published var watchAppsEnabled: Bool {
        didSet { defaults.set(watchAppsEnabled, forKey: "watchAppsEnabled"); refresh() }
    }
    @Published var watchedItems: [WatchedItem] {
        didSet {
            defaults.set(try? JSONEncoder().encode(watchedItems), forKey: "watchedItems")
            refresh()
        }
    }
    /// Stay awake this long after the last watched activity.
    @Published var watchGraceMinutes: Int {
        didSet { defaults.set(watchGraceMinutes, forKey: "watchGraceMinutes"); refresh() }
    }
    @Published var excludedCalendarIDs: Set<String> {
        didSet { defaults.set(Array(excludedCalendarIDs), forKey: "excludedCalendarIDs"); refresh() }
    }

    // MARK: - Internals

    /// `--preview-panel --demo`: sample events and settings, for screenshots. See `Demo` below.
    static let isDemo = CommandLine.arguments.contains("--preview-panel") && CommandLine.arguments.contains("--demo")

    // A demo keeps its settings apart, so it never changes the real ones.
    private let defaults = isDemo ? UserDefaults(suiteName: Demo.suite)! : UserDefaults.standard
    private let store = EKEventStore()
    private let assertion = SleepAssertion()
    private let waker = WakeScheduler()
    private let lid = LidScheduler()
    private var powerWatcher: PowerSourceWatcher?
    /// Set when the lid hold paused for a low battery; cleared above `lidBatteryResume` or on power.
    private var lidBatteryLatched = false
    private let watcher = ProcessWatcher()
    private var lastWatchedActivity: Date?
    private let holds = ProcessHolds()
    private var timer: Timer?
    private var expiryTimer: Timer?
    private var power: SystemPower?
    private var checkInTimer: Timer?
    private var powerSource: PowerSource?
    /// What the battery safeguards say right now, whatever the mode. nil = no objection.
    private var safeguard: PauseReason?
    /// On battery the charge only falls, so once it's under the limit stay paused until power is
    /// connected, rather than flapping on noisy readings around the limit.
    private var batteryLatched = false
    private var observers: [NSObjectProtocol] = []
    /// Opts out of App Nap, which could otherwise delay the 30 s check by minutes and start events late.
    /// Idle system sleep stays allowed; the power assertions decide that.
    private var noNap: NSObjectProtocol?
    /// Demo stand-ins for what a real Mac would report: events, busy watched items, `macawake run`
    /// holds and the power source. See `Demo`.
    private var demoEvents: [EKEvent] = []
    private var demoWorking: [WatchedItem] = []
    private var demoHeld: [String] = []
    private var demoPower = PowerState(onBattery: false, percent: 100, hasBattery: true)

    private let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()
    private let relativeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        f.doesRelativeDateFormatting = true   // "Today, 14:00" / "Tomorrow, 09:30"
        return f
    }()

    init() {
        if Self.isDemo { Demo.resetDefaults() }
        let savedMode = Mode(rawValue: defaults.string(forKey: "mode") ?? "") ?? .auto
        let savedUntil = defaults.double(forKey: "timedUntil")
        let until = savedUntil > 0 ? Date(timeIntervalSince1970: savedUntil) : nil
        defaults.removeObject(forKey: "timedReturnMode")   // no longer used: a timer always ends in Off
        timedUntil = savedMode == .timed ? until : nil
        let savedStart = defaults.double(forKey: "timedStart")
        timedStart = (savedMode == .timed && savedStart > 0) ? Date(timeIntervalSince1970: savedStart) : nil
        // A timer with no end time can't run; turn off. An expired one is handled by refresh().
        mode = (savedMode == .timed && until == nil) ? .off : savedMode
        keepDisplayOn = defaults.object(forKey: "keepDisplayOn") as? Bool ?? true
        includeAllDay = defaults.object(forKey: "includeAllDay") as? Bool ?? false
        ignoreFreeEvents = defaults.object(forKey: "ignoreFreeEvents") as? Bool ?? false
        leadMinutes = defaults.object(forKey: "leadMinutes") as? Int ?? 2
        trailMinutes = defaults.object(forKey: "trailMinutes") as? Int ?? 0
        excludedCalendarIDs = Set(defaults.stringArray(forKey: "excludedCalendarIDs") ?? [])
        wakeForEvents = defaults.object(forKey: "wakeForEvents") as? Bool ?? true
        sleepCheckMinutes = defaults.object(forKey: "sleepCheckMinutes") as? Int ?? 15
        batteryStopPercent = defaults.object(forKey: "batteryStopPercent") as? Int ?? 10
        onlyWhenPluggedIn = defaults.object(forKey: "onlyWhenPluggedIn") as? Bool ?? false
        pauseInLowPowerMode = defaults.object(forKey: "pauseInLowPowerMode") as? Bool ?? false
        lidClosedAwake = defaults.object(forKey: "lidClosedAwake") as? Bool ?? false
        watchAppsEnabled = defaults.object(forKey: "watchAppsEnabled") as? Bool ?? false
        watchedItems = defaults.data(forKey: "watchedItems")
            .flatMap { try? JSONDecoder().decode([WatchedItem].self, from: $0) } ?? []
        watchGraceMinutes = defaults.object(forKey: "watchGraceMinutes") as? Int ?? 5
        wakeHelperInstalled = waker.isHelperInstalled
        lidHelperInstalled = lid.isHelperInstalled
        // A lid status preview shows the lid setting on desktops too. The demo counts as a MacBook (`DeviceKind`).
        showsLidSetting = device.isLaptop || Self.previewLidStatus != nil
        helpersNeedUpdate = waker.helperNeedsUpdate || lid.helperNeedsUpdate

        // A demo runs beside the real app: no timers, power assertions or wake requests.
        if Self.isDemo { startDemo(); return }

        noNap = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Watching calendar events and timers"
        )
        startObserving()
        scheduleTimedExpiry()   // didSet doesn't run during init

        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            hasAccess = true
            reloadCalendars()
            refresh()
        case .notDetermined:
            requestAccess()
        default:
            hasAccess = false
            refresh()
        }
    }

    // MARK: - Calendar access

    func requestAccess() {
        Task {
            do {
                hasAccess = try await store.requestFullAccessToEvents()
            } catch {
                NSLog("MacAwake: calendar access error: \(error)")
                hasAccess = false
            }
            if hasAccess { store.reset() }
            reloadCalendars()
            refresh()
        }
    }

    func openPrivacySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
    }

    private func reloadCalendars() {
        guard hasAccess else { calendars = []; return }
        calendars = store.calendars(for: .event).sorted { a, b in
            let bySource = a.source.title.localizedCaseInsensitiveCompare(b.source.title)
            if bySource != .orderedSame { return bySource == .orderedAscending }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }
    }

    func binding(for cal: EKCalendar) -> Binding<Bool> {
        let id = cal.calendarIdentifier
        return Binding(
            get: { !self.excludedCalendarIDs.contains(id) },
            set: { on in
                if on { self.excludedCalendarIDs.remove(id) } else { self.excludedCalendarIDs.insert(id) }
            }
        )
    }

    // MARK: - Refresh triggers

    private func startObserving() {
        // A held process exited.
        holds.onChange = { [weak self] in self?.refresh() }

        // Poll every 30 s so we catch event start/end boundaries.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer?.tolerance = 5

        // Calendar edited / synced.
        observers.append(NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.reloadCalendars(); self?.refresh() }
        })

        // Mac woke from sleep — re-evaluate immediately.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })

        // Plugged in / unplugged, charge level, Low Power Mode.
        powerSource = PowerSource { [weak self] in
            Task { @MainActor in self?.refresh() }
        }

        // A watched app opened or quit: no need to wait for the 30 s poll.
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.watchAppsEnabled, self.watchedItems.contains(where: { $0.kind == .app })
                    else { return }
                    self.refresh()
                }
            })
        }

        // Any wake, including the dark wakes our check-ins cause (which NSWorkspace doesn't report).
        power = SystemPower { [weak self] in
            Task { @MainActor in self?.handlePowerOn() }
        }

        // About to sleep — make sure the next wake is up to date.
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })

        // Quitting — don't leave a wake behind that nothing will act on, and give the lid back.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.waker.request(nil)
                self?.lid.request(false)
            }
        })

        // The lid hold pauses when the Mac gets hot or the battery runs low.
        observers.append(NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        })
        powerWatcher = PowerSourceWatcher { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
    }

    /// The Mac just powered on, possibly only in a dark wake for a check-in. Keep it up for a minute,
    /// ask the calendar to sync, and look again once it has had time to. `EKEventStoreChanged` also
    /// refreshes as soon as anything new arrives; `refresh()` then schedules the next wake.
    private func handlePowerOn() {
        guard mode == .auto, wakeForEvents, wakeHelperInstalled, hasAccess else { return refresh() }
        assertion.holdForCheckIn(seconds: 60)
        store.refreshSourcesIfNecessary()
        refresh()
        checkInTimer?.invalidate()
        checkInTimer = Timer.scheduledTimer(withTimeInterval: 40, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Timed mode

    /// Keep the Mac awake for `minutes`, then switch to Off.
    func startTimed(minutes: Int) {
        timedStart = Date()
        timedUntil = Date().addingTimeInterval(Double(minutes) * 60)
        if mode == .timed { refresh() } else { mode = .timed }
    }

    /// Add time to a running timer.
    func extendTimed(minutes: Int) {
        guard mode == .timed, let until = timedUntil else { return startTimed(minutes: minutes) }
        timedUntil = max(until, Date()).addingTimeInterval(Double(minutes) * 60)
        refresh()
    }

    func stopTimed() {
        guard mode == .timed else { return }
        mode = .off
    }

    // MARK: - URL commands (macawake://, the CLI, Shortcuts)

    /// Runs a validated `macawake://` command. Mode commands do exactly what the panel's controls do;
    /// holds never change the mode.
    func perform(_ command: URLCommand) {
        switch command {
        case .start(let minutes):
            startTimed(minutes: minutes)
        case .extend(let minutes):
            extendTimed(minutes: minutes)
            // A URL may not push a timer more than 24 h out.
            let cap = Date().addingTimeInterval(Double(URLCommand.maxMinutes) * 60)
            if let until = timedUntil, until > cap { timedUntil = cap; refresh() }
        case .stop:
            stopTimed()
        case .setMode(let m):
            mode = m
        case .hold(let pid):
            if !holds.add(pid: pid) { NSLog("MacAwake: refused hold for pid \(pid)") }
            refresh()
        case .release(let pid):
            holds.remove(pid: pid)
            refresh()
        }
    }

    private func scheduleTimedExpiry() {
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let until = timedUntil else { return }
        // Fire just after the end: a timer can fire a hair early, and refresh() would then see time left
        // and wait for the next 30 s poll.
        let t = Timer(fire: until.addingTimeInterval(0.5), interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        expiryTimer = t
    }

    // MARK: - Core logic

    func refresh() {
        let now = Date()

        // Timer ran out (or we woke after it would have): switch to Off.
        if mode == .timed, timedUntil.map({ now >= $0 }) ?? true {
            mode = .off   // didSet refreshes
            return
        }
        var active: [EKEvent] = []
        var upcoming: EKEvent?

        if hasAccess {
            let events = Self.isDemo ? demoEvents : relevantEvents(around: now)
            active = events.filter { window(for: $0).contains(now) }
            upcoming = events.first { window(for: $0).start > now }
            agenda = Array(events.filter { $0.endDate > now }.prefix(4))
        } else {
            agenda = []
        }

        // If several events overlap, stay awake until the last one ends.
        let latest = active.max { $0.endDate < $1.endDate }
        currentEvent = latest
        awakeUntil = latest.map { window(for: $0).end }
        nextEvent = upcoming

        // Watched apps and commands (Calendar mode only), with a grace period after the last activity.
        let watching = mode == .auto && watchAppsEnabled && !watchedItems.isEmpty
        let working = watching ? (Self.isDemo ? demoWorking : watcher.active(watchedItems, now: now)) : []
        if !working.isEmpty {
            lastWatchedActivity = now
            if recentWatched != working { recentWatched = working }
        }
        if !watching { lastWatchedActivity = nil }
        let graceEnd = lastWatchedActivity.map { $0.addingTimeInterval(Double(watchGraceMinutes) * 60) }
        let watchedAwake = graceEnd.map { now < $0 } ?? false
        if activeWatched != working { activeWatched = working }
        watchGraceUntil = (watchedAwake && working.isEmpty) ? graceEnd : nil

        let modeAwake: Bool
        let modeReason: String
        switch mode {
        case .auto:
            modeAwake = latest != nil || watchedAwake
            modeReason = latest != nil
                ? "Calendar event: \(latest?.title ?? "")"
                : working.isEmpty
                    ? "MacAwake: \(recentWatched.first?.name ?? "watched app") finished, staying awake briefly"
                    : "MacAwake: \(watchedSummary(working))"
        case .alwaysOn:
            modeAwake = true
            modeReason = "MacAwake: always awake"
        case .timed:
            modeAwake = true
            modeReason = "MacAwake: awake until \(timeFormatter.string(from: timedUntil ?? now))"
        case .off:
            modeAwake = false
            modeReason = ""
        }

        // `macawake run` holds keep the Mac awake whatever the mode.
        holds.prune(now: now)
        heldNames = Self.isDemo ? demoHeld : holds.names
        heldAwake = !modeAwake && !heldNames.isEmpty
        let shouldBeAwake = modeAwake || heldAwake
        let reason = heldAwake ? "MacAwake: while \(heldNames.joined(separator: ", ")) runs" : modeReason

        if Self.isDemo {
            // The real safeguard rule on made-up power; the lid shows on as if its helper had acted.
            // `MACAWAKE_FAKE_POWER` overrides it (e.g. a desktop on a UPS); a desktop demo has no battery by default.
            let power = PowerSource.parseFake(ProcessInfo.processInfo.environment["MACAWAKE_FAKE_POWER"])
                ?? (device.isLaptop ? demoPower : PowerState())
            powerState = power
            pauseReason = shouldBeAwake ? evaluateSafeguards(power) : nil
            isAwake = shouldBeAwake && pauseReason == nil
            scheduledWake = mode == .auto && pauseReason == nil ? upcoming.map { window(for: $0).start } : nil
            lidStatus = lidClosedAwake && lidHelperInstalled && isAwake ? .active : .off
            return
        }

        // Battery safeguards veto keeping awake in every mode; the mode itself is left as it is.
        powerState = powerSource?.current() ?? PowerState()
        safeguard = evaluateSafeguards(powerState)
        pauseReason = shouldBeAwake ? safeguard : nil
        let holdAwake = shouldBeAwake && safeguard == nil

        if holdAwake {
            // An event just started. If the Mac only half-woke for it (a scheduled "dark" wake),
            // count it as user activity so the display comes on and the Mac doesn't drop back to sleep.
            // Only events do this: a watched app or a `macawake run` hold must never light the screen
            // in a check-in dark wake.
            if !isAwake && mode == .auto && latest != nil { assertion.declareUserActivity(reason: reason) }
            assertion.enable(reason: reason, keepDisplayOn: keepDisplayOn)
        } else {
            assertion.disable()
        }
        isAwake = holdAwake

        // Schedule a hardware wake for the next event, in case the Mac is asleep by then.
        let installed = waker.isHelperInstalled
        if installed != wakeHelperInstalled { wakeHelperInstalled = installed }
        let wakes = mode == .auto && wakeForEvents && wakeHelperInstalled
        let wake = wakes ? upcoming.map { window(for: $0).start } : nil
        // Also wake regularly to look for events added while asleep, if that comes sooner. Not while a
        // battery safeguard blocks: each check-in costs charge and couldn't keep the Mac awake anyway.
        let checkIn = (wakes && hasAccess && safeguard == nil) ? nextCheckIn(after: now) : nil
        waker.request([wake, checkIn].compactMap { $0 }.min())
        scheduledWake = wake

        // A battery safeguard pause releases the lid hold too: the Mac isn't being kept awake.
        updateLid(shouldBeAwake: holdAwake)
    }

    // MARK: - Lid closed

    /// Decides the lid hold. Only while MacAwake is keeping the Mac awake, the setting is on, the helper
    /// is installed, and the battery and temperature allow it. The helper releases it by itself if the
    /// app stops renewing the lease.
    private func updateLid(shouldBeAwake: Bool) {
        let installed = lid.isHelperInstalled
        if installed != lidHelperInstalled { lidHelperInstalled = installed }

        let battery = lidBatteryAllows()
        let cool = thermalAllows()
        let want = lidClosedAwake && shouldBeAwake && installed && battery && cool
        lid.request(want)

        let status: LidStatus
        if !lidClosedAwake || !shouldBeAwake || !installed { status = .off }
        else if !battery { status = .pausedBattery }
        else if !cool { status = .pausedHot }
        else { status = lid.isHoldActive ? .active : .starting }
        let shown = Self.previewLidStatus ?? status
        if shown != lidStatus { lidStatus = shown }
    }

    /// Debug: `--preview-lid-status active|starting|battery|hot` (with `--preview-panel`) shows that
    /// status in the panel, for snapshots. It changes only what's shown, never the lease.
    private static let previewLidStatus: LidStatus? = {
        let a = CommandLine.arguments
        guard a.contains("--preview-panel"), let i = a.firstIndex(of: "--preview-lid-status"), i + 1 < a.count
        else { return nil }
        switch a[i + 1] {
        case "active": return .active
        case "starting": return .starting
        case "battery": return .pausedBattery
        case "hot": return .pausedHot
        default: return nil
        }
    }()

    /// The mandatory battery floor for the lid hold. On power: always allowed. On battery: paused at or
    /// below `lidBatteryFloor` %, and resumes only above `lidBatteryResume` %, so it doesn't flap.
    /// Swap point for the battery-safeguards change: also require its shared check here.
    private func lidBatteryAllows() -> Bool {
        let b = LidBattery.current()
        guard b.hasBattery, b.onBattery, let pct = b.percent else {
            lidBatteryLatched = false
            return true
        }
        if pct <= lidBatteryFloor { lidBatteryLatched = true }
        else if pct > lidBatteryResume { lidBatteryLatched = false }
        return !lidBatteryLatched
    }

    /// Pauses the lid hold while macOS reports the Mac as seriously hot.
    private func thermalAllows() -> Bool {
        switch ProcessInfo.processInfo.thermalState {
        case .serious, .critical: return false
        default: return true
        }
    }

    /// Turning the setting on shows the heat warning the first time.
    func setLidClosedAwake(_ on: Bool) {
        if on && !confirmLidWarning() { return }
        lidClosedAwake = on
    }

    /// Installs the lid helper (after the warning) and turns the setting on.
    func setUpLidClosed() {
        guard confirmLidWarning() else { return }
        lidHelperBusy = true
        lidHelperError = nil
        lid.install { [weak self] ok in
            guard let self else { return }
            self.lidHelperBusy = false
            self.lidHelperInstalled = self.lid.isHelperInstalled
            self.helpersNeedUpdate = self.waker.helperNeedsUpdate || self.lid.helperNeedsUpdate
            if ok { self.lidClosedAwake = true }
            else { self.lidHelperError = "Setup didn't finish. Try again, or check Console for details." }
            self.refresh()
        }
    }

    func uninstallLidHelper() {
        lidHelperBusy = true
        lidHelperError = nil
        lid.request(false)
        lid.uninstall { [weak self] ok in
            guard let self else { return }
            self.lidHelperBusy = false
            self.lidHelperInstalled = self.lid.isHelperInstalled
            if !ok { self.lidHelperError = "Couldn't remove the lid-closed helper." }
            self.refresh()
        }
    }

    /// Re-installs whichever helpers are older than the copies in this app.
    func updateHelpers() {
        if waker.helperNeedsUpdate { installWakeHelper() }
        if lid.helperNeedsUpdate {
            lidHelperBusy = true
            lid.install { [weak self] ok in
                guard let self else { return }
                self.lidHelperBusy = false
                if !ok { self.lidHelperError = "Couldn't update the lid-closed helper." }
                self.helpersNeedUpdate = self.waker.helperNeedsUpdate || self.lid.helperNeedsUpdate
                self.refresh()
            }
        }
    }

    /// Explains the risk once. Returns false if the user cancels.
    private func confirmLidWarning() -> Bool {
        if defaults.bool(forKey: "lidWarningAcknowledged") { return true }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Keep your Mac awake with the lid closed?"
        alert.informativeText = """
            While MacAwake is keeping your Mac awake, closing the lid won't put it to sleep, even on battery.

            Don't put your Mac in a bag or sleeve while this is on: it can overheat. MacAwake pauses this if \
            the Mac gets too hot or the battery drops to \(lidBatteryFloor)%, and your Mac sleeps normally \
            again as soon as MacAwake stops keeping it awake.
            """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Turn On")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return false }
        defaults.set(true, forKey: "lidWarningAcknowledged")
        return true
    }

    var lidLine: String? {
        switch lidStatus {
        case .off: return nil
        case .starting: return "Turning on lid-closed mode…"
        case .active: return "Lid can be closed"
        case .pausedBattery: return "Lid-closed paused · battery low"
        case .pausedHot: return "Lid-closed paused · Mac is hot"
        }
    }

    // MARK: - Battery safeguards

    /// False when a battery safeguard says the Mac shouldn't be kept awake right now (as of the last
    /// `refresh()`). Closed-lid mode and any other keep-awake path must check this.
    var batteryAllowsAwake: Bool { safeguard == nil }

    private func evaluateSafeguards(_ p: PowerState) -> PauseReason? {
        if !p.onBattery || batteryStopPercent <= 0 {
            batteryLatched = false
        } else if let pct = p.percent, pct < batteryStopPercent {
            batteryLatched = true
        }
        return Self.pauseReason(for: p, stopPercent: batteryStopPercent, onlyPluggedIn: onlyWhenPluggedIn,
                                respectLowPowerMode: pauseInLowPowerMode, latched: batteryLatched)
    }

    /// The safeguard rule on its own, with no state: which safeguard (if any) blocks keeping awake.
    /// Plugged in, nothing blocks. On battery, a low charge (or the latch) comes first, then
    /// "only when plugged in", then Low Power Mode.
    nonisolated static func pauseReason(for p: PowerState, stopPercent: Int, onlyPluggedIn: Bool,
                                        respectLowPowerMode: Bool, latched: Bool) -> PauseReason? {
        guard p.onBattery else { return nil }
        if stopPercent > 0, latched || (p.percent.map { $0 < stopPercent } ?? false) {
            return .batteryLow(p.percent)
        }
        if onlyPluggedIn { return .onBattery }
        if respectLowPowerMode && p.lowPowerMode { return .lowPowerMode }
        return nil
    }

    /// The next check-in time on a fixed clock grid (for 15 min: :00, :15, :30, :45), at least 2 minutes
    /// away. The grid keeps the value the same between 30 s refreshes, so the helper isn't asked to
    /// reschedule every time, and the 2 minutes give it time to act before the Mac sleeps.
    private func nextCheckIn(after now: Date) -> Date? {
        guard sleepCheckMinutes > 0 else { return nil }
        let step = Double(sleepCheckMinutes * 60)
        return Date(timeIntervalSince1970: ceil((now.timeIntervalSince1970 + 120) / step) * step)
    }

    // MARK: - Watched apps

    func addWatched(_ items: [WatchedItem]) {
        let new = items.filter { item in !watchedItems.contains { $0.kind == item.kind && $0.id == item.id } }
        if !new.isEmpty { watchedItems += new }
    }

    func removeWatched(_ item: WatchedItem) {
        watchedItems.removeAll { $0.kind == item.kind && $0.id == item.id }
    }

    func setRule(_ rule: WatchedItem.Rule, for item: WatchedItem) {
        guard let i = watchedItems.firstIndex(where: { $0.kind == item.kind && $0.id == item.id }) else { return }
        watchedItems[i].rule = rule
    }

    /// "claude is working", "claude and codex are working", "claude and 2 more are working".
    func watchedSummary(_ items: [WatchedItem]) -> String {
        guard let first = items.first else { return "a watched app is working" }
        let verb = items.contains { $0.rule == .working } ? "working" : "running"
        switch items.count {
        case 1: return "\(first.name) is \(verb)"
        case 2: return "\(first.name) and \(items[1].name) are \(verb)"
        default: return "\(first.name) and \(items.count - 1) more are \(verb)"
        }
    }

    /// "claude finished": shown while only the grace period keeps the Mac awake.
    var watchedFinishedLine: String? {
        guard let until = watchGraceUntil else { return nil }
        let who = recentWatched.first.map { recentWatched.count > 1 ? "\($0.name) and others" : $0.name } ?? "Watched app"
        return "\(who) finished · sleeping after \(timeFormatter.string(from: until))"
    }

    // MARK: - Wake helper

    func installWakeHelper() {
        guard !Self.isDemo else { return }   // a demo never changes the real helper
        wakeHelperBusy = true
        wakeHelperError = nil
        waker.install { [weak self] ok in
            guard let self else { return }
            self.wakeHelperBusy = false
            self.wakeHelperInstalled = self.waker.isHelperInstalled
            self.helpersNeedUpdate = self.waker.helperNeedsUpdate || self.lid.helperNeedsUpdate
            if !ok { self.wakeHelperError = "Setup didn't finish. Try again, or check Console for details." }
            self.refresh()
        }
    }

    func uninstallWakeHelper() {
        guard !Self.isDemo else { return }   // a demo never changes the real helper
        wakeHelperBusy = true
        waker.request(nil)
        wakeHelperError = nil
        waker.uninstall { [weak self] ok in
            guard let self else { return }
            self.wakeHelperBusy = false
            self.wakeHelperInstalled = self.waker.isHelperInstalled
            if !ok { self.wakeHelperError = "Couldn't remove the wake helper." }
            self.refresh()
        }
    }

    private func relevantEvents(around now: Date) -> [EKEvent] {
        let enabled = calendars.filter { !excludedCalendarIDs.contains($0.calendarIdentifier) }
        guard !enabled.isEmpty else { return [] }

        let predicate = store.predicateForEvents(
            withStart: now.addingTimeInterval(-24 * 3600),
            end: now.addingTimeInterval(7 * 24 * 3600),
            calendars: enabled
        )
        return store.events(matching: predicate)
            .filter(isRelevant)
            .sorted { $0.startDate < $1.startDate }
    }

    private func isRelevant(_ event: EKEvent) -> Bool {
        if event.status == .canceled { return false }
        if event.isAllDay && !includeAllDay { return false }
        if ignoreFreeEvents && event.availability == .free { return false }
        if let me = event.attendees?.first(where: { $0.isCurrentUser }),
           me.participantStatus == .declined {
            return false
        }
        return true
    }

    /// True while the event (with its buffers) is keeping the Mac awake.
    func isOngoing(_ event: EKEvent) -> Bool {
        window(for: event).contains(Date())
    }

    private func window(for event: EKEvent) -> DateInterval {
        let start = event.startDate.addingTimeInterval(-Double(leadMinutes) * 60)
        let end = max(start, event.endDate.addingTimeInterval(Double(trailMinutes) * 60))
        return DateInterval(start: start, end: end)
    }

    // MARK: - Launch at login

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            guard !Self.isDemo else { return }
            objectWillChange.send()
            do {
                if newValue { try SMAppService.mainApp.register() }
                else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("MacAwake: launch-at-login error: \(error)")
            }
        }
    }

    // MARK: - Menu text

    var menuBarSymbol: String {
        if pauseReason != nil { return "battery.25" }
        if heldAwake { return "cup.and.saucer.fill" }
        if mode == .off { return "moon.zzz" }
        if mode == .timed { return "hourglass" }
        return isAwake ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    /// Panel subtitle while only `macawake run` holds keep the Mac awake.
    var heldLine: String? {
        guard heldAwake else { return nil }
        return heldNames.count == 1 ? "While \(heldNames[0]) runs, then as before." : "While \(heldNames.count) commands run, then as before."
    }

    var statusLine: String {
        if let r = pauseReason { return "Paused — \(r.shortLabel)" }
        switch mode {
        case .off:
            return "Off — Mac sleeps normally"
        case .alwaysOn:
            return "Awake (manual override)"
        case .timed:
            guard let until = timedUntil else { return "Awake" }
            let left = max(0, Int(until.timeIntervalSinceNow / 60))
            let remaining = left >= 60 ? "\(left / 60)h \(left % 60)m" : "\(left)m"
            return "Awake for \(remaining) more · until \(timeFormatter.string(from: until))"
        case .auto:
            if let e = currentEvent, let until = awakeUntil {
                return "Awake — \(e.title ?? "Event") · until \(timeFormatter.string(from: until))"
            }
            if !activeWatched.isEmpty { return "Awake — \(watchedSummary(activeWatched))" }
            if let finished = watchedFinishedLine { return "Awake — \(finished)" }
            if !hasAccess { return "Needs calendar access" }
            return "Idle — no event right now"
        }
    }

    var nextLine: String? {
        guard mode == .auto, let e = nextEvent else { return nil }
        return "Next: \(e.title ?? "Event") · \(relativeFormatter.string(from: e.startDate))"
    }

    var wakeLine: String? {
        guard let w = scheduledWake else { return nil }
        return "Wakes Mac at \(relativeFormatter.string(from: w))"
    }
}

extension PauseReason {
    var shortLabel: String {
        switch self {
        case .batteryLow: return "battery low"
        case .onBattery: return "on battery"
        case .lowPowerMode: return "Low Power Mode"
        }
    }
}

// MARK: - Demo (screenshots)

/// Sample data for `--preview-panel --demo <state>`, so screenshots for the README show the same
/// made-up events on any Mac and never anyone's real calendar. States: `calendar` (default), `always`,
/// `timer`, `off`, and for single features `apps` (watched apps busy), `run` (a `macawake run` hold),
/// `lid` (lid-closed keep-awake on) and `battery` (paused for a low battery).
enum Demo {
    static let suite = "local.macawake.demo"

    static let choice: String = {
        let args = CommandLine.arguments
        return args.firstIndex(of: "--demo").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } ?? "calendar"
    }()

    /// Watched items shown in the `apps` state; the first one is busy.
    static let watched: [WatchedItem] = [.command("claude"), .command("codex"), .command("xcodebuild")]

    static func resetDefaults() {
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let mode: Mode = ["always": .alwaysOn, "timer": .timed, "off": .off, "run": .off][choice] ?? .auto
        d.set(mode.rawValue, forKey: "mode")
        if choice == "apps" {
            d.set(true, forKey: "watchAppsEnabled")
            d.set(try? JSONEncoder().encode(watched), forKey: "watchedItems")
        }
        if choice == "lid" { d.set(true, forKey: "lidClosedAwake") }
        if mode == .timed {
            let now = Date().timeIntervalSince1970
            d.set(now - 35 * 60, forKey: "timedStart")
            d.set(now + 85 * 60, forKey: "timedUntil")
        }
    }
}

extension AwakeController {
    fileprivate func startDemo() {
        hasAccess = true
        wakeHelperInstalled = true
        lidHelperInstalled = Demo.choice == "lid"
        if Demo.choice == "apps" { demoWorking = [Demo.watched[0]] }
        if Demo.choice == "run" { demoHeld = ["claude"] }
        if Demo.choice == "battery" { demoPower = PowerState(onBattery: true, percent: 8, hasBattery: true) }
        let work = demoCalendar("Work", red: 0.2, green: 0.5, blue: 1)
        let personal = demoCalendar("Personal", red: 0.95, green: 0.6, blue: 0.1)
        calendars = [personal, work]
        let now = Date()
        let hour = 3600.0
        demoEvents = [
            demoEvent("AI coding session", work, now.addingTimeInterval(-0.3 * hour), now.addingTimeInterval(0.7 * hour)),
            demoEvent("Team standup", work, now.addingTimeInterval(1.5 * hour), now.addingTimeInterval(1.75 * hour)),
            demoEvent("Record podcast", personal, now.addingTimeInterval(3 * hour), now.addingTimeInterval(4 * hour)),
            demoEvent("Overnight data import", work, now.addingTimeInterval(9 * hour), now.addingTimeInterval(12 * hour)),
        ]
        // Watched apps are what keeps the Mac awake in that state, not an event.
        if Demo.choice == "apps" { demoEvents.removeFirst() }
        refresh()
    }

    private func demoCalendar(_ title: String, red: CGFloat, green: CGFloat, blue: CGFloat) -> EKCalendar {
        let c = EKCalendar(for: .event, eventStore: store)
        c.title = title
        c.cgColor = CGColor(red: red, green: green, blue: blue, alpha: 1)
        return c
    }

    private func demoEvent(_ title: String, _ cal: EKCalendar, _ start: Date, _ end: Date) -> EKEvent {
        let e = EKEvent(eventStore: store)
        e.title = title
        e.calendar = cal
        e.startDate = start
        e.endDate = end
        return e
    }
}
