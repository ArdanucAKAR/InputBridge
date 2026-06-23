import Foundation
import Darwin

final class DiscoveryService: ObservableObject {
    @Published private(set) var offers: [ControllerOffer] = []
    private let group = "239.255.77.77"
    private let port: UInt16 = 41716
    private var fd: Int32 = -1
    private var readSource: DispatchSourceRead?
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.inputbridge.discovery")
    private let nonce = UUID().uuidString

    func start() {
        guard fd < 0 else { return }
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var bindAddress = sockaddr_in()
        bindAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_port = 0
        bindAddress.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)
        withUnsafePointer(to: &bindAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.receiveAvailable() }
        source.resume()
        readSource = source

        let ticker = DispatchSource.makeTimerSource(queue: queue)
        ticker.schedule(deadline: .now(), repeating: .seconds(3))
        ticker.setEventHandler { [weak self] in self?.sendDiscover() }
        ticker.resume()
        timer = ticker
    }

    func stop() {
        timer?.cancel(); timer = nil
        readSource?.cancel(); readSource = nil
        if fd >= 0 { close(fd); fd = -1 }
    }

    private func sendDiscover() {
        let message: [String: Any] = ["protocol": 1, "type": "discover", "nonce": nonce]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        var destination = sockaddr_in()
        destination.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        destination.sin_family = sa_family_t(AF_INET)
        destination.sin_port = port.bigEndian
        destination.sin_addr = in_addr(s_addr: inet_addr(group))
        data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &destination) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func receiveAvailable() {
        var buffer = [UInt8](repeating: 0, count: 4096)
        var remote = sockaddr_in()
        var remoteLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &remote) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buffer, buffer.count, 0, $0, &remoteLength)
            }
        }
        guard count > 0 else { return }
        let data = Data(buffer.prefix(Int(count)))
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (json["type"] as? String) == "offer",
              (json["nonce"] as? String) == nonce,
              let rawId = json["controllerId"] as? String,
              let controllerId = UUID(uuidString: rawId),
              let name = json["name"] as? String,
              let httpPort = json["httpPort"] as? Int else { return }

        var address = remote.sin_addr
        var chars = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        guard inet_ntop(AF_INET, &address, &chars, socklen_t(INET_ADDRSTRLEN)) != nil else { return }
        let host = String(cString: chars)
        let offer = ControllerOffer(controllerId: controllerId, name: name, host: host, httpPort: httpPort, lastSeen: Date())
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.offers.removeAll { $0.controllerId == offer.controllerId }
            self.offers.append(offer)
            self.offers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }
}
