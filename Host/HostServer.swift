import Foundation
import Network
import CoreMedia
import CoreVideo
import Combine
import ServiceManagement

struct HostOptions {
    var port: UInt16 = Wire.defaultPort
    var testPattern = false   // never capture the real screen or sound
    var dryRun = false        // never post real input or change the display size
    var printLink = false

    /// A test host never reads or writes the real pairing key and may print its own throwaway one.
    /// Either flag makes a full test host (both set), so a second copy started with one of them can never
    /// reach the real screen or post input under this app's permissions.
    var isTestHost: Bool { testPattern || dryRun }

    static func fromCommandLine() -> HostOptions {
        var o = HostOptions()
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let a = args.next() {
            switch a {
            case "--test-pattern", "--dry-run": o.testPattern = true; o.dryRun = true
            case "--print-link": o.printLink = true
            case "--port": if let v = args.next(), let p = UInt16(v) { o.port = p }
            default: break
            }
        }
        return o
    }
}

/// What the host holds open, reachable from any thread: Disconnect and New key cut connections here at once,
/// even while the server queue is busy, and a paused host refuses new ones before they reach the queue.
final class ConnectionGate {
    private let lock = NSLock()
    private var paused = false
    private var connections: [ObjectIdentifier: (connection: NWConnection, stop: StopFlag)] = [:]

    var isPaused: Bool {
        lock.lock(); defer { lock.unlock() }
        return paused
    }

    func setPaused(_ value: Bool) {
        lock.lock(); defer { lock.unlock() }
        paused = value
    }

    func add(_ connection: NWConnection, stop: StopFlag) {
        lock.lock(); defer { lock.unlock() }
        connections[ObjectIdentifier(connection)] = (connection, stop)
    }

    func remove(_ connection: NWConnection) {
        lock.lock(); defer { lock.unlock() }
        connections[ObjectIdentifier(connection)] = nil
    }

    func cancelAll() {
        lock.lock()
        let all = Array(connections.values)
        lock.unlock()
        for entry in all {
            entry.stop.set()
            entry.connection.cancel()
        }
    }
}

/// Listens for the paired phone and runs one session at a time.
final class HostServer: ObservableObject {
    static let shared = HostServer(options: .fromCommandLine())

    /// Connections still in the handshake or not yet greeted, at most, and how long one may take.
    static let maxConnecting = 8
    static let greetingDeadline: TimeInterval = 5

    @Published private(set) var clientName: String?
    @Published private(set) var listening = false
    @Published private(set) var lastError: String?
    /// nil while there is no usable key; the host does not listen then.
    @Published private(set) var pairing: Pairing?
    /// Why there is no key, or why New key could not save one.
    @Published private(set) var keyProblem: String?
    /// After Disconnect: no phone gets in until Resume, or until the host is opened again.
    @Published private(set) var paused = false
    @Published private(set) var canCapture = Permissions.canCapture
    @Published private(set) var canControl = Permissions.canControl

    let options: HostOptions
    private let queue = DispatchQueue(label: "clamshell.server", qos: .userInteractive)
    private let gate = ConnectionGate()
    private var listener: NWListener?
    private var session: Session?
    private var pending: [Session] = []
    /// Main thread only. The listener uses its own copy, `listenerKey`, on the server queue.
    private var key: Data?
    private var listenerKey: Data?
    /// Server queue only. Goes up with every New key; connections and sessions from an older one are refused.
    private var keyGeneration = 0
    private var permissionTimer: Timer?
    private var signalSources: [DispatchSourceSignal] = []
    private var refusedFull = LogLimiter(perSecond: 1)
    private var refusedPaused = LogLimiter(perSecond: 1)
    private var refusedStale = LogLimiter(perSecond: 1)

