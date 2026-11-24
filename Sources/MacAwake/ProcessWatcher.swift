import AppKit
import Darwin

/// Something MacAwake can stay awake for: a GUI app (by bundle ID) or a command-line program (by name).
struct WatchedItem: Codable, Hashable, Identifiable {
    enum Kind: String, Codable { case app, command }
    /// `working`: only while it (or anything it started) uses CPU. `running`: whenever it's open.
    enum Rule: String, Codable, CaseIterable { case working, running }

    var kind: Kind
    /// Bundle ID for apps; lower-case executable name for commands.
    var id: String
    var name: String
    var rule: Rule

    static func command(_ name: String, rule: Rule = .working) -> WatchedItem {
        WatchedItem(kind: .command, id: name.lowercased(), name: name, rule: rule)
    }

    /// Command-line AI agents offered by Add › AI agents.
    static let aiAgentPresets = ["claude", "codex", "gemini", "aider", "cursor-agent", "opencode"].map { command($0) }

    /// A safe executable name from user input: the last path component, lower case, only `[a-z0-9._+-]`.
    static func cleanCommandName(_ raw: String) -> String? {
        let base = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).lastPathComponent.lowercased()
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789._+-")
        guard !base.isEmpty, base.count <= 64, base.unicodeScalars.allSatisfy(allowed.contains) else { return nil }
        return base
    }
}

/// Finds which watched items are active. Called from `AwakeController.refresh()`; it has no timer of its own.
///
/// Only the current user's processes are looked at. "Working" means the matched process plus all its
/// descendants (and children they've already reaped) used at least `busyThreshold` of one CPU core since
/// the previous sample.
final class ProcessWatcher {
    /// Fraction of one core that counts as working (1 %).
    var busyThreshold = 0.01
    /// Samples closer together than this reuse the last result; tiny intervals give noisy CPU figures.
    private let minSampleInterval: TimeInterval = 10
    /// A longer gap (sleep, a stalled run loop) means the old samples aren't comparable; start over.
    private let maxSampleGap: TimeInterval = 120

    private var cpuByPID: [pid_t: UInt64] = [:]
    private var lastSample: Date?
    private var lastCommandResult: Set<WatchedItem> = []
    private(set) var lastScanDuration: TimeInterval = 0

