import Foundation
import Network

/// Constants both sides agree on.
enum Wire {
    static let version = 1
    static let defaultPort: UInt16 = 47800
    static let bonjourType = "_clamshell._tcp"
    static let pskIdentity = "clamshell-v1"
    static let maxMessageBytes = 32 * 1024 * 1024
    /// The host accepts no more than this in one message from a phone, a text event included. Larger ends the session.
    static let maxPhoneMessageBytes = 64 * 1024
    /// Longest layout line from the phone the host keeps for its log, in UTF-8 bytes.
    static let maxDeviceInfoBytes = 512
}

/// One byte on the wire, followed by a 4-byte big-endian payload length.
enum MsgType: UInt8 {
    case hello = 1          // phone -> Mac, JSON Hello
    case helloAck = 2       // Mac -> phone, JSON HelloAck
    case videoConfig = 3    // Mac -> phone, codec parameter sets
    case videoFrame = 4     // Mac -> phone, one encoded frame
    case input = 5          // phone -> Mac, one InputEvent
    case requestKeyframe = 6
    case cursor = 7         // Mac -> phone, normalized cursor position
    case ping = 8
    case pong = 9
    case status = 10        // Mac -> phone, JSON HostStatus (permissions changed)
    case deviceInfo = 11    // phone -> Mac, plain text about the phone's posture, for the host log
    case audio = 12         // Mac -> phone, 48 kHz stereo 16-bit little-endian PCM
    case setDisplay = 13    // phone -> Mac, u16 points wide, 0 = the Mac's own setting
}

struct Hello: Codable {
    var version: Int
    var deviceName: String
    var maxPixelWidth: Int
    var maxPixelHeight: Int
    var fps: Int
    var bitrateMbps: Double
    var codec: String // "hevc" or "h264"
    var macScale: Int? = nil  // 0 as set on the Mac, 1 larger, 2 largest
    var audio: Bool? = nil    // send the Mac's sound
    var macWidth: Int? = nil  // the Mac should look this many points wide, 0 as set on the Mac
}

struct HelloAck: Codable {
    var version: Int
    var hostName: String
    var displayPointWidth: Double
    var displayPointHeight: Double
    var streamWidth: Int
    var streamHeight: Int
    var codec: String
    var canCapture: Bool
    var canControl: Bool
    var testPattern: Bool
    var displayWidths: [Int]? = nil  // the Mac's own size choices in points wide, narrowest first
    var displayBaseWidth: Int? = nil // the one set on the Mac
    var displayNowWidth: Int? = nil  // the one showing now
}

struct HostStatus: Codable {
    var canCapture: Bool
    var canControl: Bool
}

enum VideoCodec: UInt8 {
    case h264 = 1
    case hevc = 2

    var name: String { self == .hevc ? "hevc" : "h264" }
    init(name: String) { self = name == "h264" ? .h264 : .hevc }
}

/// Everything the phone can ask the Mac to do.
enum InputEvent: Equatable {
    case moveRel(dx: Float, dy: Float)
    case moveAbs(x: Float, y: Float)            // 0...1 across the shared display
    case button(index: UInt8, down: Bool, clicks: UInt8) // clicks 0 = let the Mac count
    case scroll(dx: Float, dy: Float)           // pixels
    case key(code: UInt16, down: Bool, isRepeat: Bool) // macOS virtual key code
    case media(key: UInt8, down: Bool)          // NX_KEYTYPE_*
    case text(String)
    case action(UInt8)                          // HostAction
    case releaseAll

    func encoded() -> Data {
        var w = ByteWriter()
        switch self {
        case .moveRel(let dx, let dy): w.u8(1); w.f32(dx); w.f32(dy)
        case .moveAbs(let x, let y): w.u8(2); w.f32(x); w.f32(y)
        case .button(let index, let down, let clicks): w.u8(3); w.u8(index); w.u8(down ? 1 : 0); w.u8(clicks)
        case .scroll(let dx, let dy): w.u8(4); w.f32(dx); w.f32(dy)
        case .key(let code, let down, let isRepeat): w.u8(5); w.u16(code); w.u8(down ? 1 : 0); w.u8(isRepeat ? 1 : 0)
        case .media(let key, let down): w.u8(6); w.u8(key); w.u8(down ? 1 : 0)
        case .text(let s): w.u8(7); w.bytes(Data(s.utf8))
        case .action(let a): w.u8(8); w.u8(a)
        case .releaseAll: w.u8(9)
        }
        return w.data
    }

    init?(data: Data) {
        var r = ByteReader(data)
        guard let kind = r.u8() else { return nil }
        switch kind {
        case 1:
            guard let dx = r.f32(), let dy = r.f32() else { return nil }
            self = .moveRel(dx: dx, dy: dy)
        case 2:
            guard let x = r.f32(), let y = r.f32() else { return nil }
            self = .moveAbs(x: x, y: y)
        case 3:
            guard let i = r.u8(), let d = r.u8(), let c = r.u8() else { return nil }
            self = .button(index: i, down: d != 0, clicks: c)
        case 4:
            guard let dx = r.f32(), let dy = r.f32() else { return nil }
            self = .scroll(dx: dx, dy: dy)
        case 5:
            guard let code = r.u16(), let d = r.u8(), let rep = r.u8() else { return nil }
            self = .key(code: code, down: d != 0, isRepeat: rep != 0)
        case 6:
            guard let k = r.u8(), let d = r.u8() else { return nil }
            self = .media(key: k, down: d != 0)
        case 7:
            guard let s = String(data: r.rest(), encoding: .utf8) else { return nil }
            self = .text(s)
        case 8:
            guard let a = r.u8() else { return nil }
            self = .action(a)
        case 9:
            self = .releaseAll
        default:
            return nil
        }
    }
}