    /// A remote control is no use if the host is not running after a restart, so the real host adds itself
    /// to Login Items the first time. Once only: the panel's "Open at login" box turns it off for good.
    private static func openAtLoginOnce() {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "loginItemOffered") {
            defaults.set(true, forKey: "loginItemOffered")
            if SMAppService.mainApp.status != .enabled {
                do { try SMAppService.mainApp.register() } catch { log("open at login: could not turn on: \(error.localizedDescription)") }
            }
        }
        log("open at login: \(SMAppService.mainApp.status == .enabled ? "on" : "off")")
    }

    init(options: HostOptions) {
        self.options = options
        // Set before any phone can ask for a size, and never cleared: a test host only pretends.
        DisplayScale.simulate = options.dryRun
        Power.simulate = options.dryRun
        if options.isTestHost {
            // A throwaway key, new on every launch: a test host never touches the real one in either store.
            key = KeyStore.randomKey()
            if key == nil { keyProblem = "Could not make a pairing key: the system random source failed." }
        } else {
            if options.printLink { log("--print-link ignored: only a test host (--dry-run or --test-pattern) prints its pairing link") }
            switch KeyStore.load() {
            case .success(let stored): key = stored
            case .failure(let error): keyProblem = error.message
            }
        }
        if let keyProblem { log("pairing key: \(keyProblem)") }
        pairing = key.map { HostServer.makePairing(key: $0, port: options.port) }
        if let key {
            startListener(key: key)
        } else {
            lastError = "No pairing key, so not listening"
        }
        if options.printLink, options.isTestHost, let pairing { print(pairing.url.absoluteString); fflush(stdout) }
        if !options.isTestHost { HostServer.openAtLoginOnce() }
        if options.isTestHost { installTestSignals() }
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            let capture = Permissions.canCapture, control = Permissions.canControl
            if capture != self.canCapture { self.canCapture = capture }
            if control != self.canControl { self.canControl = control }
            guard let key = self.key else { return }
            let fresh = HostServer.makePairing(key: key, port: self.options.port)
            if fresh != self.pairing { self.pairing = fresh }
        }
    }

    /// Test hosts only, which show no menu bar icon: SIGUSR1 runs the panel's Disconnect, SIGUSR2 its Resume and
    /// SIGHUP its New key (a throwaway key, printed with --print-link), the same code the buttons call, so a
    /// script can check them.
    private func installTestSignals() {
        let actions: [(Int32, () -> Void)] = [
            (SIGUSR1, { [weak self] in self?.disconnectClient() }),
            (SIGUSR2, { [weak self] in self?.resumeConnections() }),
            (SIGHUP, { [weak self] in self?.resetKey() }),
        ]
        for (number, action) in actions {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler(handler: action)
            source.resume()
            signalSources.append(source)
        }
    }

    private static func makePairing(key: Data, port: UInt16) -> Pairing {
        let name = MacName.current
        return Pairing(name: name, hosts: Addresses.candidates(), port: port, key: key)
    }

    private var restoreTicket = 0

    /// A reconnect keeps the chosen size. Only when no phone comes back does the Mac return to normal:
    /// a second after the phone hangs up, a little longer after a dropped link, which usually redials.
    private func scheduleDisplayRestore(after delay: Double, waits: Int = 0) {
        restoreTicket += 1
        let ticket = restoreTicket
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, ticket == self.restoreTicket, self.session == nil else { return }
            // A phone is part way through connecting: let it land before deciding.
            if !self.pending.isEmpty, waits < 6 {
                self.scheduleDisplayRestore(after: 0.5, waits: waits + 1)
                return
            }
            DisplayScale.restore()
        }
    }

    /// New key, from the panel. If the new key cannot be saved, the old one keeps working and the panel says so.
    func resetKey() {
        guard let fresh = KeyStore.randomKey() else {
            keyProblem = "Could not make a new key: the system random source failed." + (key == nil ? "" : " Still using the old key.")
            log("pairing key: \(keyProblem!)")
            return
        }
        if !options.isTestHost, case .failure(let error) = KeyStore.save(fresh) {
            keyProblem = "Could not save a new key: \(error.message)" + (key == nil ? "" : " Still using the old key.")
            log("pairing key: \(keyProblem!)")
            return
        }
        log("pairing key: replaced; every paired phone must scan the new code")
        key = fresh
        keyProblem = nil
        pairing = HostServer.makePairing(key: fresh, port: options.port)
        if options.printLink, options.isTestHost, let pairing { print(pairing.url.absoluteString); fflush(stdout) }
        if lastError == "No pairing key, so not listening" { lastError = nil }
        gate.cancelAll()
        queue.async {
            // From here on, nothing the old listener hands over is accepted, and no session it started can greet.
            self.keyGeneration += 1
            self.listenerKey = fresh
            self.endAll("pairing key was reset")
            self.listener?.cancel()
            self.listener = nil
        }
        queue.asyncAfter(deadline: .now() + 0.5) { if self.listener == nil { self.startListenerOnQueue() } }
    }

    /// Disconnect, from the panel: ends the session now, even part way through typing, and refuses phones until Resume.
    func disconnectClient() {
        gate.setPaused(true)
        paused = true
        gate.cancelAll()
        log("disconnected from the Mac; connections paused")
        queue.async { self.endAll("disconnected from the Mac") }
    }

    func resumeConnections() {
        gate.setPaused(false)
        paused = false
        log("connections resumed")
    }

    private func endAll(_ reason: String) {
        session?.end(reason)
        session = nil
        pending.forEach { $0.end(reason) }
        pending.removeAll()
    }

    private func startListener(key: Data) {
        queue.async {
            self.listenerKey = key
            self.startListenerOnQueue()
        }
    }

    private func startListenerOnQueue() {
        guard let key = listenerKey else { return }
        let generation = keyGeneration
        let params = Secure.parameters(key: key)
        params.allowLocalEndpointReuse = true
        guard let port = NWEndpoint.Port(rawValue: options.port),
              let listener = try? NWListener(using: params, on: port) else {
            publish { $0.lastError = "Could not listen on port \(self.options.port)"; $0.listening = false }
            return
        }
        listener.service = NWListener.Service(type: Wire.bonjourType)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                log("listening on port \(self.options.port)")
                self.publish { $0.listening = true; $0.lastError = nil }
            case .failed(let error):
                log("listener failed: \(error)")
                self.publish { $0.listening = false; $0.lastError = error.localizedDescription }
                self.listener?.cancel()
                self.listener = nil
                self.queue.asyncAfter(deadline: .now() + 3) { if self.listener == nil { self.startListenerOnQueue() } }
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection, generation: generation)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    private func accept(_ connection: NWConnection, generation: Int) {
        // A listener for a key that New key replaced may still hand over a connection it had queued.
        guard generation == keyGeneration else {
            connection.cancel()
            refusedStale.write("refused a connection from the listener of a replaced key")
            return
        }
        if gate.isPaused {
            connection.cancel()
            refusedPaused.write("refused a connection: paused")
            return
        }
        // Each connection that has not said hello yet costs a handshake; a flood of them must not crowd out the phone's
        // session, which is never counted here.
        // When full, the one that has waited longest goes: idle connections are stale, and the phone is the newest.
        if pending.count >= Self.maxConnecting {
            let oldest = pending.removeFirst()
            oldest.end("made room for a newer connection")
            refusedFull.write("dropped the oldest waiting connection: \(Self.maxConnecting) were already connecting")
        }
        // A connection only becomes the session once it says hello. The phone dials
        // several addresses at once and keeps one, so the others must not disturb it.
        let candidate = Session(connection: connection, queue: queue, options: options, gate: gate)
        candidate.onHello = { [weak self, weak candidate] name in
            guard let self, let candidate else { return }
            self.pending.removeAll { $0 === candidate }
            guard generation == self.keyGeneration else {
                candidate.end("pairing key was reset")
                log("refused a session that used a replaced key")
                return
            }
            // The newest phone wins; an old session never blocks a reconnect.
            let old = self.session
            self.session = candidate
            old?.end("replaced by a new connection")
            log("connected: \(name)")
            self.publish { $0.clientName = name }
        }
        candidate.onEnded = { [weak self] ended, reason in
            guard let self else { return }
            self.pending.removeAll { $0 === ended }
            if self.session === ended {
                self.scheduleDisplayRestore(after: reason == "closed by peer" ? 1 : 4)
                log("session ended: \(reason)")
                self.session = nil
                self.publish { $0.clientName = nil }
            }
        }
        pending.append(candidate)
        candidate.start()
    }

    private func publish(_ change: @escaping (HostServer) -> Void) {
        DispatchQueue.main.async { change(self) }
    }
}

