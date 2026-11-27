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

private func part(_ role: ComponentRole, _ percent: Int, charging: Bool = false) -> BatteryComponent {
    BatteryComponent(role: role, percent: percent, charging: charging)
}

final class MenuBarColumnsTests: XCTestCase {
    func testKeyboardIsOneColumnWithPercent() {
        let g915 = reading("logitech-keyboard", "G915 TKL", .keyboard, [level(82)])
        XCTAssertEqual(
            MenuBarColumns.columns([g915], airPods: .separate),
            [MenuBarColumn(symbol: "keyboard", text: "82%", tone: .normal)])
    }

    func testAirPodsSeparateShowsLeftRightCaseInOrder() {
        // Components deliberately out of order: always left, right, case.
        let airPods = reading("apple:AirPods Pro", "AirPods Pro", .headset, [
            part(.`case`, 60), part(.right, 85), part(.left, 90),
        ])
        XCTAssertEqual(MenuBarColumns.columns([airPods], airPods: .separate), [
            MenuBarColumn(symbol: "airpod.left", label: "L", text: "90%", tone: .normal),
            MenuBarColumn(symbol: "airpod.right", label: "R", text: "85%", tone: .normal),
            MenuBarColumn(symbol: MenuBarColumns.caseSymbol, text: "60%", tone: .normal),
        ])
    }

    func testAirPodsCombinedShowsLowerEarbudAndHidesCase() {
        let airPods = reading("apple:AirPods Pro", "AirPods Pro", .headset, [
            part(.left, 90), part(.right, 85), part(.`case`, 60),
        ])
        XCTAssertEqual(
            MenuBarColumns.columns([airPods], airPods: .combined),
            [MenuBarColumn(symbol: "airpods", text: "85%", tone: .normal)])
    }

    func testAirPodsCombinedWithOneEarbud() {
        let airPods = reading("apple:AirPods", "AirPods", .headset, [part(.right, 40), part(.`case`, 70)])
        XCTAssertEqual(
            MenuBarColumns.columns([airPods], airPods: .combined),
            [MenuBarColumn(symbol: "airpods", text: "40%", tone: .normal)])
    }

    func testAirPodsCombinedLowEarbudIsLow() {
        let airPods = reading("apple:AirPods", "AirPods", .headset, [part(.left, 10), part(.right, 80)])
        XCTAssertEqual(MenuBarColumns.columns([airPods], airPods: .combined).map(\.tone), [.low])
    }

    func testAirPodsCombinedCaseOnlyShowsNothing() {
        let airPods = reading("apple:AirPods", "AirPods", .headset, [part(.`case`, 70)])
        XCTAssertEqual(MenuBarColumns.columns([airPods], airPods: .combined), [])
    }

    func testAirPodsCombinedChargingLowerEarbudIsCharging() {
        let airPods = reading("apple:AirPods", "AirPods", .headset, [
            part(.left, 90), part(.right, 50, charging: true),
        ])
        XCTAssertEqual(MenuBarColumns.columns([airPods], airPods: .combined).map(\.tone), [.charging])
    }

    func testAirPodsCombinedTiePrefersChargingEarbud() {
        let airPods = reading("apple:AirPods", "AirPods", .headset, [
            part(.left, 60), part(.right, 60, charging: true),
        ])
        XCTAssertEqual(
            MenuBarColumns.columns([airPods], airPods: .combined),
            [MenuBarColumn(symbol: "airpods", text: "60%", tone: .charging)])
    }

    func testAirPodsSeparateWithSingleEarbudShowsEarbudAndCase() {
        let airPods = reading("apple:AirPods", "AirPods", .headset, [part(.right, 40), part(.`case`, 70)])
        XCTAssertEqual(MenuBarColumns.columns([airPods], airPods: .separate), [
            MenuBarColumn(symbol: "airpod.right", label: "R", text: "40%", tone: .normal),
            MenuBarColumn(symbol: MenuBarColumns.caseSymbol, text: "70%", tone: .normal),
        ])
    }

    func testNoReadingsOrNoComponentsShowNothing() {
        XCTAssertEqual(MenuBarColumns.columns([], airPods: .separate), [])
        let empty = reading("a", "Empty", .other, [])
        XCTAssertEqual(MenuBarColumns.columns([empty], airPods: .separate), [])
        XCTAssertEqual(MenuBarColumns.columns([empty], airPods: .combined), [])
    }

    func testHeadsetWithOnlyMainComponent() {
        let headset = reading("bt:Headset", "Headset", .headset, [level(55)])
        let expected = [MenuBarColumn(symbol: "airpods", text: "55%", tone: .normal)]
        XCTAssertEqual(MenuBarColumns.columns([headset], airPods: .separate), expected)
        XCTAssertEqual(MenuBarColumns.columns([headset], airPods: .combined), expected)
    }

    func testFifteenPercentNotChargingIsLow() {
        XCTAssertEqual(MenuBarColumns.tone(level(15)), .low)
    }

    func testFifteenPercentChargingIsCharging() {
        XCTAssertEqual(MenuBarColumns.tone(level(15, charging: true)), .charging)
        XCTAssertEqual(MenuBarColumns.tone(level(16)), .normal)
    }

    func testPercentIsClamped() {
        let readings = [
            reading("a", "Mouse", .mouse, [level(140)]),
            reading("b", "Trackpad", .trackpad, [level(-5)]),
        ]
        XCTAssertEqual(MenuBarColumns.columns(readings, airPods: .separate).map(\.text), ["100%", "0%"])
    }

    func testSymbolsPerKind() {
        XCTAssertEqual(MenuBarColumns.symbol(for: .keyboard), "keyboard")
        XCTAssertEqual(MenuBarColumns.symbol(for: .mouse), "computermouse")
        XCTAssertEqual(MenuBarColumns.symbol(for: .headset), "airpods")
        XCTAssertEqual(MenuBarColumns.symbol(for: .trackpad), "rectangle.and.hand.point.up.left")
        XCTAssertEqual(MenuBarColumns.symbol(for: .other), "battery.100")
    }

    func testTooltipListsEveryComponent() {
        let airPods = reading("apple:AirPods Pro", "AirPods Pro", .headset, [
            part(.left, 90), part(.right, 85), part(.`case`, 60),
        ])
        let g915 = reading("logitech-keyboard", "G915 TKL", .keyboard, [level(82, charging: true)])
        XCTAssertEqual(
            MenuBarColumns.tooltip([airPods, g915]),
            "AirPods Pro: L 90%, R 85%, case 60%\nG915 TKL: 82% charging")
    }
}
