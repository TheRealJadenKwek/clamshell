import Foundation
import IOKit.pwr_mgt
import CoreGraphics
import AppKit
import ApplicationServices
import CoreImage
import CoreImage.CIFilterBuiltins
import SystemConfiguration

enum Power {
    private static var assertion: IOPMAssertionID = 0
    /// Test hosts leave the display alone: a test must never light a monitor or keep it lit.
    static var simulate = false

    /// Keeps the display on while a phone is connected, since a sleeping display has nothing to show.
    static func holdAwake(_ hold: Bool) {
        if simulate { return }
        if hold, assertion == 0 {
            IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                        IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                        "Clamshell: a phone is connected" as CFString, &assertion)
        } else if !hold, assertion != 0 {
            IOPMAssertionRelease(assertion)
            assertion = 0
        }
    }

    static func wakeDisplay() {
        if simulate { return }
        var id: IOPMAssertionID = 0
        IOPMAssertionDeclareUserActivity("Clamshell: phone connected" as CFString, kIOPMUserActiveLocal, &id)
    }

    /// A phone connected while the display slept. Server queue only.
    private(set) static var foundAsleep = false
    /// How long after the last phone left the display goes back to sleep. Long enough that a quick trip
    /// to another app on the phone does not cost a display wake on the way back.
    static let sleepAgainDelay: TimeInterval = 30

    /// Call when a phone connects, before anything wakes the display.
    static func noteDisplay() {
        if CGDisplayIsAsleep(CGMainDisplayID()) != 0 { foundAsleep = true }
    }

    /// Puts the display back to sleep for a phone that found it asleep. `idleFor` is how long ago the last
    /// phone left: any key, click or scroll since then came from someone at the Mac, and the display stays on.
    /// Off switch: `defaults write com.jadenkwek.clamshell.host sleepDisplayAfterPhone -bool false`.
    static func sleepAgain(idleFor: TimeInterval) {
        guard foundAsleep else { return }
        foundAsleep = false
        guard UserDefaults.standard.object(forKey: "sleepDisplayAfterPhone") as? Bool ?? true else { return }
        // Pointer movement is left out on purpose: a mouse that drifts on its own would count as someone there.
        let kinds: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let last = kinds.map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }.min() ?? .infinity
        if last < idleFor {
            log("display: left on, the Mac was used after the phone left")
            return
        }
        if simulate {
            log("display: would sleep again")
            return
        }
        let pmset = Process()
        pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        pmset.arguments = ["displaysleepnow"]
        do {
            try pmset.run()
            log("display: asleep again, as the phone found it")
        } catch {
            log("display: could not sleep again: \(error.localizedDescription)")
        }
    }
}

enum Permissions {
    static var canCapture: Bool { CGPreflightScreenCaptureAccess() }
    static var canControl: Bool { AXIsProcessTrusted() }

    static func requestCapture() {
        if !CGRequestScreenCaptureAccess() {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        }
    }

    static func requestControl() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        }
    }

    private static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
}

/// Where the real host keeps its pairing key: a generic password in the login Keychain, which only
/// this app can read without asking. The file is where hosts before 1.0 kept it; it is read only to
/// move a key into an empty Keychain, and then deleted.
struct KeyLocation {
    var service: String
    var account: String
    var fileURL: URL

    /// A development build has its own item, so it never shares (or replaces) the released host's key.
    #if DEBUG
    static let realService = "com.jadenkwek.clamshell.host.pairing.debug"
    #else
    static let realService = "com.jadenkwek.clamshell.host.pairing"
    #endif

    static var real: KeyLocation {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return KeyLocation(service: realService, account: "pairing-key",
                           fileURL: base.appendingPathComponent("Clamshell", isDirectory: true).appendingPathComponent("pairing.key"))
    }
}

struct KeyStoreError: Error {
    let message: String
}

/// The pairing key. Never logged, never printed by the real host.
enum KeyStore {
    static let keyLength = 32

    static let unavailable = KeyStoreError(message: "Could not read the pairing key from the Keychain. Quit and reopen Clamshell Host. If it keeps happening, click New key, then pair your iPhone again.")

