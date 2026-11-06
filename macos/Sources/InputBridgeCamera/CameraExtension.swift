import Foundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import CoreGraphics
import ImageIO

extension CMIOExtensionProperty {
    /// Set by the InputBridge app (see `CameraStreamConfig`); write-only from the app's point of view.
    static let inputBridgeConfig = CMIOExtensionProperty(rawValue: InputBridgeCameraDevice.configPropertyName)
}

final class InputBridgeProviderSource: NSObject, CMIOExtensionProviderSource {
    private(set) var provider: CMIOExtensionProvider!
    private let deviceSource: InputBridgeDeviceSource

    init(clientQueue: DispatchQueue?) {
        deviceSource = InputBridgeDeviceSource()
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        try? provider.addDevice(deviceSource.device)
    }

    func connect(to client: CMIOExtensionClient) throws {}
    func disconnect(from client: CMIOExtensionClient) {}

    var availableProperties: Set<CMIOExtensionProperty> { [] }

    func providerProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionProviderProperties {
        CMIOExtensionProviderProperties(dictionary: [:])
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}

final class InputBridgeDeviceSource: NSObject, CMIOExtensionDeviceSource {
    private(set) var device: CMIOExtensionDevice!
    private let streamSource: InputBridgeStreamSource

    override init() {
        streamSource = InputBridgeStreamSource()
        super.init()
        device = CMIOExtensionDevice(
            localizedName: InputBridgeCameraDevice.name,
            deviceID: InputBridgeCameraDevice.deviceID,
            legacyDeviceID: nil,
            source: self
        )
        try? device.addStream(streamSource.stream)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel, .inputBridgeConfig]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            props.transportType = 0x76697274 // 'virt'
        }
        if properties.contains(.deviceModel) {
            props.model = "InputBridge Camera"
        }
        if properties.contains(.inputBridgeConfig) {
            // Never hand the pairing token back out; report only whether a source is configured.
            props.setPropertyState(
                CMIOExtensionPropertyState(value: (streamSource.isConfigured ? "configured" : "") as NSString),
                forProperty: .inputBridgeConfig
            )
        }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {
        if let state = deviceProperties.propertiesDictionary[.inputBridgeConfig],
           let json = state.value as? String,
           let config = CameraStreamConfig.decode(json) {
            streamSource.configure(config)
        }
    }

    func allowed(toStartStreamFor client: CMIOExtensionClient) -> Bool { true }
}

