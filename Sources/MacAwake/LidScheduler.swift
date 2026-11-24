import Foundation
import IOKit.ps

/// Keeps a MacBook awake with its lid closed, through a small root launchd helper (`lid-helper.sh`).
///
/// The app never asks for "on". It writes a *lease*: a Unix timestamp a few minutes ahead, which it
/// keeps renewing while it wants the lid hold. The helper turns `pmset disablesleep` on while the lease
/// is valid, and back off once it lapses. It also checks every 60 seconds and at boot, so a crash,
/// force-quit or restart always brings normal sleep back.
final class LidScheduler {
    static let label = "local.macawake.lidhelper"
    static let daemonPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist")
    static let helperPath = "/Library/PrivilegedHelperTools/\(label)"
    /// Written by the helper (root, mode 644) only while MacAwake itself turned `SleepDisabled` on.
    static let statePath = "/var/db/local.macawake.lidawake"
    static let logPath = "/var/log/macawake-lid.log"

    /// How long each lease lasts, and when to renew it. A crash is noticed within lease + 60 s.
    static let leaseSeconds: TimeInterval = 180
    static let renewBelow: TimeInterval = 120

    /// Its own folder, so lease writes don't wake the wake helper (which watches `MacAwake/`).
    let leaseDir: URL
    var leaseFile: URL { leaseDir.appendingPathComponent("lease") }

    /// A `--preview-panel` copy must not touch the lease: quitting it would release the running app's hold.
    private let readOnly = CommandLine.arguments.contains("--preview-panel")
    private var lastLease: Date??   // nil = never written this run; .some(nil) = last wrote "off"

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        leaseDir = support.appendingPathComponent("MacAwake/lid", isDirectory: true)
    }

    var isHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: Self.daemonPlist.path)
    }

    /// True while the helper reports that MacAwake has `SleepDisabled` on.
    var isHoldActive: Bool {
        (try? String(contentsOfFile: Self.statePath, encoding: .utf8))?.hasPrefix("1") ?? false
    }

    var helperNeedsUpdate: Bool {
        guard isHelperInstalled,
              let bundled = Bundle.main.path(forResource: "lid-helper", ofType: "sh"),
              let new = AdminShell.helperVersion(atPath: bundled),
              let old = AdminShell.helperVersion(atPath: Self.helperPath) else { return false }
        return old < new
    }

    /// Call on every refresh. Renews the lease while `on`, and clears it straight away when not.
    func request(_ on: Bool, now: Date = Date()) {
        guard !readOnly else { return }
        if on {
            if case .some(.some(let until)) = lastLease, until.timeIntervalSince(now) > Self.renewBelow { return }
            write(now.addingTimeInterval(Self.leaseSeconds))
        } else {
            if case .some(.none) = lastLease { return }
            write(nil)
        }
    }

    private func write(_ until: Date?) {
        do {
            try FileManager.default.createDirectory(at: leaseDir, withIntermediateDirectories: true)
            let body = until.map { "\(Int($0.timeIntervalSince1970))\n" } ?? ""
            try body.write(to: leaseFile, atomically: true, encoding: .utf8)
            lastLease = .some(until)
        } catch {
            NSLog("MacAwake: could not write lid lease: \(error)")
        }
    }

    // MARK: - Install / remove (one admin prompt each)

    func install(completion: @escaping (Bool) -> Void) {
        guard let helper = Bundle.main.url(forResource: "lid-helper", withExtension: "sh") else {
            NSLog("MacAwake: lid-helper.sh missing from the app bundle")
            return completion(false)
        }
        do {
            try FileManager.default.createDirectory(at: leaseDir, withIntermediateDirectories: true)
            try "".write(to: leaseFile, atomically: true, encoding: .utf8)
        } catch {
            NSLog("MacAwake: could not create \(leaseDir.path): \(error)")
            return completion(false)
        }

        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": ["/bin/sh", Self.helperPath, leaseFile.path, Self.statePath],
            "WatchPaths": [leaseDir.path],
            "StartInterval": 60,   // the watchdog: a lapsed lease is noticed even if nothing writes
            "RunAtLoad": true,     // and at boot, before anyone logs in
            "StandardOutPath": Self.logPath,
            "StandardErrorPath": Self.logPath,
        ]
        let tmpPlist = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.label).plist")
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: tmpPlist, options: .atomic)
        } catch {
            NSLog("MacAwake: could not write lid daemon plist: \(error)")
            return completion(false)
        }

        let q = AdminShell.q
        let dest = Self.daemonPlist.path
        let script = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 755 \(q(helper.path)) \(q(Self.helperPath))",
            "/usr/bin/install -o root -g wheel -m 644 \(q(tmpPlist.path)) \(q(dest))",
            "/bin/launchctl bootout system/\(Self.label) 2>/dev/null || true",
            "/bin/launchctl bootstrap system \(q(dest))",
        ].joined(separator: " && ")

        AdminShell.run(script, prompt: "MacAwake wants to install a small helper so your Mac can stay awake with the lid closed.") { ok in
            try? FileManager.default.removeItem(at: tmpPlist)
            if ok { self.lastLease = nil }   // make the next refresh rewrite the lease
            completion(ok)
        }
    }

    func uninstall(completion: @escaping (Bool) -> Void) {
        let q = AdminShell.q
        let script = [
            "/bin/launchctl bootout system/\(Self.label) 2>/dev/null || true",
            // Turn sleep back on, but only if MacAwake was the one that turned it off.
            "if [ -f \(q(Self.statePath)) ] && [ \"$(/usr/bin/head -c 1 \(q(Self.statePath)))\" = 1 ]; then " +
                "/usr/bin/pmset -a disablesleep 0; fi",
            "/bin/rm -f \(q(Self.daemonPlist.path)) \(q(Self.helperPath)) \(q(Self.statePath))",
        ].joined(separator: "; ")
        AdminShell.run(script, prompt: "MacAwake wants to remove its lid-closed helper.") { ok in
            if ok { self.lastLease = nil }
            completion(ok)
        }
    }
}

/// Minimal battery reading for the lid hold's safety floor.
///
/// Swap point: once the battery-safeguards change lands, `AwakeController.lidBatteryAllows()` should also
/// defer to its shared check, keeping this floor as a minimum.
struct LidBattery {
    var hasBattery: Bool
    var onBattery: Bool
    var percent: Int?

    static func current() -> LidBattery {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            return LidBattery(hasBattery: false, onBattery: false, percent: nil)
        }
        for source in list {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            let state = d[kIOPSPowerSourceStateKey] as? String
            var pct: Int?
            if let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 {
                pct = cur * 100 / max
            }
            return LidBattery(hasBattery: true, onBattery: state == kIOPSBatteryPowerValue, percent: pct)
        }
        return LidBattery(hasBattery: false, onBattery: false, percent: nil)
    }
}

/// Calls back whenever the power source or battery level changes.
final class PowerSourceWatcher {
    private var source: CFRunLoopSource?
    private let onChange: () -> Void

    init(onChange: @escaping () -> Void) {
        self.onChange = onChange
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        if let s = IOPSNotificationCreateRunLoopSource({ ctx in
            guard let ctx else { return }
            Unmanaged<PowerSourceWatcher>.fromOpaque(ctx).takeUnretainedValue().onChange()
        }, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), s, .commonModes)
            source = s
        }
    }

    deinit {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
    }
}