/// One connected phone: capture, encode, send; receive input, inject.
final class Session {
    var onHello: ((String) -> Void)?
    var onEnded: ((Session, String) -> Void)?

    private let channel: MessageChannel
    private let connection: NWConnection
    private let gate: ConnectionGate
    private let queue: DispatchQueue
    private let options: HostOptions
    private var display = DisplayInfo.main()
    private var wantsAudio = false
    private var codecName = "hevc"
    private let injector: InputInjector
    private var source: FrameSource?
    private var pattern: TestPatternSource?
    private var usingRealCapture = false
    private var encoder: VideoEncoder?
    private var streamSize = (width: 0, height: 0)
    private var fps = 60
    private var needsKeyframe = true
    private var lastBuffer: CVPixelBuffer?
    private var pendingBuffer: CVPixelBuffer?
    private var lastEncode: TimeInterval = 0
    private var timer: DispatchSourceTimer?
    private var lastCursor = CGPoint(x: -1, y: -1)
    private var lastStatus: HostStatus?
    private var ticks = 0
    /// What the stream did since the last report, to tell a busy Mac from a slow link when it lags.
    private var stats = StreamStats()
    private var ended = false
    private var greeted = false
    private var deviceInfoLog = LogLimiter(perSecond: 5)
    private let epoch = ProcessInfo.processInfo.systemUptime

