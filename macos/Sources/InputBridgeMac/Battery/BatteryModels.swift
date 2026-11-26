import Foundation

// Battery readings of the devices connected to this Mac. They stay on this Mac: nothing is sent to Windows.

enum DeviceKind: String {
    case keyboard, mouse, headset, trackpad, other
}

enum ComponentRole: String {
    case main, left, right, `case`
}

struct BatteryComponent: Equatable {
    let role: ComponentRole
    let percent: Int
    let charging: Bool
}

struct BatteryReading: Equatable {
    let deviceId: String
    let name: String
    let kind: DeviceKind
    let components: [BatteryComponent]
    let readAt: Date
}

enum BatteryIds {
    /// The Logitech keyboard (G915/G913). Same id as the Windows reading of that keyboard.
    static let sharedKeyboard = "logitech-keyboard"
}
