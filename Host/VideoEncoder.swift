import Foundation
import VideoToolbox
import CoreMedia

struct EncodedFrame {
    var codec: VideoCodec
    var isKey: Bool
    var parameterSets: [Data]? // present on key frames
    var payload: Data          // length-prefixed NAL units
    var ptsMicros: UInt64
}

/// Hardware H.264 / HEVC encoder tuned for a live screen: no frame reordering,
/// key frames only when asked.
final class VideoEncoder {
    let codec: VideoCodec
    let width: Int32
    let height: Int32
    private var session: VTCompressionSession?
    private let output: (EncodedFrame) -> Void

    init(width: Int32, height: Int32, codec: VideoCodec, bitrate: Int, fps: Int, output: @escaping (EncodedFrame) -> Void) throws {
        self.codec = codec
        self.width = width
        self.height = height
        self.output = output

        let type: CMVideoCodecType = codec == .hevc ? kCMVideoCodecType_HEVC : kCMVideoCodecType_H264
        var created: VTCompressionSession?
        let lowLatency = [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: kCFBooleanTrue] as CFDictionary
        var status = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: type,
                                                encoderSpecification: lowLatency, imageBufferAttributes: nil,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &created)
        if status != noErr || created == nil {
            status = VTCompressionSessionCreate(allocator: nil, width: width, height: height, codecType: type,
                                                encoderSpecification: nil, imageBufferAttributes: nil,
                                                compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                                                compressionSessionOut: &created)
        }
        guard status == noErr, let session = created else {
            throw NSError(domain: "VideoEncoder", code: Int(status), userInfo: [NSLocalizedDescriptionKey: "Could not create the video encoder (\(status))"])
        }
        self.session = session

        func set(_ key: CFString, _ value: CFTypeRef) { VTSessionSetProperty(session, key: key, value: value) }
        set(kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate as CFNumber)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, 36_000 as CFNumber)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 600 as CFNumber)
        set(kVTCompressionPropertyKey_ProfileLevel,
            codec == .hevc ? kVTProfileLevel_HEVC_Main_AutoLevel : kVTProfileLevel_H264_High_AutoLevel)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool) {
        guard let session else { return }
        let props: CFDictionary? = forceKeyframe ? [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary : nil
        let codec = self.codec
        let output = self.output
        VTCompressionSessionEncodeFrame(session, imageBuffer: pixelBuffer, presentationTimeStamp: pts,
                                        duration: .invalid, frameProperties: props, infoFlagsOut: nil) { status, _, sample in
            guard status == noErr, let sample, CMSampleBufferDataIsReady(sample) else { return }
            guard let frame = VideoEncoder.unpack(sample, codec: codec) else { return }
            output(frame)
        }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }

    deinit { invalidate() }

    private static func unpack(_ sample: CMSampleBuffer, codec: VideoCodec) -> EncodedFrame? {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var payload = Data(count: length)
        let copied = payload.withUnsafeMutableBytes { raw -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: base)
        }
        guard copied == noErr else { return nil }

        var isKey = true
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false) as? [[CFString: Any]],
           let first = attachments.first, let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            isKey = !notSync
        }

        var sets: [Data]?
        if isKey, let format = CMSampleBufferGetFormatDescription(sample) {
            sets = parameterSets(format, codec: codec)
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let micros = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000) : 0
        return EncodedFrame(codec: codec, isKey: isKey, parameterSets: sets, payload: payload, ptsMicros: micros)
    }

    private static func parameterSets(_ format: CMFormatDescription, codec: VideoCodec) -> [Data] {
        var result: [Data] = []
        var count = 0
        func get(_ index: Int, _ pointer: inout UnsafePointer<UInt8>?, _ size: inout Int, _ count: inout Int) -> OSStatus {
            if codec == .hevc {
                return CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                           parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            }
            return CMVideoFormatDescriptionGetH264ParameterSetAtIndex(format, parameterSetIndex: index, parameterSetPointerOut: &pointer,
                                                                       parameterSetSizeOut: &size, parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        }
        var pointer: UnsafePointer<UInt8>?
        var size = 0
        guard get(0, &pointer, &size, &count) == noErr else { return [] }
        for i in 0..<count {
            var p: UnsafePointer<UInt8>?
            var s = 0
            var c = 0
            if get(i, &p, &s, &c) == noErr, let p {
                result.append(Data(bytes: p, count: s))
            }
        }
        return result
    }
}