    /// A fresh random key, or nil when the system's random source fails. Never a weak key.
    static func randomKey() -> Data? {
        var bytes = [UInt8](repeating: 0, count: keyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    /// The key in the Keychain. Only when the Keychain has no item is a key file from an older host moved in
    /// (stored, read back, then the file deleted), or else a new key made. A file never replaces an item: if both
    /// exist, the item is used and the file deleted. Any other Keychain failure fails closed, with no new key.
    static func load(_ at: KeyLocation = .real) -> Result<Data, KeyStoreError> {
        switch readKeychain(at) {
        case .found(let key):
            if FileManager.default.fileExists(atPath: at.fileURL.path) {
                log(removeFile(at) ? "pairing key: deleted a stray key file; the key in the Keychain is the one in use"
                                   : "pairing key: a stray key file could not be deleted; the key in the Keychain is the one in use")
            }
            return .success(key)
        case .notFound:
            if let fileKey = readFile(at) {
                if case .failure(let error) = writeKeychain(fileKey, at) {
                    log("pairing key: the Keychain would not take the key from the key file (\(error.message)); the file stays for the next try")
                    return .failure(unavailable)
                }
                log(removeFile(at) ? "pairing key: moved from the key file into the Keychain"
                                   : "pairing key: moved into the Keychain, but the old key file could not be deleted")
                return .success(fileKey)
            }
            guard let key = randomKey() else {
                return .failure(KeyStoreError(message: "Could not make a pairing key: the system random source failed."))
            }
            if case .failure(let error) = writeKeychain(key, at) {
                log("pairing key: the Keychain would not store a new key (\(error.message))")
                return .failure(unavailable)
            }
            return .success(key)
        case .failed(let status):
            // Not "none there": making a new key now would unpair the phone for a passing Keychain problem.
            log("pairing key: could not read it from the Keychain (error \(status))")
            return .failure(unavailable)
        }
    }

    /// New key: replaces the item in the Keychain. On failure nothing changed and the caller keeps the old key.
    static func save(_ key: Data, _ at: KeyLocation = .real) -> Result<Void, KeyStoreError> {
        if case .failure(let error) = writeKeychain(key, at) {
            return .failure(KeyStoreError(message: "the Keychain would not store it (\(error.message))."))
        }
        if FileManager.default.fileExists(atPath: at.fileURL.path), !removeFile(at) {
            log("pairing key: a stray key file could not be deleted; the key in the Keychain is the one in use")
        }
        return .success(())
    }

    // MARK: Keychain

    enum KeychainRead {
        case found(Data)
        case notFound
        case failed(OSStatus)
    }

    private static func query(_ at: KeyLocation) -> [CFString: Any] {
        [kSecClass: kSecClassGenericPassword,
         kSecAttrService: at.service,
         kSecAttrAccount: at.account,
         kSecUseDataProtectionKeychain: false]
    }

    static func readKeychain(_ at: KeyLocation) -> KeychainRead {
        var q = query(at)
        q[kSecReturnData] = true
        q[kSecMatchLimit] = kSecMatchLimitOne
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess, let data = out as? Data else { return .failed(status) }
        guard data.count == keyLength else { return .failed(errSecDecode) }
        return .found(data)
    }

    /// Adds or replaces the item, then reads it back: a write the Keychain cannot return is no use.
    private static func writeKeychain(_ key: Data, _ at: KeyLocation) -> Result<Void, KeyStoreError> {
        var add = query(at)
        add[kSecValueData] = key
        add[kSecAttrLabel] = "Clamshell Host pairing key"
        var status = SecItemAdd(add as CFDictionary, nil)
        if status == errSecDuplicateItem {
            status = SecItemUpdate(query(at) as CFDictionary, [kSecValueData: key] as CFDictionary)
        }
        guard status == errSecSuccess else { return .failure(KeyStoreError(message: "error \(status)")) }
        guard case .found(let back) = readKeychain(at), back == key else {
            return .failure(KeyStoreError(message: "it did not read back"))
        }
        return .success(())
    }

    // MARK: Key file

    private static func readFile(_ at: KeyLocation) -> Data? {
        guard let data = try? Data(contentsOf: at.fileURL), data.count == keyLength else { return nil }
        return data
    }

    private static func removeFile(_ at: KeyLocation) -> Bool {
        do {
            try FileManager.default.removeItem(at: at.fileURL)
            return true
        } catch {
            return !FileManager.default.fileExists(atPath: at.fileURL.path)
        }
    }
}

/// At most `perSecond` lines a second for one kind of message; says how many it held back when the next second starts.
struct LogLimiter {
    let perSecond: Int
    private var windowStart: TimeInterval = -1
    private var count = 0
    private var held = 0

    init(perSecond: Int) { self.perSecond = perSecond }

    mutating func write(_ line: @autoclosure () -> String) {
        let now = ProcessInfo.processInfo.systemUptime
        if windowStart < 0 || now - windowStart >= 1 {
            if held > 0 { log("(\(held) more like the last line not logged)") }
            windowStart = now
            count = 0
            held = 0
        }
        if count < perSecond {
            count += 1
            log(line())
        } else {
            held += 1
        }
    }
}

enum Addresses {
    /// Names and addresses the phone can try: Bonjour name first, then Tailscale, then the LAN.
    static func candidates() -> [String] {
        var result: [String] = []
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty { result.append(local + ".local") }
        var tailscale: [String] = []
        var lan: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return result }
        defer { freeifaddrs(ifaddr) }
        var p = ifaddr
        while let cur = p {
            defer { p = cur.pointee.ifa_next }
            let flags = Int32(cur.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let sa = cur.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let ip = String(cString: host)
            let parts = ip.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4, parts[0] != 169 else { continue }
            // 100.64.0.0/10 is the range Tailscale hands out.
            if parts[0] == 100, (64...127).contains(parts[1]) { tailscale.append(ip) } else { lan.append(ip) }
        }
        result.append(contentsOf: tailscale)
        result.append(contentsOf: lan)
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }
}

enum MacName {
    /// The name from System Settings > General > Sharing. Never touches DNS.
    static var current: String {
        (SCDynamicStoreCopyComputerName(nil, nil) as String?) ?? "Mac"
    }
}

enum QRCode {
    static func image(for text: String, side: CGFloat = 220) -> NSImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let scale = side / output.extent.width
        let scaled = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let rep = NSCIImageRep(ciImage: scaled)
        let image = NSImage(size: rep.size)
        image.addRepresentation(rep)
        return image
    }
}

private let logClock: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss.SSS"
    return formatter
}()
private let logDay: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "MM-dd"
    return formatter
}()
private let logLock = NSLock()

