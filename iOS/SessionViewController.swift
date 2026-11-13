import UIKit
import Combine

/// The working screen: the Mac's display on top, keyboard and trackpad below.
/// On an iPhone Duo held half open, the split sits exactly on the hinge.
final class SessionViewController: UIViewController {
    private let model: AppModel
    /// The paired Mac (`model.client`), or the demo's pretend Mac.
    private let client: MacLink
    private let demo: DemoMac?
    private let screenView: ScreenView
    private let keyboard = KeyboardView()
    private let trackpad = TrackpadView()
    private let chassis = ChassisView()
    private let statusLabel = UILabel()
    private let notice = NoticeLabel()
    private let displayPanel = DisplayPanel()
    private var hingeHalfOpen = false
    private var bag = Set<AnyCancellable>()
    private let hardwareRepeater = KeyRepeater()
    private var hardwareDown = Set<UInt16>()
    private var cursorAtEdge = false
    private var hingeText = "none"
    private var geometryProblem: String?
    private var lastReport = ""
    /// The iOS keyboard instead of the drawn Mac one ("keyboardStyle" = "iphone").
    private let proxy = TypingProxy()
    private var iPhoneStyle = SessionViewController.savedKeyboardIsIPhone()
    /// The app's own drawn iPhone keyboard, for the flipped hold the system keyboard cannot follow.
    private let phoneKeys = PhoneKeyboardView()
    private var phoneTyping: PhoneTyping!
    /// Height of the system keyboard last seen (unflipped) for each view width this run, so both holds match.
    private var systemKeyboardHeights: [Int: CGFloat] = [:]
    /// The bar and the proxy's buffer are in use (iOS keyboard, landscape bar, or the drawn phone keys).
    private var barActive = false
    /// iPhone keys while flipped: the drawn phone keyboard stands in for the iOS one.
    private var ownPhoneKeys: Bool { iPhoneStyle && flipped && !landscapeLayout }

    /// The iPhone keyboard is the default from build 9 (it types better); anyone on the
    /// Mac keyboard before that is moved over once, and can go back with the bar's keyboard key.
    private static func savedKeyboardIsIPhone() -> Bool {
        let defaults = UserDefaults.standard
        if !defaults.bool(forKey: "keyboardDefaultMoved") {
            defaults.set(true, forKey: "keyboardDefaultMoved")
            defaults.set("iphone", forKey: "keyboardStyle")
        }
        return defaults.string(forKey: "keyboardStyle") != "mac"
    }
    private var deckShown = false
    private var typingActive = false
    private var typingUpdateQueued = false
    /// Top of the system keyboard in this view, while it is on screen (the modifier bar is ours, above it).
    private var keyboardTop: CGFloat?
    /// The bar's trackpad key: the iOS keyboard is put away and the whole bottom is trackpad.
    /// Not saved between launches; off when the iPhone keyboard is switched off. It survives a redial,
    /// because iOS drops the link every time the app leaves the screen.
    private var padMode = SessionViewController.launchPadMode()
    /// Landscape: the bar's trackpad key brings up the iOS keyboard with the Mac picture on the left and a
    /// trackpad on the right; off, the picture fills everything above the bar. Session only, apart from `padMode`.
    private var landscapeTyping = SessionViewController.launchLandscapeTyping()
    /// The last layout was landscape (any size); set in `viewDidLayoutSubviews`.
    private var landscapeLayout = false
    /// iOS will not turn an iPhone app upside down, so for the tall hold it refuses we turn our own view
    /// half way round. The iOS keyboard cannot follow, so this hold draws its own phone keyboard (or the Mac one).
    private var flipped = SessionViewController.launchFlipped()
    /// The iOS keyboard is put away (pad mode in portrait, the default in landscape).
    private var keyboardPutAway: Bool { landscapeLayout ? !landscapeTyping : padMode }
    /// Layout renders in the simulator (which cannot fold and shows no software keyboard): `-fakeKeyboardTop <points>`.
    private let fakeKeyboardTop = SessionViewController.launchFakeKeyboardTop()
    private var lastPhase: Client.Phase = .idle
    #if DEBUG
    private var turnToDone = false
    #endif

