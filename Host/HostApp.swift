import SwiftUI
import AppKit
import ServiceManagement

/// Opening the app again shows the panel in a normal window, so it can still be reached
/// when the menu bar is too full to show the icon.
final class HostAppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPanel()
        return false
    }

    private func showPanel() {
        let window = self.window ?? {
            let controller = NSHostingController(rootView: PanelView(server: HostServer.shared))
            let w = NSWindow(contentViewController: controller)
            w.title = "Clamshell Host"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.setContentSize(controller.view.fittingSize)
            w.center()
            return w
        }()
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // macOS can refuse activation when the app was opened from the background.
        window.orderFrontRegardless()
    }
}

@main
struct ClamshellHostApp: App {
    @NSApplicationDelegateAdaptor(HostAppDelegate.self) private var appDelegate
    @StateObject private var server = HostServer.shared
    /// A test host (`--dry-run`, `--test-pattern`) runs beside the real one: no second icon in the menu bar.
    private static let showsMenuBarIcon = !CommandLine.arguments.contains { $0 == "--dry-run" || $0 == "--test-pattern" }

    var body: some Scene {
        MenuBarExtra(isInserted: .constant(ClamshellHostApp.showsMenuBarIcon)) {
            PanelView(server: server)
        } label: {
            Image(systemName: server.paused ? "laptopcomputer.slash"
                  : server.clientName == nil ? "laptopcomputer" : "laptopcomputer.and.iphone")
        }
        .menuBarExtraStyle(.window)
    }
}

struct PanelView: View {
    @ObservedObject var server: HostServer
    @State private var openAtLogin = SMAppService.mainApp.status == .enabled
    @State private var confirmReset = false
    @State private var copied = false
    /// The code is drawn only after a click, and hidden again when the panel closes or after a minute.
    @State private var showCode = false
    @State private var showTicket = 0

    private static let codeShownFor: TimeInterval = 60
    private static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            permissions
            Divider()
            pairing
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 300)
        .background(WindowCloseWatcher { hideCode() })
        .onDisappear { hideCode() }
    }

    private func hideCode() {
        showTicket += 1
        showCode = false
    }

    private func revealCode() {
        showTicket += 1
        let ticket = showTicket
        showCode = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.codeShownFor) {
            if ticket == showTicket { showCode = false }
        }
    }

    /// Marked concealed so clipboard managers skip it, and cleared after a minute if nothing replaced it.
    private func copyLink(_ link: String) {
        let board = NSPasteboard.general
        board.clearContents()
        let item = NSPasteboardItem()
        item.setString(link, forType: .string)
        item.setData(Data(), forType: Self.concealedType)
        board.writeObjects([item])
        let written = board.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.codeShownFor) {
            if board.changeCount == written { board.clearContents() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Clamshell Host").font(.headline)
                Text(statusText).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            if server.paused {
                Button("Resume") { server.resumeConnections() }
            } else if server.clientName != nil {
                Button("Disconnect") { server.disconnectClient() }
            }
        }
    }

    private var statusText: String {
        if server.paused { return "Connections paused" }
        if let name = server.clientName { return "\(name) is connected" }
        if let error = server.lastError { return error }
        return server.listening ? "Waiting for your iPhone" : "Starting"
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 8) {
            permissionRow("Show this Mac's screen", granted: server.canCapture, detail: "Screen Recording") {
                Permissions.requestCapture()
            }
            permissionRow("Use the keyboard and trackpad", granted: server.canControl, detail: "Accessibility") {
                Permissions.requestControl()
            }
            if !server.canCapture || !server.canControl {
                Text("macOS asks once for each. After allowing Screen Recording, quit and reopen Clamshell Host.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func permissionRow(_ title: String, granted: Bool, detail: String, action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(granted ? Color.green : Color.orange)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !granted { Button("Allow", action: action) }
        }
    }

    private var pairing: some View {
        VStack(alignment: .center, spacing: 10) {
            if let link = server.pairing?.url.absoluteString {
                if showCode, let image = QRCode.image(for: link, side: 200) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .padding(8)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                    Text("Open Clamshell on your iPhone and scan this once. It carries the key that lets the phone control this Mac, so do not share it.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button("Hide pairing code") { hideCode() }
                } else {
                    Text("The pairing code carries the key that lets a phone control this Mac. Show it only to scan it with your iPhone.")
                        .font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                    Button("Show pairing code") { revealCode() }
                }
                HStack {
                    Button(copied ? "Copied" : "Copy pairing link") {
                        copyLink(link)
                        copied = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                    }
                    Button("New key") { confirmReset = true }
                }
            } else {
                Button("New key") { confirmReset = true }
            }
            if let problem = server.keyProblem {
                Text(problem)
                    .font(.caption).foregroundStyle(.orange)
                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .confirmationDialog("Make a new pairing key?", isPresented: $confirmReset) {
            Button("Make a new key", role: .destructive) { hideCode(); server.resetKey() }
        } message: {
            Text("Every paired iPhone stops working until it scans the new code.")
        }
    }

    private var footer: some View {
        HStack {
            Toggle("Open at login", isOn: $openAtLogin)
                .toggleStyle(.checkbox)
                .onChange(of: openAtLogin) { _, on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        openAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
        }
    }
}

/// Calls `onHide` when the window holding the panel closes, is hidden or stops being the key window,
/// which is what happens when the menu bar panel closes.
private struct WindowCloseWatcher: NSViewRepresentable {
    let onHide: () -> Void

    func makeNSView(context: Context) -> WatcherView {
        let view = WatcherView()
        view.onHide = onHide
        return view
    }

    func updateNSView(_ view: WatcherView, context: Context) {
        view.onHide = onHide
    }

    final class WatcherView: NSView {
        var onHide: (() -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            guard let window else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.willCloseNotification, NSWindow.didResignKeyNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    self?.onHide?()
                })
            }
            observers.append(center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self, weak window] _ in
                guard let window, !window.occlusionState.contains(.visible) else { return }
                self?.onHide?()
            })
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
    }
}