    init(connection: NWConnection, queue: DispatchQueue, options: HostOptions, gate: ConnectionGate) {
        self.queue = queue
        self.options = options
        self.connection = connection
        self.gate = gate
        let stop = StopFlag()
        gate.add(connection, stop: stop)
        channel = MessageChannel(connection: connection, queue: queue)
        // Video goes the other way; nothing a phone sends needs more than this.
        channel.maxIncomingBytes = Wire.maxPhoneMessageBytes
        injector = InputInjector(display: display, queue: queue, stop: stop)
        injector.dryRun = options.dryRun
    }

    func start() {
        channel.onMessage = { [weak self] type, payload in self?.handle(type, payload) }
        channel.onClosed = { [weak self] reason in self?.end(reason) }
        channel.start()
        // A connection that never says hello is dropped.
        queue.asyncAfter(deadline: .now() + HostServer.greetingDeadline) { [weak self] in
            guard let self, !self.greeted else { return }
            self.end("no hello")
        }
    }

    func end(_ reason: String) {
        guard !ended else { return }
        ended = true
        if let line = stats.flush(now: ProcessInfo.processInfo.systemUptime) { log(line) }
        timer?.cancel()
        timer = nil
        source?.stop()
        source = nil
        pattern = nil
        encoder?.invalidate()
        encoder = nil
        lastBuffer = nil
        pendingBuffer = nil
        injector.releaseAll()
        if greeted { Power.holdAwake(false) }
        channel.close()
        gate.remove(connection)
        onEnded?(self, reason)
    }

    private func handle(_ type: MsgType, _ payload: Data) {
        switch type {
        case .hello:
            guard !greeted, let hello = try? JSONDecoder().decode(Hello.self, from: payload) else { return }
            greeted = true
            onHello?(String(hello.deviceName.prefix(64)))
            guard !ended else { return } // refused on hello (a replaced key)
            greet(hello)
        case .input:
            // A text event can be as long as a message (64 KB); the injector paces it and caps what waits.
            guard greeted, let event = InputEvent(data: payload) else { return }
            injector.handle(event)
        case .requestKeyframe:
            needsKeyframe = true
        case .deviceInfo:
            deviceInfoLog.write("phone: \(String(decoding: payload.prefix(Wire.maxDeviceInfoBytes), as: UTF8.self))")
        case .setDisplay:
            var r = ByteReader(payload)
            guard greeted, let width = r.u16() else { return }
            changeDisplay(to: Int(width))
        case .ping:
            channel.send(.pong, payload)
        default:
            break
        }
    }