    private static let interpreters: Set<String> = ["node", "bun", "deno", "python", "ruby", "perl", "bash", "sh", "zsh"]
    private static let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(info.numer), UInt64(max(info.denom, 1)))
    }()

    func active(_ items: [WatchedItem], now: Date = Date()) -> [WatchedItem] {
        let apps = NSWorkspace.shared.runningApplications
        var appPIDs: [WatchedItem: [pid_t]] = [:]
        for item in items where item.kind == .app {
            let pids = apps.filter { $0.bundleIdentifier == item.id && !$0.isTerminated }.map(\.processIdentifier)
            if !pids.isEmpty { appPIDs[item] = pids }
        }

        // Apps that only need to be open don't need a process scan at all.
        let needsScan = items.contains { $0.kind == .command }
            || appPIDs.keys.contains { $0.rule == .working }
        var result = Set(appPIDs.keys.filter { $0.rule == .running })
        guard needsScan else { cpuByPID = [:]; lastSample = nil; return items.filter(result.contains) }

        if let last = lastSample, now.timeIntervalSince(last) < minSampleInterval {
            result.formUnion(lastCommandResult)
            return items.filter(result.contains)
        }

        let started = Date()
        let table = scan()
        let interval = lastSample.map { now.timeIntervalSince($0) }
        let baseline = interval.map { $0 <= maxSampleGap } ?? false
        var scanned: Set<WatchedItem> = []

        for item in items {
            let roots: [pid_t]
            switch item.kind {
            case .app: roots = appPIDs[item] ?? []
            case .command: roots = table.procs.filter { $0.value.names.contains(item.id) }.map(\.key)
            }
            guard !roots.isEmpty else { continue }
            if item.rule == .running { scanned.insert(item); continue }
            guard baseline, let dt = interval, dt > 0 else { continue }

            // CPU used since the last sample by the roots and everything below them.
            var used: UInt64 = 0
            var seen = Set<pid_t>()
            var stack = roots
            while let pid = stack.popLast() {
                guard seen.insert(pid).inserted, let p = table.procs[pid] else { continue }
                // A process we hadn't seen started since the last sample, so all its CPU is new.
                let before = cpuByPID[pid] ?? 0
                used += p.cpuNanos >= before ? p.cpuNanos - before : 0
                stack.append(contentsOf: table.children[pid] ?? [])
            }
            if Double(used) / 1e9 / dt >= busyThreshold { scanned.insert(item) }
        }

        cpuByPID = table.procs.mapValues(\.cpuNanos)
        lastSample = now
        lastCommandResult = scanned.filter { $0.kind == .command || $0.rule == .working }
        lastScanDuration = Date().timeIntervalSince(started)
        result.formUnion(scanned)
        return items.filter(result.contains)
    }

    // MARK: - Process table

    private struct Proc {
        var names: Set<String>
        var cpuNanos: UInt64
    }

    private func scan() -> (procs: [pid_t: Proc], children: [pid_t: [pid_t]]) {
        let uid = getuid()
        var capacity = Int(proc_listallpids(nil, 0)) + 64
        var pids = [pid_t](repeating: 0, count: max(capacity, 256))
        capacity = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        guard capacity > 0 else { return ([:], [:]) }

        var procs: [pid_t: Proc] = [:]
        var children: [pid_t: [pid_t]] = [:]
        for pid in pids.prefix(capacity) where pid > 0 {
            var info = proc_bsdshortinfo()
            let size = Int32(MemoryLayout<proc_bsdshortinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDT_SHORTBSDINFO, 0, &info, size) == size,
                  info.pbsi_uid == uid else { continue }

            let comm = withUnsafeBytes(of: info.pbsi_comm) { raw in
                String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
            }.lowercased()
            var names: Set<String> = [comm]
            // `p_comm` is cut at 16 characters; the executable path has the full name.
            if comm.count >= 15, let path = Self.path(of: pid) { names.insert(path) }
            // Scripts run by an interpreter (`node …/bin/codex.js`): match on what it runs.
            if Self.interpreters.contains(where: { comm.hasPrefix($0) }) {
                names.formUnion(Self.scriptNames(of: pid))
            }

            procs[pid] = Proc(names: names, cpuNanos: Self.cpuNanos(of: pid))
            children[pid_t(info.pbsi_ppid), default: []].append(pid)
        }
        return (procs, children)
    }

    private static func path(of pid: pid_t) -> String? {
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return nil }
        return (String(cString: buf) as NSString).lastPathComponent.lowercased()
    }

    /// User + system time of the process and of children it has reaped, in nanoseconds.
    private static func cpuNanos(of pid: pid_t) -> UInt64 {
        var usage = rusage_info_v2()
        let ok = withUnsafeMutablePointer(to: &usage) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) == 0
            }
        }
        guard ok else { return 0 }
        // These are Mach time units (not nanoseconds on Apple silicon).
        let ticks = usage.ri_user_time &+ usage.ri_system_time &+ usage.ri_child_user_time &+ usage.ri_child_system_time
        return ticks.multipliedReportingOverflow(by: timebase.numer).partialValue / timebase.denom
    }

    /// The base names (without extension) of `argv[0]` and the first non-option argument.
    private static func scriptNames(of pid: pid_t) -> Set<String> {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
        var buf = [UInt8](repeating: 0, count: min(size, 256 * 1024))
        size = buf.count
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0, size > 4 else { return [] }

        // Layout: argc (Int32), executable path, NUL padding, then argv[0...argc-1].
        let argc = Int(buf.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var parts: [String] = []
        var i = 4
        while i < size && buf[i] != 0 { i += 1 }        // executable path
        while i < size && buf[i] == 0 { i += 1 }        // padding
        while i < size && parts.count < min(argc, 8) {
            let start = i
            while i < size && buf[i] != 0 { i += 1 }
            parts.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        guard let first = parts.first else { return [] }
        var names: Set<String> = [baseName(first)]
        if let script = parts.dropFirst().first(where: { !$0.hasPrefix("-") }) { names.insert(baseName(script)) }
        return names
    }

    private static func baseName(_ s: String) -> String {
        let last = (s as NSString).lastPathComponent
        let ext = (last as NSString).pathExtension
        let stem = ["js", "mjs", "cjs", "ts", "py"].contains(ext) ? (last as NSString).deletingPathExtension : last
        return stem.lowercased()
    }
}
