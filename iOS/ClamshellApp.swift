import SwiftUI
import UIKit
import Security
import VisionKit

/// What the app may rotate to. Half open, the session locks this to one tall orientation.
final class ClamshellAppDelegate: NSObject, UIApplicationDelegate {
    static var orientations: UIInterfaceOrientationMask = .all

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.orientations
    }
}

@main
struct ClamshellApp: App {
    @UIApplicationDelegateAdaptor(ClamshellAppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .preferredColorScheme(.dark)
                .onOpenURL { model.offer($0) }
        }
    }
}

final class AppModel: ObservableObject {
    @Published private(set) var pairing: Pairing?
    /// The pretend Mac while the demo runs. Never saved: the next launch shows the pairing screen again.
    @Published private(set) var demo: DemoMac?
    /// A pairing link waiting for the person's yes: one opened from outside the app, or pasted.
    /// It never changes while its confirm is up, and "Pair" pairs the value the confirm was shown with.
    @Published private(set) var pendingPairing: Pairing?
    /// An outside pairing link was turned away because this phone is already paired: the alert's title.
    @Published var refusedLink: String?
    let client = Client()

    init() {
        let defaults = UserDefaults.standard
        #if DEBUG
        // `-forgetPairing YES`: start from the pairing screen, as a fresh install would (UI tests).
        if defaults.bool(forKey: "forgetPairing") { PairingStore.clear() }
        if defaults.bool(forKey: "checkTextPieces") { Client.checkPieces() }
        #endif
        #if DEBUG
        // `-demo YES` (debug builds, for tests and screenshots): straight into the demo, with no pairing loaded and no dial.
        let launchDemo = defaults.bool(forKey: "demo")
        #else
        let launchDemo = false
        #endif
        if launchDemo {
            startDemo()
        } else {
            #if DEBUG
            // A link passed at launch (used by tests and by the simulator) wins over the saved one.
            if let text = defaults.string(forKey: "pairingURL"), let url = URL(string: text),
               let fresh = Pairing.cleaned(url: url) {
                PairingStore.save(fresh)
            }
            #endif
            pairing = PairingStore.load()
            if let pairing { client.connect(to: pairing) }
        }
        #if DEBUG
        if let text = defaults.string(forKey: "layoutSnapshot") {
            let parts = text.split(separator: "x").compactMap { Double($0) }
            if parts.count == 2 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    LayoutSnapshot.write(model: self, size: CGSize(width: parts[0], height: parts[1]))
                }
            }
        }
        #endif
    }

    /// A code read by the app's own scanner: pairs at once.
    @discardableResult
    func pair(with url: URL) -> Bool {
        guard let fresh = Pairing.cleaned(url: url) else { return false }
        pair(fresh)
        return true
    }

    private func pair(_ fresh: Pairing) {
        demo = nil
        PairingStore.save(fresh)
        pairing = fresh
        client.connect(to: fresh)
    }

    /// A pairing link from outside the app (any web page or app can open one) or from the clipboard.
    /// It never re-pairs a phone that is already paired, and pairs a new one only after the person says yes.
    /// A link with no key, or not a pairing link at all, is ignored. Returns whether it was a pairing link.
    @discardableResult
    func offer(_ url: URL) -> Bool {
        guard let fresh = Pairing.cleaned(url: url) else { return false }
        // One question at a time: while a confirm (or the refusal) is up, further links are ignored.
        guard pendingPairing == nil, refusedLink == nil else { return true }
        // During the demo the confirm shows over it, as if unpaired; a pairing kept from before the demo still counts.
        if let existing = pairing ?? (demo != nil ? PairingStore.load() : nil) {
            refusedLink = "Already paired with \(existing.name)."
            return true
        }
        pendingPairing = fresh
        return true
    }

    /// "Pair" on the confirm: pairs exactly what the confirm showed (and ends the demo, if one is running).
    func confirm(_ shown: Pairing) {
        pendingPairing = nil
        guard pairing == nil else { return }
        pair(shown)
    }

    /// "Cancel" on the confirm: nothing changes, a running demo included.
    func cancelPending() {
        pendingPairing = nil
    }

    /// What the confirm shows: the name, then up to four addresses, then the port.
    static func describe(_ pairing: Pairing) -> String {
        var addresses = pairing.hosts.prefix(4).map { String(Pairing.withoutControls($0).prefix(64)) }.joined(separator: ", ")
        if pairing.hosts.count > 4 { addresses += " and \(pairing.hosts.count - 4) more" }
        if pairing.hosts.isEmpty { addresses = "found on this network by name" }
        return "\(pairing.name)\n\(addresses)\nport \(String(pairing.port))"
    }

    func forget() {
        client.disconnect()
        PairingStore.clear()
        pairing = nil
    }

    /// The session screen against a Mac drawn inside the app. `-demoText "<string>"` pre-fills what was typed.
    func startDemo() {
        #if DEBUG
        let text = UserDefaults.standard.string(forKey: "demoText") ?? ""
        #else
        let text = ""
        #endif
        demo = DemoMac(text: text)
    }

    func endDemo() {
        demo = nil
    }
}

