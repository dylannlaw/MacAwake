import XCTest
@testable import MacAwake

final class URLCommandTests: XCTestCase {
    private func parse(_ s: String, now: Date = Date(), calendar: Calendar = .current) -> URLCommand? {
        URLCommand.parse(URL(string: s)!, now: now, calendar: calendar)
    }

    func testSimpleCommands() {
        XCTAssertEqual(parse("macawake://stop"), .stop)
        XCTAssertEqual(parse("macawake://always"), .setMode(.alwaysOn))
        XCTAssertEqual(parse("macawake://calendar"), .setMode(.auto))
        XCTAssertEqual(parse("macawake://off"), .setMode(.off))
        XCTAssertEqual(parse("MACAWAKE://STOP/"), .stop)
    }

    func testSimpleCommandsRejectParameters() {
        XCTAssertNil(parse("macawake://stop?x=1"))
        XCTAssertNil(parse("macawake://off?minutes=5"))
    }

    func testStartMinutes() {
        XCTAssertEqual(parse("macawake://start?minutes=30"), .start(minutes: 30))
        XCTAssertEqual(parse("macawake://start?minutes=1440"), .start(minutes: 1440))
        XCTAssertNil(parse("macawake://start?minutes=0"))
        XCTAssertNil(parse("macawake://start?minutes=1441"))
        XCTAssertNil(parse("macawake://start?minutes=-5"))
        XCTAssertNil(parse("macawake://start?minutes=1e3"))
        XCTAssertNil(parse("macawake://start?minutes=12345"))
        XCTAssertNil(parse("macawake://start?minutes="))
        XCTAssertNil(parse("macawake://start?minutes=5&until=10:00"))
        XCTAssertNil(parse("macawake://start"))
        XCTAssertNil(parse("macawake://start?foo=1"))
    }

    func testStartUntil() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 10, minute: 0))!
        XCTAssertEqual(parse("macawake://start?until=11:30", now: now, calendar: cal), .start(minutes: 90))
        // Already passed today: tomorrow.
        XCTAssertEqual(parse("macawake://start?until=09:00", now: now, calendar: cal), .start(minutes: 23 * 60))
        XCTAssertNil(parse("macawake://start?until=25:00", now: now, calendar: cal))
        XCTAssertNil(parse("macawake://start?until=10:60", now: now, calendar: cal))
        XCTAssertNil(parse("macawake://start?until=9:00", now: now, calendar: cal))
        XCTAssertNil(parse("macawake://start?until=0900", now: now, calendar: cal))
        XCTAssertNil(parse("macawake://start?until=ab:cd", now: now, calendar: cal))
        XCTAssertNil(parse("macawake://start?until=10:00:00", now: now, calendar: cal))
    }

    func testMinutesUntilNextDay() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 1, day: 5, hour: 10, minute: 0))!
        // Exactly now means the next occurrence, a day later: 1440 min is still allowed.
        XCTAssertEqual(URLCommand.minutesUntil("10:00", now: now, calendar: cal), 1440)
    }

    func testExtend() {
        XCTAssertEqual(parse("macawake://extend?minutes=15"), .extend(minutes: 15))
        XCTAssertNil(parse("macawake://extend"))
        XCTAssertNil(parse("macawake://extend?minutes=0"))
        XCTAssertNil(parse("macawake://extend?until=10:00"))
    }

    func testHoldAndRelease() {
        XCTAssertEqual(parse("macawake://hold?pid=123"), .hold(pid: 123))
        XCTAssertEqual(parse("macawake://release?pid=9999999"), .release(pid: 9_999_999))
        XCTAssertNil(parse("macawake://hold?pid=1"))
        XCTAssertNil(parse("macawake://hold?pid=0"))
        XCTAssertNil(parse("macawake://hold?pid=12345678"))
        XCTAssertNil(parse("macawake://hold?pid=abc"))
        XCTAssertNil(parse("macawake://hold"))
        XCTAssertNil(parse("macawake://hold?pid=5&x=1"))
    }

    func testRejectsMalformedURLs() {
        XCTAssertNil(parse("https://stop"))
        XCTAssertNil(parse("macawake://unknown"))
        XCTAssertNil(parse("macawake://user@stop"))
        XCTAssertNil(parse("macawake://user:pw@stop"))
        XCTAssertNil(parse("macawake://stop:80"))
        XCTAssertNil(parse("macawake://stop#frag"))
        XCTAssertNil(parse("macawake://stop/extra"))
        XCTAssertNil(parse("macawake:stop"))
        XCTAssertNil(parse("macawake://start?minutes=5&minutes=6"))
        XCTAssertNil(parse("macawake://start?=5"))
        XCTAssertNil(parse("macawake://start?minutes"))
    }

    func testHelpers() {
        XCTAssertEqual(URLCommand.minutes("60"), 60)
        XCTAssertNil(URLCommand.minutes("٣"))   // non-ASCII digit
        XCTAssertEqual(URLCommand.pid("2"), 2)
        XCTAssertNil(URLCommand.pid(""))
    }

    @MainActor
    func testDelegateIgnoresBadURLs() {
        // Valid commands would go to the real shared controller, which a test must never start; bad ones
        // are dropped before they get there.
        let tooLong = URL(string: "macawake://start?minutes=5&" + String(repeating: "a", count: 300) + "=1")!
        AppDelegate().application(NSApplication.shared, open: [URL(string: "macawake://bogus")!, tooLong])
    }
}
