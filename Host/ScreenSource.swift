import Foundation
import ScreenCaptureKit
import CoreMedia
import CoreVideo
import CoreGraphics
import AppKit

/// Something that produces screen frames.
protocol FrameSource: AnyObject {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)? { get set }
    func start() async throws
    func stop()
}

struct DisplayInfo {
    var id: CGDirectDisplayID
    var bounds: CGRect     // global points, top-left origin (CGEvent space)
    var pixelWidth: Int
    var pixelHeight: Int

    static func main() -> DisplayInfo {
        let id = CGMainDisplayID()
        let bounds = CGDisplayBounds(id)
        var pw = CGDisplayPixelsWide(id)
        var ph = CGDisplayPixelsHigh(id)
        if let mode = CGDisplayCopyDisplayMode(id) {
            pw = mode.pixelWidth
            ph = mode.pixelHeight
        }
        return DisplayInfo(id: id, bounds: bounds, pixelWidth: pw, pixelHeight: ph)
    }

    /// Largest even-sized stream that fits the phone's limits without upscaling.
    func streamSize(maxWidth: Int, maxHeight: Int) -> (Int, Int) {
        let w = Double(pixelWidth), h = Double(pixelHeight)
        let scale = min(1.0, Double(max(maxWidth, 320)) / w, Double(max(maxHeight, 200)) / h)
        let sw = Int((w * scale / 2).rounded(.down)) * 2
        let sh = Int((h * scale / 2).rounded(.down)) * 2
        return (max(sw, 2), max(sh, 2))
    }
}

/// The Mac's main display through ScreenCaptureKit. Frames arrive only when the
/// screen changes, so an idle desktop costs nothing.
final class ScreenSource: NSObject, FrameSource, SCStreamOutput, SCStreamDelegate {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    var onStopped: ((String) -> Void)?
    var onAudio: ((Data) -> Void)?
    private let captureAudio: Bool
    private let audioQueue = DispatchQueue(label: "clamshell.audio", qos: .userInteractive)
    private let display: DisplayInfo
    private let width: Int
    private let height: Int
    private let fps: Int
    private var stream: SCStream?
    private var firstFrameClock: Date?
    private let queue = DispatchQueue(label: "clamshell.capture", qos: .userInteractive)

    init(display: DisplayInfo, width: Int, height: Int, fps: Int, captureAudio: Bool) {
        self.captureAudio = captureAudio
        self.display = display
        self.width = width
        self.height = height
        self.fps = fps
    }