/// A pairing link comes from anywhere (any web page or app can open one), so what it says is cleaned before it
/// is shown or kept: the name and the addresses lose control characters and line breaks.
extension Pairing {
    static func cleaned(url: URL) -> Pairing? {
        Pairing(url: url)?.cleaned()
    }

    /// The name on one line: no control or format characters, whitespace collapsed, at most 40 characters
    /// ("Mac" when nothing is left). Addresses lose control characters and empty ones are dropped; each is kept
    /// whole up to 253 characters (the longest DNS name), so a real one still dials.
    func cleaned() -> Pairing {
        let words = Self.withoutControls(name, breaksAsSpaces: true).split(whereSeparator: { $0.isWhitespace })
        var clean = String(words.joined(separator: " ").prefix(40)).trimmingCharacters(in: .whitespaces)
        if clean.isEmpty { clean = "Mac" }
        let addresses = hosts.map { String(Self.withoutControls($0).prefix(253)) }.filter { !$0.isEmpty }
        return Pairing(name: clean, hosts: addresses, port: port, key: key)
    }

    /// Drops control, format and line or paragraph separator characters (line breaks, bidi overrides),
    /// keeping the zero-width joiner that emoji need. In a name a break becomes a space, so words stay apart.
    static func withoutControls(_ text: String, breaksAsSpaces: Bool = false) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator:
                if breaksAsSpaces { scalars.append(" ") }
            case .format where scalar != "\u{200D}":
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }
}

/// The pairing (where the Mac is, and the shared key) lives in the Keychain.
enum PairingStore {
    private static let service = "com.jadenkwek.clamshell.pairing"
    private static let account = "mac"

    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func save(_ pairing: Pairing) {
        guard let data = try? JSONEncoder().encode(pairing) else { return }
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load() -> Pairing? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        // Cleaned again, for pairings saved before names were cleaned.
        return (try? JSONDecoder().decode(Pairing.self, from: data)).map { $0.cleaned() }
    }

    static func clear() {
        SecItemDelete(query as CFDictionary)
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if model.demo != nil || model.pairing != nil {
                SessionContainer(model: model)
                    .id(model.demo.map(ObjectIdentifier.init)) // a fresh session when the demo starts or ends
                    .ignoresSafeArea()
                    .persistentSystemOverlays(.hidden)
                    .statusBarHidden(true)
            } else {
                PairingView(model: model)
            }
        }
        .background(Color.black)
        .alert("Pair with this Mac?", isPresented: Binding(get: { model.pendingPairing != nil },
                                                           set: { if !$0 { model.cancelPending() } }),
               presenting: model.pendingPairing) { shown in
            Button("Cancel", role: .cancel) { model.cancelPending() }
            Button("Pair") { model.confirm(shown) }
        } message: { pairing in
            Text(AppModel.describe(pairing))
        }
        .alert(model.refusedLink ?? "", isPresented: Binding(get: { model.refusedLink != nil },
                                                             set: { if !$0 { model.refusedLink = nil } })) {
            Button("OK", role: .cancel) { model.refusedLink = nil }
        } message: {
            Text("Choose Forget this Mac in the menu first.")
        }
    }
}

struct SessionContainer: UIViewControllerRepresentable {
    let model: AppModel

    func makeUIViewController(context: Context) -> SessionViewController {
        SessionViewController(model: model)
    }

    func updateUIViewController(_ controller: SessionViewController, context: Context) {}
}

// MARK: - Pairing