    private func greet(_ hello: Hello) {
        DisplayScale.simulate = options.dryRun
        Power.simulate = options.dryRun
        if let width = hello.macWidth { DisplayScale.apply(width: width) } else { DisplayScale.apply(step: hello.macScale ?? 0) }
        display = DisplayInfo.main()
        injector.display = display
        wantsAudio = hello.audio == true
        let codec = VideoCodec(name: hello.codec)
        codecName = codec.name
        let size = display.streamSize(maxWidth: hello.maxPixelWidth, maxHeight: hello.maxPixelHeight)
        streamSize = (size.0, size.1)
        fps = min(max(hello.fps, 15), 60)
        let mbps = hello.bitrateMbps.isFinite ? min(max(hello.bitrateMbps, 1), 80) : 20
        let bitrate = Int(mbps * 1_000_000)
        do {
            encoder = try VideoEncoder(width: Int32(size.0), height: Int32(size.1), codec: codec, bitrate: bitrate, fps: fps) { [weak self] frame in
                guard let self else { return }
                self.queue.async { self.send(frame) }
            }
        } catch {
            end("encoder: \(error.localizedDescription)")
            return
        }

        let real = !options.testPattern && Permissions.canCapture
        sendAck()

        if real { startRealCapture() } else {
            startPattern(note: options.testPattern ? "waiting for input"
                         : "Screen Recording is off on the Mac. Allow Clamshell Host in System Settings.")
        }
        Power.wakeDisplay()
        Power.holdAwake(true)

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.05, repeating: 1.0 / 60.0)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        self.timer = timer
    }

    private func sendAck() {
        let status = HostStatus(canCapture: Permissions.canCapture, canControl: options.dryRun || Permissions.canControl)
        lastStatus = status
        let choices = DisplayScale.choices()
        channel.sendJSON(.helloAck, HelloAck(version: Wire.version,
                                             hostName: MacName.current,
                                             displayPointWidth: display.bounds.width, displayPointHeight: display.bounds.height,
                                             streamWidth: streamSize.width, streamHeight: streamSize.height, codec: codecName,
                                             canCapture: status.canCapture, canControl: status.canControl,
                                             testPattern: options.testPattern,
                                             displayWidths: choices.widths, displayBaseWidth: choices.base, displayNowWidth: choices.now))
    }

    /// A new size from the phone's Display panel, without dropping the session.
    private func changeDisplay(to width: Int) {
        DisplayScale.apply(width: width)
        display = DisplayInfo.main()
        injector.display = display
        sendAck()
        if usingRealCapture { startRealCapture() }
    }

    private func startRealCapture() {
        source?.stop()
        pattern = nil
        let screen = ScreenSource(display: display, width: streamSize.width, height: streamSize.height, fps: fps, captureAudio: wantsAudio)
        screen.onAudio = { [weak self] pcm in
            guard let self else { return }
            self.queue.async {
                guard !self.ended, self.channel.framesInFlight <= 8 else { return }
                self.channel.send(.audio, pcm)
            }
        }
        screen.onFrame = { [weak self] buffer, _ in
            guard let self else { return }
            self.queue.async { self.frameArrived(buffer) }
        }
        screen.onStopped = { [weak self, weak screen] reason in
            guard let self else { return }
            self.queue.async {
                // A capture that was replaced must not take the new one down with it.
                guard !self.ended, self.usingRealCapture, let screen, self.source === screen else { return }
                log("capture stopped: \(reason)")
                self.usingRealCapture = false
                self.startPattern(note: "Screen capture stopped: \(reason)")
            }
        }
        source = screen
        usingRealCapture = true
        needsKeyframe = true
        Task { [weak self] in
            do {
                try await screen.start()
            } catch {
                guard let self else { return }
                self.queue.async { [weak screen] in
                    guard !self.ended, let screen, self.source === screen else { return }
                    log("capture failed: \(error.localizedDescription)")
                    self.usingRealCapture = false
                    self.startPattern(note: "Could not capture the screen: \(error.localizedDescription)")
                }
            }
        }
    }

    private func startPattern(note: String) {
        source?.stop()
        let p = TestPatternSource(width: streamSize.width, height: streamSize.height, fps: options.testPattern ? min(fps, 30) : 2)
        p.note = note
        p.plain = !options.testPattern
        p.onFrame = { [weak self] buffer, _ in
            guard let self else { return }
            self.queue.async { self.frameArrived(buffer) }
        }
        if options.testPattern {
            injector.onEvent = { [weak self, weak p] text in
                log("input: \(text)")
                p?.note = text
                if let self { p?.cursor = self.injector.cursorPosition() }
            }
        }
        pattern = p
        source = p
        usingRealCapture = false
        needsKeyframe = true
        Task { try? await p.start() }
    }

    private func frameArrived(_ buffer: CVPixelBuffer) {
        guard !ended else { return }
        lastBuffer = buffer
        stats.captured += 1
        stats.maxInFlight = max(stats.maxInFlight, channel.framesInFlight)
        // The link is behind: keep only the newest frame and send it once the queue drains.
        if channel.framesInFlight > 3 {
            stats.held += 1
            pendingBuffer = buffer
            return
        }
        pendingBuffer = nil
        encode(buffer)
    }

    private func encode(_ buffer: CVPixelBuffer) {
        guard let encoder else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let pts = CMTime(seconds: now - epoch, preferredTimescale: 1_000_000)
        encoder.encode(buffer, pts: pts, forceKeyframe: needsKeyframe)
        needsKeyframe = false
        lastEncode = now
    }

    private func send(_ frame: EncodedFrame) {
        guard !ended else { return }
        stats.sent += 1
        stats.bytes += frame.payload.count
        if frame.isKey, let sets = frame.parameterSets, !sets.isEmpty {
            channel.send(.videoConfig, VideoConfigMsg(codec: frame.codec, parameterSets: sets).encoded())
        }
        channel.send(.videoFrame, VideoFrameMsg.encode(isKey: frame.isKey, ptsMicros: frame.ptsMicros, payload: frame.payload), countsAsFrame: true)
    }

    private func tick() {
        guard !ended else { return }
        ticks += 1
        let cursor = injector.cursorPosition()
        if abs(cursor.x - lastCursor.x) > 0.0004 || abs(cursor.y - lastCursor.y) > 0.0004 {
            lastCursor = cursor
            var w = ByteWriter()
            w.f32(Float(cursor.x))
            w.f32(Float(cursor.y))
            channel.send(.cursor, w.data)
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let line = stats.tick(now: now) { log(line) }
        if let pending = pendingBuffer, channel.framesInFlight <= 1 {
            pendingBuffer = nil
            encode(pending)
        } else if needsKeyframe, let last = lastBuffer, now - lastEncode > 0.05, channel.framesInFlight <= 3 {
            // A still screen sends no frames, so answer a key frame request from the last one.
            encode(last)
        }

        if ticks % 120 == 0 {
            let status = HostStatus(canCapture: Permissions.canCapture, canControl: options.dryRun || Permissions.canControl)
            if status.canCapture != lastStatus?.canCapture || status.canControl != lastStatus?.canControl {
                lastStatus = status
                channel.sendJSON(.status, status)
            }
            if !usingRealCapture, !options.testPattern, status.canCapture {
                startRealCapture()
            }
        }
    }
}

