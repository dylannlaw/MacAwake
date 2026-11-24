import Foundation
import IOKit.pwr_mgt

/// Tells the app each time the Mac powers on from sleep, including "dark" wakes.
///
/// `NSWorkspace.didWakeNotification` only fires for a full wake (display on). A scheduled check-in
/// wake is usually a dark wake, so this listens to IOKit's system power messages instead.
final class SystemPower {
    private var rootPort: io_connect_t = 0
    private var notifyPort: IONotificationPortRef?
    private var notifier: io_object_t = 0
    private let onWake: () -> Void

    // IOMessage.h builds these with macros Swift can't import: iokit_common_msg(x) = 0xE0000000 | x.
    private static let canSystemSleep: natural_t = 0xE000_0270
    private static let systemWillSleep: natural_t = 0xE000_0280
    private static let systemHasPoweredOn: natural_t = 0xE000_0300

    init(onWake: @escaping () -> Void) {
        self.onWake = onWake
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        rootPort = IORegisterForSystemPower(refcon, &notifyPort, { refcon, _, messageType, argument in
            guard let refcon else { return }
            Unmanaged<SystemPower>.fromOpaque(refcon).takeUnretainedValue()
                .handle(messageType, argument)
        }, &notifier)
        if rootPort == 0 {
            NSLog("MacAwake: could not register for power notifications")
            return
        }
        if let notifyPort {
            CFRunLoopAddSource(CFRunLoopGetMain(),
                               IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue(),
                               .commonModes)
        }
    }

    private func handle(_ messageType: natural_t, _ argument: UnsafeMutableRawPointer?) {
        switch messageType {
        case Self.canSystemSleep, Self.systemWillSleep:
            // We never object to sleep; acknowledge straight away so sleep isn't delayed.
            IOAllowPowerChange(rootPort, Int(bitPattern: argument))
        case Self.systemHasPoweredOn:
            onWake()
        default:
            break
        }
    }

    deinit {
        if notifier != 0 { IODeregisterForSystemPower(&notifier) }
        if rootPort != 0 { IOServiceClose(rootPort) }
        if let notifyPort { IONotificationPortDestroy(notifyPort) }
    }
}
