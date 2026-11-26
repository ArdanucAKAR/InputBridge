import Foundation
import XCTest

private func reading(
    _ deviceId: String, _ name: String, _ kind: DeviceKind, _ components: [BatteryComponent]
) -> BatteryReading {
    BatteryReading(
        deviceId: deviceId, name: name, kind: kind, components: components,
        readAt: Date(timeIntervalSince1970: 1_795_082_400))
}

private func level(_ percent: Int, charging: Bool = false) -> BatteryComponent {
    BatteryComponent(role: .main, percent: percent, charging: charging)
}

final class BatteryStripTests: XCTestCase {
    func testSingleComponentIsOneSegmentWithPercent() {
        let g915 = reading("logitech-keyboard", "G915 TKL", .keyboard, [level(82)])
        XCTAssertEqual(
            BatteryStrip.segments([g915]),
            [StripSegment(symbol: "keyboard", text: "82%", tone: .normal)])
    }

    func testAirPodsShowLeftRightAndCaseInOrder() {
        // Components deliberately out of order: the strip always shows left, right, case.
        let airPods = reading("apple:AirPods Pro", "AirPods Pro", .headset, [
            BatteryComponent(role: .`case`, percent: 60, charging: false),
            BatteryComponent(role: .right, percent: 85, charging: false),
            BatteryComponent(role: .left, percent: 90, charging: false),
        ])
        XCTAssertEqual(BatteryStrip.segments([airPods]), [
            StripSegment(symbol: "airpods", text: "L90", tone: .normal),
            StripSegment(symbol: "", text: "R85", tone: .normal),
            StripSegment(symbol: BatteryStrip.caseSymbol, text: "60", tone: .normal),
        ])
    }

    func testAirPodsWithoutCaseShowTwoSegments() {
        let airPods = reading("apple:AirPods", "AirPods", .headset, [
            BatteryComponent(role: .left, percent: 90, charging: false),
            BatteryComponent(role: .right, percent: 85, charging: false),
        ])
        XCTAssertEqual(BatteryStrip.segments([airPods]).map(\.text), ["L90", "R85"])
    }

    func testFifteenPercentNotChargingIsLow() {
        let mouse = reading("apple:Magic Mouse", "Magic Mouse", .mouse, [level(15)])
        XCTAssertEqual(BatteryStrip.segments([mouse]).map(\.tone), [.low])
    }

    func testFifteenPercentChargingIsCharging() {
        let mouse = reading("apple:Magic Mouse", "Magic Mouse", .mouse, [level(15, charging: true)])
        XCTAssertEqual(BatteryStrip.segments([mouse]).map(\.tone), [.charging])
    }

    func testNoReadingsNoSegments() {
        XCTAssertEqual(BatteryStrip.segments([]), [])
    }

    func testSymbolsPerKind() {
        let readings = [
            reading("a", "Mouse", .mouse, [level(50)]),
            reading("b", "Trackpad", .trackpad, [level(64)]),
        ]
        XCTAssertEqual(BatteryStrip.segments(readings).map(\.symbol), ["computermouse", "rectangle.and.hand.point.up.left"])
    }
}
