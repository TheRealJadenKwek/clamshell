import Foundation
import Network
import Security

/// TLS 1.2 with a pre-shared key: the link is encrypted and only a device holding
/// the pairing key can complete the handshake. No certificates, no accounts.
enum Secure {
    /// In order of preference. ECDHE-PSK mixes a fresh key exchange into every session (forward secrecy);
    /// plain PSK stays after it so a new build still connects to an old one that offers only that.
    static let cipherSuites: [UInt16] = [
        UInt16(TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256), // 0xCCAC
        UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256),             // 0x00A8, what builds before forward secrecy offer
    ]

    static func parameters(key: Data, cipherSuites: [UInt16] = Secure.cipherSuites) -> NWParameters {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        let keyData = key.withUnsafeBytes { DispatchData(bytes: $0) }
        let identity = Data(Wire.pskIdentity.utf8).withUnsafeBytes { DispatchData(bytes: $0) }
        sec_protocol_options_add_pre_shared_key(sec, keyData as __DispatchData, identity as __DispatchData)
        for raw in cipherSuites {
            if let suite = tls_ciphersuite_t(rawValue: raw) { sec_protocol_options_append_tls_ciphersuite(sec, suite) }
        }
        // Every connection proves the key again. A resumed session skips that: after New key, a phone holding
        // the old key could resume an earlier session (the cache outlives the listener), and it would skip the
        // fresh key exchange too.
        sec_protocol_options_set_tls_resumption_enabled(sec, false)
        sec_protocol_options_set_tls_tickets_enabled(sec, false)
        sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
        sec_protocol_options_set_max_tls_protocol_version(sec, .TLSv12)

        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 5
        tcp.keepaliveInterval = 2
        tcp.keepaliveCount = 3
        tcp.connectionTimeout = 8

        let params = NWParameters(tls: tls, tcp: tcp)
        params.serviceClass = .interactiveVideo
        return params
    }
}

/// Length-prefixed messages over one NWConnection. All callbacks arrive on `queue`.
final class MessageChannel {
    let connection: NWConnection
    let queue: DispatchQueue
    var onMessage: ((MsgType, Data) -> Void)?
    var onReady: (() -> Void)?
    var onClosed: ((String) -> Void)?
    /// A message announcing more than this ends the connection. The host lowers it for what a phone sends.
    var maxIncomingBytes = Wire.maxMessageBytes

    /// Video frames handed to the network and not yet written. Used to drop frames
    /// instead of queueing them when the link is slower than the screen.
    private(set) var framesInFlight = 0
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onReady?()
                self.readHeader()
            case .failed(let error):
                self.finish("failed: \(error.localizedDescription)")
            case .waiting(let error):
                // A wrong key shows up here as a TLS error; do not wait forever.
                self.finish("waiting: \(error.localizedDescription)")
            case .cancelled:
                self.finish("cancelled")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func send(_ type: MsgType, _ payload: Data = Data(), countsAsFrame: Bool = false) {
        guard !closed else { return }
        var header = Data(capacity: 5)
        header.append(type.rawValue)
        withUnsafeBytes(of: UInt32(payload.count).bigEndian) { header.append(contentsOf: $0) }
        if countsAsFrame { framesInFlight += 1 }
        connection.send(content: header + payload, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if countsAsFrame { self.framesInFlight -= 1 }
            if let error { self.finish("send: \(error.localizedDescription)") }
        })
    }

    func sendJSON<T: Encodable>(_ type: MsgType, _ value: T) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        send(type, data)
    }

    func close() {
        guard !closed else { return }
        connection.cancel()
    }

    private func finish(_ reason: String) {
        guard !closed else { return }
        closed = true
        connection.stateUpdateHandler = nil
        connection.cancel()
        onClosed?(reason)
    }

    private func readHeader() {
        connection.receive(minimumIncompleteLength: 5, maximumLength: 5) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, data.count == 5, error == nil else {
                self.finish(error.map { "receive: \($0.localizedDescription)" } ?? "closed by peer")
                return
            }
            let typeByte = data[data.startIndex]
            let length = data.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
            guard length <= self.maxIncomingBytes else {
                self.finish("oversized message")
                return
            }
            if length == 0 {
                self.deliver(typeByte, Data())
                if isComplete { self.finish("closed by peer") } else { self.readHeader() }
            } else {
                self.readBody(typeByte, length)
            }
        }
    }

    private func readBody(_ typeByte: UInt8, _ length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            guard let data, data.count == length, error == nil else {
                self.finish(error.map { "receive: \($0.localizedDescription)" } ?? "closed by peer")
                return
            }
            self.deliver(typeByte, data)
            if isComplete { self.finish("closed by peer") } else { self.readHeader() }
        }
    }

    private func deliver(_ typeByte: UInt8, _ payload: Data) {
        guard let type = MsgType(rawValue: typeByte) else { return } // unknown types are skipped
        onMessage?(type, payload)
    }
}
