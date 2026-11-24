import AppKit

/// A `macawake://` command. Any web page or local process can open such a URL, so `parse` treats it
/// as untrusted: only known commands, only known parameters, digits only, and out-of-range values
/// are rejected (never clamped).
enum URLCommand: Equatable {
    case start(minutes: Int)
    case extend(minutes: Int)
    case stop
    case setMode(Mode)
    case hold(pid: pid_t)
    case release(pid: pid_t)

    /// Longest timer a URL may set: 24 h.
    static let maxMinutes = 1440

    static func parse(_ url: URL, now: Date = Date(), calendar: Calendar = .current) -> URLCommand? {
        guard let c = URLComponents(url: url, resolvingAgainstBaseURL: false),
              c.scheme?.lowercased() == "macawake",
              c.user == nil, c.password == nil, c.port == nil, c.fragment == nil,
              c.path.isEmpty || c.path == "/",
              let host = c.host?.lowercased()
        else { return nil }

        // Query items: no duplicates, no empty names. Each command checks which names it allows.
        var query: [String: String] = [:]
        for item in c.queryItems ?? [] {
            guard !item.name.isEmpty, query[item.name] == nil, let v = item.value else { return nil }
            query[item.name] = v
        }
        func only(_ allowed: Set<String>) -> Bool { Set(query.keys).isSubset(of: allowed) }

        switch host {
        case "start":
            guard only(["minutes", "until"]) else { return nil }
            if let m = query["minutes"] {
                guard query["until"] == nil, let n = minutes(m) else { return nil }
                return .start(minutes: n)
            }
            guard let u = query["until"], let n = minutesUntil(u, now: now, calendar: calendar) else { return nil }
            return .start(minutes: n)
        case "extend":
            guard only(["minutes"]), let m = query["minutes"], let n = minutes(m) else { return nil }
            return .extend(minutes: n)
        case "hold", "release":
            guard only(["pid"]), let p = query["pid"], let pid = pid(p) else { return nil }
            return host == "hold" ? .hold(pid: pid) : .release(pid: pid)
        case "stop", "always", "calendar", "off":
            guard query.isEmpty else { return nil }
            switch host {
            case "stop": return .stop
            case "always": return .setMode(.alwaysOn)
            case "calendar": return .setMode(.auto)
            default: return .setMode(.off)
            }
        default:
            return nil
        }
    }

    /// 1–4 ASCII digits, 1…1440.
    static func minutes(_ s: String) -> Int? {
        guard let n = digits(s, maxLength: 4), (1...maxMinutes).contains(n) else { return nil }
        return n
    }

    /// `HH:MM`, 24-hour local time. A time already passed today means tomorrow.
    static func minutesUntil(_ s: String, now: Date, calendar: Calendar) -> Int? {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let h = digits(String(parts[0]), maxLength: 2), h <= 23,
              let m = digits(String(parts[1]), maxLength: 2), m <= 59,
              let target = calendar.nextDate(after: now, matching: DateComponents(hour: h, minute: m, second: 0),
                                             matchingPolicy: .nextTime)
        else { return nil }
        let n = Int((target.timeIntervalSince(now) / 60).rounded(.up))
        return (1...maxMinutes).contains(n) ? n : nil
    }

    /// 1–7 ASCII digits, 2…9_999_999 (never launchd, pid 1).
    static func pid(_ s: String) -> pid_t? {
        guard let n = digits(s, maxLength: 7), n >= 2 else { return nil }
        return pid_t(n)
    }

    private static func digits(_ s: String, maxLength: Int) -> Int? {
        guard !s.isEmpty, s.count <= maxLength,
              s.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) })
        else { return nil }
        return Int(s)
    }
}

/// Receives `macawake://` URLs. SwiftUI owns the app's Apple-event URL handler (it replaces one
/// installed by hand), and with only a `MenuBarExtra` there's no view for `onOpenURL`, so URLs come in
/// through the delegate SwiftUI forwards to.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            guard url.absoluteString.utf8.count <= 256, let command = URLCommand.parse(url) else {
                // Long URLs are never valid commands.
                NSLog("MacAwake: ignored URL: %@", String(url.absoluteString.prefix(256)))
                continue
            }
            MainActor.assumeIsolated { AwakeController.shared.perform(command) }
        }
    }
}
