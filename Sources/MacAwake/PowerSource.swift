import Foundation
import IOKit.ps

/// A snapshot of how the Mac is powered.
struct PowerState: Equatable {
    /// Running on battery or UPS, not on the power adapter.
    var onBattery = false
    /// Charge of the internal battery (else a UPS), 0–100. nil if there's none or it isn't reported.
    var percent: Int?
    /// An internal battery or a UPS is present, so the battery settings apply.
    var hasBattery = false
    var lowPowerMode = false
}

/// Why a battery safeguard is stopping MacAwake from keeping the Mac awake.
enum PauseReason: Equatable {
    case batteryLow(Int?)
    case onBattery
    case lowPowerMode
}

/// Reads `PowerState` and calls back whenever it changes (plug/unplug, charge level, Low Power Mode).
final class PowerSource {
    private let onChange: () -> Void
    private var runLoopSource: CFRunLoopSource?
    private var lpmObserver: NSObjectProtocol?
    /// Testing only: `MACAWAKE_FAKE_POWER=battery:8`, `battery:50,lpm`, `ac:5` or `none`.
    private let fake: PowerState? = PowerSource.parseFake(ProcessInfo.processInfo.environment["MACAWAKE_FAKE_POWER"])

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        if let src = IOPSNotificationCreateRunLoopSource({ context in PowerSource.deliver(context) }, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            runLoopSource = src
        }
        lpmObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.onChange() }
    }

    deinit {
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes) }
        if let lpmObserver { NotificationCenter.default.removeObserver(lpmObserver) }
    }

    /// Passes an IOKit callback on to the `PowerSource` it was registered for.
    static func deliver(_ context: UnsafeMutableRawPointer?) {
        guard let context else { return }
        Unmanaged<PowerSource>.fromOpaque(context).takeUnretainedValue().onChange()
    }

    func current() -> PowerState {
        if let fake { return fake }
        let lpm = ProcessInfo.processInfo.isLowPowerModeEnabled
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return PowerState(lowPowerMode: lpm) }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] ?? []
        let descriptions = list.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        return Self.state(providing: providing, descriptions: descriptions, lowPowerMode: lpm)
    }

    /// Builds the `PowerState` from what IOKit reports: the providing source and each source's description.
    static func state(providing: String?, descriptions: [[String: Any]], lowPowerMode: Bool) -> PowerState {
        var state = PowerState(lowPowerMode: lowPowerMode)
        if let providing { state.onBattery = providing != kIOPMACPowerKey }
        var battery: Int?, ups: Int?
        for d in descriptions {
            guard d[kIOPSIsPresentKey] as? Bool ?? true else { continue }
            let type = d[kIOPSTypeKey] as? String
            guard type == kIOPSInternalBatteryType || type == kIOPSUPSType else { continue }
            state.hasBattery = true
            var pct: Int?
            if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                pct = Int((Double(cur) / Double(max) * 100).rounded())
            }
            if type == kIOPSInternalBatteryType { battery = battery ?? pct } else { ups = ups ?? pct }
        }
        state.percent = battery ?? ups
        return state
    }

    static func parseFake(_ value: String?) -> PowerState? {
        guard let value, !value.isEmpty else { return nil }
        var s = PowerState()
        for part in value.lowercased().split(separator: ",") {
            let kv = part.split(separator: ":", maxSplits: 1)
            switch kv.first {
            case "battery": s.onBattery = true; s.hasBattery = true; s.percent = kv.count > 1 ? Int(kv[1]) : nil
            case "ac": s.onBattery = false; s.hasBattery = true; s.percent = kv.count > 1 ? Int(kv[1]) : nil
            case "none": s = PowerState()
            case "lpm": s.lowPowerMode = true
            default: break
            }
        }
        return s
    }
}

/// Debug: `MacAwake --self-test-battery` checks the safeguard rule against a table, prints the result
/// and exits (status 1 on any failure). Not reachable from the UI.
func runBatterySelfTest() -> Never {
    let result = batterySelfTest()
    result.lines.forEach { print($0) }
    exit(result.failed == 0 ? 0 : 1)
}