/// A log file that keeps its last megabyte once it passes `limit`, at launch and while running.
final class LogFile {
    static let launchLimit: UInt64 = 4_000_000
    static let runningLimit: UInt64 = 8_000_000
    static let keep = 1_000_000

    let url: URL
    private let handle: FileHandle
    private var size: UInt64

    init?(url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) { FileManager.default.createFile(atPath: url.path, contents: nil) }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        self.url = url
        self.handle = handle
        size = (try? handle.seekToEnd()) ?? 0
        if size > Self.launchLimit { trim() }
    }

    func write(_ data: Data) {
        do { try handle.write(contentsOf: data) } catch { return }
        size += UInt64(data.count)
        if size > Self.runningLimit { trim() }
    }

    private func trim() {
        guard let data = try? Data(contentsOf: url) else { return }
        var tail = data.suffix(Self.keep)
        // Start on a whole line.
        if let newline = tail.firstIndex(of: 0x0A) { tail = tail[(newline + 1)...] }
        do {
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: tail)
            size = UInt64(tail.count)
        } catch {
            size = (try? handle.seekToEnd()) ?? size
        }
    }
}

/// The real host also keeps its log in ~/Library/Logs/Clamshell/host.log, so it is there after a restart
/// or when the host was opened by hand. Test hosts (--dry-run, --test-pattern) only write to stderr.
/// The pairing key never goes through `log`.
private let logFile: LogFile? = {
    let args = CommandLine.arguments
    guard !args.contains("--dry-run"), !args.contains("--test-pattern") else { return nil }
    let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Clamshell")
    return LogFile(url: folder.appendingPathComponent("host.log"))
}()

