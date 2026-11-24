import XCTest
@testable import MacAwake

final class PowerTests: XCTestCase {
    func testParseFake() {
        XCTAssertNil(PowerSource.parseFake(nil))
        XCTAssertNil(PowerSource.parseFake(""))
        XCTAssertEqual(PowerSource.parseFake("battery:8"), PowerState(onBattery: true, percent: 8, hasBattery: true))
        XCTAssertEqual(PowerSource.parseFake("BATTERY:50,lpm"),
                       PowerState(onBattery: true, percent: 50, hasBattery: true, lowPowerMode: true))
        XCTAssertEqual(PowerSource.parseFake("ac:5"), PowerState(onBattery: false, percent: 5, hasBattery: true))
        XCTAssertEqual(PowerSource.parseFake("battery"), PowerState(onBattery: true, percent: nil, hasBattery: true))
        XCTAssertEqual(PowerSource.parseFake("ac"), PowerState(onBattery: false, percent: nil, hasBattery: true))
        XCTAssertEqual(PowerSource.parseFake("battery:9,none"), PowerState())
        XCTAssertEqual(PowerSource.parseFake("wat"), PowerState())
    }

    func testPauseReasonTable() {
        func reason(_ fake: String, stop: Int = 10, plugged: Bool = false, lpm: Bool = false, latched: Bool = false) -> PauseReason? {
            AwakeController.pauseReason(for: PowerSource.parseFake(fake)!, stopPercent: stop, onlyPluggedIn: plugged,
                                        respectLowPowerMode: lpm, latched: latched)
        }
        XCTAssertNil(reason("ac:5", plugged: true, lpm: true, latched: true))
        XCTAssertEqual(reason("battery:9"), .batteryLow(9))
        XCTAssertNil(reason("battery:10"))
        XCTAssertEqual(reason("battery:12", latched: true), .batteryLow(12))
        XCTAssertNil(reason("battery:5", stop: 0, latched: true))
        XCTAssertEqual(reason("battery:80", plugged: true), .onBattery)
        XCTAssertEqual(reason("battery:5", plugged: true), .batteryLow(5))
        XCTAssertEqual(reason("battery:50,lpm", lpm: true), .lowPowerMode)
        XCTAssertNil(reason("battery:50,lpm"))
        XCTAssertNil(reason("ac:50,lpm", lpm: true))
        XCTAssertNil(reason("none", plugged: true, lpm: true))
        XCTAssertNil(reason("battery"))
    }

    func testShortLabels() {
        XCTAssertEqual(PauseReason.batteryLow(3).shortLabel, "battery low")
        XCTAssertEqual(PauseReason.onBattery.shortLabel, "on battery")
        XCTAssertEqual(PauseReason.lowPowerMode.shortLabel, "Low Power Mode")
    }

    func testSelfTestTablePasses() {
        let r = batterySelfTest()
        XCTAssertEqual(r.failed, 0)
        XCTAssertEqual(r.lines.last, "All 12 passed.")
        XCTAssertTrue(r.lines.dropLast().allSatisfy { $0.hasPrefix("ok") })
    }

    func testPowerSourceReadsAndNotifies() {
        let source = PowerSource {}
        let s = source.current()
        if s.hasBattery { XCTAssertNotNil(s.percent) }
        // Low Power Mode changes call back.
        let called = expectation(description: "changed")
        let watched = PowerSource { called.fulfill() }
        NotificationCenter.default.post(name: .NSProcessInfoPowerStateDidChange, object: nil)
        wait(for: [called], timeout: 2)
        _ = watched
    }

    func testPowerSourceUsesFakeFromEnvironment() {
        setenv("MACAWAKE_FAKE_POWER", "battery:42,lpm", 1)
        defer { unsetenv("MACAWAKE_FAKE_POWER") }
        let source = PowerSource {}
        XCTAssertEqual(source.current(), PowerState(onBattery: true, percent: 42, hasBattery: true, lowPowerMode: true))
    }

    func testLidBatteryAndWatcher() {
        let b = LidBattery.current()
        if !b.hasBattery { XCTAssertNil(b.percent) }
        var w: PowerSourceWatcher? = PowerSourceWatcher {}
        XCTAssertNotNil(w)
        w = nil
    }
}
