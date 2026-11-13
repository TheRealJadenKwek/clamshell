import Foundation
import AVFoundation
import CoreMedia

/// Feeds encoded frames straight into a display layer, which decodes in hardware
/// and shows each frame as soon as it arrives.
final class VideoRenderer {
    let layer = AVSampleBufferDisplayLayer()
    /// Called (on the caller's queue) when decoding cannot continue without a key frame.
    var onNeedsKeyframe: (() -> Void)?

    private var format: CMVideoFormatDescription?
    private var waitingForKey = true
    private var lastKeyRequest: TimeInterval = 0
    private(set) var framesShown = 0

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColorCompat.black
    }

    func reset() {
        format = nil
        waitingForKey = true
        framesShown = 0
        layer.sampleBufferRenderer.flush()
    }

    /// The layer drops its decoder when the app goes to the background.
    func recover() {
        waitingForKey = true
        layer.sampleBufferRenderer.flush()
        requestKey(force: true)
    }

    func configure(_ config: VideoConfigMsg) {
        guard let made = VideoRenderer.makeFormat(config) else {
            requestKey(force: false)
            return
        }
        if let format, CMFormatDescriptionEqual(format, otherFormatDescription: made) { return }
        format = made
    }

    func enqueue(payload: Data, isKey: Bool, ptsMicros: UInt64) {
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed || renderer.requiresFlushToResumeDecoding {
            renderer.flush()
            waitingForKey = true
        }
        if waitingForKey {
            guard isKey, format != nil else {
                requestKey(force: false)
                return
            }
            waitingForKey = false
        }
        guard let format, let sample = VideoRenderer.makeSample(payload, format: format, ptsMicros: ptsMicros) else { return }
        renderer.enqueue(sample)
        framesShown += 1
    }

    private func requestKey(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastKeyRequest > 0.5 else { return }
        lastKeyRequest = now
        onNeedsKeyframe?()
    }

    private static func makeFormat(_ config: VideoConfigMsg) -> CMVideoFormatDescription? {
        let sets = config.parameterSets
        guard !sets.isEmpty else { return nil }
        let buffers: [UnsafeMutablePointer<UInt8>] = sets.map { set in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: p, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer<UInt8>($0) }
        let sizes = sets.map { $0.count }
        var out: CMVideoFormatDescription?
        let status: OSStatus
        if config.codec == .hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                         parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                         nalUnitHeaderLength: 4, extensions: nil, formatDescriptionOut: &out)
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                                                                         parameterSetPointers: pointers, parameterSetSizes: sizes,
                                                                         nalUnitHeaderLength: 4, formatDescriptionOut: &out)
        }
        return status == noErr ? out : nil
    }

    private static func makeSample(_ payload: Data, format: CMVideoFormatDescription, ptsMicros: UInt64) -> CMSampleBuffer? {
        // A time past Int64 would trap the conversion below: a bad host's frame is dropped instead.
        guard let pts = CMTimeValue(exactly: ptsMicros) else { return nil }
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: payload.count,
                                                 blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: payload.count, flags: kCMBlockBufferAssureMemoryNowFlag,
                                                 blockBufferOut: &block) == noErr, let block else { return nil }
        let copied = payload.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0, dataLength: payload.count)
        }
        guard copied == noErr else { return nil }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
                                        decodeTimeStamp: .invalid)
        var size = payload.count
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format, sampleCount: 1,
                                        sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
                                        sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, let sample else { return nil }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

enum UIColorCompat {
    static let black = CGColor(gray: 0, alpha: 1)
}
