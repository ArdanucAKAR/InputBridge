import Foundation
import XCTest

private func reading(_ deviceId: String, _ name: String, _ kind: DeviceKind, percent: Int = 50) -> BatteryReading {
    BatteryReading(
        deviceId: deviceId, name: name, kind: kind,
        components: [BatteryComponent(role: .main, percent: percent, charging: false)],
        readAt: Date(timeIntervalSince1970: 1_795_082_400))
}

final class BatteryMergeTests: XCTestCase {
    private let localKeyboard = reading(BatteryIds.sharedKeyboard, "G915 TKL", .keyboard, percent: 82)
    private let remoteKeyboard = reading(BatteryIds.sharedKeyboard, "G915 TKL", .keyboard, percent: 40)
    private let trackpad = reading("apple:Magic Trackpad", "Magic Trackpad", .trackpad, percent: 64)

    func testRemoteMerge_IgnoresMissingController() {
        let local = [localKeyboard, trackpad]
        XCTAssertEqual(BatteryMerge.visible(local: local, remote: []), local)
    }

    func testLocalSharedKeyboardWinsOverRemote() {
        let visible = BatteryMerge.visible(local: [localKeyboard], remote: [remoteKeyboard])
        XCTAssertEqual(visible, [localKeyboard])
        XCTAssertFalse(visible[0].remote)
    }

    func testRemoteSharedKeyboardShownAsRemoteWhenNotLocal() {
        let visible = BatteryMerge.visible(local: [trackpad], remote: [remoteKeyboard])
        XCTAssertEqual(visible.map(\.deviceId), [BatteryIds.sharedKeyboard, trackpad.deviceId])
        XCTAssertTrue(visible[0].remote)
        XCTAssertEqual(visible[0].components, remoteKeyboard.components)
        XCTAssertFalse(visible[1].remote)
    }

    func testRemoteReadingsOtherThanSharedKeyboardIgnored() {
        let remoteAirPods = reading("apple:AirPods", "AirPods", .headset)
        XCTAssertEqual(BatteryMerge.visible(local: [trackpad], remote: [remoteAirPods]), [trackpad])
    }

    func testOrdersKeyboardHeadsetTrackpadThenName() {
        let airPods = reading("apple:AirPods", "AirPods", .headset)
        let otherTrackpad = reading("apple:A Trackpad", "a trackpad", .trackpad)
        let visible = BatteryMerge.visible(local: [trackpad, airPods, otherTrackpad, localKeyboard], remote: [])
        XCTAssertEqual(visible.map(\.name), ["G915 TKL", "AirPods", "a trackpad", "Magic Trackpad"])
    }
}
