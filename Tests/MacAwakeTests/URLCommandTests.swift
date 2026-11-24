import Testing
import Foundation
@testable import MacAwake

struct URLCommandTests {
    private func parse(_ s: String) -> URLCommand? { URLCommand.parse(URL(string: s)!) }

    @Test func simpleCommands() {
        #expect(parse("macawake://stop") == .stop)
        #expect(parse("macawake://always") == .setMode(.alwaysOn))
        #expect(parse("macawake://calendar") == .setMode(.auto))
        #expect(parse("macawake://off") == .setMode(.off))
        #expect(parse("MACAWAKE://STOP/") == .stop)
    }

    @Test func timerCommands() {
        #expect(parse("macawake://start?minutes=30") == .start(minutes: 30))
        #expect(parse("macawake://extend?minutes=5") == .extend(minutes: 5))
        #expect(parse("macawake://start?minutes=1440") == .start(minutes: 1440))
    }

    @Test func rejectsBadMinutes() {
        for bad in ["0", "1441", "-5", "abc", "", "１２", "00012", "1.5"] {
            #expect(parse("macawake://start?minutes=\(bad)") == nil, "\(bad)")
        }
        #expect(parse("macawake://start") == nil)
        #expect(parse("macawake://start?minutes=5&until=10:00") == nil)
        #expect(parse("macawake://extend") == nil)
    }

    @Test func holdAndRelease() {
        #expect(parse("macawake://hold?pid=123") == .hold(pid: 123))
        #expect(parse("macawake://release?pid=2") == .release(pid: 2))
        #expect(parse("macawake://hold?pid=1") == nil)
        #expect(parse("macawake://hold?pid=0") == nil)
        #expect(parse("macawake://hold?pid=12345678") == nil)
        #expect(parse("macawake://hold") == nil)
    }

    @Test func rejectsUntrustedShapes() {
        #expect(parse("https://stop") == nil)
        #expect(parse("macawake://unknown") == nil)
        #expect(parse("macawake://stop?x=1") == nil)
        #expect(parse("macawake://stop#frag") == nil)
        #expect(parse("macawake://user@stop") == nil)
        #expect(parse("macawake://stop:80") == nil)
        #expect(parse("macawake://stop/extra") == nil)
        #expect(parse("macawake://extend?minutes=5&minutes=6") == nil)
        #expect(parse("macawake://extend?minutes=5&other=1") == nil)
    }

    @Test func untilTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: 10, minute: 0))!
        #expect(URLCommand.minutesUntil("10:30", now: now, calendar: cal) == 30)
        #expect(URLCommand.minutesUntil("09:00", now: now, calendar: cal) == 23 * 60)  // tomorrow
        #expect(URLCommand.minutesUntil("24:00", now: now, calendar: cal) == nil)
        #expect(URLCommand.minutesUntil("10:60", now: now, calendar: cal) == nil)
        #expect(URLCommand.minutesUntil("9:00", now: now, calendar: cal) == nil)
        #expect(URLCommand.minutesUntil("10", now: now, calendar: cal) == nil)
        let url = URL(string: "macawake://start?until=11:00")!
        #expect(URLCommand.parse(url, now: now, calendar: cal) == .start(minutes: 60))
    }
}
