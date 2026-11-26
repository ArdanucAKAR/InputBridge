import Foundation
import XCTest

private func reading(_ deviceId: String, _ name: String, _ kind: DeviceKind, percent: Int = 50) -> BatteryReading {
    BatteryReading(
        deviceId: deviceId, name: name, kind: kind,
        components: [BatteryComponent(role: .main, percent: percent, charging: false)],
        readAt: Date(timeIntervalSince1970: 1_795_082_400))
}

private struct StubSource: BatterySource {
    let name: String
    func read() -> [BatteryReading] { [] }
}

final class BatteryOrderTests: XCTestCase {
    func testOrdersKeyboardMouseHeadsetTrackpadOtherThenName() {
        let keyboard = reading(BatteryIds.sharedKeyboard, "G915 TKL", .keyboard, percent: 82)
        let trackpad = reading("apple:Magic Trackpad", "Magic Trackpad", .trackpad, percent: 64)
        let airPods = reading("apple:AirPods", "AirPods", .headset)
        let otherTrackpad = reading("apple:A Trackpad", "a trackpad", .trackpad)
        let mouse = reading("apple:Magic Mouse", "Magic Mouse", .mouse)
        let pencil = reading("apple:Pencil", "Pencil", .other)
        let sorted = BatteryOrder.sorted([pencil, trackpad, airPods, mouse, otherTrackpad, keyboard])
        XCTAssertEqual(
            sorted.map(\.name), ["G915 TKL", "Magic Mouse", "AirPods", "a trackpad", "Magic Trackpad", "Pencil"])
    }

    func testSameNameOrdersByDeviceId() {
        let second = reading("apple:b", "AirPods", .headset)
        let first = reading("apple:a", "AirPods", .headset)
        XCTAssertEqual(BatteryOrder.sorted([second, first]).map(\.deviceId), ["apple:a", "apple:b"])
    }

    func testDisabledReadsNothing() {
        let a = StubSource(name: "a")
        let b = StubSource(name: "b")
        XCTAssertTrue(BatteryOrder.sourcesToRead(all: [a, b], enabled: false).isEmpty)
        XCTAssertEqual(BatteryOrder.sourcesToRead(all: [a, b], enabled: true).count, 2)
    }
}