/// Counts what the stream did, and reports it every 10 seconds while the screen is changing.
///
/// Read it like this when a session lags: few frames captured with a late timer or a high load is the Mac
/// being busy; frames held back with many in flight is the link being slower than the screen; neither is
/// the phone.
struct StreamStats {
    var captured = 0
    var sent = 0
    var held = 0
    var bytes = 0
    var maxInFlight = 0
    private var maxLate: TimeInterval = 0
    private var lastTick: TimeInterval = 0
    private var since: TimeInterval = 0

    static let period: TimeInterval = 10
    /// The session's timer runs 60 times a second.
    static let tickInterval: TimeInterval = 1.0 / 60.0

    /// Call on every timer tick. Returns a line to log when a period with frames in it has ended.
    mutating func tick(now: TimeInterval) -> String? {
        if lastTick > 0 { maxLate = max(maxLate, now - lastTick - Self.tickInterval) }
        lastTick = now
        if since == 0 { since = now }
        guard now - since >= Self.period else { return nil }
        return flush(now: now)
    }

    /// The line for the period so far, and a fresh start. Also called when the session ends, so the last
    /// seconds before a hang-up are not lost: that is when a lag is at its worst.
    mutating func flush(now: TimeInterval) -> String? {
        let span = now - since
        defer { self = StreamStats(); lastTick = now; since = now }
        guard captured > 0, since > 0, span >= 1 else { return nil }
        var load = [Double](repeating: 0, count: 1)
        let haveLoad = getloadavg(&load, 1) == 1
        return String(format: "stream: %.0fs, captured %d, sent %d, held %d, in flight max %d, %.1f Mbps, timer late max %.0f ms, load %@",
                      span, captured, sent, held, maxInFlight, Double(bytes) * 8 / span / 1_000_000,
                      max(maxLate, 0) * 1000, haveLoad ? String(format: "%.0f", load[0]) : "?")
    }
}