struct PairingView: View {
    @ObservedObject var model: AppModel
    @State private var message: String?
    @State private var scanning = false

    static let hostDownload = URL(string: "https://github.com/TheRealJadenKwek/clamshell/releases/latest")!
    static let privacy = URL(string: "https://github.com/TheRealJadenKwek/clamshell/blob/main/PRIVACY.md")!

    var body: some View {
        GeometryReader { geometry in
            // Fits without scrolling on a 375 x 667 iPhone and the Duo's cover screen; scrolls when the height is tight.
            ScrollView {
                content
                    .padding(.horizontal, 28)
                    .padding(.vertical, 20)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .background(Color.black)
    }

    private var content: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 4)
            Image(systemName: "laptopcomputer.and.iphone")
                .font(.system(size: 42, weight: .light))
                .foregroundStyle(.white)
            VStack(spacing: 8) {
                Text("Pair with your Mac").font(.title2.weight(.semibold))
                Text("Open Clamshell Host in the Mac's menu bar and scan the code it shows. You only do this once.")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: 6) {
                Text("Clamshell Host is a free app for your Mac.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(alignment: .center, spacing: 10) {
                    Text(Self.hostDownload.absoluteString)
                        .font(.footnote.monospaced())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("pair-host-link")
                    ShareLink(item: Self.hostDownload) {
                        Image(systemName: "square.and.arrow.up")
                            .font(.body.weight(.medium))
                            .frame(width: 36, height: 36)
                    }
                    .tint(.white)
                    .accessibilityLabel("Share the Clamshell Host link")
                    .accessibilityIdentifier("pair-share")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
            if scanning {
                ScannerView { text in
                    if let url = URL(string: text), model.pair(with: url) {
                        scanning = false
                    } else {
                        message = "That is not a Clamshell code."
                    }
                }
                .frame(maxWidth: 340, maxHeight: 340)
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18))
            }
            VStack(spacing: 10) {
                if !scanning {
                    Button {
                        if DataScannerViewController.isSupported {
                            message = nil
                            scanning = true
                        } else {
                            message = "This iPhone cannot scan codes. On the Mac, use Copy pairing link, then Paste pairing link here."
                        }
                    } label: {
                        Text("Scan the code").frame(maxWidth: 260)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.white)
                    .foregroundStyle(.black)
                    .controlSize(.large)
                    .accessibilityIdentifier("pair-scan")
                }
                Button {
                    if let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                       let url = URL(string: text), model.offer(url) {
                        message = nil
                    } else {
                        message = "No pairing link on the clipboard. Use Copy pairing link on the Mac first."
                    }
                } label: {
                    Text("Paste pairing link").frame(maxWidth: 260)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                .controlSize(.large)
                .accessibilityIdentifier("pair-paste")
                Button("Try the demo") {
                    model.startDemo()
                }
                .font(.callout.weight(.medium))
                .foregroundStyle(.white.opacity(0.75))
                .padding(.vertical, 6)
                .accessibilityIdentifier("pair-demo")
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.orange).multilineTextAlignment(.center)
            }
            Spacer(minLength: 4)
            VStack(spacing: 4) {
                Text("Your Mac's screen and your typing go only between this iPhone and your Mac.")
                    .multilineTextAlignment(.center)
                Link("Privacy", destination: Self.privacy)
                    .foregroundStyle(.white.opacity(0.75))
                    .accessibilityIdentifier("pair-privacy")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }
}

struct ScannerView: UIViewControllerRepresentable {
    let onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])],
                                                qualityLevel: .balanced, recognizesMultipleItems: false,
                                                isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        scanner.delegate = context.coordinator
        try? scanner.startScanning()
        return scanner
    }

    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
    }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var last = ""

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let code) = item, let text = code.payloadStringValue, text != last {
                    last = text
                    onCode(text)
                }
            }
        }
    }
}

#if DEBUG
/// Draws the session screen at any size into Documents/layout.png, so the layout for a
/// display that is not on hand (the Duo's inner screen) can be checked.
enum LayoutSnapshot {
    static func write(model: AppModel, size: CGSize) {
        let controller = SessionViewController(model: model)
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(origin: .zero, size: size)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            controller.view.layer.render(in: context.cgContext)
        }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("layout.png")
        try? image.pngData()?.write(to: url)
    }
}
#endif