    func start() async throws {
        let began = Date()
        firstFrameClock = began
        // Only the display is used. Asking for off-screen windows too is slow on a busy Mac.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        log(String(format: "capture: displays listed in %.2fs", Date().timeIntervalSince(began)))
        guard let scDisplay = content.displays.first(where: { $0.displayID == display.id }) ?? content.displays.first else {
            throw NSError(domain: "ScreenSource", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display to share"])
        }
        let filter = SCContentFilter(display: scDisplay, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 4
        config.scalesToFit = true
        config.capturesAudio = captureAudio
        if captureAudio {
            config.sampleRate = 48_000
            config.channelCount = 2
            config.excludesCurrentProcessAudio = true
        }
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        if captureAudio { try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue) }
        try await stream.startCapture()
        self.stream = stream
        log(String(format: "capture: started in %.2fs", Date().timeIntervalSince(began)))
    }

    func stop() {
        let stream = self.stream
        self.stream = nil
        Task { try? await stream?.stopCapture() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        if type == .audio {
            deliverAudio(sampleBuffer)
            return
        }
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, let status = SCFrameStatus(rawValue: raw), status == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer else { return }
        if let clock = firstFrameClock {
            firstFrameClock = nil
            log(String(format: "capture: first frame after %.2fs", Date().timeIntervalSince(clock)))
        }
        onFrame?(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    /// Float32 from ScreenCaptureKit to interleaved 16-bit. Silence is not sent.
    private func deliverAudio(_ sampleBuffer: CMSampleBuffer) {
        guard let onAudio, sampleBuffer.isValid else { return }
        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let first = list.first, let left = first.mData?.assumingMemoryBound(to: Float32.self) else { return }
            let right = list.count > 1 ? (list[1].mData?.assumingMemoryBound(to: Float32.self) ?? left) : left
            let frames = Int(first.mDataByteSize) / MemoryLayout<Float32>.size
            var pcm = Data(count: frames * 4)
            var audible = false
            pcm.withUnsafeMutableBytes { raw in
                let out = raw.bindMemory(to: Int16.self)
                for i in 0..<frames {
                    let l = Int16(max(-1, min(1, left[i])) * 32767), r = Int16(max(-1, min(1, right[i])) * 32767)
                    if l != 0 || r != 0 { audible = true }
                    out[i * 2] = l.littleEndian
                    out[i * 2 + 1] = r.littleEndian
                }
            }
            if audible { onAudio(pcm) }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStopped?(error.localizedDescription)
    }
}

/// A moving pattern with a clock, for testing the whole pipeline on a Mac that
/// has not granted Screen Recording yet.
final class TestPatternSource: FrameSource {
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    private let width: Int
    private let height: Int
    private let fps: Int
    private var timer: DispatchSourceTimer?
    private var frameIndex = 0
    private let queue = DispatchQueue(label: "clamshell.pattern", qos: .userInteractive)
    /// The last input the phone sent, drawn into the picture so a test can see the round trip.
    var note: String = "waiting for input"
    var cursor = CGPoint(x: 0.5, y: 0.5)
    /// A blank dark screen, shown when the real screen cannot be captured yet. The phone explains why.
    var plain = false

    init(width: Int, height: Int, fps: Int) {
        self.width = width
        self.height = height
        self.fps = fps
    }

    func start() async throws {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 1.0 / Double(fps))
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func tick() {
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [kCVPixelBufferCGBitmapContextCompatibilityKey: true,
                                      kCVPixelBufferCGImageCompatibilityKey: true,
                                      kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary]
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let pb else { return }
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pb), width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: CVPixelBufferGetBytesPerRow(pb), space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return }
        let w = CGFloat(width), h = CGFloat(height)
        ctx.setFillColor(CGColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        if plain {
            frameIndex += 1
            onFrame?(pb, CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps)))
            return
        }
        // Grid
        ctx.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: 0.08))
        ctx.setLineWidth(1)
        let step = w / 16
        var x: CGFloat = 0
        while x <= w { ctx.move(to: CGPoint(x: x, y: 0)); ctx.addLine(to: CGPoint(x: x, y: h)); x += step }
        var y: CGFloat = 0
        while y <= h { ctx.move(to: CGPoint(x: 0, y: y)); ctx.addLine(to: CGPoint(x: w, y: y)); y += step }
        ctx.strokePath()
        // Moving bar
        let t = CGFloat(frameIndex % (fps * 4)) / CGFloat(fps * 4)
        ctx.setFillColor(CGColor(red: 0.25, green: 0.55, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: t * (w - 80), y: h * 0.08, width: 80, height: h * 0.04))
        // Text (CoreGraphics origin is bottom-left)
        let seconds = frameIndex / fps
        draw("Clamshell test pattern   \(width)x\(height)   t=\(seconds)s", at: CGPoint(x: w * 0.05, y: h * 0.80), size: h * 0.05, in: ctx)
        draw(note, at: CGPoint(x: w * 0.05, y: h * 0.66), size: h * 0.06, in: ctx)
        // Fake cursor
        let cx = cursor.x * w, cy = (1 - cursor.y) * h
        ctx.setFillColor(CGColor(red: 1, green: 0.8, blue: 0.2, alpha: 1))
        ctx.fillEllipse(in: CGRect(x: cx - 10, y: cy - 10, width: 20, height: 20))
        frameIndex += 1
        onFrame?(pb, CMTime(value: CMTimeValue(frameIndex), timescale: CMTimeScale(fps)))
    }

    private func draw(_ text: String, at point: CGPoint, size: CGFloat, in ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: size, weight: .medium),
                                                    .foregroundColor: NSColor.white]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attrs))
        ctx.textPosition = point
        CTLineDraw(line, ctx)
    }
}
