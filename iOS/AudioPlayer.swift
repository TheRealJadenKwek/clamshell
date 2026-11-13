import AVFoundation

/// Plays the Mac's sound as it arrives: 48 kHz stereo 16-bit PCM.
final class AudioPlayer {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
    private let lock = NSLock()
    private var queuedFrames = 0
    private static let startFrames = 48_000 / 20    // 50 ms cushion before starting
    private static let maxFrames = 48_000 / 4       // behind by more than this: drop, never add delay

    init() {
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
    }

    func play(_ data: Data) {
        let frames = data.count / 4
        guard frames > 0, frames + backlog <= Self.maxFrames, startIfNeeded(),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)),
              let channels = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            for i in 0..<frames {
                channels[0][i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4, as: Int16.self))) / 32768
                channels[1][i] = Float(Int16(littleEndian: raw.loadUnaligned(fromByteOffset: i * 4 + 2, as: Int16.self))) / 32768
            }
        }
        adjust(frames)
        node.scheduleBuffer(buffer) { [weak self] in self?.adjust(-frames) }
        if !node.isPlaying, backlog >= Self.startFrames { node.play() }
    }

    func stop() {
        node.stop()
        engine.stop()
        lock.withLock { queuedFrames = 0 }
    }

    private var backlog: Int { lock.withLock { queuedFrames } }

    private func adjust(_ delta: Int) {
        lock.withLock { queuedFrames = max(0, queuedFrames + delta) }
    }

    private func startIfNeeded() -> Bool {
        if engine.isRunning { return true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            try engine.start()
            return true
        } catch {
            return false
        }
    }
}
