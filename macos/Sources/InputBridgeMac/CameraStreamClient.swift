import Foundation

/// Receives the Windows camera stream and hands frames to the camera extension.
/// All public methods and callbacks run on the main queue.
final class CameraStreamClient: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var buffer = Data()
    private let queue = DispatchQueue(label: "com.inputbridge.camera.client")

    /// Called when a stream that was not stopped by `stop()` ends: the connection dropped,
    /// Windows refused it, or Windows stopped the camera.
    var onEnded: (() -> Void)?

    var isActive: Bool { task != nil }

    func start(url: URL, token: String) {
        stop()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 86400
        let session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
        self.session = session
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.dataTask(with: request)
        self.task = task
        task.resume()
    }

    func stop() {
        task?.cancel()
        task = nil
        session?.invalidateAndCancel()
        session = nil
        queue.sync {
            buffer.removeAll(keepingCapacity: true)
            CameraFrameStore.clear()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard dataTask === task else { return }
        queue.async { [weak self] in
            self?.append(data)
        }
    }

    func urlSession(_ session: URLSession, task finished: URLSessionTask, didCompleteWithError error: Error?) {
        guard finished === task else { return } // a stream we stopped ourselves
        task = nil
        self.session?.finishTasksAndInvalidate()
        self.session = nil
        queue.async {
            CameraFrameStore.clear()
        }
        onEnded?()
    }

    private func append(_ data: Data) {
        buffer.append(data)
        while buffer.count >= 4 {
            let length = Self.uint32BE(buffer)
            if length == 0 || length > 8_000_000 { buffer.removeAll(keepingCapacity: true); return }
            let total = 4 + Int(length)
            guard buffer.count >= total else { return }
            let jpeg = buffer.subdata(in: 4..<total)
            buffer.removeSubrange(0..<total)
            try? CameraFrameStore.write(jpeg: jpeg)
        }
    }

    private static func uint32BE(_ data: Data) -> UInt32 {
        UInt32(data[data.startIndex]) << 24
            | UInt32(data[data.startIndex + 1]) << 16
            | UInt32(data[data.startIndex + 2]) << 8
            | UInt32(data[data.startIndex + 3])
    }
}