/// The self-test's table run, as text lines plus the number of failures.
func batterySelfTest() -> (lines: [String], failed: Int) {
    func s(_ fake: String) -> PowerState { PowerSource.parseFake(fake)! }
    let cases: [(String, PowerState, Int, Bool, Bool, Bool, PauseReason?)] = [
        // name, power, stop%, onlyPluggedIn, respectLPM, latched, expected
        ("AC at 5% never blocks", s("ac:5"), 10, true, true, true, nil),
        ("battery 9% < 10% → low", s("battery:9"), 10, false, false, false, .batteryLow(9)),
        ("battery 10% is not below 10%", s("battery:10"), 10, false, false, false, nil),
        ("latched at 12% stays low", s("battery:12"), 10, false, false, true, .batteryLow(12)),
        ("stop = never ignores latch", s("battery:5"), 0, false, false, true, nil),
        ("only plugged in, on battery", s("battery:80"), 10, true, false, false, .onBattery),
        ("low battery wins over unplugged", s("battery:5"), 10, true, false, false, .batteryLow(5)),
        ("LPM respected on battery", s("battery:50,lpm"), 10, false, true, false, .lowPowerMode),
        ("LPM ignored when not respected", s("battery:50,lpm"), 10, false, false, false, nil),
        ("LPM ignored on AC", s("ac:50,lpm"), 10, false, true, false, nil),
        ("no battery never blocks", s("none"), 50, true, true, false, nil),
        ("unknown percent: no level block", s("battery"), 10, false, false, false, nil),
    ]
    var failed = 0
    var lines: [String] = []
    for (name, p, stop, plugged, lpm, latched, want) in cases {
        let got = AwakeController.pauseReason(for: p, stopPercent: stop, onlyPluggedIn: plugged,
                                              respectLowPowerMode: lpm, latched: latched)
        let ok = got == want
        if !ok { failed += 1 }
        lines.append("\(ok ? "ok  " : "FAIL") \(name)\(ok ? "" : " — got \(String(describing: got))")")
    }

    // Device kind: which battery settings each kind of Mac gets.
    let devices: [(String, DeviceKind, DeviceKind)] = [
        ("Apple silicon MacBook Air", DeviceKind.classify(productName: "MacBook Air (M2, 2022)", model: "Mac14,2",
                                                          hasClamshell: false, hasInternalBattery: false), .laptop),
        ("Apple silicon Mac mini", DeviceKind.classify(productName: "Mac mini (M2)", model: "Mac14,3",
                                                       hasClamshell: false, hasInternalBattery: true), .desktop),
        ("Mac Studio", DeviceKind.classify(productName: "Mac Studio (2023)", model: "Mac14,13",
                                           hasClamshell: false, hasInternalBattery: false), .desktop),
        ("iMac", DeviceKind.classify(productName: "iMac (24-inch, M3)", model: "Mac15,4",
                                     hasClamshell: false, hasInternalBattery: false), .desktop),
        ("Intel MacBook Pro", DeviceKind.classify(productName: nil, model: "MacBookPro16,1",
                                                  hasClamshell: false, hasInternalBattery: false), .laptop),
        ("Intel Mac mini", DeviceKind.classify(productName: nil, model: "Macmini8,1",
                                               hasClamshell: true, hasInternalBattery: false), .desktop),
        ("unknown name, lid sensor", DeviceKind.classify(productName: nil, model: "Mac99,1",
                                                         hasClamshell: true, hasInternalBattery: false), .laptop),
        ("unknown name, battery", DeviceKind.classify(productName: nil, model: nil,
                                                      hasClamshell: false, hasInternalBattery: true), .laptop),
        ("unknown name, nothing", DeviceKind.classify(productName: nil, model: nil,
                                                      hasClamshell: false, hasInternalBattery: false), .desktop),
    ]
    let styles: [(String, BatterySettingsStyle?, BatterySettingsStyle?)] = [
        ("laptop, battery unreadable", .for(.laptop, power: s("none")), .battery),
        ("laptop on AC", .for(.laptop, power: s("ac:80")), .battery),
        ("desktop, no UPS", .for(.desktop, power: s("none")), nil),
        ("desktop with UPS", .for(.desktop, power: s("ac:100")), .ups),
    ]
    var total = cases.count
    for (name, got, want) in devices {
        total += 1
        let ok = got == want
        if !ok { failed += 1 }
        lines.append("\(ok ? "ok  " : "FAIL") device: \(name)\(ok ? "" : " — got \(got)")")
    }
    for (name, got, want) in styles {
        total += 1
        let ok = got == want
        if !ok { failed += 1 }
        lines.append("\(ok ? "ok  " : "FAIL") settings: \(name)\(ok ? "" : " — got \(String(describing: got))")")
    }
    lines.append("This Mac: \(DeviceKind.current.rawValue) (\(DeviceInfo.productName() ?? DeviceInfo.model() ?? "unknown"))")
    lines.append(failed == 0 ? "All \(total) passed." : "\(failed) of \(total) failed.")
    return (lines, failed)
}