final class InputBridgeStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let queue = DispatchQueue(label: "com.inputbridge.camera.stream")
    private var timer: DispatchSourceTimer?
    private var latest: CVPixelBuffer?
    private let black: CVPixelBuffer
    private let formatDescription: CMFormatDescription
    private var config = CameraStreamConfig.disabled
    private var client: WindowsCameraClient?

    override init() {
        black = Self.makeBuffer() ?? Self.fallbackBuffer()
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: black, formatDescriptionOut: &description)
        formatDescription = description ?? Self.makeFormatDescription()
        super.init()
        latest = black
        stream = CMIOExtensionStream(
            localizedName: InputBridgeCameraDevice.name,
            streamID: InputBridgeCameraDevice.streamID,
            direction: .source,
            clockType: .hostTime,
            source: self
        )
    }

    var isConfigured: Bool { queue.sync { config.enabled && !config.url.isEmpty } }

    /// Called when the app changes the source. Restarts an active connection so a new address,
    /// a new pairing or switching back to the Windows profile takes effect at once.
    func configure(_ newConfig: CameraStreamConfig) {
        queue.async { [self] in
            guard newConfig != config else { return }
            config = newConfig
            guard timer != nil else { return }
            connect()
        }
    }

    var formats: [CMIOExtensionStreamFormat] {
        [
            CMIOExtensionStreamFormat(
                formatDescription: formatDescription,
                maxFrameDuration: CMTime(value: 1, timescale: 30),
                minFrameDuration: CMTime(value: 1, timescale: 30),
                validFrameDurations: nil
            )
        ]
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.streamActiveFormatIndex, .streamFrameDuration]
    }

    func streamProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { props.frameDuration = CMTime(value: 1, timescale: 30) }
        return props
    }

    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool { true }

    /// An app (Zoom, FaceTime…) started using the camera: pull frames from Windows, which turns its camera on.
    func startStream() throws {
        queue.sync { [self] in
            guard timer == nil else { return }
            latest = black
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now(), repeating: .milliseconds(33))
            source.setEventHandler { [weak self] in self?.publish() }
            source.resume()
            timer = source
            connect()
        }
    }

    /// The last app stopped using the camera: disconnect, and Windows turns its camera off shortly after.
    func stopStream() throws {
        queue.sync { [self] in
            timer?.cancel()
            timer = nil
            client?.stop()
            client = nil
            latest = black
        }
    }

    /// Runs on `queue`.
    private func connect() {
        client?.stop()
        client = nil
        latest = black
        guard config.enabled, let url = URL(string: config.url) else { return }
        let client = WindowsCameraClient(url: url, token: config.token, queue: queue) { [weak self] buffer in
            self?.latest = buffer
        } onDisconnect: { [weak self] in
            self?.latest = self?.black
        }
        self.client = client
        client.start()
    }

    private func publish() {
        guard let pixelBuffer = latest else { return }
        let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: hostTime,
            decodeTimeStamp: .invalid
        )
        var sampleFormat: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &sampleFormat)
        guard let sampleFormat else { return }
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: sampleFormat,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        )
        guard let sample else { return }
        let nanos = UInt64(max(0, hostTime.seconds) * 1_000_000_000)
        stream.send(sample, discontinuity: [], hostTimeInNanoseconds: nanos)
    }

    private static func makeFormatDescription() -> CMFormatDescription {
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCVPixelFormatType_32BGRA,
            width: 1920,
            height: 1080,
            extensions: nil,
            formatDescriptionOut: &description
        )
        return description!
    }

    static func makeBuffer() -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        if let base = CVPixelBufferGetBaseAddress(buffer) {
            memset(base, 0, CVPixelBufferGetDataSize(buffer))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        return buffer
    }

    private static func fallbackBuffer() -> CVPixelBuffer {
        makeBuffer()!
    }
}

/// Streams JPEG frames from the paired Windows controller (`GET /api/camera/stream`) and reconnects
/// while the camera is in use. All callbacks run on the queue it was created with.
final class WindowsCameraClient: NSObject, URLSessionDataDelegate {
    private let url: URL
    private let token: String
    private let queue: DispatchQueue
    private let onFrame: (CVPixelBuffer) -> Void
    private let onDisconnect: () -> Void
    private var session: URLSession?
    private var parser = JPEGFrameParser()
    private var stopped = false

    init(url: URL, token: String, queue: DispatchQueue,
         onFrame: @escaping (CVPixelBuffer) -> Void, onDisconnect: @escaping () -> Void) {
        self.url = url
        self.token = token
        self.queue = queue
        self.onFrame = onFrame
        self.onDisconnect = onDisconnect
    }

    func start() {
        guard !stopped else { return }
        let operationQueue = OperationQueue()
        operationQueue.underlyingQueue = queue
        operationQueue.maxConcurrentOperationCount = 1
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: operationQueue)
        self.session = session
        parser.reset()
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        session.dataTask(with: request).resume()
    }

    func stop() {
        stopped = true
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !stopped, let jpeg = parser.append(data), let buffer = JPEGDecoder.pixelBuffer(from: jpeg) else { return }
        onFrame(buffer)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard session === self.session, !stopped else { return }
        session.finishTasksAndInvalidate()
        self.session = nil
        onDisconnect()
        // Windows may be on its own profile or briefly unreachable; keep trying while the camera is in use.
        queue.asyncAfter(deadline: .now() + 3) { [weak self] in self?.start() }
    }
}

enum JPEGDecoder {
    static func pixelBuffer(from data: Data) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let buffer = InputBridgeStreamSource.makeBuffer() else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: 1920,
            height: 1080,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        return buffer
    }
}

@main
enum InputBridgeCamera {
    static func main() {
        let providerSource = InputBridgeProviderSource(clientQueue: nil)
        CMIOExtensionProvider.startService(provider: providerSource.provider)
        CFRunLoopRun()
    }
}
