import Foundation
import IOKit

/// What kind of Mac this is. Decides which battery and lid settings the panel offers.
enum DeviceKind: String, Equatable {
    /// MacBook, MacBook Air, MacBook Pro: a built-in battery and a lid.
    case laptop
    /// Mac mini, Mac Studio, iMac, Mac Pro: no battery and no lid (a UPS may still be attached).
    case desktop

    /// Read once at launch; the hardware doesn't change while the app runs.
    /// Testing only: `MACAWAKE_FAKE_DEVICE=laptop|desktop` overrides it. A demo defaults to `laptop`,
    /// so screenshots show every setting.
    static let current: DeviceKind = {
        let env = ProcessInfo.processInfo.environment["MACAWAKE_FAKE_DEVICE"]?.lowercased()
        if let env, let fake = DeviceKind(rawValue: env) { return fake }
        let args = CommandLine.arguments   // same test as AwakeController.isDemo, which is main-actor only
        if args.contains("--preview-panel") && args.contains("--demo") { return .laptop }
        return classify(productName: DeviceInfo.productName(), model: DeviceInfo.model(),
                        hasClamshell: DeviceInfo.hasClamshell(),
                        hasInternalBattery: LidBattery.current().hasBattery)
    }()

    /// The pure rule, checked by `--self-test-battery`.
    /// 1. The marketing name ("MacBook Pro (14-inch, 2023)", "Mac mini (M2)"), from the device tree on Apple silicon.
    /// 2. The model identifier on Intel ("MacBookPro16,1", "Macmini8,1", "iMac20,1", "MacPro7,1").
    ///    Apple silicon models are just "Mac14,2", which says nothing, so this only settles Intel Macs.
    /// 3. Hardware: a lid sensor (`AppleClamshellState`) or a built-in battery means a laptop.
    static func classify(productName: String?, model: String?, hasClamshell: Bool, hasInternalBattery: Bool) -> DeviceKind {
        for name in [productName, model].compactMap({ $0?.lowercased() }) {
            if name.hasPrefix("macbook") { return .laptop }
            if ["mac mini", "macmini", "mac studio", "imac", "mac pro", "macpro"].contains(where: name.hasPrefix) {
                return .desktop
            }
        }
        return hasClamshell || hasInternalBattery ? .laptop : .desktop
    }

    var isLaptop: Bool { self == .laptop }
}

/// Which battery settings to offer, given the kind of Mac and what's plugged in.
enum BatterySettingsStyle: Equatable {
    /// A MacBook: always shown, even if the battery can't be read right now.
    case battery
    /// A desktop on a UPS that macOS can see: the same rules, worded for a UPS.
    case ups

    static func `for`(_ kind: DeviceKind, power: PowerState) -> BatterySettingsStyle? {
        switch kind {
        case .laptop: return .battery
        case .desktop: return power.hasBattery ? .ups : nil
        }
    }
}

/// Small IOKit / sysctl readers behind `DeviceKind.current`. Each returns nil/false when it can't tell.
enum DeviceInfo {
    /// "MacBook Air (M2, 2022)" on Apple silicon. Not set on Intel Macs.
    static func productName() -> String? {
        let entry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product")
        guard entry != MACH_PORT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        guard let data = IORegistryEntryCreateCFProperty(entry, "product-name" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? Data else { return nil }
        let name = String(decoding: data.prefix { $0 != 0 }, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    /// `hw.model`, for example "MacBookPro16,1" or "Mac14,2".
    static func model() -> String? {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    /// Only Macs with a lid report a clamshell state.
    static func hasClamshell() -> Bool {
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != MACH_PORT_NULL else { return false }
        defer { IOObjectRelease(root) }
        return IORegistryEntryCreateCFProperty(root, "AppleClamshellState" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() != nil
    }
}