func log(_ message: String) {
    logLock.lock()
    defer { logLock.unlock() }
    let now = Date()
    let time = logClock.string(from: now)
    FileHandle.standardError.write(Data("[clamshell \(time)] \(message)\n".utf8))
    logFile?.write(Data("[clamshell \(logDay.string(from: now)) \(time)] \(message)\n".utf8))
}

/// Makes the Mac's interface bigger while a phone is connected, like Larger Text in Displays.
/// Set for this app only, so macOS puts the display back by itself if the host quits.
enum DisplayScale {
    /// Test hosts only log what they would do.
    static var simulate = false
    private static var simulated: CGDisplayMode?
    private static var original: CGDisplayMode?

    private static var current: CGDisplayMode? { simulated ?? CGDisplayCopyDisplayMode(CGMainDisplayID()) }

    private static func ratio(_ mode: CGDisplayMode) -> Double { Double(mode.width) / Double(mode.height) }

    /// The sizes the slider in System Settings offers: sharp, same shape, same refresh rate.
    private static func usable(like base: CGDisplayMode) -> [CGDisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
        let modes = (CGDisplayCopyAllDisplayModes(CGMainDisplayID(), options) as? [CGDisplayMode]) ?? []
        return modes.filter {
            $0.pixelWidth > $0.width && $0.isUsableForDesktopGUI()
                && abs(ratio($0) - ratio(base)) < 0.02 && $0.refreshRate == base.refreshRate
        }
    }

    static func choices() -> (widths: [Int], base: Int, now: Int) {
        guard let now = current else { return ([], 0, 0) }
        let base = original ?? now
        return (Set(usable(like: base).map(\.width)).sorted(), base.width, now.width)
    }

    /// 0, or the Mac's own width, puts the display back.
    static func apply(width: Int) {
        guard let now = current else { return }
        let base = original ?? now
        guard width > 0, width != base.width else { restore(); return }
        guard let mode = usable(like: base).first(where: { $0.width == width }) else {
            log("display: no mode \(width) wide")
            return
        }
        original = base
        if mode.ioDisplayModeID != now.ioDisplayModeID { _ = set(mode) }
    }

    /// What phones on build 3 ask for.
    static func apply(step: Int) {
        guard step > 0, let now = current else { restore(); return }
        let target = Double((original ?? now).width) * (step == 1 ? 0.72 : 0.56)
        guard let width = choices().widths.min(by: { abs(Double($0) - target) < abs(Double($1) - target) }) else { return }
        apply(width: width)
    }

    /// The Mac's own size is only forgotten once it is really back, so a restore that did not take is
    /// tried again by the next connection or the next restore.
    static func restore() {
        guard let base = original else { return }
        if let now = current, now.ioDisplayModeID == base.ioDisplayModeID {
            original = nil
            return
        }
        if set(base) { original = nil }
    }

    /// Returns whether the display now has this mode.
    ///
    /// The display is woken first. A mode change asked for while the display sleeps does not fail fast:
    /// the window server holds it for 10 seconds and then refuses it (error 1014), and this runs on the
    /// server's one queue. That was longer than a phone waits for the Mac, so the first connection to an
    /// idle Mac failed every time. Asked for right after a wake, the change goes through as the display
    /// comes on (under 2 seconds in the host's logs).
    private static func set(_ mode: CGDisplayMode) -> Bool {
        if simulate {
            simulated = mode
            log("display: would set \(mode.width)x\(mode.height)")
            return true
        }
        Power.wakeDisplay()
        let began = ProcessInfo.processInfo.systemUptime
        let id = CGMainDisplayID()
        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return false }
        CGConfigureDisplayWithDisplayMode(config, id, mode, nil)
        let result = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard result == .success else {
            log(String(format: "display: %dx%d, result %d, %.2fs", mode.width, mode.height, result.rawValue,
                       ProcessInfo.processInfo.systemUptime - began))
            return false
        }
        // The window server finishes a moment later, and capture and the pointer need the new size.
        for _ in 0..<60 where Int(CGDisplayBounds(id).width) != mode.width { usleep(25_000) }
        // The time is logged because this blocks the session: a `stream:` line that spans it shows a late timer.
        log(String(format: "display: %dx%d, result 0, %.2fs", mode.width, mode.height,
                   ProcessInfo.processInfo.systemUptime - began))
        return true
    }
}