    /// `-padMode YES` at launch starts in pad mode (debug builds, for layout renders).
    private static func launchPadMode() -> Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "padMode")
        #else
        return false
        #endif
    }

    private static func launchFlipped() -> Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "flipped")
        #else
        return false
        #endif
    }

    private func setFlipped(_ on: Bool) {
        guard on != flipped || (on && view.transform.isIdentity) else { return }
        flipped = on
        view.transform = on ? CGAffineTransform(rotationAngle: .pi) : .identity
        view.setNeedsLayout()
        scheduleTypingUpdate()
        reportDevice()
    }

    /// `-landscapeTyping YES` at launch starts landscape in typing (debug builds, for layout renders).
    private static func launchLandscapeTyping() -> Bool {
        #if DEBUG
        return UserDefaults.standard.bool(forKey: "landscapeTyping")
        #else
        return false
        #endif
    }

    private static func launchFakeKeyboardTop() -> CGFloat? {
        #if DEBUG
        let value = UserDefaults.standard.double(forKey: "fakeKeyboardTop")
        return value > 0 ? CGFloat(value) : nil
        #else
        return nil
        #endif
    }

    init(model: AppModel) {
        self.model = model
        demo = model.demo
        if let demo {
            client = demo
            screenView = ScreenView(pictureView: demo.makeView())
        } else {
            client = model.client
            screenView = ScreenView(videoLayer: model.client.renderer.layer)
        }
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .all }
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(proxy) // behind everything; it is only there to own the iOS keyboard
        view.addSubview(chassis)
        view.addSubview(screenView)
        view.addSubview(keyboard)
        view.addSubview(trackpad)
        view.addSubview(phoneKeys)
        phoneKeys.isHidden = true
        phoneTyping = PhoneTyping(proxy: proxy, view: phoneKeys)
        proxy.onReset = { [weak self] in self?.phoneTyping?.reset() }
        let latchesChanged = proxy.bar.onLatchesChanged
        proxy.bar.onLatchesChanged = { [weak self] in
            latchesChanged?()
            self?.phoneTyping?.refreshShift() // no auto-capital while a Mac modifier is latched
        }
        #if DEBUG
        if UserDefaults.standard.bool(forKey: "autocorrectTable") { PhoneTyping.writeTable() }
        #endif
        view.addSubview(proxy.bar) // laid out by us, over the chassis, never as an input accessory
        proxy.bar.isHidden = true
        proxy.bar.padOn = padMode

        statusLabel.numberOfLines = 0
        statusLabel.textAlignment = .center
        statusLabel.textColor = UIColor(white: 1, alpha: 0.8)
        statusLabel.font = .systemFont(ofSize: 15, weight: .medium)
        view.addSubview(statusLabel)
        view.addSubview(notice)
        view.addSubview(displayPanel)

        let send: ([InputEvent]) -> Void = { [weak self] events in self?.client.send(events) }
        keyboard.send = send
        trackpad.send = send
        screenView.send = send
        keyboard.onDisplay = { [weak self] in self?.toggleDisplayPanel() }
        keyboard.onIPhoneKeyboard = { [weak self] in self?.setKeyboardStyle(iPhone: true) }
        displayPanel.onPick = { [weak self] width in self?.client.setDisplay(width: width) }
        trackpad.onClick = { [weak self] in self?.clicked() }
        trackpad.report = { [weak self] text in self?.client.sendDeviceInfo(text) }
        screenView.onClick = { [weak self] in self?.clicked() }
        keyboard.menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in done(self?.menuItems() ?? []) },
        ])
        proxy.send = send
        proxy.bar.send = send
        proxy.bar.onKey = { [weak self] in self?.proxy.reset() }
        proxy.bar.onMacKeyboard = { [weak self] in self?.setKeyboardStyle(iPhone: false) }
        proxy.bar.onPad = { [weak self] in
            guard let self else { return }
            if self.landscapeLayout {
                self.setLandscapeTyping(!self.landscapeTyping)
            } else {
                self.setPadMode(!self.padMode)
            }
        }
        proxy.bar.menuButton.menu = UIMenu(children: [
            UIDeferredMenuElement.uncached { [weak self] done in done(self?.menuItems() ?? []) },
        ])
        client.onCursor = { [weak self] point in self?.cursorMoved(to: point) }

        #if DEBUG
        let forcedHinge = UserDefaults.standard.string(forKey: "forceHinge") // "half" in layout tests
        #else
        let forcedHinge: String? = nil
        #endif
        if forcedHinge == "half" { hingeHalfOpen = true }
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        NotificationCenter.default.addObserver(self, selector: #selector(followDevice),
                                               name: UIDevice.orientationDidChangeNotification, object: nil)
        if #available(iOS 27.1, *), forcedHinge == nil {
            let hinge = UIHingeInteraction { [weak self] _, update in
                guard let self else { return }
                self.hingeText = update.hinge.map { "status \($0.status.rawValue) at \(Int($0.angle * 180 / .pi)) deg" } ?? "none"
                self.reportDevice()
                let halfOpen = update.hinge?.status == .partiallyOpen
                guard halfOpen != self.hingeHalfOpen else { return }
                self.hingeHalfOpen = halfOpen
                self.applyPosture()
                self.view.setNeedsLayout()
                UIView.animate(withDuration: 0.25) { self.view.layoutIfNeeded() }
            }
            view.addInteraction(hinge)
        }

        client.linkState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                self?.render(phase: state.phase, problem: state.problem, ack: state.ack, status: state.status)
            }
            .store(in: &bag)
        if demo != nil { screenView.badge = DemoPill() }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(keyboardWillChangeFrame(_:)),
                           name: UIResponder.keyboardWillChangeFrameNotification, object: nil)
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { ClamshellAppDelegate.orientations }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if flipped { setFlipped(true) }
        UIApplication.shared.isIdleTimerDisabled = true
        Haptics.shared.start()
        becomeFirstResponder()
        applyPosture()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// A soft tick when the trackpad pushes the cursor into an edge of the Mac screen.
    private func cursorMoved(to point: CGPoint) {
        screenView.cursorMoved(to: point)
        let atEdge = point.x <= 0.0005 || point.x >= 0.9985 || point.y <= 0.0005 || point.y >= 0.9985
        if atEdge, !cursorAtEdge, trackpad.isTouching { Haptics.shared.play(.edge) }
        cursorAtEdge = atEdge
    }

    @objc private func didBecomeActive() {
        UIApplication.shared.isIdleTimerDisabled = true
        Haptics.shared.start()
        if client.phase == .connected { client.recoverVideo() } else { client.reconnect() }
        scheduleTypingUpdate()
    }

    @objc private func willResignActive() {
        Haptics.shared.stop()
        hardwareRepeater.stopAll()
        hardwareDown.removeAll()
        keyboard.releaseEverything()
        proxy.bar.releaseEverything()
        phoneKeys.releaseEverything()
    }

    /// A click on the trackpad or the Mac screen uses up latched modifiers, and may move the Mac's text cursor.
    private func clicked() {
        keyboard.consumeLatches()
        proxy.bar.consumeLatches()
        proxy.reset()
    }

    // MARK: iPhone keyboard

    private func setKeyboardStyle(iPhone: Bool) {
        guard iPhone != iPhoneStyle else { return }
        iPhoneStyle = iPhone
        if !iPhone { setPadFlag(false) }
        UserDefaults.standard.set(iPhone ? "iphone" : "mac", forKey: "keyboardStyle")
        updateTypingMode()
        view.setNeedsLayout()
    }

    /// The trackpad key on the bar. Latched bar modifiers stay latched across the switch,
    /// so a latched Command then a click on the big trackpad is a Command-click.
    private func setPadMode(_ on: Bool) {
        guard on != padMode else { return }
        setPadFlag(on)
        proxy.reset()
        updateTypingMode()
        view.setNeedsLayout()
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.view.layoutIfNeeded()
        }
    }

    private func setPadFlag(_ on: Bool) {
        padMode = on
        if !landscapeLayout { proxy.bar.padOn = on }
    }

    /// Landscape's trackpad key: typing (iOS keyboard, picture left, trackpad right) or the picture alone.
    /// Latched bar modifiers stay latched across the switch, as with pad mode.
    private func setLandscapeTyping(_ on: Bool) {
        guard on != landscapeTyping else { return }
        landscapeTyping = on
        if landscapeLayout { proxy.bar.padOn = !on }
        proxy.reset()
        updateTypingMode()
        view.setNeedsLayout()
        UIView.animate(withDuration: 0.25, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            self.view.layoutIfNeeded()
        }
    }

    /// The iPhone keyboard mode applies with the deck on screen, the session connected and the mode on;
    /// the iOS keyboard itself is up in that mode unless the bar's trackpad key is on.
    /// Landscape always uses the bar (whatever the saved keyboard style), with the keyboard put away by default.
    private func updateTypingMode() {
        let live = deckShown && client.phase == .connected && view.window != nil
        // Never the proxy while flipped: the system keyboard would come up at the wrong edge.
        let want = ((iPhoneStyle && !flipped) || landscapeLayout) && live
        // The drawn phone keys share the bar and the proxy's buffer, so turning the phone over
        // between them and the iOS keyboard keeps both (the Mac's cursor has not moved).
        let barWanted = want || (ownPhoneKeys && live)
        if barWanted != barActive {
            barActive = barWanted
            if barWanted {
                keyboard.releaseEverything()
            } else {
                proxy.bar.releaseEverything()
                phoneKeys.releaseEverything()
            }
            proxy.reset()
        }
        if want != typingActive {
            typingActive = want
            if want {
                claimKeyboard(tries: 10)
            } else {
                if proxy.isFirstResponder { proxy.resignFirstResponder() }
                keyboardTop = nil
                becomeFirstResponder()
            }
            view.setNeedsLayout()
            return
        }
        guard typingActive else { return }
        if keyboardPutAway {
            // Pad mode: the keyboard goes away, and hardware keys come here as in Mac keyboard mode.
            if proxy.isFirstResponder {
                proxy.resignFirstResponder()
                keyboardTop = nil
                becomeFirstResponder()
                view.setNeedsLayout()
            }
        } else if !proxy.isFirstResponder, presentedViewController == nil {
            claimKeyboard(tries: 10) // pad mode ended, or something took the keyboard (an alert, the app going away)
        }
    }

    /// Right after launch the window may not take a first responder yet, so try again for a few seconds.
    private func claimKeyboard(tries: Int) {
        guard typingActive, !keyboardPutAway, !proxy.isFirstResponder else { return }
        // Layout runs that fake the keyboard's top (debug only): a simulator keyboard would just cover the faked layout.
        guard fakeKeyboardTop == nil else { return }
        if proxy.becomeFirstResponder() || tries <= 0 { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.claimKeyboard(tries: tries - 1) }
    }

    @objc private func keyboardWillChangeFrame(_ note: Notification) {
        guard let info = note.userInfo, let end = (info[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue else { return }
        let space = view.window?.windowScene?.screen.coordinateSpace
        let frame = space.map { view.convert(end, from: $0) } ?? end
        let top: CGFloat? = frame.height > 0 && frame.intersects(view.bounds) && frame.minY < view.bounds.maxY ? frame.minY : nil
        if let top, !flipped, top > view.bounds.minY {
            systemKeyboardHeights[Int(view.bounds.width.rounded())] = view.bounds.maxY - top
        }
        guard top != keyboardTop else { return }
        keyboardTop = top
        let duration = info[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let curve = info[UIResponder.keyboardAnimationCurveUserInfoKey] as? UInt ?? 7
        view.setNeedsLayout()
        UIView.animate(withDuration: duration, delay: 0, options: [UIView.AnimationOptions(rawValue: curve << 16), .beginFromCurrentState]) {
            self.view.layoutIfNeeded()
        }
    }

    // MARK: Posture

    /// Half open, the fold has to run across the screen: Mac above, keyboard below. With the base flat on
    /// a table iOS often stays in the wide orientation, so ask for a tall one and hold it until the fold changes.
    private func applyPosture() {
        guard let scene = view.window?.windowScene else { return }
        let mask = hingeHalfOpen ? laptopMask(in: scene) : UIInterfaceOrientationMask.all
        if hingeHalfOpen { setFlipped(false) }
        ClamshellAppDelegate.orientations = mask
        setNeedsUpdateOfSupportedInterfaceOrientations()
        view.window?.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            DispatchQueue.main.async {
                self?.geometryProblem = error.localizedDescription
                self?.reportDevice()
            }
        }
        if !hingeHalfOpen { followDevice() }
    }

    /// Opened flat, iOS keeps the orientation the laptop posture locked (and does not turn at all with
    /// rotation lock on), so turn the picture to match how the phone is held ourselves.
    @objc private func followDevice() {
        guard !hingeHalfOpen, let scene = view.window?.windowScene else { return }
        // Only the big inner screen: the cover screen turns by itself.
        guard max(view.bounds.width, view.bounds.height) > 800 else { return }
        // The inner screen's own "portrait" is a quarter turn from the phone's (held like a book it reports landscapeLeft).
        let target: UIInterfaceOrientation
        var half = false
        switch UIDevice.current.orientation {
        case .portrait: target = .landscapeLeft
        case .landscapeLeft: target = .portrait
        case .portraitUpsideDown: target = .landscapeRight
        case .landscapeRight: target = .portrait; half = true // iOS refuses portraitUpsideDown: turn our own view instead
        default: return
        }
        setFlipped(half)
        turn(to: target, in: scene)
    }

    private func turn(to target: UIInterfaceOrientation, in scene: UIWindowScene) {
        guard target != scene.effectiveGeometry.interfaceOrientation else { return }
        let mask: UIInterfaceOrientationMask
        switch target {
        case .portrait: mask = .portrait
        case .portraitUpsideDown: mask = .portraitUpsideDown
        case .landscapeLeft: mask = .landscapeLeft
        default: mask = .landscapeRight
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            DispatchQueue.main.async {
                self?.geometryProblem = "turn to \(target.rawValue): \(error.localizedDescription)"
                self?.reportDevice()
            }
        }
    }

    /// The menu's way out when the picture is the wrong way up and the phone cannot tell.
    private func turnAround() {
        guard let scene = view.window?.windowScene else { return }
        if view.bounds.height >= view.bounds.width { setFlipped(!flipped); return }
        let opposite: UIInterfaceOrientation
        switch scene.effectiveGeometry.interfaceOrientation {
        case .portrait: opposite = .portraitUpsideDown
        case .portraitUpsideDown: opposite = .portrait
        case .landscapeLeft: opposite = .landscapeRight
        case .landscapeRight: opposite = .landscapeLeft
        default: return
        }
        turn(to: opposite, in: scene)
    }

    private func laptopMask(in scene: UIWindowScene) -> UIInterfaceOrientationMask {
        let current = scene.effectiveGeometry.interfaceOrientation
        let tallNow = view.bounds.height >= view.bounds.width
        // On the Duo's inner screen "portrait" can be the wide one, so work it out from the current shape.
        let tall: [UIInterfaceOrientation] = current.isPortrait == tallNow
            ? [.portrait, .portraitUpsideDown] : [.landscapeLeft, .landscapeRight]
        let saved = UIInterfaceOrientation(rawValue: UserDefaults.standard.integer(forKey: "laptopOrientation"))
        var sensed: UIInterfaceOrientation?
        switch UIDevice.current.orientation {
        case .portrait: sensed = .portrait
        case .portraitUpsideDown: sensed = .portraitUpsideDown
        case .landscapeLeft: sensed = .landscapeRight   // device and interface landscape are mirrored
        case .landscapeRight: sensed = .landscapeLeft
        default: sensed = nil
        }
        let chosen = [saved, sensed, tallNow ? current : nil].compactMap { $0 }.first { tall.contains($0) } ?? tall[0]
        switch chosen {
        case .portrait: return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeLeft
        default: return .landscapeRight
        }
    }

    /// For when iOS cannot tell which half is on the table.
    private func flipLaptop() {
        guard let scene = view.window?.windowScene else { return }
        let opposite: UIInterfaceOrientation
        switch scene.effectiveGeometry.interfaceOrientation {
        case .portrait: opposite = .portraitUpsideDown
        case .portraitUpsideDown: opposite = .portrait
        case .landscapeLeft: opposite = .landscapeRight
        case .landscapeRight: opposite = .landscapeLeft
        default: return
        }
        UserDefaults.standard.set(opposite.rawValue, forKey: "laptopOrientation")
        applyPosture()
    }

    /// One line in the Mac's host log whenever the phone's posture changes.
    private func reportDevice() {
        let b = view.bounds, s = view.safeAreaInsets
        let interface = view.window?.windowScene?.effectiveGeometry.interfaceOrientation.rawValue ?? 0
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        var text = "build \(build), hinge \(hingeText), interface \(interface), device \(UIDevice.current.orientation.rawValue), "
        text += "bounds \(Int(b.width))x\(Int(b.height)), safe \(Int(s.top)) \(Int(s.left)) \(Int(s.bottom)) \(Int(s.right)), split \(hingeHalfOpen)"
        text += ", keys \(iPhoneStyle ? "iphone" : "mac")"
        let own = !phoneKeys.isHidden
        let kb = own ? phoneKeys.frame.minY : keyboardTop
        text += ", kb \(kb.map { String(Int($0)) } ?? "none"), pad \(padMode ? 1 : 0), land \(landscapeTyping ? 1 : 0), flip \(flipped ? 1 : 0)"
        text += ", own \(own ? 1 : 0)"
        if let geometryProblem { text += ", geometry error: \(geometryProblem)" }
        guard text != lastReport else { return }
        lastReport = text
        client.sendDeviceInfo(text)
    }

    // MARK: Layout

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let b = view.bounds
        let safe = view.safeAreaInsets
        let portrait = b.height >= b.width
        let bottomInset = max(safe.bottom - 14, 4)
        let halfOpen = hingeHalfOpen && portrait
        let gutter: CGFloat = 5
        let barH = ModifierBar.height
        // The Mac's screen runs edge to edge: a camera cutout just covers whatever is under it.
        var screenFrame = CGRect.zero
        var deck = CGRect.zero

        if halfOpen {
            // Laptop posture: the fold runs across the middle of the tall side.
            screenFrame = CGRect(x: 0, y: 0, width: b.width, height: b.midY - gutter)
            deck = CGRect(x: 0, y: b.midY + gutter, width: b.width, height: b.maxY - bottomInset - (b.midY + gutter))
        } else if portrait {
            let aspect = screenView.streamSize.width / max(screenView.streamSize.height, 1)
            let available = b.height - bottomInset
            let screenHeight = min(b.width / aspect, available * 0.46)
            screenFrame = CGRect(x: 0, y: 0, width: b.width, height: screenHeight)
            deck = CGRect(x: 0, y: screenFrame.maxY + 6, width: b.width, height: b.maxY - bottomInset - screenFrame.maxY - 6)
        } else {
            // Landscape: the whole display is the Mac screen. Touch it, or use a hardware keyboard.
            screenFrame = b
        }

        let showDeck = deck.height > 160
        // Landscape, any size: the bar along the bottom (or on the iOS keyboard while typing), whatever the keyboard style.
        let landscapeKeys = !portrait && client.phase == .connected
        landscapeLayout = !portrait
        proxy.bar.padOn = landscapeLayout ? !landscapeTyping : padMode
        proxy.bar.showsMacKeyboard = portrait
        deckShown = showDeck || landscapeKeys
        // Laid out for the iOS keyboard as soon as the mode applies; the keyboard itself follows (scheduleTypingUpdate).
        // Flipped, the same layout with the app's own phone keyboard in place of the iOS one.
        let iPhoneKeys = showDeck && iPhoneStyle && client.phase == .connected
        let pad = iPhoneKeys && padMode
        var ownKeysTop: CGFloat?
        if iPhoneKeys, !pad, ownPhoneKeys {
            let drawn = PhoneKeyboardView.height(forWidth: b.width)
            // A recorded height only within sense: never below the drawn keyboard's own, never over half the view.
            let height = systemKeyboardHeights[Int(b.width.rounded())].map { min(max($0, drawn), b.height / 2) } ?? drawn
            ownKeysTop = b.maxY - height
        }
        // The modifier bar is ours: on the keyboard's top while typing, under the Mac picture in pad mode.
        // The Mac picture never sits under it.
        var barTop: CGFloat = 0
        if iPhoneKeys {
            if pad {
                barTop = halfOpen ? b.midY - gutter - barH : screenFrame.maxY + 6
            } else {
                // The faked top (debug layout runs only) wins over a keyboard the simulator happens to draw.
                barTop = max((ownKeysTop ?? fakeKeyboardTop ?? keyboardTop ?? deck.maxY) - barH, 0)
                if halfOpen, barTop < b.midY, barTop + barH > b.midY {
                    barTop = b.midY - gutter - barH // never across the fold: it ends the top screen instead
                }
                if !halfOpen {
                    screenFrame.size.height = max(min(screenFrame.height, barTop - 6), 0)
                    deck = CGRect(x: 0, y: screenFrame.maxY + 6, width: b.width, height: b.maxY - bottomInset - screenFrame.maxY - 6)
                }
            }
            if halfOpen { screenFrame.size.height = min(b.midY - gutter, barTop) }
        }

        screenView.alignsToBottom = halfOpen
        screenView.frame = screenFrame
        keyboard.isHidden = !showDeck || iPhoneKeys
        trackpad.isHidden = !showDeck
        chassis.isHidden = !showDeck
        proxy.bar.isHidden = !iPhoneKeys
        if ownKeysTop == nil, !phoneKeys.isHidden { phoneKeys.releaseEverything() }
        let phoneKeysWereHidden = phoneKeys.isHidden
        phoneKeys.isHidden = ownKeysTop == nil
        // Coming up: the strip, shift and correction state catch up with the buffer and the settings.
        if phoneKeysWereHidden, !phoneKeys.isHidden { phoneTyping.keyboardShown() }
        if let ownKeysTop {
            // Full width to the bottom edge, like the iOS keyboard; the keys keep clear of the screen's edge
            // and corners there by the same margin the rest of this layout keeps.
            phoneKeys.frame = CGRect(x: 0, y: ownKeysTop, width: b.width, height: b.maxY - ownKeysTop)
            phoneKeys.bottomPadding = bottomInset
        }
        var padRegion = deck
        if showDeck {
            let hingeTop = halfOpen ? b.midY : screenFrame.maxY
            // Behind the bar too, so nothing shows through around it.
            let chassisTop = iPhoneKeys ? min(hingeTop, barTop) : hingeTop
            chassis.frame = CGRect(x: 0, y: chassisTop, width: b.width, height: b.maxY - chassisTop)
            let deckWidth = min(deck.width, 820) - 12
            // A real palm rest either side of the trackpad when there is room for one.
            // With the iOS keyboard mode the trackpad takes the full width instead.
            let padWidth = halfOpen && !iPhoneKeys ? deckWidth * 0.62 : deckWidth - 8
            if iPhoneKeys {
                proxy.bar.frame = CGRect(x: 0, y: barTop, width: b.width, height: barH)
                let top: CGFloat, bottom: CGFloat
                if pad {
                    // Pad mode: everything under the bar (and below the fold) is trackpad.
                    top = max(barTop + barH, hingeTop) + 8
                    bottom = deck.maxY - 2
                } else {
                    // Typing: whatever room is left between the Mac picture and the bar.
                    // Half open the iOS keyboard is shorter than the bottom half: the strip under the fold is trackpad too.
                    top = max(hingeTop, screenFrame.maxY) + (halfOpen ? 5 : 8)
                    bottom = barTop - (halfOpen ? 4 : 8)
                }
                let height = max(bottom - top, 0)
                trackpad.frame = CGRect(x: deck.midX - padWidth / 2, y: top, width: padWidth, height: height)
                trackpad.isHidden = height < (halfOpen && !pad ? 36 : 70)
                padRegion = trackpad.isHidden ? screenFrame : CGRect(x: deck.minX, y: top, width: deck.width, height: height)
            } else {
                let keyboardHeight = KeyboardView.height(forWidth: deckWidth, limit: deck.height * 0.68)
                keyboard.frame = CGRect(x: deck.midX - deckWidth / 2, y: deck.minY + 4, width: deckWidth, height: keyboardHeight)
                trackpad.frame = CGRect(x: deck.midX - padWidth / 2, y: keyboard.frame.maxY + 8, width: padWidth,
                                        height: max(deck.maxY - keyboard.frame.maxY - 10, 40))
            }
            proxy.frame = CGRect(x: deck.minX, y: deck.minY, width: 1, height: 1)
        }

        if landscapeKeys {
            let aspect = screenView.streamSize.width / max(screenView.streamSize.height, 1)
            let barTop: CGFloat
            if landscapeTyping {
                // Typing: the bar on the iOS keyboard's top, the Mac picture fitted on the left, a trackpad on the right.
                barTop = max((fakeKeyboardTop ?? keyboardTop ?? b.maxY - bottomInset) - barH, 0) // faked top wins (debug only)
                let height = max(barTop - 6, 0)
                screenFrame = CGRect(x: 0, y: 0, width: min(height * aspect, b.width), height: height)
                let left = screenFrame.maxX + 8
                let right = b.maxX - safe.right - 8
                let top: CGFloat = 8
                let bottom = barTop - 8
                trackpad.frame = CGRect(x: left, y: top, width: max(right - left, 0), height: max(bottom - top, 0))
                trackpad.isHidden = trackpad.frame.width < 150 || trackpad.frame.height < 70
                chassis.frame = CGRect(x: screenFrame.maxX, y: 0, width: b.width - screenFrame.maxX, height: b.height)
                padRegion = trackpad.isHidden ? screenFrame : trackpad.frame
            } else {
                // Keyboard put away: the bar along the bottom, the picture fitted in everything above it, no trackpad.
                barTop = max(b.maxY - bottomInset - barH, 0)
                screenFrame = CGRect(x: 0, y: 0, width: b.width, height: max(barTop - 4, 0))
                trackpad.isHidden = true
                chassis.frame = CGRect(x: 0, y: screenFrame.maxY, width: b.width, height: b.maxY - screenFrame.maxY)
                padRegion = screenFrame
            }
            screenView.frame = screenFrame
            keyboard.isHidden = true
            chassis.isHidden = false
            proxy.bar.isHidden = false
            proxy.bar.frame = CGRect(x: 0, y: barTop, width: b.width, height: barH)
            proxy.frame = CGRect(x: 0, y: barTop, width: 1, height: 1)
        }

        // App messages are the one thing the camera must not cover.
        let clear = screenFrame.inset(by: UIEdgeInsets(top: safe.top, left: safe.left, bottom: 0, right: safe.right))
        let labelSize = statusLabel.sizeThatFits(CGSize(width: clear.width - 48, height: .greatestFiniteMagnitude))
        statusLabel.frame = CGRect(x: clear.midX - labelSize.width / 2, y: clear.midY - labelSize.height / 2,
                                   width: labelSize.width, height: labelSize.height)
        let noticeSize = notice.sizeThatFits(CGSize(width: clear.width - 32, height: .greatestFiniteMagnitude))
        notice.frame = CGRect(x: clear.midX - noticeSize.width / 2, y: clear.minY + 8,
                              width: noticeSize.width, height: noticeSize.height)
        displayPanel.frame = b
        displayPanel.cardCenterY = showDeck || landscapeKeys ? padRegion.midY : b.midY
        reportDevice()
        scheduleTypingUpdate()
    }

    /// Outside layout, because showing or hiding the iOS keyboard lays the view out again.
    private func scheduleTypingUpdate() {
        guard !typingUpdateQueued else { return }
        typingUpdateQueued = true
        DispatchQueue.main.async { [weak self] in
            self?.typingUpdateQueued = false
            self?.updateTypingMode()
        }
    }

    private func render(phase: Client.Phase, problem: String?, ack: HelloAck?, status: HostStatus?) {
        if let ack, ack.streamWidth > 0, ack.streamHeight > 0 {
            screenView.streamSize = CGSize(width: ack.streamWidth, height: ack.streamHeight)
            displayPanel.update(ack)
            #if DEBUG
            if phase == .connected, UserDefaults.standard.bool(forKey: "showDisplayPanel"), displayPanel.isHidden { displayPanel.setOpen(true) }
            #endif
        }
        let name = model.pairing?.name ?? "your Mac"
        switch phase {
        case .connected:
            statusLabel.text = nil
        case .connecting:
            statusLabel.text = problem ?? "Connecting to \(name)"
        case .idle:
            statusLabel.text = nil
        }
        statusLabel.isHidden = statusLabel.text == nil
        screenView.alpha = phase == .connected ? 1 : 0.25

        if phase == .connected {
            lastReport = ""
            reportDevice()
            #if DEBUG
            // `-turnTo <1|2|3|4>`: ask for that orientation once, 2 s after connecting; any refusal lands in the posture report.
            let turnTo = UserDefaults.standard.integer(forKey: "turnTo")
            if !turnToDone, let target = UIInterfaceOrientation(rawValue: turnTo), target != .unknown {
                turnToDone = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, let scene = self.view.window?.windowScene else { return }
                    self.turn(to: target, in: scene)
                }
            }
            #endif
        }
        if phase != lastPhase {
            // A reconnect or a dropped link: the Mac's focus may have changed, and nothing may stay held.
            proxy.bar.releaseEverything()
            proxy.reset()
            lastPhase = phase
        }
        scheduleTypingUpdate()

        var warning: String?
        if phase == .connected, let status {
            if !status.canCapture, ack?.testPattern != true {
                warning = "Screen Recording is off on the Mac. Open Clamshell Host there and allow it."
            } else if !status.canControl {
                warning = "The Mac has not allowed control yet. Open Clamshell Host there and allow Accessibility."
            }
        }
        notice.text = warning
        notice.isHidden = warning == nil
        if phase != .connected {
            if !displayPanel.isHidden { displayPanel.setOpen(false) }
            hardwareRepeater.stopAll()
            hardwareDown.removeAll()
        }
        view.setNeedsLayout()
    }

    // MARK: Menu

    private func toggleDisplayPanel() {
        guard displayPanel.isAvailable else { return }
        displayPanel.setOpen(displayPanel.isHidden)
    }

    private func menuItems() -> [UIMenuElement] {
        var title = demo != nil ? "Demo Mac" : model.pairing?.name ?? "Mac"
        if let ms = client.latencyMs, client.phase == .connected { title += "  \(ms) ms" }
        let header = UIAction(title: title, attributes: .disabled) { _ in }

        let display = UIAction(title: "Display", image: UIImage(systemName: "display"),
                               attributes: displayPanel.isAvailable ? [] : .disabled) { [weak self] _ in
            self?.toggleDisplayPanel()
        }

        let paste = UIAction(title: "Type iPhone clipboard on the Mac", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in
            guard let self, let text = UIPasteboard.general.string, !text.isEmpty else { return }
            // The Mac types it at a steady pace, so a whole book would type for minutes: refuse it here.
            if text.utf8.count > Self.clipboardLimit, text.count > Self.clipboardLimit {
                let alert = UIAlertController(title: "That is too much to type.",
                                              message: "Copy 200,000 characters or fewer.", preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .cancel))
                self.present(alert, animated: true)
                return
            }
            self.client.send(.text(text))
        }
        let saver = UserDefaults.standard.bool(forKey: "dataSaver")
        let dataSaver = UIAction(title: "Data saver", image: UIImage(systemName: "antenna.radiowaves.left.and.right"),
                                 state: saver ? .on : .off) { [weak self] _ in
            UserDefaults.standard.set(!saver, forKey: "dataSaver")
            self?.client.reconnect()
        }
        let haptics = UIAction(title: "Haptic clicks", image: UIImage(systemName: "hand.tap"),
                               state: Haptics.shared.enabled ? .on : .off) { _ in
            Haptics.shared.enabled.toggle()
            Haptics.shared.play(.click)
        }
        let reconnect = UIAction(title: "Reconnect", image: UIImage(systemName: "arrow.clockwise")) { [weak self] _ in
            self?.client.reconnect()
        }
        let forget = UIAction(title: "Forget this Mac", image: UIImage(systemName: "trash"), attributes: .destructive) { [weak self] _ in
            self?.confirmForget()
        }
        let soundOn = UserDefaults.standard.object(forKey: "macSound") as? Bool ?? true
        let sound = UIAction(title: "Mac sound", image: UIImage(systemName: "speaker.wave.2"), state: soundOn ? .on : .off) { [weak self] _ in
            UserDefaults.standard.set(!soundOn, forKey: "macSound")
            self?.client.reconnect()
        }
        var items: [UIMenuElement] = [header, display, trackpadMenu(), keyboardMenu(), sound, paste, haptics, dataSaver, reconnect, forget]
        if demo != nil {
            // No sound, link or pairing to manage: the way out comes first instead.
            let end = UIAction(title: "End demo", image: UIImage(systemName: "xmark.circle")) { [weak self] _ in
                self?.model.endDemo()
            }
            items = [end, header, display, trackpadMenu(), keyboardMenu(), paste, haptics]
        }
        let posture = demo != nil ? 5 : 4
        if hingeHalfOpen {
            items.insert(UIAction(title: "Flip top and bottom", image: UIImage(systemName: "arrow.up.arrow.down")) { [weak self] _ in
                self?.flipLaptop()
            }, at: posture)
        } else {
            items.insert(UIAction(title: "Turn upside down", image: UIImage(systemName: "arrow.triangle.2.circlepath")) { [weak self] _ in
                self?.turnAround()
            }, at: posture)
        }
        return items
    }

    /// The drawn phone keys' strip and shift follow a settings change (when hidden, they catch up as they come up).
    private func refreshPhoneKeys() {
        if !phoneKeys.isHidden { phoneTyping.refresh() }
    }

    /// The drawn Mac keyboard, or the iOS keyboard with autocorrect, predictions, swipe typing and dictation.
    private func keyboardMenu() -> UIMenu {
        UIMenu(title: "Keyboard", image: UIImage(systemName: "keyboard"), children: [
            UIAction(title: "iPhone keyboard", state: iPhoneStyle ? .on : .off) { [weak self] _ in
                guard let self else { return }
                self.setKeyboardStyle(iPhone: !self.iPhoneStyle)
            },
            UIAction(title: "Autocorrect", state: proxy.autocorrect ? .on : .off) { [weak self] _ in
                self?.proxy.autocorrect.toggle()
                self?.refreshPhoneKeys()
            },
            UIAction(title: "Auto-capitalize", state: proxy.autoCapitalize ? .on : .off) { [weak self] _ in
                self?.proxy.autoCapitalize.toggle()
                self?.refreshPhoneKeys()
            },
        ])
    }

    /// Trackpad settings, like the Point & Click pane on a Mac. The trackpad reads them
    /// when a finger lands, so a change takes effect on the next touch.
    private func trackpadMenu() -> UIMenu {
        let d = UserDefaults.standard
        func flag(_ key: String) -> Bool { d.object(forKey: key) == nil ? true : d.bool(forKey: key) }
        func toggle(_ title: String, _ key: String, disabled: Bool = false) -> UIAction {
            let on = flag(key)
            return UIAction(title: title, attributes: disabled ? .disabled : [], state: on ? .on : .off) { _ in
                d.set(!on, forKey: key)
            }
        }
        let pressure = d.object(forKey: "clickPressure") == nil ? 1 : min(max(d.integer(forKey: "clickPressure"), 0), 2)
        let levels = ["Light", "Medium", "Firm"].enumerated().map { index, title in
            UIAction(title: title, state: index == pressure ? .on : .off) { _ in d.set(index, forKey: "clickPressure") }
        }
        return UIMenu(title: "Trackpad", image: UIImage(systemName: "hand.point.up.left"), children: [
            toggle("Tap to click", "tapToClick"),
            toggle("Press to click", "pressToClick"),
            toggle("Force Click", "forceClick", disabled: !flag("pressToClick")),
            UIMenu(title: "Click pressure", options: .displayInline, children: levels),
        ])
    }

    /// Longest clipboard "Type iPhone clipboard on the Mac" sends, in characters.
    private static let clipboardLimit = 200_000

    private func confirmForget() {
        let alert = UIAlertController(title: "Forget this Mac?", message: "You will need to scan the code on the Mac again.",
                                      preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Forget", style: .destructive) { [weak self] _ in self?.model.forget() })
        present(alert, animated: true)
    }

    // MARK: Hardware keyboard

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let code = HardwareKeys.macCode(for: key.keyCode) else {
                unhandled.insert(press)
                continue
            }
            if proxy.isFirstResponder {
                // The hidden text field types characters itself; only keys it cannot type go straight to the Mac.
                guard HardwareKeys.isNavigation(code) else {
                    unhandled.insert(press)
                    continue
                }
                proxy.reset()
            } else if !phoneKeys.isHidden {
                proxy.reset() // the drawn phone keys' buffer no longer matches what is around the Mac's cursor
            }
            hardwareDown.insert(code)
            client.send(.key(code: code, down: true, isRepeat: false))
            if !HardwareKeys.isModifier(code) {
                hardwareRepeater.start(Int(code)) { [weak self] in
                    self?.client.send(.key(code: code, down: true, isRepeat: true))
                }
            }
        }
        if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        var unhandled = Set<UIPress>()
        for press in presses {
            guard let key = press.key, let code = HardwareKeys.macCode(for: key.keyCode) else {
                unhandled.insert(press)
                continue
            }
            if proxy.isFirstResponder, !hardwareDown.contains(code) {
                unhandled.insert(press) // its press went to the text field too
                continue
            }
            hardwareRepeater.stop(Int(code))
            if hardwareDown.remove(code) != nil {
                client.send(.key(code: code, down: false, isRepeat: false))
            }
        }
        if !unhandled.isEmpty { super.pressesEnded(unhandled, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        pressesEnded(presses, with: event)
    }
}

