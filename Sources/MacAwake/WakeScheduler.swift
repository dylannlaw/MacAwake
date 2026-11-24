import Foundation

/// Schedules a hardware wake for the next calendar event, so a sleeping Mac comes back in time.
///
/// Only root can schedule wakes, so this works with a small launchd daemon (installed once, with an
/// admin prompt). The app writes the next wake time, as a Unix timestamp, to a file in Application
/// Support. The daemon watches that folder and calls `pmset schedule wake` for it.
final class WakeScheduler {
    static let label = "local.macawake.wakehelper"
    static let daemonPlist = URL(fileURLWithPath: "/Library/LaunchDaemons/\(label).plist")
    static let helperPath = "/Library/PrivilegedHelperTools/\(label)"
    static let statePath = "/var/db/local.macawake.lastwake"

    let requestDir: URL
    let daemonPlist: URL
    let helperPath: String
    private let bundle: Bundle
    var requestFile: URL { requestDir.appendingPathComponent("next-wake") }

    private var lastWritten: Date??   // nil = never written this run

    /// The parameters exist so tests can point everything at a scratch folder.
    init(requestDir: URL? = nil, daemonPlist: URL = WakeScheduler.daemonPlist,
         helperPath: String = WakeScheduler.helperPath, bundle: Bundle = .main) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        self.requestDir = requestDir ?? support.appendingPathComponent("MacAwake", isDirectory: true)
        self.daemonPlist = daemonPlist
        self.helperPath = helperPath
        self.bundle = bundle
    }

    var isHelperInstalled: Bool {
        FileManager.default.fileExists(atPath: daemonPlist.path)
    }

    /// Ask for a wake at `date`, or clear it with nil. Writes only when the value changes.
    func request(_ date: Date?) {
        // Round up to a whole second and add a little slack, so the Mac wakes just inside the window
        // and the app sees the event as active straight away.
        let target = date.map { Date(timeIntervalSince1970: ceil($0.timeIntervalSince1970) + 5) }
        if let last = lastWritten, last == target { return }

        do {
            try FileManager.default.createDirectory(at: requestDir, withIntermediateDirectories: true)
            let body = target.map { "\(Int($0.timeIntervalSince1970))\n" } ?? ""
            try body.write(to: requestFile, atomically: true, encoding: .utf8)
            lastWritten = .some(target)
        } catch {
            NSLog("MacAwake: could not write wake request: \(error)")
        }
    }

    // MARK: - Install / remove (one admin prompt each)

    func install(completion: @escaping (Bool) -> Void) {
        guard let helper = bundle.url(forResource: "wake-helper", withExtension: "sh") else {
            NSLog("MacAwake: wake-helper.sh missing from the app bundle")
            completion(false)
            return
        }
        do {
            try FileManager.default.createDirectory(at: requestDir, withIntermediateDirectories: true)
        } catch {
            NSLog("MacAwake: could not create \(requestDir.path): \(error)")
            completion(false)
            return
        }

        let plist: [String: Any] = [
            "Label": Self.label,
            "ProgramArguments": ["/bin/sh", helperPath, requestFile.path, Self.statePath],
            "WatchPaths": [requestDir.path],
            "RunAtLoad": true,
            "StandardOutPath": "/var/log/macawake-wake.log",
            "StandardErrorPath": "/var/log/macawake-wake.log",
        ]
        let tmpPlist = FileManager.default.temporaryDirectory.appendingPathComponent("\(Self.label).plist")
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: tmpPlist, options: .atomic)
        } catch {
            NSLog("MacAwake: could not write daemon plist: \(error)")
            completion(false)
            return
        }

        let dest = daemonPlist.path
        let script = [
            "/bin/mkdir -p /Library/PrivilegedHelperTools",
            "/usr/bin/install -o root -g wheel -m 755 \(q(helper.path)) \(q(helperPath))",
            "/usr/bin/install -o root -g wheel -m 644 \(q(tmpPlist.path)) \(q(dest))",
            "/bin/launchctl bootout system/\(Self.label) 2>/dev/null || true",
            "/bin/launchctl bootstrap system \(q(dest))",
        ].joined(separator: " && ")

        runAsAdmin(script, prompt: "MacAwake wants to install a small helper so it can wake your Mac for calendar events.") { ok in
            try? FileManager.default.removeItem(at: tmpPlist)
            if ok { self.lastWritten = nil }   // make the next refresh rewrite the request
            completion(ok)
        }
    }

    func uninstall(completion: @escaping (Bool) -> Void) {
        let script = [
            "/bin/launchctl bootout system/\(Self.label) 2>/dev/null || true",
            // Cancel the wake we last scheduled, if any.
            "if [ -f \(q(Self.statePath)) ]; then t=$(/bin/cat \(q(Self.statePath)) | /usr/bin/tr -cd 0-9); " +
                "[ -n \"$t\" ] && /usr/bin/pmset schedule cancel wake \"$(/bin/date -r $t '+%m/%d/%y %H:%M:%S')\" MacAwake; true; fi",
            "/bin/rm -f \(q(daemonPlist.path)) \(q(helperPath)) \(q(Self.statePath))",
        ].joined(separator: "; ")
        runAsAdmin(script, prompt: "MacAwake wants to remove its wake helper.", completion: completion)
    }

    private func runAsAdmin(_ command: String, prompt: String, completion: @escaping (Bool) -> Void) {
        AdminShell.run(command, prompt: prompt, completion: completion)
    }

    private func q(_ s: String) -> String { AdminShell.q(s) }

    /// True when the installed root copy is older than the one in this app.
    var helperNeedsUpdate: Bool {
        guard isHelperInstalled,
              let bundled = bundle.path(forResource: "wake-helper", ofType: "sh"),
              let new = AdminShell.helperVersion(atPath: bundled),
              let old = AdminShell.helperVersion(atPath: helperPath) else { return false }
        return old < new
    }
}