enum HostAction: UInt8 {
    case missionControl = 1
    case wakeDisplay = 2
    case forceClick = 3   // Look Up, what a Mac's Force Click does by default
}

/// NX_KEYTYPE_* values for the media row.
enum MediaKey: UInt8 {
    case soundUp = 0, soundDown = 1, brightnessUp = 2, brightnessDown = 3
    case mute = 7, play = 16, next = 17, previous = 18
}

// MARK: - Video messages

struct VideoConfigMsg {
    var codec: VideoCodec
    var parameterSets: [Data]

    func encoded() -> Data {
        var w = ByteWriter()
        w.u8(codec.rawValue)
        w.u8(UInt8(parameterSets.count))
        for p in parameterSets { w.u16(UInt16(p.count)); w.bytes(p) }
        return w.data
    }

    init(codec: VideoCodec, parameterSets: [Data]) {
        self.codec = codec
        self.parameterSets = parameterSets
    }

    init?(data: Data) {
        var r = ByteReader(data)
        guard let c = r.u8(), let codec = VideoCodec(rawValue: c), let n = r.u8() else { return nil }
        var sets: [Data] = []
        for _ in 0..<n {
            guard let len = r.u16(), let d = r.take(Int(len)) else { return nil }
            sets.append(d)
        }
        self.codec = codec
        self.parameterSets = sets
    }
}

enum VideoFrameMsg {
    /// flags(1) + pts micros(8) + payload (length-prefixed NAL units)
    static func encode(isKey: Bool, ptsMicros: UInt64, payload: Data) -> Data {
        var w = ByteWriter(capacity: payload.count + 9)
        w.u8(isKey ? 1 : 0)
        w.u64(ptsMicros)
        w.bytes(payload)
        return w.data
    }

    static func decode(_ data: Data) -> (isKey: Bool, ptsMicros: UInt64, payload: Data)? {
        var r = ByteReader(data)
        guard let f = r.u8(), let pts = r.u64() else { return nil }
        return (f & 1 == 1, pts, r.rest())
    }
}

// MARK: - Bytes

struct ByteWriter {
    var data: Data
    init(capacity: Int = 16) { data = Data(); data.reserveCapacity(capacity) }
    mutating func u8(_ v: UInt8) { data.append(v) }
    mutating func u16(_ v: UInt16) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func u64(_ v: UInt64) { withUnsafeBytes(of: v.bigEndian) { data.append(contentsOf: $0) } }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func bytes(_ d: Data) { data.append(d) }
}

struct ByteReader {
    private let data: Data
    private var offset: Int
    init(_ data: Data) { self.data = data; self.offset = data.startIndex }

    private mutating func read<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.endIndex else { return nil }
        var v: T = 0
        for i in 0..<size { v = (v << 8) | T(data[offset + i]) }
        offset += size
        return v
    }

    mutating func u8() -> UInt8? { read(UInt8.self) }
    mutating func u16() -> UInt16? { read(UInt16.self) }
    mutating func u32() -> UInt32? { read(UInt32.self) }
    mutating func u64() -> UInt64? { read(UInt64.self) }
    mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
    mutating func take(_ n: Int) -> Data? {
        guard n >= 0, offset + n <= data.endIndex else { return nil }
        defer { offset += n }
        return data.subdata(in: offset..<(offset + n))
    }
    mutating func rest() -> Data {
        defer { offset = data.endIndex }
        return data.subdata(in: offset..<data.endIndex)
    }
}

// MARK: - Pairing link

/// What the QR code on the Mac carries: where to find the Mac and the shared key.
struct Pairing: Codable, Equatable {
    var name: String
    var hosts: [String]
    var port: UInt16
    var key: Data // 32 random bytes, never leaves the two devices

    var url: URL {
        var c = URLComponents()
        c.scheme = "clamshell"
        c.host = "pair"
        var items = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "port", value: String(port)),
            URLQueryItem(name: "key", value: key.base64URLEncoded),
        ]
        for h in hosts { items.append(URLQueryItem(name: "h", value: h)) }
        c.queryItems = items
        return c.url!
    }

    init(name: String, hosts: [String], port: UInt16, key: Data) {
        self.name = name
        self.hosts = hosts
        self.port = port
        self.key = key
    }

    init?(url: URL) {
        guard url.scheme == "clamshell", url.host == "pair",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func first(_ n: String) -> String? { items.first { $0.name == n }?.value }
        guard let keyText = first("key"), let key = Data(base64URLEncoded: keyText), key.count >= 16 else { return nil }
        self.name = first("name") ?? "Mac"
        self.port = first("port").flatMap { UInt16($0) } ?? Wire.defaultPort
        self.hosts = items.filter { $0.name == "h" }.compactMap { $0.value }.filter { !$0.isEmpty }
        self.key = key
    }
}

extension Data {
    var base64URLEncoded: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64URLEncoded s: String) {
        var t = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t.append("=") }
        self.init(base64Encoded: t)
    }
}