/// A small rounded warning shown over the top of the Mac screen.
final class NoticeLabel: UILabel {
    private let inset = UIEdgeInsets(top: 7, left: 12, bottom: 7, right: 12)

    override init(frame: CGRect) {
        super.init(frame: frame)
        numberOfLines = 0
        textAlignment = .center
        font = .systemFont(ofSize: 12, weight: .medium)
        textColor = .black
        backgroundColor = UIColor(white: 1, alpha: 0.92)
        layer.cornerRadius = 10
        layer.cornerCurve = .continuous
        layer.masksToBounds = true
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: inset))
    }

    override func sizeThatFits(_ size: CGSize) -> CGSize {
        let inner = super.sizeThatFits(CGSize(width: size.width - inset.left - inset.right, height: size.height))
        return CGSize(width: inner.width + inset.left + inset.right, height: inner.height + inset.top + inset.bottom)
    }
}

/// USB HID usage codes (what a Bluetooth or Smart keyboard reports) to macOS virtual key codes.
enum HardwareKeys {
    private static let table: [Int: UInt16] = {
        var t: [Int: UInt16] = [:]
        let letters: [UInt16] = [0, 11, 8, 2, 14, 3, 5, 4, 34, 38, 40, 37, 46, 45, 31, 35, 12, 15, 1, 17, 32, 9, 13, 7, 16, 6]
        for (i, code) in letters.enumerated() { t[0x04 + i] = code }
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        for (i, code) in digits.enumerated() { t[0x1E + i] = code }
        let functionKeys: [UInt16] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in functionKeys.enumerated() { t[0x3A + i] = code }
        let rest: [Int: UInt16] = [
            0x28: 36, 0x29: 53, 0x2A: 51, 0x2B: 48, 0x2C: 49, 0x2D: 27, 0x2E: 24, 0x2F: 33, 0x30: 30, 0x31: 42,
            0x33: 41, 0x34: 39, 0x35: 50, 0x36: 43, 0x37: 47, 0x38: 44, 0x39: 57,
            0x4A: 115, 0x4B: 116, 0x4C: 117, 0x4D: 119, 0x4E: 121, 0x4F: 124, 0x50: 123, 0x51: 125, 0x52: 126,
            0xE0: 59, 0xE1: 56, 0xE2: 58, 0xE3: 55, 0xE4: 62, 0xE5: 60, 0xE6: 61, 0xE7: 54,
        ]
        t.merge(rest) { $1 }
        return t
    }()

    static func macCode(for usage: UIKeyboardHIDUsage) -> UInt16? {
        table[usage.rawValue]
    }

    static func isModifier(_ code: UInt16) -> Bool {
        [54, 55, 56, 57, 58, 59, 60, 61, 62].contains(code)
    }

    /// Escape, arrows, Home, End, Page Up and Down, forward delete and F1 to F12: keys that type no text.
    static func isNavigation(_ code: UInt16) -> Bool {
        [53, 115, 116, 117, 119, 121, 123, 124, 125, 126,
         122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111].contains(code)
    }
}

/// The Space Black aluminium under the keyboard.
final class ChassisView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let gradient = layer as! CAGradientLayer
        gradient.colors = [UIColor(red: 0.190, green: 0.186, blue: 0.200, alpha: 1).cgColor,
                           UIColor(red: 0.150, green: 0.148, blue: 0.160, alpha: 1).cgColor]
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
