import Foundation
import Network
import UIKit
import Combine

/// The phone's side of the link: finds the Mac, keeps the connection up, shows
/// video, sends input. Published values change on the main thread.
final class Client: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case connected
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var ack: HelloAck?
    @Published private(set) var hostStatus: HostStatus?
    @Published private(set) var latencyMs: Int?
    @Published private(set) var lastProblem: String?

    let renderer = VideoRenderer()
    /// Normalized Mac cursor position, delivered on the main thread.
    var onCursor: ((CGPoint) -> Void)?

    private let queue = DispatchQueue(label: "clamshell.client", qos: .userInteractive)
    private var pairing: Pairing?
    private var attempts: [MessageChannel] = []
    private var channel: MessageChannel?
    private let audio = AudioPlayer()
    private var wanted = false
    private var retryDelay = 0.4
    private var generation = 0
    private var pingTimer: DispatchSourceTimer?
    private var failures = 0
    private let pathMonitor = NWPathMonitor()
    private var network = ""
    private var onWiFi = true
    private var onVPN = false
    /// A dial that reaches nothing can sit for over a minute per address. Give up sooner and say why.
    private static let attemptLimit: Double = 6

    init() {
        renderer.onNeedsKeyframe = { [weak self] in
            self?.channel?.send(.requestKeyframe)
        }
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            self.onWiFi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            self.onVPN = path.usesInterfaceType(.other)
            let now = "\(path.status) \(self.onWiFi) \(self.onVPN) \(path.availableInterfaces.map(\.name))"
            let changed = !self.network.isEmpty && now != self.network
            self.network = now
            // Joined Wi-Fi or turned on a VPN while looking for the Mac: dial again now.
            guard changed, self.wanted, self.channel == nil, path.status == .satisfied else { return }
            self.retryDelay = 0.4
            self.startAttempt()
        }
        pathMonitor.start(queue: queue)
    }

    func connect(to pairing: Pairing) {
        queue.async {
            self.pairing = pairing
            self.wanted = true
            self.retryDelay = 0.4
            self.failures = 0
            self.startAttempt()
        }
    }

    func disconnect() {
        audio.stop()
        queue.async {
            self.wanted = false
            self.generation += 1
            self.teardown()
            self.publish { $0.phase = .idle; $0.ack = nil; $0.latencyMs = nil }
        }
    }

    /// Drop the link and dial again right away (after returning to the app, or from the menu).
    func reconnect() {
        queue.async {
            guard self.wanted else { return }
            self.retryDelay = 0.4
            self.startAttempt()
        }
    }

    func sendDeviceInfo(_ text: String) {
        queue.async { self.channel?.send(.deviceInfo, Data(text.utf8)) }
    }

    /// Resizes the Mac now and on every later connection. 0 is the Mac's own setting.
    func setDisplay(width: Int) {
        UserDefaults.standard.set(width, forKey: "macWidth")
        var w = ByteWriter()
        w.u16(UInt16(clamping: width))
        queue.async { self.channel?.send(.setDisplay, w.data) }
    }

    func send(_ event: InputEvent) {
        send([event])
    }

    /// Where every input event leaves the phone. Long text goes in pieces the host takes (see `pieces`).
    func send(_ events: [InputEvent]) {
        queue.async {
            for e in events {
                if case .text(let s) = e, s.utf8.count > Self.textPieceCharacters {
                    for piece in Self.pieces(of: s) { self.channel?.send(.input, InputEvent.text(piece).encoded()) }
                } else {
                    self.channel?.send(.input, e.encoded())
                }
            }
        }
    }

    /// The host ends the session on a message over `Wire.maxPhoneMessageBytes`, and hosts before 1.0 drop a text
    /// event over 4,096 bytes, so long text (a big paste, the clipboard) goes as consecutive pieces of at most
    /// 1,000 characters, split between characters, and never over 4,000 UTF-8 bytes (long emoji sequences).
    /// A single character over 4,000 bytes (a pile of combining marks) is dropped, never sent whole.
    static let textPieceCharacters = 1000
    static let textPieceBytes = 4000

    static func pieces(of text: String) -> [String] {
        var out: [String] = []
        var piece = ""
        var count = 0
        var bytes = 0
        for ch in text {
            let size = ch.utf8.count
            guard size <= textPieceBytes else { continue }
            if count > 0, count == textPieceCharacters || bytes + size > textPieceBytes {
                out.append(piece)
                piece = ""
                count = 0
                bytes = 0
            }
            piece.append(ch)
            count += 1
            bytes += size
        }
        if !piece.isEmpty { out.append(piece) }
        return out
    }

    #if DEBUG
    /// `-checkTextPieces YES`: checks `pieces` on long and multi-byte text, into Documents/text-pieces.txt.
    static func checkPieces() {
        var lines: [String] = []
        func check(_ name: String, _ text: String, _ expected: [Int], leaving: String? = nil) {
            let p = pieces(of: text)
            let ok = p.map(\.count) == expected && p.joined() == (leaving ?? text)
                && p.allSatisfy { $0.count <= textPieceCharacters && $0.utf8.count <= textPieceBytes }
            assert(ok, "text pieces wrong for \(name)")
            lines.append("\(ok ? "ok" : "FAIL") \(name): characters \(p.map(\.count)), bytes \(p.map(\.utf8.count))")
        }
        check("short", "hello", [5])
        check("exactly 1000", String(repeating: "a", count: 1000), [1000])
        check("2500 plain", String(repeating: "abcdefghi ", count: 250), [1000, 1000, 500])
        check("2001 accented", String(repeating: "\u{E9}", count: 2001), [1000, 1000, 1])
        check("1100 family emoji", String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 1100),
              [222, 222, 222, 222, 212])
        // "e" with 2,000 combining acute accents is one character of 4,001 bytes: dropped, the rest kept in order.
        check("oversize character dropped", "ab" + "e" + String(repeating: "\u{301}", count: 2000) + "cd", [4], leaving: "abcd")
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("text-pieces.txt")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
    #endif

    func recoverVideo() {
        queue.async { self.renderer.recover() }
    }

    // MARK: Connecting (client queue)

    private func teardown() {
        pingTimer?.cancel()
        pingTimer = nil
        attempts.forEach { $0.onClosed = nil; $0.onReady = nil; $0.close() }
        attempts.removeAll()
        channel?.onClosed = nil
        channel?.onMessage = nil
        channel?.close()
        channel = nil
    }

    private func startAttempt() {
        guard wanted, let pairing else { return }
        generation += 1
        let gen = generation
        teardown()
        publish { $0.phase = .connecting; $0.latencyMs = nil }

        var endpoints: [NWEndpoint] = []
        if let port = NWEndpoint.Port(rawValue: pairing.port) {
            for host in pairing.hosts { endpoints.append(.hostPort(host: NWEndpoint.Host(host), port: port)) }
        }
        // Tests turn this off (`-noBonjour YES`, debug builds): Bonjour would find the real host on this Mac.
        #if DEBUG
        let bonjour = !UserDefaults.standard.bool(forKey: "noBonjour")
        #else
        let bonjour = true
        #endif
        if bonjour {
            endpoints.append(.service(name: pairing.name, type: Wire.bonjourType, domain: "local.", interface: nil))
        }

        var remaining = endpoints.count
        var problems: [String] = []
        for endpoint in endpoints {
            let connection = NWConnection(to: endpoint, using: Secure.parameters(key: pairing.key))
            let attempt = MessageChannel(connection: connection, queue: queue)
            attempt.onReady = { [weak self, weak attempt] in
                guard let self, let attempt, gen == self.generation, self.channel == nil else { return }
                self.adopt(attempt, gen: gen)
            }
            attempt.onClosed = { [weak self, weak attempt] reason in
                guard let self, gen == self.generation else { return }
                if let attempt, attempt === self.channel {
                    self.connectionLost(reason, gen: gen)
                    return
                }
                remaining -= 1
                problems.append(reason)
                if remaining == 0, self.channel == nil {
                    self.allAttemptsFailed(problems, gen: gen)
                }
            }
            attempts.append(attempt)
            attempt.start()
        }

        queue.asyncAfter(deadline: .now() + Self.attemptLimit) { [weak self] in
            guard let self, gen == self.generation, self.wanted, self.channel == nil, remaining > 0 else { return }
            self.attempts.forEach { $0.onClosed = nil; $0.onReady = nil; $0.close() }
            self.attempts.removeAll()
            self.allAttemptsFailed(problems + ["timed out"], gen: gen)
        }
    }

    private func adopt(_ winner: MessageChannel, gen: Int) {
        channel = winner
        for other in attempts where other !== winner {
            other.onClosed = nil
            other.onReady = nil
            other.close()
        }
        attempts = [winner]
        renderer.reset()
        winner.onMessage = { [weak self] type, payload in self?.handle(type, payload) }

        let settings = StreamSettings.current
        var hello = Hello(version: Wire.version, deviceName: UIDevice.current.name,
                          maxPixelWidth: settings.maxPixelWidth, maxPixelHeight: settings.maxPixelHeight,
                          fps: 60, bitrateMbps: settings.bitrateMbps, codec: settings.codec)
        let defaults = UserDefaults.standard
        hello.macWidth = defaults.integer(forKey: "macWidth")
        hello.audio = (defaults.object(forKey: "macSound") as? Bool ?? true) && !defaults.bool(forKey: "dataSaver")
        winner.sendJSON(.hello, hello)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 1, repeating: 2)
        timer.setEventHandler { [weak self] in
            guard let self, let channel = self.channel else { return }
            var w = ByteWriter()
            w.u64(DispatchTime.now().uptimeNanoseconds)
            channel.send(.ping, w.data)
        }
        timer.resume()
        pingTimer = timer
    }

    private func connectionLost(_ reason: String, gen: Int) {
        channel = nil
        pingTimer?.cancel()
        pingTimer = nil
        publish { $0.phase = .connecting; $0.latencyMs = nil; $0.lastProblem = nil }
        scheduleRetry(gen: gen)
    }

    private func allAttemptsFailed(_ problems: [String], gen: Int) {
        failures += 1
        let text = explain(problems)
        if failures >= 2 || problems.contains("timed out") { publish { $0.lastProblem = text } }
        scheduleRetry(gen: gen)
    }

    private func scheduleRetry(gen: Int) {
        guard wanted else { return }
        let delay = retryDelay
        retryDelay = min(retryDelay * 1.7, 3)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, gen == self.generation, self.wanted else { return }
            self.startAttempt()
        }
    }

    private func explain(_ problems: [String]) -> String {
        let all = problems.joined(separator: " ").lowercased()
        // A wrong key fails the TLS-PSK handshake's check (seen as -9820 "bad MAC").
        if all.contains("-9820") || all.contains("bad mac") {
            return "The Mac refused the pairing key. Scan the code on the Mac again."
        }
        // The host hung up during the handshake: paused (seen as error 54, reset by peer) or busy (-9816, closed).
        if all.contains("-9816") || all.contains("error 54") || all.contains("reset by peer") || all.contains("closed during handshake") {
            return "The Mac is not accepting connections. Open Clamshell Host in the Mac's menu bar and choose Resume."
        }
        if !onWiFi && !onVPN {
            return "This iPhone is off Wi-Fi. Join the Mac's Wi-Fi, or turn on Tailscale on both to connect from anywhere."
        }
        return "Can't reach the Mac. Check that it is awake, on the same Wi-Fi as this iPhone, and that Clamshell Host is running."
    }

    // MARK: Messages (client queue)

    private func handle(_ type: MsgType, _ payload: Data) {
        switch type {
        case .helloAck:
            guard let ack = try? JSONDecoder().decode(HelloAck.self, from: payload) else { return }
            retryDelay = 0.4
            failures = 0
            publish {
                $0.ack = ack
                $0.hostStatus = HostStatus(canCapture: ack.canCapture, canControl: ack.canControl)
                $0.phase = .connected
                $0.lastProblem = nil
            }
        case .videoConfig:
            guard let config = VideoConfigMsg(data: payload) else { return }
            renderer.configure(config)
        case .videoFrame:
            guard let frame = VideoFrameMsg.decode(payload) else { return }
            renderer.enqueue(payload: frame.payload, isKey: frame.isKey, ptsMicros: frame.ptsMicros)
        case .cursor:
            var r = ByteReader(payload)
            // A bad host must not crash the phone: NaN or infinity would reach the zoom's layer transform.
            guard let x = r.f32(), let y = r.f32(), x.isFinite, y.isFinite else { return }
            let p = CGPoint(x: CGFloat(min(max(x, 0), 1)), y: CGFloat(min(max(y, 0), 1)))
            DispatchQueue.main.async { self.onCursor?(p) }
        case .pong:
            var r = ByteReader(payload)
            guard let sent = r.u64() else { return }
            let ms = Int((DispatchTime.now().uptimeNanoseconds &- sent) / 1_000_000)
            publish { $0.latencyMs = ms }
        case .audio:
            audio.play(payload)
        case .status:
            guard let status = try? JSONDecoder().decode(HostStatus.self, from: payload) else { return }
            publish { $0.hostStatus = status }
        default:
            break
        }
    }

    private func publish(_ change: @escaping (Client) -> Void) {
        DispatchQueue.main.async { change(self) }
    }
}

