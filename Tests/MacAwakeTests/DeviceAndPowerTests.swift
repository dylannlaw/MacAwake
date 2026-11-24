import Testing
import Foundation
@testable import MacAwake

struct DeviceAndPowerTests {
    @Test func classifyByName() {
        #expect(DeviceKind.classify(productName: "MacBook Air (M2, 2022)", model: nil, hasClamshell: false, hasInternalBattery: false) == .laptop)
        #expect(DeviceKind.classify(productName: "Mac mini (M2)", model: nil, hasClamshell: true, hasInternalBattery: true) == .desktop)
        #expect(DeviceKind.classify(productName: nil, model: "MacBookPro16,1", hasClamshell: false, hasInternalBattery: false) == .laptop)
        #expect(DeviceKind.classify(productName: nil, model: "iMac20,1", hasClamshell: false, hasInternalBattery: true) == .desktop)
        #expect(DeviceKind.classify(productName: nil, model: "MacPro7,1", hasClamshell: false, hasInternalBattery: false) == .desktop)
    }

    @Test func classifyByHardware() {
        #expect(DeviceKind.classify(productName: nil, model: "Mac14,2", hasClamshell: true, hasInternalBattery: false) == .laptop)
        #expect(DeviceKind.classify(productName: nil, model: "Mac14,2", hasClamshell: false, hasInternalBattery: true) == .laptop)
        #expect(DeviceKind.classify(productName: nil, model: nil, hasClamshell: false, hasInternalBattery: false) == .desktop)
        #expect(DeviceKind.laptop.isLaptop)
        #expect(!(DeviceKind.desktop.isLaptop))
    }

    @Test func batterySettingsStyle() {
        #expect(BatterySettingsStyle.for(.laptop, power: PowerState()) == .battery)
        #expect(BatterySettingsStyle.for(.desktop, power: PowerState(hasBattery: true)) == .ups)
        #expect(BatterySettingsStyle.for(.desktop, power: PowerState()) == nil)
    }

    @Test func parseFakePower() {
        #expect(PowerSource.parseFake(nil) == nil)
        #expect(PowerSource.parseFake("") == nil)
        #expect(PowerSource.parseFake("battery:8") == PowerState(onBattery: true, percent: 8, hasBattery: true))
        #expect(PowerSource.parseFake("battery:50,lpm") == PowerState(onBattery: true, percent: 50, hasBattery: true, lowPowerMode: true))
        #expect(PowerSource.parseFake("AC:5") == PowerState(onBattery: false, percent: 5, hasBattery: true))
        #expect(PowerSource.parseFake("none") == PowerState())
        #expect(PowerSource.parseFake("bogus") == PowerState())
    }
}
