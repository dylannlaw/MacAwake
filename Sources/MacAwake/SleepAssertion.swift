import Foundation
import IOKit.pwr_mgt

/// The same power-management assertions `caffeinate -d -i` takes, without spawning a process.
/// macOS releases them automatically if the app quits or crashes.
final class SleepAssertion {
    private var systemID: IOPMAssertionID = 0
    private var displayID: IOPMAssertionID = 0
    private var activityID: IOPMAssertionID = 0
    private var checkInID: IOPMAssertionID = 0
    private var currentReason: String?
    private var displayOn = false

    var isActive: Bool { systemID != 0 }

    func enable(reason: String, keepDisplayOn: Bool) {
        // No-op if nothing changed, so the 30 s refresh doesn't churn assertions.
        if isActive && reason == currentReason && keepDisplayOn == displayOn { return }
        disable()

        let r = reason as CFString
        let on = IOPMAssertionLevel(kIOPMAssertionLevelOn)

        // Equivalent to `caffeinate -i`: stop idle system sleep.
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                    on, r, &systemID)
        // Equivalent to `caffeinate -d`: stop the display from sleeping.
        if keepDisplayOn {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        on, r, &displayID)
        }
        currentReason = reason
        displayOn = keepDisplayOn
    }

    /// Tells macOS the user is active: turns the display on and resets the idle timer.
    /// After a scheduled wake this turns a "dark wake" into a full one.
    func declareUserActivity(reason: String) {
        IOPMAssertionDeclareUserActivity(reason as CFString, kIOPMUserActiveLocal, &activityID)
    }

    /// Keeps a dark wake going for up to `seconds`, so the calendar can sync before the Mac sleeps again.
    /// `NetworkClientActive` is the public assertion macOS honours in a dark wake (on AC power; on battery
    /// it may be ignored). It turns itself off after the timeout, so nothing needs to release it.
    func holdForCheckIn(seconds: Int) {
        if checkInID != 0 { IOPMAssertionRelease(checkInID); checkInID = 0 }
        IOPMAssertionCreateWithDescription(kIOPMAssertNetworkClientActive as CFString,
                                           "MacAwake: checking the calendar" as CFString,
                                           nil, nil, nil,
                                           CFTimeInterval(seconds),
                                           kIOPMAssertionTimeoutActionRelease as CFString,
                                           &checkInID)
    }

    func disable() {
        if systemID != 0 { IOPMAssertionRelease(systemID); systemID = 0 }
        if displayID != 0 { IOPMAssertionRelease(displayID); displayID = 0 }
        currentReason = nil
    }

    deinit {
        disable()
        if checkInID != 0 { IOPMAssertionRelease(checkInID) }
    }
}
