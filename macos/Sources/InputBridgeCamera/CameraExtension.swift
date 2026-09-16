import Foundation
import CoreMedia
import CoreMediaIO
import CoreVideo
import CoreGraphics
import ImageIO

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
        device = CMIOExtensionDevice(localizedName: "InputBridge Camera", deviceID: UUID(), legacyDeviceID: nil, source: self)
        try? device.addStream(streamSource.stream)
    }

    var availableProperties: Set<CMIOExtensionProperty> {
        [.deviceTransportType, .deviceModel]
    }

    func deviceProperties(forProperties properties: Set<CMIOExtensionProperty>) throws -> CMIOExtensionDeviceProperties {
        let props = CMIOExtensionDeviceProperties(dictionary: [:])
        if properties.contains(.deviceTransportType) {
            props.transportType = 0x76697274
        }
        if properties.contains(.deviceModel) {
            props.model = "InputBridge Camera"
        }
        return props
    }

    func setDeviceProperties(_ deviceProperties: CMIOExtensionDeviceProperties) throws {}

    func allowed(toStartStreamFor client: CMIOExtensionClient) -> Bool { true }
}

final class InputBridgeStreamSource: NSObject, CMIOExtensionStreamSource {
    private(set) var stream: CMIOExtensionStream!
    private let queue = DispatchQueue(label: "com.inputbridge.camera.stream")
    private var timer: DispatchSourceTimer?
    private var lastSeq: String?
    private var latest: CVPixelBuffer?
    private let black: CVPixelBuffer
    private let formatDescription: CMFormatDescription

    override init() {
        black = Self.makeBuffer() ?? Self.fallbackBuffer()
        var description: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: black, formatDescriptionOut: &description)
        formatDescription = description ?? Self.makeFormatDescription()
        super.init()
        latest = black
        stream = CMIOExtensionStream(
            localizedName: "InputBridge Camera",
            streamID: UUID(),
            direction: .source,
            clockType: .hostTime,
            source: self
        )
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

    func startStream() throws {
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now(), repeating: .milliseconds(33))
        source.setEventHandler { [weak self] in self?.publish() }
        source.resume()
        timer = source
    }

    func stopStream() throws {
        timer?.cancel()
        timer = nil
    }

    private func publish() {
        if let frame = CameraFrameStore.read() {
            if frame.seq != lastSeq, let buffer = JPEGDecoder.pixelBuffer(from: frame.jpeg) {
                lastSeq = frame.seq
                latest = buffer
            }
        }
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

    private static func makeBuffer() -> CVPixelBuffer? {
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

enum JPEGDecoder {
    static func pixelBuffer(from data: Data) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        var buffer: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, 1920, 1080, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &buffer)
        guard let buffer else { return nil }
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