/// Phase, last problem, the Mac's handshake and its permissions, as the session screen shows them.
typealias LinkState = (phase: Client.Phase, problem: String?, ack: HelloAck?, status: HostStatus?)

/// What the session screen drives: the real Mac (`Client`) or the demo's pretend one (`DemoMac`).
/// Everything the session reads or calls goes through this; the paired path is `Client` unchanged.
protocol MacLink: AnyObject {
    var phase: Client.Phase { get }
    var latencyMs: Int? { get }
    /// Normalized Mac cursor position, delivered on the main thread.
    var onCursor: ((CGPoint) -> Void)? { get set }
    /// Delivers the current state, then every change.
    var linkState: AnyPublisher<LinkState, Never> { get }
    func send(_ event: InputEvent)
    func send(_ events: [InputEvent])
    func setDisplay(width: Int)
    func sendDeviceInfo(_ text: String)
    func reconnect()
    func recoverVideo()
}

extension Client: MacLink {
    var linkState: AnyPublisher<LinkState, Never> {
        $phase.combineLatest($lastProblem, $ack, $hostStatus)
            .map { (phase: $0, problem: $1, ack: $2, status: $3) }
            .eraseToAnyPublisher()
    }
}

/// How sharp and how heavy the stream is. Stored on the phone.
struct StreamSettings {
    var maxPixelWidth: Int
    var maxPixelHeight: Int
    var bitrateMbps: Double
    var codec: String

    static var current: StreamSettings {
        let d = UserDefaults.standard
        let saver = d.bool(forKey: "dataSaver")
        let codec = d.string(forKey: "codec") ?? "hevc"
        return saver
            ? StreamSettings(maxPixelWidth: 1600, maxPixelHeight: 1040, bitrateMbps: 5, codec: codec)
            : StreamSettings(maxPixelWidth: 2880, maxPixelHeight: 1864, bitrateMbps: 20, codec: codec)
    }
}
