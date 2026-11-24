import Darwin
import Foundation

/// Temporary "stay awake while this process runs" holds, added by `macawake://hold?pid=…`
/// (what `macawake run` sends). Held only in memory; they never change the mode.
@MainActor
final class ProcessHolds {
    static let maxHolds = 16
    static let maxAge: TimeInterval = 24 * 3600

    private struct Hold {
        let startSec: UInt64
        let startUsec: UInt64
        let name: String
        let added: Date
        let source: DispatchSourceProcess
    }

    private var holds: [pid_t: Hold] = [:]
    /// Called when a held process exits, so the controller can refresh straight away.
    var onChange: (() -> Void)?

    /// Adds a hold on `pid`. Refused when the process doesn't exist, belongs to another user,
    /// or there are already `maxHolds`.
    @discardableResult
    func add(pid: pid_t, now: Date = Date()) -> Bool {
        prune(now: now)
        guard let info = Self.info(pid), info.pbi_uid == getuid() else { return false }
        if holds[pid] != nil { return true }
        guard holds.count < Self.maxHolds else { return false }

        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.remove(pid: pid)
                self.onChange?()
            }
        }
        holds[pid] = Hold(startSec: info.pbi_start_tvsec, startUsec: info.pbi_start_tvusec,
                          name: Self.name(of: info), added: now, source: source)
        source.resume()
        return true
    }

    func remove(pid: pid_t) {
        holds.removeValue(forKey: pid)?.source.cancel()
    }

    /// Drops holds whose process has ended (or whose PID now belongs to a different process,
    /// detected by its start time) and holds older than `maxAge`.
    func prune(now: Date = Date()) {
        for (pid, h) in holds {
            let info = Self.info(pid)
            let same = info.map { $0.pbi_start_tvsec == h.startSec && $0.pbi_start_tvusec == h.startUsec } ?? false
            if !same || now.timeIntervalSince(h.added) > Self.maxAge { remove(pid: pid) }
        }
    }

    /// Names of the held processes, oldest hold first.
    var names: [String] {
        holds.values.sorted { $0.added < $1.added }.map(\.name)
    }

    var isEmpty: Bool { holds.isEmpty }

    private static func info(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func name(of info: proc_bsdinfo) -> String {
        // pbi_name is the longer name (up to 32 bytes), pbi_comm the short one; prefer the first.
        var i = info
        let longName = withUnsafeBytes(of: &i.pbi_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        if !longName.isEmpty { return longName }
        return withUnsafeBytes(of: &i.pbi_comm) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }
}
