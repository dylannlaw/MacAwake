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
    @Published private(set) var wakeHelperBusy = false
    /// Shown in the panel when setting up or removing the helper didn't work.
    @Published private(set) var wakeHelperError: String?

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
    private let watcher = ProcessWatcher()
    private var lastWatchedActivity: Date?
    private var timer: Timer?
    private var expiryTimer: Timer?
    private var power: SystemPower?
    private var checkInTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// Opts out of App Nap, which could otherwise delay the 30 s check by minutes and start events late.
    /// Idle system sleep stays allowed; the power assertions decide that.
    private var noNap: NSObjectProtocol?
    /// Sample events shown instead of the calendar's in a demo.
    private var demoEvents: [EKEvent] = []

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
        watchAppsEnabled = defaults.object(forKey: "watchAppsEnabled") as? Bool ?? false
        watchedItems = defaults.data(forKey: "watchedItems")
            .flatMap { try? JSONDecoder().decode([WatchedItem].self, from: $0) } ?? []
        watchGraceMinutes = defaults.object(forKey: "watchGraceMinutes") as? Int ?? 5
        wakeHelperInstalled = waker.isHelperInstalled

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

        // Quitting — don't leave a wake behind that nothing will act on.
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.waker.request(nil) }
        })
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
        let working = watching ? watcher.active(watchedItems, now: now) : []
        if !working.isEmpty {
            lastWatchedActivity = now
            if recentWatched != working { recentWatched = working }
        }
        if !watching { lastWatchedActivity = nil }
        let graceEnd = lastWatchedActivity.map { $0.addingTimeInterval(Double(watchGraceMinutes) * 60) }
        let watchedAwake = graceEnd.map { now < $0 } ?? false
        if activeWatched != working { activeWatched = working }
        watchGraceUntil = (watchedAwake && working.isEmpty) ? graceEnd : nil

        let shouldBeAwake: Bool
        let reason: String
        switch mode {
        case .auto:
            shouldBeAwake = latest != nil || watchedAwake
            reason = latest != nil
                ? "Calendar event: \(latest?.title ?? "")"
                : working.isEmpty
                    ? "MacAwake: \(recentWatched.first?.name ?? "watched app") finished, staying awake briefly"
                    : "MacAwake: \(watchedSummary(working))"
        case .alwaysOn:
            shouldBeAwake = true
            reason = "MacAwake: always awake"
        case .timed:
            shouldBeAwake = true
            reason = "MacAwake: awake until \(timeFormatter.string(from: timedUntil ?? now))"
        case .off:
            shouldBeAwake = false
            reason = ""
        }

        if Self.isDemo {
            isAwake = shouldBeAwake
            scheduledWake = mode == .auto ? upcoming.map { window(for: $0).start } : nil
            return
        }

        if shouldBeAwake {
            // An event just started. If the Mac only half-woke for it (a scheduled "dark" wake),
            // count it as user activity so the display comes on and the Mac doesn't drop back to sleep.
            // Only events do this: a watched app must never light the screen in a check-in dark wake.
            if !isAwake && mode == .auto && latest != nil { assertion.declareUserActivity(reason: reason) }
            assertion.enable(reason: reason, keepDisplayOn: keepDisplayOn)
        } else {
            assertion.disable()
        }
        isAwake = shouldBeAwake

        // Schedule a hardware wake for the next event, in case the Mac is asleep by then.
        let installed = waker.isHelperInstalled
        if installed != wakeHelperInstalled { wakeHelperInstalled = installed }
        let wakes = mode == .auto && wakeForEvents && wakeHelperInstalled
        let wake = wakes ? upcoming.map { window(for: $0).start } : nil
        // Also wake regularly to look for events added while asleep, if that comes sooner.
        let checkIn = (wakes && hasAccess) ? nextCheckIn(after: now) : nil
        waker.request([wake, checkIn].compactMap { $0 }.min())
        scheduledWake = wake
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
        if mode == .off { return "moon.zzz" }
        if mode == .timed { return "hourglass" }
        return isAwake ? "cup.and.saucer.fill" : "cup.and.saucer"
    }

    var statusLine: String {
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

// MARK: - Demo (screenshots)

/// Sample data for `--preview-panel --demo [calendar|always|timer|off]`, so screenshots for the README
/// show the same made-up events on any Mac and never anyone's real calendar.
enum Demo {
    static let suite = "local.macawake.demo"

    static func resetDefaults() {
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        let args = CommandLine.arguments
        let choice = args.firstIndex(of: "--demo").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        let mode: Mode = ["always": .alwaysOn, "timer": .timed, "off": .off][choice ?? ""] ?? .auto
        d.set(mode.rawValue, forKey: "mode")
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
